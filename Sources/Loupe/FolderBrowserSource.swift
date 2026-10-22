import AppKit
import HomeScreenKit
import LoupeCore

extension Notification.Name {
    /// A share that was offline answered again (`ThumbnailStore.setOnVolumeAnswered`); the object is its key (`String`).
    /// Posted on the main thread; every window's Home asks again for that share's dimmed cards.
    static let coverVolumeAnswered = Notification.Name("local.loupe.coverVolumeAnswered")
}

/// Home's Folders tab on Loupe's data (file browser spec §4.2): listings from `BrowserListingSource` (the last eight
/// kept in memory, so Back and Up show at once), a `FolderWatcher` on the open folder, thumbnails from the strip's
/// store (the folder's files as one more window's request), folder and zip cards from the store's cover queue (folder
/// covers and folder cards specs: the cover and the facts), the sort and the card style in folder settings, and rename
/// and Trash through `BrowserFileActions`.
@MainActor final class FolderBrowserSource {
    weak var view: HomeBrowserView?
    /// Opens a photo, a folder or a zip in the viewer, here or in a new tab or window.
    var onOpen: ((OpenTarget, HomeClick) -> Void)?
    /// A folder was pinned or unpinned: the sidebar's places change.
    var onPlacesChanged: (() -> Void)?
    /// Asks before deleting for good (a volume without a Trash); the answer comes back on the main actor.
    var confirmDelete: ((String, @escaping (Bool) -> Void) -> Void)?

    private let thumbnails: ThumbnailStore
    private let places: BrowserPlaces
    private let settings: FolderSettings?
    private let positions: FolderPositions
    private let actions: BrowserFileActions
    /// The thumbnail store's id for the browser's request: apart from every viewer session's.
    private let thumbnailWindow: Int
    private static var nextWindow = 1 << 40

    /// Which listing is still wanted: one of a place the user has left delivers nothing.
    private var gate = BrowserListingGate()
    /// The last complete listings, newest last.
    private var memory: [(path: String, listing: BrowserListing)] = []
    private static let memoryLimit = 8
    /// The entries of the place on screen, by id.
    private var shown: [String: BrowserEntry] = [:]
    private var shownFiles: [URL] = []
    private var stamps: [URL: FileStamp] = [:]
    private let watcher = FolderWatcher()
    private var watchChanges: AsyncStream<Void>.Continuation?
    /// Pictures asked for that were not made yet: they come with the store's `thumbnailChanged`.
    private var waiting: [URL: String] = [:]
    private var pictureTask: Task<Void, Never>?
    private var maxPixel = 440

    /// How a folder's or zip's card shows its photos (`folder-cover`); a change makes every cover again.
    var coverLayout = HomeMosaic.Layout.hero {
        didSet { if coverLayout != oldValue { remakeCovers() } }
    }
    /// The mosaics kept for cards asked for again (`CoverCards`). A mosaic is a card's pixels squared, ~2 MB for a
    /// 352 pt card at 2x: the budget is the folder's cards times that (`CoverCards.limit`), 32 MB at least and 256 MB
    /// at most, set on each ask.
    /// The folder on screen, for its cards' covers, and where the catalog keeps its files: resolved once, off the main
    /// thread (`ThumbnailStore.shownFolderPlace`); nil while it is being resolved.
    private var coverFolder: String?
    private var coverPlace: CoverPlace?
    private var placeTask: Task<Void, Never>?
    /// The folder's cards' covers: those kept, and the cards still waiting for one.
    private var cards = CoverCards(limitBytes: CoverCards.limit(cards: 0, pixels: 0))
    /// The cards' size in points and the screen's scale, as last asked.
    private var coverSize: (width: CGFloat, scale: CGFloat)?
    /// The last call to the cover queue sent: each goes after it, so the queue sees them in order.
    private var coverSend: Task<Void, Never>?
    /// The share the folder on screen is on (`ThumbnailStore.networkVolume`, from the mount table, off the main
    /// thread); nil on a local volume or while it is being resolved. Which dimmed cards a share's return wakes.
    private var coverShare: String?
    /// What the cover queue told about the folder's cards (folder cards spec): kept while the folder is on screen, so a
    /// card laid out again, or Home shown again after the viewer, gets its facts at once, with the visit as it is now.
    private var facts: [String: FolderCardFacts] = [:]
    /// Cards that have their picture but whose work is not done: the summary is still to be listed
    /// (`FolderCard.summaryPending`), the card is offline without pictures, or its share came back. They go to the cover
    /// queue with the browser's asks while they are in its live area (after the cards in view waiting for a picture),
    /// once the folder's complete listing has come, until their work is done or the folder changes.
    private var followUps: Set<String> = []
    /// The folder and zip cards of the browser's last ask, in its order (those in view first), and those in view.
    private var lastAsked: [String] = []
    private var lastInView: Set<String> = []
    /// The entries on screen come from a complete listing (`BrowserListingSource.full`): its folders have their dates.
    /// Until then a card's picture is made (it needs none), but no summary is listed for it (`followUps` wait): one
    /// counted without the folder's date would never be fresh.
    private var shownDated = false
    private var observers: [NSObjectProtocol] = []

