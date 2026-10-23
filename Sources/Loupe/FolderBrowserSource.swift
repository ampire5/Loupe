import AppKit
import HomeScreenKit
import LoupeCore

extension Notification.Name {
    /// A share that was offline answered again (`ThumbnailStore.setOnVolumeAnswered`); the object is its key (`String`).
    /// Posted on the main thread; every window's Home asks again for that share's dimmed cards.
    static let coverVolumeAnswered = Notification.Name("local.loupe.coverVolumeAnswered")
    /// Some count of Home's preparation may have changed (a cover queue's client, the subtree walk, a pause): every
    /// window's Home reads its progress anew. Posted on the main thread.
    static let thumbsProgressChanged = Notification.Name("local.loupe.thumbsProgressChanged")
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
    /// Where Recent has a folder's photo, for a card whose folder has no visit yet (`FolderCardFacts.visit`).
    private let recent: RecentStore?
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
    /// The ancestors' probe after a failed relist of the open folder (`FolderRelistFailure`): one in flight at most.
    private let ancestorProbe = AncestorProbe()
    private var watchChanges: AsyncStream<Void>.Continuation?
    /// Pictures asked for that were not made yet: they come with the store's `thumbnailChanged`.
    private var waiting: [URL: String] = [:]
    private var pictureTask: Task<Void, Never>?
    private var maxPixel = 440

    /// How a folder's or zip's card shows its photos (`folder-cover`); a change makes every cover again.
    var coverLayout = HomeMosaic.Layout.hero {
        didSet { if coverLayout != oldValue { remakeCovers() } }
    }
    /// The layout the covers are made in: `coverLayout`, except a list row's small cover, four photos (mockup C).
    /// The list's cover width is its own, so a switch to or from it drops the covers made at the other size anyway.
    private var shownCoverLayout: HomeMosaic.Layout { view?.shownStyle == .list ? .quad : coverLayout }
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
    /// The direct subfolders of the cards in view, by card id, in Finder order, for the work ahead (thumbs-ahead spec,
    /// stage 4: `ThumbnailStore.subfolderNames`, never a listing of its own): each card's entries made once, off the
    /// main thread, when its names come (`AheadSubfolders`). Asked for once per card, and again when its facts come
    /// (its work may have listed it meanwhile); until the folder changes.
    private var subfolders = AheadSubfolders()
    private var subfoldersAsked: Set<String> = []
    /// The subfolders the last ask sent ahead whose work is not done yet: when none is left, the window moves on.
    private var aheadSent: Set<String> = []
    /// Cards whose "+N inside" is to be counted again (a subfolder made ahead wrote its summary), each once per
    /// `insideRefreshDelay` however many of its subfolders do.
    private var insideRefresh: [String: Task<Void, Never>] = [:]
    /// Cards whose work is done without a cover to give (no photos, unreadable, none of its photos made): their cards
    /// stop waiting (`HomeBrowserView.stopWaiting`), told again whenever they are asked for (laid out anew, Home shown
    /// again). A card whose cover waits on a share is not among them: it keeps waiting. Until the folder changes.
    private var noCover: Set<String> = []
    /// The view's last ask as it came (before `thumbs-ahead = off` trims it), asked again when the setting changes.
    private var lastWant: (ids: [String], visible: Int, width: CGFloat)?
    /// `thumbs-ahead` as the asks so far followed it.
    private var thumbsAhead = Settings.shared.config.thumbsAhead
    private var observers: [NSObjectProtocol] = []

