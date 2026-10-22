import AppKit
import HomeScreenKit
import LoupeCore

/// Home's Folders tab on Loupe's data (file browser spec §4.2): listings from `BrowserListingSource` (the last eight
/// kept in memory, so Back and Up show at once), a `FolderWatcher` on the open folder, thumbnails from the strip's
/// store (the folder's files as one more window's request), folder and zip covers from the store's cover queue (folder
/// covers spec), the sort in folder settings, and rename and Trash through `BrowserFileActions`.
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
    private var observer: NSObjectProtocol?

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
        observer = NotificationCenter.default.addObserver(forName: .thumbnailChanged, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let url = note.object as? URL else { return }
                self?.thumbnailChanged(url)
            }
        }
    }

    /// The tab hid or the window closed: no polls, no thumbnails for it.
    var isPaused = false {
        didSet {
            watcher.isPaused = isPaused
            guard isPaused else { return sendCovers() }
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
        if let observer { NotificationCenter.default.removeObserver(observer) }
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
        continuation.yield(listing)
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
        guard !ArchivePath.isArchive(folder) else { return }
        let thumbnails = self.thumbnails
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
        for (id, image) in ask.cached { view?.setImage(image, for: id) }
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
        cards.reset()
        stopQueuedCovers()
        guard let folder, let path else { return }
        let thumbnails = self.thumbnails
        placeTask = Task { @MainActor [weak self] in
            let place = await thumbnails.shownFolderPlace(folder)
            guard let self, !Task.isCancelled, self.coverFolder == path, place != .notNow else { return }
            self.coverPlace = place
            self.sendCovers()
        }
    }

    /// The folder and zip cards still waiting for a cover to the store's cover queue, once the folder on screen is
    /// resolved. Each card's work makes its cover (`ThumbnailStore.folderCover`: from the catalog or the pick
    /// remembered when they have the photos, else from a listing of names, both off the main thread) in the chosen
    /// layout, and gives it to the card; nil from it is "not now", and the queue tries again later.
    private func sendCovers() {
        guard !isPaused, let place = coverPlace, let size = coverSize else { return }
        let shownLocation: ThumbnailLocation?, network: Bool
        switch place {
        case .located(let location): (shownLocation, network) = (location, location.isNetwork)
        case .unknown(let onShare): (shownLocation, network) = (nil, onShare)
        case .notNow: return
        }
        // The remembered photo of each folder first (a zip's entry name is one path component already).
        let entries = Dictionary(cards.pending.compactMap { id in shown[id].map { (id, ($0, positions.fileName(in: $0.url))) } },
                                 uniquingKeysWith: { a, _ in a })
        let ids = cards.pending, visible = cards.visiblePending
        let layout = coverLayout, side = size.width, scale = size.scale
        let cellPixels = layout.cellPixels(width: side, scale: scale)
        let thumbnails = self.thumbnails
        let deliver: @MainActor (String, CGImage) -> Void = { [weak self] id, mosaic in
            // A mosaic of another folder, layout or size is not kept.
            guard let self, self.shown[id] != nil, self.coverLayout == layout, self.coverSize?.width == side,
                  self.coverSize?.scale == scale else { return }
            self.cards.delivered(id, mosaic)
            self.view?.setImage(mosaic, for: id)
        }
        let work: @Sendable (String) async -> Bool = { id in
            guard let card = entries[id] else { return true }
            let (entry, lastViewed) = card
            guard let images = await thumbnails.folderCover(entry.url, archive: entry.kind == .archive,
                                                            in: shownLocation?.subfolder(entry.url.lastPathComponent),
                                                            network: network, maxPixel: cellPixels,
                                                            lastViewed: lastViewed,
                                                            modified: entry.date) else { return false }
            // No photos: the card keeps its symbol.
            guard !Task.isCancelled, !images.isEmpty,
                  let mosaic = HomeMosaic.make(images, size: CGSize(width: side, height: side), layout: layout,
                                               scale: scale) else { return true }
            await deliver(id, mosaic)
            return true
        }
        sendToQueue { queue, client in
            await queue.want(ids, visible: visible, client: client, isNetwork: { _ in network }, work: work)
        }
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
        case "reveal": NSWorkspace.shared.activateFileViewerSelecting([ArchivePath.split(entry.url)?.archive ?? entry.url])
        case "copyPath":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ArchivePath.copyText(entry.url), forType: .string)
        case "pin", "unpin":
            if item == "pin" { places.pin(entry.url) } else { places.unpin(entry.url) }
            view?.reloadPlaces()
            onPlacesChanged?()
        case "rename": view?.beginRename()
        case "trash": view?.trashSelected()
        default: break
        }
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
