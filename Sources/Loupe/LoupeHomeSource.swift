import AppKit
import HomeScreenKit
import LoupeCore

/// Home's source for the browser and the sidebar (Photos style spec §6): the places and folders from
/// `FolderBrowserSource`, Recent, Sessions and Stash from `CollectionSource`, each request sent by its location or by
/// its card's kind.
@MainActor final class LoupeHomeSource: HomeSource {
    let folders: FolderBrowserSource
    let collections: CollectionSource
    let photos: PhotosBrowserSource
    private var historyObserver: NSObjectProtocol?
    private func isPhotos(_ location: BrowserLocation?) -> Bool {
        if case .source(let id) = location { return PhotosLocation.owns(id) }
        return false
    }
    /// Whether Stash has an address (its sidebar section).
    private let hasStash: () -> Bool

    init(folders: FolderBrowserSource, collections: CollectionSource, hasStash: @escaping () -> Bool,
         photos: PhotosBrowserSource? = nil) {
        self.folders = folders
        self.collections = collections
        self.hasStash = hasStash
        self.photos = photos ?? PhotosBrowserSource()
        historyObserver = NotificationCenter.default.addObserver(forName: FileViewHistory.didChange,
            object: folders.fileViewHistory, queue: .main) { [weak self] note in
                guard let dates = note.userInfo?["dates"] as? [URL: Date] else { return }
                MainActor.assumeIsolated { self?.view?.setLastViewed(dates) }
            }
    }

    deinit { if let historyObserver { NotificationCenter.default.removeObserver(historyObserver) } }

    /// The browser both halves draw into.
    weak var view: HomeBrowserView? {
        didSet {
            folders.view = view
            collections.view = view
            photos.view = view
        }
    }

    func places() async -> [BrowserEntry] { await folders.places() }