    init(thumbnails: ThumbnailStore, places: BrowserPlaces, settings: FolderSettings?, positions: FolderPositions,
         recent: RecentStore?, stores: [any PathMoving]) {
        self.thumbnails = thumbnails
        self.places = places
        self.settings = settings
        self.positions = positions
        self.recent = recent
        actions = BrowserFileActions(stores: stores)
        thumbnailWindow = Self.nextWindow
        Self.nextWindow += 1
        watcher.onChange = { [weak self] _ in self?.watchChanges?.yield() }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .thumbnailChanged, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let url = note.object as? URL else { return }
                self?.progressMayHaveChanged()
                self?.thumbnailChanged(url)
            }
        })
        observers.append(center.addObserver(forName: .thumbsProgressChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.progressMayHaveChanged() }
        })
        observers.append(center.addObserver(forName: .coverVolumeAnswered, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let volume = note.object as? String else { return }
                self?.shareAnswered(volume)
            }
        })
        observers.append(center.addObserver(forName: .settingsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.thumbsAheadMayHaveChanged() }
        })
    }

    /// `thumbs-ahead` changed (the settings window, loupe.conf): the view's last ask is sent again under it, so the
    /// margin and the subfolders ahead start or stop at once, no restart.
    private func thumbsAheadMayHaveChanged() {
        let now = Settings.shared.config.thumbsAhead
        guard now != thumbsAhead else { return }
        thumbsAhead = now
        guard !isPaused, case .folder = view?.location, let last = lastWant else { return }
        wantImages(last.ids, visible: last.visible, width: last.width)
    }

    /// The tab hid or the window closed: no polls, no thumbnails for it.
    var isPaused = false {
        didSet {
            watcher.isPaused = isPaused
            guard isPaused else {
                // Back from the viewer: the visits and the two-page keys may have changed.
                showSummaries()
                progressMayHaveChanged()
                // The browser keeps its cards (the folder on screen shown again asks for nothing): its last ask goes
                // again, so the request is no longer held and the pictures still missing are waited for anew.
                let changed = changedWhilePaused
                changedWhilePaused = []
                askAgain(changed)
                if case .folder = view?.location, let last = lastWant {
                    return wantImages(last.ids, visible: last.visible, width: last.width)
                }
                return sendCovers()
            }
            progressTask?.cancel()
            progressTask = nil
            // Nothing of the browser's goes on reading while the viewer shows what was clicked; its request stays,
            // made of nothing (`holdRequest`), so back on Home its folder needs no new sync.
            pictureTask?.cancel()
            waiting.removeAll()
            holdRequest()
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
        endOwnWalk()
        isStopped = true   // no held request: the window closes, its request goes
        isPaused = true
        Task { [thumbnails, thumbnailWindow] in await thumbnails.setRequest(window: thumbnailWindow, nil, stamps: [:]) }
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

    /// The folder's complete listing kept from an earlier visit (`memory`): the browser draws it in the move's turn.
    func lastListing(for location: BrowserLocation) -> BrowserListing? {
        guard case .folder(let folder) = location else { return nil }
        let path = folder.standardizedFileURL.path
        return memory.last { $0.path == path }?.listing
    }

    /// The folders and zips in `folder` for the path's sibling menu and the sidebar's tree: from a listing kept in
    /// memory, else names only off the main thread (no stat, so a slow share answers as soon as it can); a cancelled
    /// request stops at the next part. A folder that cannot be listed (a share's error) throws: the tree leaves it
    /// unlisted, to be asked again, rather than empty for good.
    func folders(in folder: URL) async throws -> [BrowserEntry] {
        let path = folder.standardizedFileURL.path
        if let kept = memory.last(where: { $0.path == path })?.listing { return kept.entries.filter(\.isContainer) }
        let archives = Settings.shared.config.archiveFolders
        let task = Task.detached(priority: .userInitiated) {
            try BrowserListingSource.names(folder, archives: archives) { _ in !Task.isCancelled }
        }
        return try await withTaskCancellationHandler {
            try await task.value.filter(\.isContainer)
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
        listingFailed = false
        listingAnswered(false, reset: true)
        // A zip's listing is its photos: no cards with covers.
        showCovers(of: ArchivePath.isArchive(folder) ? nil : folder)
        return AsyncThrowingStream { continuation in
            // The kept listing at once, in the move's turn: the browser draws it then (`lastListing`) and asks for its
            // pictures by id, which must find its entries here.
            if let remembered { deliver(remembered, token: token, to: continuation) }
            let task = Task { @MainActor [weak self] in
                /// Still the place on screen: else nothing of this listing reaches the source's state or the view.
                @MainActor func wanted() -> Bool { !Task.isCancelled && self?.gate.isCurrent(token) == true }
                @MainActor func deliver(_ listing: BrowserListing) {
                    if wanted() { self?.deliver(listing, token: token, to: continuation) }
                }
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
                    var failing = false
                    for await _ in changes {
                        // A change heard after the place was left (or the stream ended) lists nothing.
                        guard wanted() else { return }
                        let started = ContinuousClock.now
                        do {
                            let entries = try await Task.detached { try BrowserListingSource.full(folder, archives: archives) }.value
                            guard wanted() else { return }
                            let listing = BrowserListing(entries: entries, complete: true)
                            deliver(listing)
                            self.keep(listing, for: path)
                            self.keepSummary(of: folder, entries)
                            self.watcher.listed(in: ContinuousClock.now - started, succeeded: true)
                            failing = false
                        } catch {
                            guard wanted() else { return }
                            self.watcher.listed(in: ContinuousClock.now - started, succeeded: false)
                            // Gone only when the system says so and the nearest ancestor that is there answers; a
                            // share that times out or dropped keeps the grid, the next poll tries again
                            // (`FolderRelistFailure`). One probe at a time: one still out counts as no answer.
                            let ancestors = await self.ancestorProbe.run(folder, timeout: .seconds(1)) ?? []
                            guard wanted() else { return }
                            if FolderRelistFailure(error, ancestors: ancestors) == .gone {
                                await self.folderGone(folder)
                                return
                            }
                            if !failing { self.view?.showToast("Folder not answering: \(folder.lastPathComponent)") }
                            failing = true
                        }
                    }
                } catch {
                    if wanted() {
                        self?.listingFailed = true
                        self?.progressMayHaveChanged()
                    }
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

    /// A listing of the place on screen to the source's state and the view; a names-only part after a complete listing
    /// of the same place (a relist's first pass on a share) goes nowhere: it would drop the stamps, the dates and the
    /// follow-ups the complete one gave (`BrowserListingGate.admits`).
    private func deliver(_ listing: BrowserListing, token: Int,
                         to continuation: AsyncThrowingStream<BrowserListing, Error>.Continuation) {
        guard gate.admits(complete: listing.complete, token: token) else { return }
        remember(listing.entries)
        let wasDated = shownDated
        shownDated = listing.complete
        listingAnswered(listing.complete)
        continuation.yield(listing)
        guard listing.complete, !wasDated else { return }
        // The cards now have their folders' dates (a stored summary is fresh only at its folder's date): the summaries
        // waiting for them go to the cover queue, at once.
        sendCovers()
        let ready = Array(followUps)
        if !ready.isEmpty { sendToQueue { queue, client in await queue.forget(ready, client: client) } }
    }

    /// A listing of the folder on screen came (`complete`: with stamps), or a new one starts (`reset`): the clock of the
    /// names-only wait starts at its first part and stops at the complete one; when it runs out the progress is read
    /// again (no count changes meanwhile).
    private func listingAnswered(_ complete: Bool, reset: Bool = false) {
        if complete || reset {
            namesOnlySince = nil
            listingStallCheck?.cancel()
            listingStallCheck = nil
            return
        }
        guard namesOnlySince == nil else { return }
        namesOnlySince = .now
        listingStallCheck = Task { @MainActor [weak self] in
            guard (try? await Task.sleep(for: Self.listingAnswerLimit)) != nil, let self else { return }
            self.listingStallCheck = nil
            self.progressMayHaveChanged()
        }
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
        lastWant = (ids, visible, width)
        // `thumbs-ahead = off`: only what is in view, no margin.
        let ids = Settings.shared.config.thumbsAhead == .off ? Array(ids.prefix(visible)) : ids
        let scale = view?.window?.backingScaleFactor ?? 2
        maxPixel = Int((width * scale).rounded())
        let wanted = ids.compactMap { shown[$0] }
        let inView = Set(ids.prefix(visible))
        let files = wanted.filter { $0.kind == .file }
        sendRequest(ThumbnailRequest.inViewFirst(files.map(\.url), inView: Set(files.filter { inView.contains($0.id) }.map(\.url))))
        let cardIDs = wanted.filter { $0.kind == .folder || $0.kind == .archive }.map(\.id)
        // The folder cards' picture: a poster's slot, a compact card's 76 pt square (its layout kept there, as board B
        // draws it), a row's cover; with photos in the grid too, `width` is theirs.
        let coverWidth = view?.coverWidth ?? width
        // Another card size or screen: the mosaics kept and those being made are the wrong size.
        if let size = coverSize, size.width != coverWidth || size.scale != scale { dropCovers() }
        coverSize = (coverWidth, scale)
        let liveCards = shown.values.reduce(0) { $0 + ($1.kind == .folder || $1.kind == .archive ? 1 : 0) }
        cards.setLimit(CoverCards.limit(cards: liveCards, pixels: Int((coverWidth * scale).rounded())))
        let ask = cards.ask(cardIDs, visible: cardIDs.filter(inView.contains).count)
        lastAsked = cardIDs
        lastInView = Set(cardIDs.filter(inView.contains))
        for (id, image) in ask.cached { view?.setImage(image, for: id) }
        let given = cardIDs.filter(noCover.contains)
        if !given.isEmpty { view?.stopWaiting(for: given) }
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
                    self.pictured.insert(entry.url)
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
        subfolders = AheadSubfolders()
        subfoldersAsked = []
        aheadSent = []
        for task in insideRefresh.values { task.cancel() }
        insideRefresh = [:]
        noCover = []
        lastWant = nil
        lastProgress = nil
        shownDated = false   // the new folder's entries are dated once its own complete listing comes
        lastAsked = []
        lastInView = []
        requestedVisible = []
        pictured = []
        changedWhilePaused = []
        stopQueuedCovers()
        progressMayHaveChanged()
        guard let folder, let path else { return }
        let thumbnails = self.thumbnails
        placeTask = Task { @MainActor [weak self] in
            let place = await thumbnails.shownFolderPlace(folder)
            let share = await Task.detached(priority: .utility) { ThumbnailStore.networkVolume(folder) }.value
            guard let self, !Task.isCancelled, self.coverFolder == path, place != .notNow else { return }
            self.coverPlace = place
            self.coverShare = share
            // Its photos' folder is the same: the store needs no second resolve of it.
            if case .located(let location) = place { Task { await thumbnails.knowLocation(of: folder, location) } }
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
    ///
    /// With `thumbs-ahead = folder`, the subfolders of the cards in view follow every window's margin in the queue
    /// (`aheadWork`), in the grid's order, once the folder's entries are dated.
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
        let aheadList = shownDated && Settings.shared.config.thumbsAhead == .folder ? aheadIDs(in: shownLocation) : []
        aheadSent = Set(aheadList)
        // The kept entries as they are now (copied on write: nothing is made for this ask).
        let ahead = subfolders
        let layout = shownCoverLayout, side = size.width, scale = size.scale
        let compact = view?.shownStyle == .cards   // board B: the layout kept at 76 pt
        let cellPixels = layout.cellPixels(width: side, scale: scale)
        let thumbnails = self.thumbnails
        /// The card as it is when its work starts (a want sent before the complete listing runs after it too): its
        /// entry (with its folder's date once the listing is complete), its remembered photo (a zip's entry name is
        /// one path component already), whether the entries are dated, whether it still wants its picture (a
        /// follow-up's is on screen, or kept), and since when its photos' dates may count as new (its visit now, else
        /// now: a visit recorded later is later). Nil: no longer this folder's.
        typealias CardNow = (entry: BrowserEntry, lastViewed: String?, dated: Bool, picture: Bool, since: Date)
        let lookup: @MainActor (String) -> CardNow? = { [weak self] id in
            guard let self, self.coverFolder == folderPath, let entry = self.shown[id] else { return nil }
            return (entry, self.positions.fileName(in: entry.url), self.shownDated, self.cards.pending.contains(id),
                    self.visit(of: entry.url)?.visited ?? Date())
        }
        let deliver: @MainActor (String, CGImage?, FolderCardFacts, Bool, Bool) -> Void = {
            [weak self] id, mosaic, facts, again, noCover in
            guard let self, self.coverFolder == folderPath, self.shown[id] != nil else { return }
            self.keepFacts(facts, for: id, again: again)
            // Done without a picture (no photos, unreadable, none made): the card stops waiting for one.
            if noCover {
                self.noCover.insert(id)
                self.view?.stopWaiting(for: [id])
            }
            // A mosaic of another layout or size is not kept.
            guard let mosaic, self.shownCoverLayout == layout, self.coverSize?.width == side,
                  self.coverSize?.scale == scale else { return }
            self.cards.delivered(id, mosaic)
            self.view?.setImage(mosaic, for: id)
        }
        let subfolderWork = aheadWork(network: network, folderPath: folderPath)
        let work: @Sendable (String) async -> Bool = { id in
            if let subfolder = ahead.card(id) { return await subfolderWork(subfolder) }
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
            // Only the dates that may still be new, sorted (off the main thread): bounded by the photos new since.
            let facts = FolderCardFacts(summary: made.summary, inside: inside,
                                        photoDates: made.photoDates.map { NewPhotoDates($0, since: card.since) },
                                        problem: made.problem)
            // No photos: the card keeps its symbol.
            var mosaic: CGImage?
            if card.picture, !made.images.isEmpty {
                mosaic = HomeMosaic.make(made.images, size: CGSize(width: side, height: side), layout: layout, scale: scale,
                                         compact: compact)
            }
            let again = made.summaryPending || (made.problem == .offline && made.images.isEmpty)
            guard !Task.isCancelled else { return true }
            await deliver(id, mosaic, facts, again, card.picture && mosaic == nil && !again)
            return !again
        }
        sendToQueue { queue, client in
            await queue.want(ids, visible: visible, ahead: aheadList, client: client, isNetwork: { _ in network },
                             work: work)
        }
    }

    /// The queue ids of the folder cards in view's subfolders, card by card in the grid's order (the last ask's), those
    /// whose names are known, at most `AheadSubfolders.limit` in all: the kept entries joined, nothing made per
    /// subfolder. The others' names are asked for (`askSubfolders`), and they come with a later `sendCovers`.
    private func aheadIDs(in shownLocation: ThumbnailLocation?) -> [String] {
        var cards: [String] = []
        for id in lastAsked where lastInView.contains(id) {
            guard let entry = shown[id], entry.kind == .folder else { continue }
            if !subfolders.has(id) {
                askSubfolders(id, of: entry.url, in: shownLocation?.subfolder(entry.url.lastPathComponent))
            }
            cards.append(id)
        }
        return subfolders.ids(for: cards)
    }

    /// Subfolder `id`'s work ahead is done: it leaves the window (`AheadSubfolders.markDone`); once every one the last
    /// ask sent is done, the covers are sent again with the next subfolders still to do (the same cards in view).
    private func aheadDone(_ id: String) {
        subfolders.markDone(id)
        guard aheadSent.remove(id) != nil, aheadSent.isEmpty else { return }
        sendCovers()
    }

    /// The card's subfolders' names from the store (memory or catalog, never a listing) and their entries, off the
    /// main thread; known, the covers are sent again with them.
    private func askSubfolders(_ id: String, of folder: URL, in location: ThumbnailLocation?) {
        guard subfoldersAsked.insert(id).inserted else { return }
        if facts[id]?.summary?.folders == 0 {
            subfolders.set(AheadSubfolders.entries([], card: id, folder: folder, location: location), for: id)
            return
        }
        let thumbnails = self.thumbnails, folderPath = coverFolder
        Task { @MainActor [weak self] in
            guard let names = await thumbnails.subfolderNames(of: folder, in: location) else { return }
            let entries = await Task.detached(priority: .utility) {
                AheadSubfolders.entries(names, card: id, folder: folder, location: location)
            }.value
            guard let self, self.coverFolder == folderPath, self.shown[id] != nil else { return }
            self.subfolders.set(entries, for: id)
            if !names.isEmpty { self.sendCovers() }
        }
    }

    /// The work ahead on one subfolder (`ThumbnailStore.prepareAhead`) while its parent card is on screen. A summary
    /// it wrote (new or changed) has its parent card's "+N inside" counted again (`refreshInside`); a fresh one skipped
    /// costs the parent nothing.
    private func aheadWork(network: Bool, folderPath: String) -> @Sendable (AheadSubfolders.Card) async -> Bool {
        let thumbnails = self.thumbnails
        let lastViewed: @MainActor (AheadSubfolders.Card) -> String?? = { [weak self] card in
            guard let self, self.coverFolder == folderPath, self.shown[card.parent] != nil else { return nil }
            return .some(self.positions.fileName(in: card.url))
        }
        let refresh: @MainActor (String, ThumbnailLocation) -> Void = { [weak self] parent, location in
            guard let self, self.coverFolder == folderPath else { return }
            self.refreshInside(of: parent, at: location)
        }
        let finished: @MainActor (String) -> Void = { [weak self] id in
            guard let self, self.coverFolder == folderPath else { return }
            self.aheadDone(id)
        }
        return { card in
            guard let viewed = await lastViewed(card) else { return true }
            let made = await thumbnails.prepareAhead(card.url, in: card.location, network: network, lastViewed: viewed)
            if made.summaryWritten, let parentLocation = card.parentLocation { await refresh(card.parent, parentLocation) }
            if made.done { await finished(card.id) }
            return made.done
        }
    }

    /// How long a card waits before its "+N inside" is counted again after a subfolder's summary was written: the
    /// summaries of its subfolders made meanwhile go in the same count (one catalog query and one redraw per card per
    /// this, not one per subfolder).
    private static let insideRefreshDelay: Duration = .milliseconds(500)

    /// The card `parent`'s "+N inside" from its subfolders' stored summaries (`ThumbnailStore.childSummaries`, at
    /// `location`), after `insideRefreshDelay`, once for every summary written meanwhile.
    private func refreshInside(of parent: String, at location: ThumbnailLocation) {
        guard insideRefresh[parent] == nil else { return }
        let thumbnails = self.thumbnails, folderPath = coverFolder
        insideRefresh[parent] = Task { @MainActor [weak self] in
            guard (try? await Task.sleep(for: Self.insideRefreshDelay)) != nil else { return }
            self?.insideRefresh[parent] = nil
            let inside = await thumbnails.childSummaries(of: location)
            guard let self, self.coverFolder == folderPath, self.facts[parent] != nil else { return }
            self.facts[parent]?.inside = inside
            self.showSummary(parent)
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
        // Its work may have listed it: its subfolders' names may be known now.
        if !subfolders.has(id), subfoldersAsked.remove(id) != nil, lastInView.contains(id) { sendCovers() }
    }

    /// The card's facts with its visit and two-page keys as they are now (folder settings and positions are in memory).
    private func showSummary(_ id: String) {
        guard let entry = shown[id], let facts = facts[id] else { return }
        let config = FolderCardFacts.config(for: entry.url, base: Settings.shared.config, settings: settings)
        view?.setSummary(facts.cardSummary(visit: visit(of: entry.url), config: config), for: id)
    }

    /// The folder's visit, else where Recent has it (`FolderCardFacts.visit`): both in memory.
    private func visit(of folder: URL) -> FolderVisit? {
        FolderCardFacts.visit(positions.visit(in: folder), recent: recent?.entry(for: folder))
    }

    /// The facts of the cards laid out again (back from the viewer: a visit or the two-page keys may have changed),
    /// and of those of the last ask: a card laid out later asks for its picture and gets its facts then
    /// (`wantImages`). The view redraws only those that changed.
    private func showSummaries() {
        var seen: Set<String> = []
        for id in (view?.liveIDs ?? []) + lastAsked where facts[id] != nil && seen.insert(id).inserted { showSummary(id) }
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

    /// The browser's request while the viewer shows (`isPaused`): the folder's files and stamps as they are, so the
    /// store keeps its folder open and synced, but nothing of it to make (no file in view, nothing outward from them).
    /// Back on Home, the same files and stamps reorder its queue only (`ThumbnailStore.setRequest`).
    private func holdRequest() {
        guard !isStopped, !shownFiles.isEmpty else { return }
        let request = ThumbnailRequest(files: shownFiles, current: -1, visible: [], isKey: false, isHome: true,
                                       visibleOnly: true)
        let stamps = self.stamps, thumbnails = self.thumbnails, window = thumbnailWindow
        Task { @MainActor [weak self] in
            let changed = await thumbnails.setRequest(window: window, request, stamps: stamps)
            self?.askAgain(changed)
        }
    }

    /// The window is closing (`stop`): nothing is held for it any more.
    private var isStopped = false
    /// Changed photos the store handed back while the viewer showed (`askAgain`): their cards are told on return.
    private var changedWhilePaused: [URL] = []

    /// The folder's photos as a window's request: the store makes the missing thumbnails, those in view first.
    /// `files`: those in view first, then the margin's.
    private func sendRequest(_ files: [URL]) {
        guard !isPaused, !shownFiles.isEmpty else { return }
        requestedVisible = files
        let index = Dictionary(shownFiles.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let shownIndices = files.compactMap { index[$0] }
        let request = ThumbnailRequest(files: shownFiles, current: shownIndices.first ?? -1,
                                       visible: shownIndices,
                                       isKey: view?.window?.isKeyWindow ?? false, isHome: true,
                                       // `thumbs-ahead = visible | off`: what is asked for, never the rest of the folder.
                                       visibleOnly: Settings.shared.config.thumbsAhead != .folder)
        let stamps = self.stamps, thumbnails = self.thumbnails, window = thumbnailWindow
        Task { @MainActor [weak self] in
            let changed = await thumbnails.setRequest(window: window, request, stamps: stamps)
            self?.askAgain(changed)
            // The generator's count follows the request (its listing synced with the catalog): read it anew.
            self?.progressMayHaveChanged()
        }
    }

    /// Photos the store served from the catalog before their stamps (a share's names-only listing) that the real
    /// stamps show changed (`ThumbnailStore.setRequest`): their cards drop the old picture and wait for the new one.
    private func askAgain(_ changed: [URL]) {
        guard !isPaused else { return changedWhilePaused += changed }
        for url in changed {
            pictured.remove(url)
            guard let entry = shown[url.path], entry.kind == .file else { continue }
            view?.setImage(nil, for: entry.id)
            waiting[url.standardizedFileURL] = entry.id
        }
        if !changed.isEmpty { progressMayHaveChanged() }
    }

    private func thumbnailChanged(_ url: URL) {
        guard let id = waiting.removeValue(forKey: url.standardizedFileURL) else { return }
        let maxPixel = maxPixel
        Task { @MainActor [weak self] in
            guard let self, let image = await self.thumbnails.cell(url, maxPixel: maxPixel) else { return }
            self.view?.setImage(image, for: id)
            self.pictured.insert(url)
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
        if entry.kind == .folder, case .folder = location {
            items.append(HomeMenuItem(id: "prepare-subtree", title: "Prepare thumbnails of folder and subfolders"))
        }
        if entry.kind == .folder || entry.kind == .archive, case .folder = location {
            items.append(HomeMenuItem(id: "refresh-cover", title: "Refresh cover"))
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
        case "prepare-subtree": prepareSubtree(entry)
        case "refresh-cover": refreshCover(entry)
        default: break
        }
    }

    /// The app's one subtree walk (thumbs-ahead spec, stage 5) on the store's cover queue, as a client of its own: a
    /// walk asked from any window ends the one before.
    private static var walk: ThumbsWalk?
    /// The window whose command started the walk: its progress counts the walk's folders.
    private static weak var walkOwner: FolderBrowserSource?

    /// "Prepare thumbnails of folder and subfolders": the walk from this card's folder down to `thumbs-depth`, where
    /// the catalog keeps it as for its card.
    private func prepareSubtree(_ entry: BrowserEntry) {
        guard entry.kind == .folder else { return }
        prepareSubtree(of: entry.url, location: shownLocation?.subfolder(entry.url.lastPathComponent))
    }

    /// The popover's "Prepare subfolders": the walk from the folder on screen down to `thumbs-depth`.
    func prepareShownSubtree(of location: BrowserLocation) {
        guard case .folder(let folder) = location, !ArchivePath.isArchive(folder),
              coverFolder == folder.standardizedFileURL.path else { return }
        prepareSubtree(of: folder, location: shownLocation)
    }

    /// The walk from `folder` (where the catalog keeps it: `location`) down to `thumbs-depth`.
    private func prepareSubtree(of folder: URL, location: ThumbnailLocation?) {
        let walk = Self.walk ?? {
            let made = ThumbsWalk(store: thumbnails, queue: thumbnails.coverQueue, client: Self.nextWindow)
            Self.nextWindow += 1
            Self.walk = made
            Task {
                await made.setOnProgress { _ in
                    Task { @MainActor in NotificationCenter.default.post(name: .thumbsProgressChanged, object: nil) }
                }
            }
            return made
        }()
        Self.walkOwner = self
        let depth = Settings.shared.config.thumbsDepth
        Task { await walk.start(folder, location: location, depth: depth) }
    }

    /// The popover's "Stop preparing": the walk ends (`ThumbsWalk.cancel`), whichever window started it.
    func stopSubtree() {
        guard let walk = Self.walk else { return }
        Task { await walk.cancel() }
    }

    /// The window that started the walk goes away (closed): its walk, which no other window counts or can stop from
    /// its own popover, ends with it.
    private func endOwnWalk() {
        guard Self.walkOwner === self else { return }
        Self.walkOwner = nil
        stopSubtree()
    }

    /// "Refresh cover": the card's summary and pick go from the catalog and memory (`forgetSummaryAndPick`), and the
    /// card goes to the cover queue again, its picture and facts made anew.
    private func refreshCover(_ entry: BrowserEntry) {
        guard entry.kind == .folder || entry.kind == .archive, coverPlace != nil else { return }
        let id = entry.id, folder = entry.url, thumbnails = self.thumbnails
        let location = shownLocation?.subfolder(entry.url.lastPathComponent)
        cards.again(id, inView: lastInView.contains(id))
        // Given up on before (no cover then): it waits again for the new one.
        if noCover.remove(id) != nil { view?.resumeWaiting(for: [id]) }
        sendToQueue { queue, client in
            if let location { await thumbnails.forgetSummaryAndPick(of: location, folder: folder) }
            await queue.forget([id], client: client)
        }
        sendCovers()
    }

    /// Where the catalog keeps the folder on screen, once resolved; nil without one.
    private var shownLocation: ThumbnailLocation? {
        if case .located(let location) = coverPlace { return location }
        return nil
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

    /// The style chosen for the folder (the switch, the View menu, ⌥⌘1–⌥⌘3): its own from now on, its subfolders'
    /// until they choose theirs.
    func setCardStyle(_ style: CardStyle, for location: BrowserLocation) {
        guard case .folder(let folder) = location else { return }
        settings?.set(CardStyle.settingKey, style.rawValue, for: folder)
    }

    // MARK: Progress

    /// The user's pause of the work ahead (thumbs-ahead spec, "Пауза"): the app's, for the session (a new folder or
    /// window keeps it), never written to loupe.conf.
    private(set) static var aheadPausedByUser = false
    /// The last pause sent to the store: each goes after it, so the store sees them in order.
    private static var pauseSend: Task<Void, Never>?

    /// The popover's "Pause" / "Resume": the store makes only what is in view and the margin, the cover queue holds the
    /// work ahead and the walk (`ThumbnailStore.pauseAhead`); every window's progress reads anew.
    func pauseAhead(_ on: Bool) {
        guard Self.aheadPausedByUser != on else { return }
        Self.aheadPausedByUser = on
        let thumbnails = self.thumbnails, previous = Self.pauseSend
        Self.pauseSend = Task {
            await previous?.value
            await thumbnails.pauseAhead(on)
        }
        NotificationCenter.default.post(name: .thumbsProgressChanged, object: nil)
    }

    /// How far Home's preparation of the folder on screen is, for the toolbar's pill (`HomeBrowserView.setProgress`,
    /// thumbs-ahead plan Task 9): told only when it changed, at most every `progressInterval`; nothing to do (no
    /// stage) when the browser shows no folder.
    var onProgress: ((ThumbsProgress) -> Void)? {
        didSet { progressMayHaveChanged() }
    }
    /// At most four a second (thumbs-ahead spec, "Данные"): the counters change with every thumbnail and card made.
    private static let progressInterval: Duration = .milliseconds(250)
    private var progressTask: Task<Void, Never>?
    private var lastProgress: ThumbsProgress?
    /// The photos of the last request in view and the margin: before the complete listing (names only, no stamps)
    /// the generator does not count them, so the progress counts those without a stamp in view.
    private var requestedVisible: [URL] = []
    /// Photos of the folder on screen whose picture was given (from the catalog too, before their stamps): one in view
    /// without a stamp but with its picture does not wait for the share.
    private var pictured: Set<URL> = []
    /// Since when the folder on screen has only its names-only listing (nil: complete, or none yet), and whether its
    /// listing failed: the photos in view without stamps then wait for the share, not counted as work.
    private var namesOnlySince: ContinuousClock.Instant?
    private var listingFailed = false
    private var listingStallCheck: Task<Void, Never>?
    /// How long the complete listing may take after the names-only one before the share counts as not answering.
    /// Basis: the names-only pass takes ~0.05 s on a share and the complete one "seconds on a cold share"
    /// (`BrowserListingSource`); 30 s is several times that, and a folder whose listing is slower only puts the pill
    /// out until its listing comes (the popover says it waits for the share).
    private static let listingAnswerLimit: Duration = .seconds(30)
    private var lastProgressLocation: BrowserLocation?

    /// A count may have changed: the progress is read once `progressInterval` has passed, whatever else changes
    /// meanwhile. Nothing while no one listens or the browser is hidden.
    private func progressMayHaveChanged() {
        guard onProgress != nil, !isPaused, progressTask == nil else { return }
        progressTask = Task { @MainActor [weak self] in
            guard (try? await Task.sleep(for: Self.progressInterval)) != nil, let self else { return }
            self.progressTask = nil
            let location = self.view?.location
            let progress = await self.currentProgress()
            // A late count of a place the browser has left is dropped, and the new place's is read.
            guard self.view?.location == location else { return self.progressMayHaveChanged() }
            // A new place is told even with the same counts: the popover dropped the last place's on the move.
            guard !self.isPaused, progress != self.lastProgress || location != self.lastProgressLocation else { return }
            self.lastProgress = progress
            self.lastProgressLocation = location
            self.onProgress?(progress)
        }
    }

    /// The three counters joined (`ThumbsProgress.join`): the generator's for the browser's window, the cover queue's
    /// for its client, the walk's when this window started it, and the pauses.
    private func currentProgress() async -> ThumbsProgress {
        guard case .folder(let folder) = view?.location else { return ThumbsProgress() }
        let thumbnails = self.thumbnails, window = thumbnailWindow, location = shownLocation
        // The walk's count follows the window that started it, whatever folder that window shows now.
        let walk = Self.walkOwner === self ? Self.walk : nil
        let generator = await thumbnails.generatorProgress(window: window)
        let covers = await thumbnails.coverQueue.progress(client: window)
        let browsing = await thumbnails.coverQueue.browsingPaused
        let walked = await walk?.progress
        // Names only so far (a share's first pass): the photos in view wait for their stamps, then to be made (those
        // the catalog served meanwhile do not).
        let unlisted = shownDated ? 0
            : requestedVisible.reduce(0) { $0 + (stamps[$1] == nil && !pictured.contains($1) ? 1 : 0) }
        // Work still to do on a share that does not answer waits for it: the visible cards' subfolders (the popover
        // says so), what is in view and the folder's photos (not work under way: the pill goes out).
        let left = covers.ahead.done < covers.ahead.total || generator.all.done < generator.all.total || unlisted > 0
            || covers.inView.done < covers.inView.total || covers.margin.done < covers.margin.total
            || generator.visible.done < generator.visible.total
        let offline = left ? await thumbnails.isShareOffline(folder, in: location) : false
        // The complete listing did not come: it failed, or the share has not answered for `listingAnswerLimit`.
        let stalled = listingFailed || namesOnlySince.map { ContinuousClock.now - $0 >= Self.listingAnswerLimit } ?? false
        return ThumbsProgress.join(generator: generator, covers: covers, walk: walked,
                                   pausedByUser: Self.aheadPausedByUser, browsing: browsing,
                                   aheadWaitsForShare: offline && covers.ahead.done < covers.ahead.total,
                                   unlistedInView: unlisted, shareOffline: offline,
                                   unlistedWaitsForShare: offline || stalled)
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
        case .grid, .quad: return max(64, pixels / 2)
        case .hero, .stack, .single: return pixels
        }
    }
}
