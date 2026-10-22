import AppKit
import HomeScreenKit
import LoupeCore

/// Home's source for the browser and the sidebar (Photos style spec §6): the places and folders from
/// `FolderBrowserSource`, Recent, Sessions and Stash from `CollectionSource`, each request sent by its location or by
/// its card's kind.
@MainActor final class LoupeHomeSource: HomeSource {
    let folders: FolderBrowserSource
    let collections: CollectionSource
    /// Whether Stash has an address (its sidebar section).
    private let hasStash: () -> Bool

    init(folders: FolderBrowserSource, collections: CollectionSource, hasStash: @escaping () -> Bool) {
        self.folders = folders
        self.collections = collections
        self.hasStash = hasStash
    }

    /// The browser both halves draw into.
    weak var view: HomeBrowserView? {
        didSet {
            folders.view = view
            collections.view = view
        }
    }

    func places() async -> [BrowserEntry] { await folders.places() }

    func list(_ location: BrowserLocation) -> AsyncThrowingStream<BrowserListing, Error> {
        if case .source(let id) = location { return collections.list(id) }
        return folders.list(location)
    }

    func folders(in folder: URL) async -> [BrowserEntry] { await folders.folders(in: folder) }
    func parent(of folder: URL) -> BrowserLocation { folders.parent(of: folder) }
    func symbol(for entry: BrowserEntry) -> String { folders.symbol(for: entry) }

    func wantImages(_ ids: [String], width: CGFloat) { wantImages(ids, visible: ids.count, width: width) }

    /// The first `visible` of `ids` are in view: a folder's cards in view get their covers before the margin's.
    func wantImages(_ ids: [String], visible: Int, width: CGFloat) {
        if case .source = view?.location {
            collections.wantImages(ids, width: width)
        } else {
            folders.wantImages(ids, visible: visible, width: width)
        }
    }

    func menu(for entry: BrowserEntry, in location: BrowserLocation) -> [HomeMenuItem] {
        entry.kind == .collection ? collections.menu(for: entry) : folders.menu(for: entry, in: location)
    }

    func perform(_ item: String, on entry: BrowserEntry, in location: BrowserLocation) {
        if entry.kind == .collection { collections.perform(item, on: entry) } else { folders.perform(item, on: entry, in: location) }
    }

    func open(_ entry: BrowserEntry, in location: BrowserLocation, sort: BrowserSort, how: HomeClick) {
        if entry.kind == .collection {
            collections.open(entry, how: how)
        } else {
            folders.open(entry, in: location, sort: sort, how: how)
        }
    }

    func rename(_ entry: BrowserEntry, to name: String) async throws -> BrowserEntry { try await folders.rename(entry, to: name) }
    func trash(_ entry: BrowserEntry) async throws { try await folders.trash(entry) }

    func sort(for location: BrowserLocation) -> BrowserSort {
        if case .source(let id) = location { return collections.sort(for: id) }
        return folders.sort(for: location)
    }

    func setSort(_ sort: BrowserSort, for location: BrowserLocation) {
        if case .source(let id) = location { collections.setSort(sort, for: id) } else { folders.setSort(sort, for: location) }
    }

    /// Only a folder's own cards have a style (`folder-cards`); the collections are drawn as they are.
    func cardStyle(for location: BrowserLocation) -> CardStyle { folders.cardStyle(for: location) }

    func setCardStyle(_ style: CardStyle, for location: BrowserLocation) { folders.setCardStyle(style, for: location) }

    func info(for source: String) -> HomeSourceInfo { collections.info(for: source) }

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
        let wasSource = if case .source? = old { true } else { false }
        if case .source = new, !wasSource { folders.leave() }
        if wasSource, old != new { collections.stopPictures() }
    }

    func pageFilterChosen(_ index: Int, in source: String) {
        if source == HomeCollections.stash { collections.onStashFilter?(index) }
    }
}