    func list(_ location: BrowserLocation) -> AsyncThrowingStream<BrowserListing, Error> {
        let stream: AsyncThrowingStream<BrowserListing, Error>
        if case .source(let id) = location { stream = PhotosLocation.owns(id) ? photos.list(id) : collections.list(id) }
        else { stream = folders.list(location) }
        let history = folders.fileViewHistory
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await original in stream {
                        try Task.checkCancellation()
                        continuation.yield(original)
                        let dates = await history.lastViewed(original.entries.filter(\.isFile).map(\.url))
                        try Task.checkCancellation()
                        // Optional history never holds back the already available listing or rebuilds its tree.
                        await Task.yield()
                        if self.view?.location == location { self.view?.setLastViewed(dates) }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func lastListing(for location: BrowserLocation) -> BrowserListing? { folders.lastListing(for: location) }

    func folders(in folder: URL) async throws -> [BrowserEntry] { try await folders.folders(in: folder) }
    func parent(of folder: URL) -> BrowserLocation { folders.parent(of: folder) }
    func symbol(for entry: BrowserEntry) -> String {
        if entry.id == "photos-collection:" + PhotosLocation.library { return "photo.on.rectangle" }
        if entry.id.hasPrefix("photos-collection:") { return "rectangle.stack" }
        return folders.symbol(for: entry)
    }

    func wantImages(_ ids: [String], width: CGFloat) { wantImages(ids, visible: ids.count, width: width) }

    /// The first `visible` of `ids` are in view: a folder's cards in view get their covers before the margin's.
    func wantImages(_ ids: [String], visible: Int, width: CGFloat) {
        if isPhotos(view?.location) { photos.wantImages(ids, width: width) }
        else if case .source = view?.location {
            collections.wantImages(ids, width: width)
        } else {
            folders.wantImages(ids, visible: visible, width: width)
        }
    }

    func menu(for entry: BrowserEntry, in location: BrowserLocation) -> [HomeMenuItem] {
        if isPhotos(location) {
            return entry.kind == .file ? [HomeMenuItem(id: "photos-open", title: "Open"),
                HomeMenuItem(id: "photos-tab", title: "Open in New Tab"),
                HomeMenuItem(id: "photos-window", title: "Open in New Window")] : []
        }
        return entry.kind == .collection ? collections.menu(for: entry) : folders.menu(for: entry, in: location)
    }

    func perform(_ item: String, on entry: BrowserEntry, in location: BrowserLocation) {
        if isPhotos(location) {
            photos.open(entry, how: item == "photos-tab" ? .openNewTab : item == "photos-window" ? .openNewWindow : .open)
            return
        }
        if entry.kind == .collection { collections.perform(item, on: entry) } else { folders.perform(item, on: entry, in: location) }
    }

    /// A folder's, a place's or a zip's row in the sidebar: Show in Finder and Copy Path, as their cards.
    func sidebarMenu(for row: HomeSidebarRow) -> [HomeMenuItem] {
        isPhotos(row.location) ? [] : folders.sidebarMenu(for: row)
    }
    func performSidebar(_ item: String, on row: HomeSidebarRow) { folders.performSidebar(item, on: row) }

    func open(_ entry: BrowserEntry, in location: BrowserLocation, sort: BrowserSort, how: HomeClick) {
        if isPhotos(location) { photos.open(entry, how: how, sort: sort) }
        else if entry.kind == .collection {
            collections.open(entry, how: how)
        } else {
            folders.open(entry, in: location, sort: sort, how: how)
        }
    }

    func rename(_ entry: BrowserEntry, to name: String) async throws -> BrowserEntry {
        guard entry.url.isFileURL else { throw PhotosLibraryError.permission }
        return try await folders.rename(entry, to: name)
    }
    func trash(_ entry: BrowserEntry) async throws {
        guard entry.url.isFileURL else { throw PhotosLibraryError.permission }
        try await folders.trash(entry)
    }

    func sort(for location: BrowserLocation) -> BrowserSort {
        if case .source(let id) = location, PhotosLocation.owns(id) { return photos.sort(for: id) }
        if case .source(let id) = location { return collections.sort(for: id) }
        return folders.sort(for: location)
    }

    func setSort(_ sort: BrowserSort, for location: BrowserLocation) {
        if case .source(let id) = location, PhotosLocation.owns(id) { photos.setSort(sort, for: id); return }
        if case .source(let id) = location { collections.setSort(sort, for: id) } else { folders.setSort(sort, for: location) }
    }

    /// Only a folder's own cards have a style (`folder-cards`); the collections are drawn as they are.
    func cardStyle(for location: BrowserLocation) -> CardStyle { folders.cardStyle(for: location) }

    func setCardStyle(_ style: CardStyle, for location: BrowserLocation) { folders.setCardStyle(style, for: location) }

    func info(for source: String) -> HomeSourceInfo { PhotosLocation.owns(source) ? photos.info(source) : collections.info(for: source) }

    /// Recent and Sessions; the places (the home folder, the volumes, the pinned folders), each opening as a tree;
    /// Stash's library when it has an address.
    func sidebar() async -> [HomeSidebarSection] {
        let places = await folders.places().map { e in
            HomeSidebarRow(id: e.id, title: e.name, symbol: folders.symbol(for: e), location: .folder(e.url),
                           expandable: !e.isDimmed, isDimmed: e.isDimmed)
        }
        var sections = [
            HomeSidebarSection(id: "library", title: nil, rows: [
                HomeSidebarRow(id: HomeCollections.recent, title: "Recent", symbol: "clock",
                               location: .source(HomeCollections.recent)),
                HomeSidebarRow(id: HomeCollections.sessions, title: "Sessions", symbol: "rectangle.stack",
                               location: .source(HomeCollections.sessions)),
                HomeSidebarRow(id: PhotosLocation.root, title: "Photos", symbol: "photo.on.rectangle",
                               location: .source(PhotosLocation.root)),
            ]),
            HomeSidebarSection(id: "places", title: "Places", rows: places),
        ]
        if hasStash() {
            sections.append(HomeSidebarSection(id: "stash", title: "Stash", rows: [
                HomeSidebarRow(id: HomeCollections.stash, title: "Library", symbol: "server.rack",
                               location: .source(HomeCollections.stash)),
            ]))
        }
        return sections
    }

    /// Into one of Home's own sources (Stash's page too, which lists nothing): the folder's listing, watch and
    /// thumbnails stop; out of Recent or Sessions: their covers and mosaics stop.
    func moved(from old: BrowserLocation?, to new: BrowserLocation) {
        // HomeBrowserView subscribes to the destination before notifying us. On an internal Photos move,
        // stopping the source here would cancel the destination's newly registered listing task.
        if isPhotos(old), !isPhotos(new) { photos.stop() }
        else if isPhotos(old), old != new { photos.stopPictures() }
        let wasSource = if case .source? = old { true } else { false }
        if case .source = new, !wasSource { folders.leave() }
        if wasSource, old != new { collections.stopPictures() }
    }

    /// Folder and zip cards get their facts and covers from the cover queue: they wait for them, shimmering, until
    /// they come or the folders' source gives up on them (`FolderBrowserSource.noCover`).
    var sendsCardFacts: Bool { true }

    /// The progress popover's Pause / Resume: the user's pause of the work ahead, the session's (every window's).
    func pauseThumbs(_ on: Bool, in location: BrowserLocation) { folders.pauseAhead(on) }

    /// The progress popover's Prepare subfolders: the walk from the folder on screen.
    func prepareSubtree(of location: BrowserLocation) { folders.prepareShownSubtree(of: location) }

    /// The progress popover's Stop preparing (while the walk runs): the walk ends.
    func stopSubtree(in location: BrowserLocation) { folders.stopSubtree() }

    /// The room the folder's volume has (`1.2 TB free` under the folder's name): asked of the volume off the main thread,
    /// a second at most, so a share that does not answer leaves the line as it was.
    func freeSpace(for location: BrowserLocation) async -> Int64? {
        guard case .folder(let url) = location else { return nil }
        return await BrowserPlaces.freeSpace(of: [url], timeout: .seconds(1))[url]
    }

    func pageFilterChosen(_ index: Int, in source: String) {
        if source == HomeCollections.stash { collections.onStashFilter?(index) }
    }
}
