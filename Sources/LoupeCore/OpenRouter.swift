import Foundation

/// What is being opened (windows-and-tabs spec §2.2).
public enum OpenTarget: Equatable, Sendable {
    case file(URL)                 // a photo, a zip to enter, or a zip entry
    case folder(URL)               // a directory to enter (the caller checked the path is one)
    case stashGallery(id: String)
    case photos(album: String, asset: String)
}

/// What the router needs to know about one viewer tab.
public struct TabFacts: Equatable, Sendable {
    public var tab: Int            // controller identity
    public var window: Int         // the tab group (window) it is in
    public var current: URL?       // nil while the tab shows Stash or nothing
    public var folder: URL?        // folder or archive of `current`; nil while Stash is on screen
    public var stashGallery: String?
    public var lastActive: Int     // larger = more recent

    public init(tab: Int, window: Int, current: URL?, folder: URL?, stashGallery: String?, lastActive: Int) {
        self.tab = tab
        self.window = window
        self.current = current
        self.folder = folder
        self.stashGallery = stashGallery
        self.lastActive = lastActive
    }
}

public enum OpenDecision: Equatable, Sendable {
    case focus(tab: Int, open: URL?)   // open: the file to switch the tab to, nil = leave as is
    case newTab(besideTab: Int)        // in the window of that tab
    case newWindow
    case replace(tab: Int)
}

/// An open asked for a place whatever is open and whatever `open-in` says: ⌘-click or middle click in Stash and File ›
/// Open in New Tab (`tab`), ⇧-click or ⇧ + middle click and File › Open in New Window (`window`).
public enum OpenForce: Equatable, Sendable { case tab, window }

/// Where an open goes: an already-open tab, a new tab or window, or the current tab. Pure.
public enum OpenRouter {
    /// Spec §2.2: the same file, then the same folder (archive), then the same Stash gallery; of several tabs the most
    /// recently active (ties: the first in `tabs`). `front`: the front viewer tab (nil: no window). `force`: no matching,
    /// a new tab beside `front` (a new window without a front tab) or a new window, whatever `openIn` says.
    public static func route(_ target: OpenTarget, tabs: [TabFacts], front: Int?, openIn: OpenIn,
                             force: OpenForce? = nil) -> OpenDecision {
        if force == nil, let hit = match(target, in: tabs) { return hit }
        guard let front else { return .newWindow }
        switch force {
        case .tab: return .newTab(besideTab: front)
        case .window: return .newWindow
        case nil: break
        }
        switch openIn {
        case .tab: return .newTab(besideTab: front)
        case .window: return .newWindow
        case .replace: return .replace(tab: front)
        }
    }

    /// Several opens at once: the first of each folder (archive), in the given order. A file is keyed by its folder, a
    /// folder to enter by itself; Stash galleries pass through.
    public static func firstPerFolder(_ targets: [OpenTarget]) -> [OpenTarget] {
        var seen = Set<String>()
        return targets.filter {
            switch $0 {
            case .file(let url): return seen.insert(folder(of: url).path).inserted
            case .folder(let url): return seen.insert(url.standardizedFileURL.path).inserted
            case .stashGallery, .photos: return true
            }
        }
    }

    /// The folder a file belongs to: its archive for a zip entry, a zip itself for a zip, else the parent.
    public static func folder(of url: URL) -> URL {
        let url = url.standardizedFileURL
        if let archive = ArchivePath.split(url)?.archive { return archive }
        return ArchivePath.isArchive(url) ? url : url.deletingLastPathComponent()
    }

    private static func match(_ target: OpenTarget, in tabs: [TabFacts]) -> OpenDecision? {
        // by path: a directory URL with and without the trailing slash is the same place
        func path(_ url: URL?) -> String? { url?.standardizedFileURL.path }
        func latest(_ hits: [TabFacts]) -> TabFacts? {
            hits.reduce(nil) { best, t in t.lastActive > (best?.lastActive ?? Int.min) ? t : best }
        }
        switch target {
        case .photos(let album, let asset):
            guard let hit = latest(tabs.filter { $0.current.flatMap(PhotosLocation.album(in:)) == album }) else { return nil }
            // The source grid may have changed its collection sort in another window. Reopen the source target
            // even for the same selected asset so that this viewer refreshes its sequence from the shared choice.
            return .focus(tab: hit.tab, open: PhotosLocation.assetURL(album: album, asset: asset, revision: ""))
        case .stashGallery(let id):
            return latest(tabs.filter { $0.stashGallery == id }).map { .focus(tab: $0.tab, open: nil) }
        case .folder(let url):
            return latest(tabs.filter { path($0.folder) == path(url) }).map { .focus(tab: $0.tab, open: nil) }
        case .file(let url):
            let url = url.standardizedFileURL
            if let t = latest(tabs.filter { $0.folder != nil && path($0.current) == url.path }) {
                return .focus(tab: t.tab, open: nil)
            }
            // a zip that is itself a tab's folder
            if let t = latest(tabs.filter { path($0.folder) == url.path }) {
                return .focus(tab: t.tab, open: nil)
            }
            let folder = folder(of: url).path
            if let t = latest(tabs.filter { path($0.folder) == folder }) {
                return .focus(tab: t.tab, open: url)
            }
            return nil
        }
    }
}
