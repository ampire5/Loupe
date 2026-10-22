import AppKit
import HomeScreenKit
import LoupeCore

/// What a click on a Recent card or its menu asks for (Home spec §2.3).
enum HomeCardAction {
    case open, openNewTab, openNewWindow, showInFinder, copyPath, remove
}

/// What a session card's click or menu asks for (Home spec §2.3).
enum SessionCardAction {
    case open, rename, replaceWithCurrent, delete
}

/// Home's own sources on Loupe's data (Photos style spec §3.4, §3.6, §3.8): Recent from the recent store with the
/// unreachable dimmed, the sessions, and Stash's page. Covers (Recent) and mosaics (Sessions) are read as the cards ask;
/// clicks and menus go back to the window as actions.
@MainActor final class CollectionSource {
    weak var view: HomeBrowserView?
    var onRecent: ((RecentEntry, HomeCardAction) -> Void)?
    var onSession: ((SavedSession, SessionCardAction) -> Void)?
    /// A segment of Stash's filter (Scenes, Images, Galleries).
    var onStashFilter: ((Int) -> Void)?

    private let thumbnails: ThumbnailStore
    private let recent: () -> [RecentEntry]
    private let sessions: () -> [SavedSession]
    private let stashPage: () -> NSView?
    /// What the last listings showed, by card id: clicks, menus and pictures look them up.
    private var shownRecent: [String: RecentEntry] = [:]
    private var shownSessions: [String: SavedSession] = [:]
    /// The last Recent listing's reachability check: its dimming, and what the covers wait for.
    private var reachability: RecentReachability?
    /// Recent's and Sessions' sorts, for this run.
    private var sorts: [String: BrowserSort] = [:]
    private var pictureTask: Task<Void, Never>?
    /// How a session's card shows its photos (`folder-cover`, as folders' cards do).
    var coverLayout = HomeMosaic.Layout.hero

    init(thumbnails: ThumbnailStore, recent: @escaping () -> [RecentEntry], sessions: @escaping () -> [SavedSession],
         stashPage: @escaping () -> NSView?) {
        self.thumbnails = thumbnails
        self.recent = recent
        self.sessions = sessions
        self.stashPage = stashPage
    }

    func info(for id: String) -> HomeSourceInfo {
        switch id {
        case HomeCollections.sessions:
            HomeSourceInfo(title: "Sessions", sortKeys: [.date, .name], noun: "session",
                           emptyHint: "No saved sessions — File › Save Session As…")
        case HomeCollections.stash:
            HomeSourceInfo(title: "Stash", page: stashPage(), pageFilters: ["Scenes", "Images", "Galleries"])
        default:
            HomeSourceInfo(title: "Recent", sortKeys: [.date, .name], groupsByDate: true, noun: "item",
                           emptyHint: "Open a photo with ⌘O or drop it here")
        }
    }

    // MARK: Listings

