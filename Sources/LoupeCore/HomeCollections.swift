import Foundation
import HomeScreenModel

/// Home's own sources as the browser's entries (Photos style spec §3.4, §3.6): recent folders, archives and Stash
/// galleries, and the saved sessions, as collection cards; their ids, menus and where each Home tab is. A card's id
/// says what it stands for (`target`); menu item ids are the actions the controller runs.
public enum HomeCollections {
    public static let recent = "recent", sessions = "sessions", stash = "stash"

    /// What a card's id stands for.
    public enum Target: Equatable, Sendable {
        case session(Int64)
        case recent(String)
    }

    /// Where a Home tab is in the browser; Folders has no place of its own (the browser's last folder).
    public static func location(of tab: HomeTab) -> BrowserLocation? {
        switch tab {
        case .recent: .source(recent)
        case .sessions: .source(sessions)
        case .stash: .source(stash)
        case .folders: nil
        }
    }

    /// The Home tab a location belongs to: the places and every folder are Folders.
    public static func tab(of location: BrowserLocation) -> HomeTab {
        switch location {
        case .source(sessions): .sessions
        case .source(stash): .stash
        case .source: .recent
        case .places, .folder: .folders
        }
    }

    // MARK: Recent

    public static func recentEntries(_ entries: [RecentEntry], dimmed: Set<String>, now: Date) -> [BrowserEntry] {
        entries.map { e in
            var progress: Double?
            if let index = e.index, let count = e.count, count > 0 { progress = min(1, Double(index + 1) / Double(count)) }
            return BrowserEntry(url: e.url, name: e.displayTitle, kind: .collection, date: e.opened,
                                isDimmed: dimmed.contains(e.path), key: "recent:\(e.path)", subtitle: recentLine(e, now: now),
                                progress: progress, badge: e.gallery != nil ? "Stash" : nil)
        }
    }

    /// Recent as listings: at once as the store has it, then, once `availability` answers, again with the paths that
    /// cannot be reached dimmed (only when there are any). A share that does not answer holds nothing back.
    public static func recentListings(_ entries: [RecentEntry], now: Date,
                                      availability: @escaping @Sendable ([String]) async -> [String: Bool?])
        -> AsyncStream<BrowserListing> {
        AsyncStream { continuation in
            continuation.yield(BrowserListing(entries: recentEntries(entries, dimmed: [], now: now), complete: true))
            let task = Task {
                let reachable = await availability(entries.map(\.path))
                let gone = Set(entries.map(\.path).filter { reachable[$0] == .some(false) })
                if !gone.isEmpty, !Task.isCancelled {
                    continuation.yield(BrowserListing(entries: recentEntries(entries, dimmed: gone, now: now), complete: true))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `137 / 2 719 · 2 h ago`: the photo last viewed and when the folder was opened.
    public static func recentLine(_ e: RecentEntry, now: Date) -> String? {
        var parts: [String] = []
        if let index = e.index {
            parts.append(e.count.map { "\(index + 1) / \(BrowserSummary.number($0))" } ?? "\(index + 1)")
        }
        parts.append(ago(e.opened, now: now))
        return parts.joined(separator: " · ")
    }

    /// `now`, `5 min ago`, `2 h ago`, else the day (`17 Oct`).
    static func ago(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600)) h ago" }
        return dayFormat.string(from: date)
    }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "d MMM"
        return f
    }()

    public static func recentMenu() -> [HomeMenuItem] {
        [HomeMenuItem(id: "tab", title: "Open in New Tab"), HomeMenuItem(id: "window", title: "Open in New Window"),
         HomeMenuItem(id: "finder", title: "Show in Finder"), HomeMenuItem(id: "copy", title: "Copy Path"),
         HomeMenuItem(id: "remove", title: "Remove from Recent")]
    }

    // MARK: Sessions

    /// Last Session leads whatever the sort, with its `Last` pill.
    public static func sessionEntries(_ sessions: [SavedSession]) -> [BrowserEntry] {
        sessions.map { s in
            BrowserEntry(url: URL(string: "loupe-session:\(s.id)")!, name: s.name, kind: .collection, date: s.saved,
                         key: "session:\(s.id)", subtitle: summary(s), badge: s.isLast ? "Last" : nil, leads: s.isLast)
        }
    }

    public static func sessionMenu(isLast: Bool) -> [HomeMenuItem] {
        [HomeMenuItem(id: "open", title: "Open")]
            + (isLast ? [] : [HomeMenuItem(id: "rename", title: "Rename…"),
                              HomeMenuItem(id: "replace", title: "Replace with Current Windows")])
            + [HomeMenuItem(id: "delete", title: "Delete…")]
    }

    /// "2 windows · 7 tabs · Today 14:02".
    static func summary(_ s: SavedSession) -> String {
        let w = s.snapshot.windows.count, t = s.snapshot.tabCount
        let when = Calendar.current.isDateInToday(s.saved)
            ? "Today " + s.saved.formatted(date: .omitted, time: .shortened)
            : s.saved.formatted(date: .abbreviated, time: .omitted)
        return "\(w) window\(w == 1 ? "" : "s") · \(t) tab\(t == 1 ? "" : "s") · \(when)"
    }

    // MARK: Ids

    public static func target(_ key: String) -> Target? {
        if key.hasPrefix("session:"), let n = Int64(key.dropFirst("session:".count)) { return .session(n) }
        if key.hasPrefix("recent:") { return .recent(String(key.dropFirst("recent:".count))) }
        return nil
    }
}

/// Recent's one reachability check (`HomeGrid.availability`, a second at most): the listing dims what it finds gone
/// and the covers wait for it, so a share that does not answer is never read for a cover.
public final class RecentReachability: Sendable {
    private let task: Task<[String: Bool?], Never>

    public init(paths: [String], check: @escaping @Sendable ([String]) async -> [String: Bool?]) {
        task = Task { await check(paths) }
    }

    /// True, false, or nil for a path that did not answer in time.
    public var answers: [String: Bool?] { get async { await task.value } }

    /// The paths found gone.
    public var unreachable: Set<String> {
        get async { Set(await answers.compactMap { $0.value == .some(false) ? $0.key : nil }) }
    }

    public func cancel() { task.cancel() }
}

/// When Home's source is worth writing back as `home-tab`: on the user's own move to another tab than the window last
/// showed, not on the window's own shows, reloads, a remount or a folder gone.
public struct HomeTabMemory: Sendable {
    private var last: HomeTab?

    public init() {}

    /// The tab to save, if any; `saved` is `home-tab` as it is now.
    public mutating func moved(to tab: HomeTab, byUser: Bool, saved: HomeTab) -> HomeTab? {
        defer { last = tab }
        return byUser && tab != last && tab != saved ? tab : nil
    }
}