    init(thumbnails: ThumbnailStore, places: BrowserPlaces, settings: FolderSettings?, positions: FolderPositions,
         stores: [any PathMoving]) {
        self.thumbnails = thumbnails
        self.places = places
        self.settings = settings
        self.positions = positions
        actions = BrowserFileActions(stores: stores)
        thumbnailWindow = Self.nextWindow
        Self.nextWindow += 1
        watcher.onChange = { [weak self] _ in self?.watchChanges?.yield() }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .thumbnailChanged, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let url = note.object as? URL else { return }
                self?.thumbnailChanged(url)
            }
        })
        observers.append(center.addObserver(forName: .coverVolumeAnswered, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let volume = note.object as? String else { return }
                self?.shareAnswered(volume)
            }
        })
    }

    /// The tab hid or the window closed: no polls, no thumbnails for it.
    var isPaused = false {
        didSet {
            watcher.isPaused = isPaused
            guard isPaused else {
                // Back from the viewer: the visits and the two-page keys may have changed.
                showSummaries()
                return sendCovers()
            }
            // Nothing of the browser's goes on reading while the viewer shows what was clicked.
            pictureTask?.cancel()
            waiting.removeAll()
            Task { [thumbnails, thumbnailWindow] in await thumbnails.setRequest(window: thumbnailWindow, nil, stamps: [:]) }
            // Those made stay made (`cards`): back on Home, only the cards still waiting are sent again.
            stopQueuedCovers()
        }
    }

    /// The browser went to one of Home's own sources: no listing, watch or thumbnails of the folder left.
    func leave() {
        _ = gate.begin(nil)
        stopWatching()
        showCovers(of: nil)
        pictureTask?.cancel()
        waiting.removeAll()
        Task { [thumbnails, thumbnailWindow] in await thumbnails.setRequest(window: thumbnailWindow, nil, stamps: [:]) }
    }

    func stop() {
        isPaused = true
        _ = gate.begin(nil)
        stopWatching()
        showCovers(of: nil)
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    // MARK: Places

    /// The home folder, the volumes and the pins, each dimmed when it does not answer within a second. Nothing of the
    /// browser's changes: the sidebar and the path's menus ask too, while a folder is listing.
    func places() async -> [BrowserEntry] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let volumes = await Task.detached { BrowserListingSource.volumes() }.value
        return await BrowserListingSource.places(pins: places.pins(), home: home, volumes: volumes)
    }

    func parent(of folder: URL) -> BrowserLocation { BrowserListingSource.parent(of: folder) }

    /// The folders and zips in `folder` for the path's sibling menu: from a listing kept in memory, else names only off
    /// the main thread (no stat, so a slow share answers as soon as it can); a cancelled request stops at the next part.
    func folders(in folder: URL) async -> [BrowserEntry] {
        let path = folder.standardizedFileURL.path
        if let kept = memory.last(where: { $0.path == path })?.listing { return kept.entries.filter(\.isContainer) }
        let archives = Settings.shared.config.archiveFolders
        let task = Task.detached(priority: .userInitiated) {
            (try? BrowserListingSource.names(folder, archives: archives) { _ in !Task.isCancelled }) ?? []
        }
        return await withTaskCancellationHandler {
            await task.value.filter(\.isContainer)
        } onCancel: {
            task.cancel()
        }
    }

    func symbol(for entry: BrowserEntry) -> String {
        switch entry.kind {
        case .folder: return "folder"
        case .archive: return "doc.zipper"
        case .file: return "photo"
        case .collection: return "rectangle.stack"
        case .place:
            if entry.url.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL { return "house" }
            if BrowserListingSource.parent(of: entry.url) == .places { return "externaldrive" }
            return "pin"
        }
    }

    // MARK: Listings

    func list(_ location: BrowserLocation) -> AsyncThrowingStream<BrowserListing, Error> {
        switch location {
        case .places: listPlaces()
        case .folder(let folder): list(folder)
        case .source: AsyncThrowingStream { $0.finish() }
        }
    }

    /// The places as `places()` gives them, then with each one's free space (`1.2 TB free`), asked off the main
    /// thread for a second at most: a share that does not answer keeps its card without it.
    private func listPlaces() -> AsyncThrowingStream<BrowserListing, Error> {
        // The Places page is the browser's place now: a folder's listing and watch stop.
        let token = gate.begin(nil)
        stopWatching()
        showCovers(of: nil)
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor [weak self] in
                guard let entries = await self?.places(), let self, !Task.isCancelled, self.gate.isCurrent(token) else { return }
                self.remember(entries)
                continuation.yield(BrowserListing(entries: entries, complete: true))
                let space = await BrowserPlaces.freeSpace(of: entries.filter { !$0.isDimmed }.map(\.url), timeout: .seconds(1))
                if !space.isEmpty, !Task.isCancelled, self.gate.isCurrent(token) {
                    let spaced = entries.map { e in
                        var e = e
                        e.subtitle = space[e.url].map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) + " free" }
                        return e
                    }
                    continuation.yield(BrowserListing(entries: spaced, complete: true))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func list(_ folder: URL) -> AsyncThrowingStream<BrowserListing, Error> {
        let path = folder.standardizedFileURL.path
        let remembered = memory.last { $0.path == path }?.listing
        let archives = Settings.shared.config.archiveFolders
        let token = gate.begin(path)
        stopWatching()
        // A zip's listing is its photos: no cards with covers.
        showCovers(of: ArchivePath.isArchive(folder) ? nil : folder)
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor [weak self] in
                /// Still the place on screen: else nothing of this listing reaches the source's state or the view.
                @MainActor func wanted() -> Bool { !Task.isCancelled && self?.gate.isCurrent(token) == true }
                @MainActor func deliver(_ listing: BrowserListing) { if wanted() { self?.deliver(listing, to: continuation) } }
                if let remembered { deliver(remembered) }
                do {
                    let started = ContinuousClock.now
                    for try await listing in BrowserListingSource.listings(folder, archives: archives) {
                        guard let self, wanted() else { return }
                        deliver(listing)
                        if listing.complete {
                            self.keep(listing, for: path)
                            self.keepSummary(of: folder, listing.entries)
                            self.watcher.listed(in: ContinuousClock.now - started, succeeded: true)
                            if let counted = await self.counted(listing), wanted() {
                                deliver(counted)
                                self.keep(counted, for: path)
                            }
                        }
                    }
                    guard let self, wanted(), !ArchivePath.isArchive(folder) else { return }
                    let (changes, sink) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
                    self.watchChanges = sink
                    self.watcher.watch(folder)
                    for await _ in changes {
                        let started = ContinuousClock.now
                        do {
                            let entries = try await Task.detached { try BrowserListingSource.full(folder, archives: archives) }.value
                            guard wanted() else { return }
                            let listing = BrowserListing(entries: entries, complete: true)
                            deliver(listing)
                            self.keep(listing, for: path)
                            self.keepSummary(of: folder, entries)
                            self.watcher.listed(in: ContinuousClock.now - started, succeeded: true)
                        } catch {
                            guard wanted() else { return }
                            self.watcher.listed(in: ContinuousClock.now - started, succeeded: false)
                            await self.folderGone(folder)
                            return
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { @MainActor [weak self] in
                    guard let self, self.gate.isCurrent(token) else { return }
                    self.stopWatching()
                }
            }
        }
    }

    /// No more polls or relists of the folder left.
    private func stopWatching() {
        watchChanges?.finish()
        watchChanges = nil
        watcher.stop()
    }

    private func deliver(_ listing: BrowserListing, to continuation: AsyncThrowingStream<BrowserListing, Error>.Continuation) {
        remember(listing.entries)
        let wasDated = shownDated
        shownDated = listing.complete
        continuation.yield(listing)
        guard listing.complete, !wasDated else { return }
        // The cards now have their folders' dates (a stored summary is fresh only at its folder's date): the summaries
        // waiting for them go to the cover queue, at once.
        sendCovers()
        let ready = Array(followUps)
        if !ready.isEmpty { sendToQueue { queue, client in await queue.forget(ready, client: client) } }
    }

    /// The entries on screen: what `wantImages` and the menus look up by id.
    private func remember(_ entries: [BrowserEntry]) {
        shown = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        shownFiles = entries.filter { $0.kind == .file }.map(\.url)
        stamps = [:]
        for e in entries where e.kind == .file {
            if let date = e.date, let size = e.size { stamps[e.url] = FileStamp(modified: date, size: Int(size)) }
        }
    }

    private func keep(_ listing: BrowserListing, for path: String) {
        memory.removeAll { $0.path == path }
        memory.append((path, listing))
        if memory.count > Self.memoryLimit { memory.removeFirst() }
    }

    private func forget(_ folder: URL) {
        let path = folder.standardizedFileURL.path
        memory.removeAll { $0.path == path }
    }

    /// The open folder's summary from its complete listing (which has the photos' dates and sizes, on a share too): the
    /// store counts it and keeps it in the catalog, off the main thread, so the folder's card has it when it is next
    /// shown. A zip's card has its own from the zip's directory.
    private func keepSummary(of folder: URL, _ entries: [BrowserEntry]) {
        let thumbnails = self.thumbnails
        guard !ArchivePath.isArchive(folder) else {
            // A zip's listing on a share is the share's answer too (a folder's is told by its summary).
            Task.detached(priority: .utility) {
                guard ThumbnailStore.networkVolume(folder) != nil else { return }   // the mount table: never hangs
                await thumbnails.volumeAnswered(folder, in: nil)
            }
            return
        }
        Task.detached(priority: .utility) { await thumbnails.putOpenFolderSummary(folder, listing: entries) }
    }

    /// The listing with the photo counts the catalog knows for its folders; nil when it knows none.
    private func counted(_ listing: BrowserListing) async -> BrowserListing? {
        let folders = listing.entries.filter { $0.kind != .file }.map(\.url)
        guard !folders.isEmpty else { return nil }
        let counts = await thumbnails.knownCounts(folders)
        guard !counts.isEmpty else { return nil }
        var counted = listing
        for i in counted.entries.indices { counted.entries[i].count = counts[counted.entries[i].url] }
        return counted
    }

    /// The open folder went away: up to the nearest folder that is still there.
    private func folderGone(_ folder: URL) async {
        let ancestor = await Task.detached { () -> URL? in
            var at = folder.deletingLastPathComponent()
            while at.path != "/" {
                if FileManager.default.fileExists(atPath: at.path) { return at }
                at = at.deletingLastPathComponent()
            }
            return nil
        }.value
        forget(folder)
        view?.show(ancestor.map { .folder($0) } ?? .places, selecting: nil)
        view?.showToast("Folder unavailable: \(folder.path)")
    }

    // MARK: Pictures

    func wantImages(_ ids: [String], width: CGFloat) { wantImages(ids, visible: ids.count, width: width) }

    /// The first `visible` of `ids` are in view, the rest is the margin around it. Photos come from the strip's store,
    /// those in view first; folder and zip cards go to the cover queue.
    func wantImages(_ ids: [String], visible: Int, width: CGFloat) {
        let scale = view?.window?.backingScaleFactor ?? 2
        maxPixel = Int((width * scale).rounded())
        let wanted = ids.compactMap { shown[$0] }
        let inView = Set(ids.prefix(visible))
        let files = wanted.filter { $0.kind == .file }
        sendRequest(ThumbnailRequest.inViewFirst(files.map(\.url), inView: Set(files.filter { inView.contains($0.id) }.map(\.url))))
        let cardIDs = wanted.filter { $0.kind == .folder || $0.kind == .archive }.map(\.id)
        // Another card size or screen: the mosaics kept and those being made are the wrong size.
        if let size = coverSize, size.width != width || size.scale != scale { dropCovers() }
        coverSize = (width, scale)
        let liveCards = shown.values.reduce(0) { $0 + ($1.kind == .folder || $1.kind == .archive ? 1 : 0) }
        cards.setLimit(CoverCards.limit(cards: liveCards, pixels: Int((width * scale).rounded())))
        let ask = cards.ask(cardIDs, visible: cardIDs.filter(inView.contains).count)
        lastAsked = cardIDs
        lastInView = Set(cardIDs.filter(inView.contains))
        for (id, image) in ask.cached { view?.setImage(image, for: id) }
        // A card laid out again has lost its facts in the view too.
        for id in cardIDs where facts[id] != nil { showSummary(id) }
        if !ask.forget.isEmpty {
            let forget = ask.forget
            sendToQueue { queue, client in await queue.forget(forget, client: client) }
        }
        sendCovers()
        pictureTask?.cancel()
        let maxPixel = maxPixel
        pictureTask = Task { @MainActor [weak self] in
            for entry in files {
                guard let self, !Task.isCancelled else { return }
                if let image = await self.thumbnails.cell(entry.url, maxPixel: maxPixel) {
                    self.view?.setImage(image, for: entry.id)
                } else {
                    self.waiting[entry.url.standardizedFileURL] = entry.id
                }
            }
        }
    }

    // MARK: Covers

    /// The folder on screen changed (nil: none, the places or one of Home's own sources): the old one's covers stop
    /// and the new one is resolved, off the main thread, for its cards' (`ThumbnailStore.shownFolderPlace`).
    private func showCovers(of folder: URL?) {
        let path = folder?.standardizedFileURL.path
        guard path != coverFolder else { return }
        placeTask?.cancel()
        placeTask = nil
        coverFolder = path
        coverPlace = nil
        coverShare = nil
        cards.reset()
        facts = [:]
        followUps = []
        lastAsked = []
        lastInView = []
        stopQueuedCovers()
        guard let folder, let path else { return }
        let thumbnails = self.thumbnails
        placeTask = Task { @MainActor [weak self] in
            let place = await thumbnails.shownFolderPlace(folder)
            let share = await Task.detached(priority: .utility) { ThumbnailStore.networkVolume(folder) }.value
            guard let self, !Task.isCancelled, self.coverFolder == path, place != .notNow else { return }
            self.coverPlace = place
            self.coverShare = share
            self.sendCovers()
        }
    }

    /// The folder and zip cards still waiting for a cover, then those waiting for the rest of their facts
    /// (`followUps`), to the store's cover queue, once the folder on screen is resolved. Each card's work
    /// (`ThumbnailStore.folderCard`, off the main thread: from the catalog or the pick remembered when they have the
    /// photos, else from a listing) makes its cover in the chosen layout and brings its facts: the summary, and the
    /// stored summaries of its subfolders (`ThumbnailStore.childSummaries`, one catalog query). The main thread only
    /// puts them together (`showSummary`). Nil from the store is "not now", and the queue tries again later; so is a
    /// card whose summary is still to be listed, or that is offline without pictures (the queue asks again at its pace,
    /// and a share that answers asks at once: `shareAnswered`).
    private func sendCovers() {
        guard !isPaused, let place = coverPlace, let size = coverSize, let folderPath = coverFolder else { return }
        let shownLocation: ThumbnailLocation?, network: Bool
        switch place {
        case .located(let location): (shownLocation, network) = (location, location.isNetwork)
        case .unknown(let onShare): (shownLocation, network) = (nil, onShare)
        case .notNow: return
        }
        let pending = cards.pending, visiblePending = cards.visiblePending
        let waiting = Set(pending)
        // The follow-ups of the last ask (the live area: a card scrolled away waits until it is asked for again), in
        // its order, those in view with the cards in view; none before the folders' dates have come.
        let asked = shownDated ? lastAsked.filter { followUps.contains($0) && !waiting.contains($0) } : []
        let inView = asked.filter(lastInView.contains)
        let ids = Array(pending.prefix(visiblePending)) + inView + pending.dropFirst(visiblePending)
            + asked.filter { !lastInView.contains($0) }
        let visible = visiblePending + inView.count
        let layout = coverLayout, side = size.width, scale = size.scale
        let cellPixels = layout.cellPixels(width: side, scale: scale)
        let thumbnails = self.thumbnails
        /// The card as it is when its work starts (a want sent before the complete listing runs after it too): its
        /// entry (with its folder's date once the listing is complete), its remembered photo (a zip's entry name is
        /// one path component already), whether the entries are dated, and whether it still wants its picture (a
        /// follow-up's is on screen, or kept). Nil: no longer this folder's.
        let lookup: @MainActor (String) -> (entry: BrowserEntry, lastViewed: String?, dated: Bool, picture: Bool)? = {
            [weak self] id in
            guard let self, self.coverFolder == folderPath, let entry = self.shown[id] else { return nil }
            return (entry, self.positions.fileName(in: entry.url), self.shownDated, self.cards.pending.contains(id))
        }
        let deliver: @MainActor (String, CGImage?, FolderCardFacts, Bool) -> Void = { [weak self] id, mosaic, facts, again in
            guard let self, self.coverFolder == folderPath, self.shown[id] != nil else { return }
            self.keepFacts(facts, for: id, again: again)
            // A mosaic of another layout or size is not kept.
            guard let mosaic, self.coverLayout == layout, self.coverSize?.width == side,
                  self.coverSize?.scale == scale else { return }
            self.cards.delivered(id, mosaic)
            self.view?.setImage(mosaic, for: id)
        }
        let work: @Sendable (String) async -> Bool = { id in
            guard let card = await lookup(id) else { return true }
            let entry = card.entry
            // Only its summary is wanted: that waits for the folder's date (`shownDated`), which brings it back.
            guard card.picture || card.dated else { return false }
            let location = shownLocation?.subfolder(entry.url.lastPathComponent)
            guard let made = await thumbnails.folderCard(entry.url, archive: entry.kind == .archive, in: location,
                                                         network: network, maxPixel: cellPixels,
                                                         lastViewed: card.lastViewed, modified: entry.date) else { return false }
            guard !Task.isCancelled else { return true }
            var inside: ChildSummaries?
            if let location, let summary = made.summary, summary.folders > 0 {
                inside = await thumbnails.childSummaries(of: location)
            }
            let facts = FolderCardFacts(summary: made.summary, inside: inside, photoDates: made.photoDates,
                                        problem: made.problem)
            // No photos: the card keeps its symbol.
            var mosaic: CGImage?
            if card.picture, !made.images.isEmpty {
                mosaic = HomeMosaic.make(made.images, size: CGSize(width: side, height: side), layout: layout, scale: scale)
            }
            let again = made.summaryPending || (made.problem == .offline && made.images.isEmpty)
            guard !Task.isCancelled else { return true }
            await deliver(id, mosaic, facts, again)
            return !again
        }
        sendToQueue { queue, client in
            await queue.want(ids, visible: visible, client: client, isNetwork: { _ in network }, work: work)
        }
    }

    /// A card's facts from the cover queue: kept, and shown. Without this pass's dates (the summary came from the
    /// catalog) the dates of an earlier pass at the same folder date stay, for "+N new" by date.
    private func keepFacts(_ new: FolderCardFacts, for id: String, again: Bool) {
        var new = new
        if new.photoDates == nil, let old = facts[id], let date = old.summary?.folderModified,
           date == new.summary?.folderModified {
            new.photoDates = old.photoDates
        }
        facts[id] = new
        if again { followUps.insert(id) } else { followUps.remove(id) }
        showSummary(id)
    }

    /// The card's facts with its visit and two-page keys as they are now (folder settings and positions are in memory).
    private func showSummary(_ id: String) {
        guard let entry = shown[id], let facts = facts[id] else { return }
        let config = FolderCardFacts.config(for: entry.url, base: Settings.shared.config, settings: settings)
        view?.setSummary(facts.cardSummary(visit: positions.visit(in: entry.url), config: config), for: id)
    }

    /// Every card's facts again (back from the viewer: a visit or the two-page keys may have changed). The view keeps
    /// only those in its listing, and redraws only those that changed.
    private func showSummaries() {
        for id in facts.keys { showSummary(id) }
    }

    /// A share that was offline answered (`ThumbnailStore.setOnVolumeAnswered`): the cards of the folder on screen
    /// that are on it and dimmed, or still waiting, are asked for again at once.
    private func shareAnswered(_ volume: String) {
        guard let place = coverPlace else { return }
        let location: ThumbnailLocation?
        if case .located(let shown) = place { location = shown } else { location = nil }
        func isOn(_ id: String) -> Bool {
            guard let entry = shown[id] else { return false }
            return ThumbnailStore.cardIsOn(volume, location: location?.subfolder(entry.url.lastPathComponent),
                                           share: coverShare)
        }
        let dimmed = facts.filter { $0.value.problem == .offline }.keys.filter(isOn)
        let waiting = (cards.pending + Array(followUps)).filter(isOn)
        guard !dimmed.isEmpty || !waiting.isEmpty else { return }
        followUps.formUnion(dimmed)
        // Paused (the viewer on screen), the queue holds none of these cards: they go with the next `sendCovers`.
        guard !isPaused else { return }
        sendCovers()
        let again = Array(Set(dimmed + waiting))
        sendToQueue { queue, client in await queue.forget(again, client: client) }
    }

    /// None of this browser's cards in the cover queue: those running are cancelled, those made forgotten.
    private func stopQueuedCovers() {
        sendToQueue { queue, client in await queue.want([], visible: 0, client: client, isNetwork: { _ in false }) { _ in true } }
    }

    /// `call` on the store's cover queue as this browser (its client id is the browser's thumbnail window), after the
    /// calls sent before it.
    private func sendToQueue(_ call: @escaping @Sendable (CoverQueue, Int) async -> Void) {
        let queue = thumbnails.coverQueue, client = thumbnailWindow, previous = coverSend
        coverSend = Task {
            await previous?.value
            await call(queue, client)
        }
    }

    /// The layout changed: no mosaic kept is right, and the browser drops its cards' pictures and asks for them again,
    /// in its order (those in view first); each covered card is made again.
    private func remakeCovers() {
        dropCovers()
        guard case .folder = view?.location else { return }
        view?.reload()
    }

    /// No mosaic kept, and those being made stopped (a running cover keeps the layout and size it began with): every
    /// card asked for from now on is made again.
    private func dropCovers() {
        cards.dropImages()
        stopQueuedCovers()
    }

    /// The folder's photos as a window's request: the store makes the missing thumbnails, those in view first.
    /// `files`: those in view first, then the margin's.
    private func sendRequest(_ files: [URL]) {
        guard !isPaused, !shownFiles.isEmpty else { return }
        let index = Dictionary(shownFiles.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let shownIndices = files.compactMap { index[$0] }
        let request = ThumbnailRequest(files: shownFiles, current: shownIndices.first ?? -1,
                                       visible: shownIndices,
                                       isKey: view?.window?.isKeyWindow ?? false)
        let stamps = self.stamps, thumbnails = self.thumbnails, window = thumbnailWindow
        Task { await thumbnails.setRequest(window: window, request, stamps: stamps) }
    }

    private func thumbnailChanged(_ url: URL) {
        guard let id = waiting.removeValue(forKey: url.standardizedFileURL) else { return }
        let maxPixel = maxPixel
        Task { @MainActor [weak self] in
            guard let self, let image = await self.thumbnails.cell(url, maxPixel: maxPixel) else { return }
            self.view?.setImage(image, for: id)
        }
    }

    // MARK: Menus

    func menu(for entry: BrowserEntry, in location: BrowserLocation) -> [HomeMenuItem] {
        var items: [HomeMenuItem] = []
        if entry.kind != .place {
            items += [HomeMenuItem(id: "open", title: "Open"), HomeMenuItem(id: "openNewTab", title: "Open in New Tab"),
                      HomeMenuItem(id: "openNewWindow", title: "Open in New Window")]
        }
        items += [HomeMenuItem(id: "reveal", title: "Show in Finder"), HomeMenuItem(id: "copyPath", title: "Copy Path")]
        if entry.kind == .folder || entry.kind == .place {
            items.append(places.isPinned(entry.url) ? HomeMenuItem(id: "unpin", title: "Unpin")
                                                    : HomeMenuItem(id: "pin", title: "Pin"))
        }
        if entry.canRename { items.append(HomeMenuItem(id: "rename", title: "Rename…")) }
        if entry.canTrash { items.append(HomeMenuItem(id: "trash", title: "Move to Trash")) }
        return items
    }

    func perform(_ item: String, on entry: BrowserEntry, in location: BrowserLocation) {
        switch item {
        case "open": open(entry, how: .open)
        case "openNewTab": open(entry, how: .openNewTab)
        case "openNewWindow": open(entry, how: .openNewWindow)
        case "reveal": reveal(entry.url)
        case "copyPath": copyPath(entry.url)
        case "pin", "unpin":
            if item == "pin" { places.pin(entry.url) } else { places.unpin(entry.url) }
            view?.reloadPlaces()
            onPlacesChanged?()
        case "rename": view?.beginRename()
        case "trash": view?.trashSelected()
        default: break
        }
    }

    /// A sidebar row of a folder, a place or a zip (`.folder` rows): the cards' Show in Finder and Copy Path.
    func sidebarMenu(for row: HomeSidebarRow) -> [HomeMenuItem] {
        guard case .folder = row.location else { return [] }
        return [HomeMenuItem(id: "reveal", title: "Show in Finder"), HomeMenuItem(id: "copyPath", title: "Copy Path")]
    }

    func performSidebar(_ item: String, on row: HomeSidebarRow) {
        guard case .folder(let url) = row.location else { return }
        switch item {
        case "reveal": reveal(url)
        case "copyPath": copyPath(url)
        default: break
        }
    }

    /// The Finder shows `url` selected (a zip's entry: the zip).
    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([ArchivePath.split(url)?.archive ?? url])
    }

    private func copyPath(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ArchivePath.copyText(url), forType: .string)
    }

    func open(_ entry: BrowserEntry, in location: BrowserLocation, sort: BrowserSort, how: HomeClick) {
        open(entry, how: how)
    }

    /// A photo opens on itself; a folder or a zip in the viewer on its remembered photo (`openFolder` recalls it).
    private func open(_ entry: BrowserEntry, how: HomeClick) {
        switch entry.kind {
        case .file, .archive: onOpen?(.file(entry.url), how)
        case .folder, .place: onOpen?(.folder(entry.url), how)
        case .collection: break
        }
    }

    // MARK: Changes

    func rename(_ entry: BrowserEntry, to name: String) async throws -> BrowserEntry {
        let actions = self.actions, url = entry.url
        let new = try await Task.detached { try actions.rename(url, to: name) }.value
        forget(url.deletingLastPathComponent())
        var renamed = entry
        renamed.url = new
        renamed.name = new.lastPathComponent
        // The card asks for its picture under the new id at once (before the watcher's relist).
        shown[entry.id] = nil
        shown[renamed.id] = renamed
        if let i = shownFiles.firstIndex(of: url) {
            shownFiles[i] = new
            stamps[new] = stamps.removeValue(forKey: url)
        }
        return renamed
    }

    func trash(_ entry: BrowserEntry) async throws {
        let actions = self.actions, url = entry.url
        do {
            try await Task.detached { try actions.trash(url, permanently: false) }.value
        } catch BrowserTrashError.noTrash {
            guard await askDelete(entry.name) else { throw CancellationError() }
            try await Task.detached { try actions.trash(url, permanently: true) }.value
        }
        forget(url.deletingLastPathComponent())
    }

    private func askDelete(_ name: String) async -> Bool {
        guard let confirmDelete else { return false }
        return await withCheckedContinuation { c in confirmDelete(name) { c.resume(returning: $0) } }
    }

    func sort(for location: BrowserLocation) -> BrowserSort {
        guard case .folder(let folder) = location else { return .standard }
        return BrowserSort.forFolder(folder, settings: settings)
    }

    func setSort(_ sort: BrowserSort, for location: BrowserLocation) {
        guard case .folder(let folder) = location else { return }
        settings?.set(BrowserSort.settingKey, sort.text, for: folder)
    }

    /// `folder-cards`: the folder's own or inherited style, else loupe.conf's.
    func cardStyle(for location: BrowserLocation) -> CardStyle {
        guard case .folder(let folder) = location else { return .posters }
        return CardStyle.forFolder(folder, settings: settings, fallback: Settings.shared.config.folderCards)
    }

    /// The style chosen for the folder (the switch, the View menu, ⌃⌘1–⌃⌘3): its own from now on, its subfolders'
    /// until they choose theirs.
    func setCardStyle(_ style: CardStyle, for location: BrowserLocation) {
        guard case .folder(let folder) = location else { return }
        settings?.set(CardStyle.settingKey, style.rawValue, for: folder)
    }

}

extension HomeMosaic.Layout {
    /// The long side, in pixels, of the photos a card `width` points wide (at `scale`) draws in this layout: a grid's
    /// cells are a half or a quarter of the card; a hero's large cell fills the card's width and a stack's prints are
    /// ⅘ of it, so those (and one photo, which fills the card, and any layout on a narrow card) ask for the card's
    /// pixels. A card's photos are all made at one size, and they come from thumbnails of `thumb-size`, 512 px by
    /// default, which caps a large card's anyway; so a hero's small cells, a third of the card, share its large one's.
    func cellPixels(width: CGFloat, scale: CGFloat) -> Int {
        let pixels = Int((width * scale).rounded())
        guard width >= HomeMosaic.narrowWidth else { return pixels }
        switch self {
        case .grid: return max(64, pixels / 2)
        case .hero, .stack, .single: return pixels
        }
    }
}