    /// Recent read afresh from the store (dimmed after the reachability check), or the sessions; a page has none.
    func list(_ id: String) -> AsyncThrowingStream<BrowserListing, Error> {
        switch id {
        case HomeCollections.recent:
            let entries = recent()
            shownRecent = Dictionary(entries.map { ("recent:" + $0.path, $0) }, uniquingKeysWith: { a, _ in a })
            reachability?.cancel()
            let reachability = RecentReachability(paths: entries.map(\.path)) { paths in
                await HomeGrid.availability(of: paths, timeout: .seconds(1))
            }
            self.reachability = reachability
            let listings = HomeCollections.recentListings(entries, now: Date()) { _ in await reachability.answers }
            return AsyncThrowingStream { continuation in
                let task = Task { @MainActor in
                    for await listing in listings {
                        guard !Task.isCancelled else { return }
                        continuation.yield(listing)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        case HomeCollections.sessions:
            let saved = sessions()
            shownSessions = Dictionary(saved.map { ("session:\($0.id)", $0) }, uniquingKeysWith: { a, _ in a })
            let entries = HomeCollections.sessionEntries(saved)
            return AsyncThrowingStream { continuation in
                continuation.yield(BrowserListing(entries: entries, complete: true))
                continuation.finish()
            }
        default:
            return AsyncThrowingStream { $0.finish() }
        }
    }

    /// Home left Recent or Sessions: no more covers or mosaics for it.
    func stopPictures() {
        pictureTask?.cancel()
        pictureTask = nil
    }

    func sort(for id: String) -> BrowserSort { sorts[id] ?? BrowserSort(key: .date, ascending: false) }
    func setSort(_ sort: BrowserSort, for id: String) { sorts[id] = sort }

    // MARK: Pictures

    /// The cards' pictures, in the order asked (those in view first): a recent folder's last photo, a session's first
    /// four photos two by two. An unreachable share is never read.
    func wantImages(_ ids: [String], width: CGFloat) {
        pictureTask?.cancel()
        let scale = view?.window?.backingScaleFactor ?? 2
        let maxPixel = Int((width * scale).rounded())
        let layout = coverLayout
        let cellPixels = layout.cellPixels(width: width, scale: scale)
        let thumbnails = self.thumbnails
        let wanted = ids
        let reachability = self.reachability
        pictureTask = Task { @MainActor [weak self] in
            // Recent's covers wait for its reachability check (a second at most): a gone share is never read.
            let gone = wanted.contains { $0.hasPrefix("recent:") } ? await reachability?.unreachable ?? [] : []
            for id in wanted {
                guard let self, !Task.isCancelled else { return }
                if let e = self.shownRecent[id] {
                    guard !gone.contains(e.path), let file = e.file else { continue }
                    let image = await thumbnails.cover(e.url.appendingPathComponent(file), maxPixel: maxPixel)
                    guard !Task.isCancelled else { return }
                    if let image { self.view?.setImage(image, for: id) }
                } else if let s = self.shownSessions[id] {
                    let files = s.snapshot.windows.flatMap(\.tabs).compactMap { tab -> URL? in
                        if case .file(let path, _) = tab { return URL(fileURLWithPath: path) }
                        return nil
                    }.prefix(4)
                    var pictures: [CGImage] = []
                    for url in files {
                        if let image = await thumbnails.cover(url, maxPixel: cellPixels) { pictures.append(image) }
                    }
                    guard !Task.isCancelled else { return }
                    // Drawn off the main thread.
                    let made = await Task.detached(priority: .utility) { [pictures] in
                        HomeMosaic.make(pictures, size: CGSize(width: width, height: width), layout: layout, scale: scale)
                    }.value
                    guard !Task.isCancelled else { return }
                    if let mosaic = made {
                        self.view?.setImage(mosaic, for: id)
                    }
                }
            }
        }
    }

    // MARK: Clicks and menus

    func menu(for entry: BrowserEntry) -> [HomeMenuItem] {
        switch HomeCollections.target(entry.id) {
        case .recent: HomeCollections.recentMenu()
        case .session: HomeCollections.sessionMenu(isLast: entry.leads)
        case nil: []
        }
    }

    func open(_ entry: BrowserEntry, how: HomeClick) {
        if let e = shownRecent[entry.id] {
            switch how {
            case .open: onRecent?(e, .open)
            case .openNewTab: onRecent?(e, .openNewTab)
            case .openNewWindow: onRecent?(e, .openNewWindow)
            }
        } else if let s = shownSessions[entry.id] {
            onSession?(s, .open)
        }
    }

    func perform(_ item: String, on entry: BrowserEntry) {
        if let e = shownRecent[entry.id] {
            let action: HomeCardAction? = switch item {
            case "tab": .openNewTab
            case "window": .openNewWindow
            case "finder": .showInFinder
            case "copy": .copyPath
            case "remove": .remove
            default: nil
            }
            if let action { onRecent?(e, action) }
        } else if let s = shownSessions[entry.id] {
            let action: SessionCardAction? = switch item {
            case "open": .open
            case "rename": .rename
            case "replace": .replaceWithCurrent
            case "delete": .delete
            default: nil
            }
            if let action { onSession?(s, action) }
        }
    }
}
