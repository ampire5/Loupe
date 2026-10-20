import Foundation

/// Identifies a session (a window's tab) among those sharing one `ImageCache`. `solo` is the single session of a
/// cache that only ever serves one.
public struct CacheSessionID: Hashable, Sendable {
    public let raw: Int
    public init(_ raw: Int) { self.raw = raw }
    public static let solo = CacheSessionID(0)
}

/// What the cache knows of one session: the playlist it plans from and how recently it was in front.
public struct CacheOwnerFacts: Sendable {
    public var id: CacheSessionID
    public var fileIndex: [URL: Int]          // playlist index by URL
    public var current: Int?                  // index of the photo on screen, nil when none
    public var direction: Int                 // +1 / -1 (0 read as +1)
    public var isActive: Bool
    public var isVisible: Bool
    public var lastActive: ContinuousClock.Instant
    /// When the session last went off screen; nil when it never has (or the caller does not say). The idle trim
    /// counts from the later of this and `lastActive`.
    public var hiddenSince: ContinuousClock.Instant?
    /// The URL at `current`, when the caller knows it: saves `protected` a scan of `fileIndex`.
    public var currentURL: URL?

    public init(id: CacheSessionID, fileIndex: [URL: Int], current: Int?, direction: Int, isActive: Bool,
                isVisible: Bool, lastActive: ContinuousClock.Instant, hiddenSince: ContinuousClock.Instant? = nil,
                currentURL: URL? = nil) {
        self.id = id
        self.fileIndex = fileIndex
        self.current = current
        self.direction = direction
        self.isActive = isActive
        self.isVisible = isVisible
        self.lastActive = lastActive
        self.hiddenSince = hiddenSince
        self.currentURL = currentURL
    }
}

/// Which session an entry belongs to and who goes first when memory runs short (spec windows-and-tabs §3.4–3.5).
/// Pure logic: `ImageCache` feeds it the sessions' facts and applies the result.
public enum CacheOwners {
    /// URLs that are never evicted: the current photo of the active and of every visible session.
    public static func protected(_ sessions: [CacheOwnerFacts]) -> Set<URL> {
        var urls = Set<URL>()
        for s in sessions where s.isActive || s.isVisible {
            if let url = s.currentURL { urls.insert(url); continue }
            guard let current = s.current, let url = s.fileIndex.first(where: { $0.value == current })?.key else { continue }
            urls.insert(url)
        }
        return urls
    }

    /// `urls` minus `protected`, first to go first: entries no session lists (in the order given); then those of
    /// invisible and inactive sessions, the longest unused session first; the active session's last. An entry
    /// several sessions list goes by its best owner (the active one, else the latest `lastActive`). Within a
    /// session the entries farthest from its current photo go first (ties: the one behind the direction of
    /// travel, as `ImageCache.evictToFit`), its current photo last.
    public static func evictionOrder(_ urls: [URL], sessions: [CacheOwnerFacts]) -> [URL] {
        let keep = protected(sessions)
        struct Ranked {
            let url: URL
            let position: Int
            let owner: CacheOwnerFacts?
            let far: Int
            let behind: Bool
        }
        let ranked: [Ranked] = urls.enumerated().compactMap { position, url in
            guard !keep.contains(url) else { return nil }
            guard let owner = bestOwner(of: url, sessions: sessions), let index = owner.fileIndex[url] else {
                return Ranked(url: url, position: position, owner: nil, far: 0, behind: false)
            }
            let current = owner.current ?? 0
            let direction = owner.direction < 0 ? -1 : 1
            return Ranked(url: url, position: position, owner: owner, far: abs(index - current),
                          behind: (index - current) * direction < 0)
        }
        return ranked.sorted { a, b in
            switch (a.owner, b.owner) {
            case (nil, nil): return a.position < b.position
            case (nil, _): return true
            case (_, nil): return false
            case let (x?, y?):
                if x.id != y.id {
                    if x.isActive != y.isActive { return y.isActive }
                    if x.lastActive != y.lastActive { return x.lastActive < y.lastActive }
                    return x.id.raw < y.id.raw
                }
                if a.far != b.far { return a.far > b.far }
                if a.behind != b.behind { return a.behind }
                return a.position < b.position
            }
        }.map(\.url)
    }

    /// The session whose screen sets an entry's Lfit: the active one if it lists `url`, else the owner with the
    /// latest `lastActive`; nil for an entry nobody lists.
    public static func holder(of url: URL, sessions: [CacheOwnerFacts]) -> CacheSessionID? {
        bestOwner(of: url, sessions: sessions)?.id
    }

    /// Sessions to trim now: not active, not visible, and neither in front nor on screen for `after` (spec §3.5):
    /// a window that hung inactive but visible on a second monitor starts counting when it goes off screen.
    public static func idle(_ sessions: [CacheOwnerFacts], now: ContinuousClock.Instant,
                            after: Duration) -> [CacheSessionID] {
        sessions.filter { s in
            !s.isActive && !s.isVisible && now - max(s.lastActive, s.hiddenSince ?? s.lastActive) >= after
        }.map(\.id)
    }

    private static func bestOwner(of url: URL, sessions: [CacheOwnerFacts]) -> CacheOwnerFacts? {
        var best: CacheOwnerFacts?
        for s in sessions where s.fileIndex[url] != nil {
            guard let b = best else { best = s; continue }
            if b.isActive { continue }
            if s.isActive || s.lastActive > b.lastActive { best = s }
        }
        return best
    }
}
