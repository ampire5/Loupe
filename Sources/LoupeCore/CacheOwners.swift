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
    /// The neighbours the session's keep set holds at preview level, when the caller knows them.
    public var previousURL: URL?
    public var nextURL: URL?
    /// The level the photo on screen needs: `.full` at a zoom that shows more than the preview, else `.preview`.
    public var currentGoal: CacheGoal = .preview
    /// The second page of a spread on screen, held at the same level as `currentURL`.
    public var companionURL: URL?

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
    /// What one session keeps resident while it is not in front: URL → the level it is held at.
    public typealias KeepSet = [URL: CacheGoal]

    /// Keep sets (spec window-cache-ownership §1): per session the photo on screen (and the second page of a
    /// spread) at `currentGoal` plus one neighbour each side at `.preview`. When the sum of estimated sizes, an
    /// entry listed by several sessions counted once at its highest level, exceeds `share`, they are truncated
    /// in the order of the longest unused session first: the inactive sessions' neighbours, then their current
    /// photos down to `.preview`, then the whole sets of those neither active nor visible, and last the active
    /// session's neighbours (its own plan reads them anyway). The active session keeps its current photo at the
    /// level it needs whatever the share; with `share` 0 what is left is `protected`.
    public static func keepSets(_ sessions: [CacheOwnerFacts], share: Int,
                                estimate: (URL, CacheGoal) -> Int) -> [CacheSessionID: KeepSet] {
        struct Held {
            var current: KeepSet = [:]
            var neighbours: KeepSet = [:]
            var set: KeepSet { current.merging(neighbours) { max($0, $1) } }
        }
        var held: [CacheSessionID: Held] = [:]
        for s in sessions {
            var h = Held()
            if let url = currentURL(of: s) {
                h.current[url] = s.currentGoal
                if let c = s.companionURL { h.current[c] = max(h.current[c] ?? .bytes, s.currentGoal) }
                for n in [s.previousURL, s.nextURL] {
                    if let n, h.current[n] == nil { h.neighbours[n] = .preview }
                }
            }
            held[s.id] = h
        }
        let order = sessions.sorted { a, b in
            if a.isActive != b.isActive { return b.isActive }
            if a.lastActive != b.lastActive { return a.lastActive < b.lastActive }
            return a.id.raw < b.id.raw
        }
        func total() -> Int {
            var union: KeepSet = [:]
            for h in held.values { union.merge(h.set) { max($0, $1) } }
            return union.reduce(0) { $0 + estimate($1.key, $1.value) }
        }
        var sum = total()
        func dropNeighbours(_ s: CacheOwnerFacts) {
            guard sum > share, !(held[s.id]?.neighbours.isEmpty ?? true) else { return }
            held[s.id]?.neighbours = [:]
            sum = total()
        }
        for s in order where !s.isActive { dropNeighbours(s) }
        for s in order where sum > share && !s.isActive {
            guard var h = held[s.id], h.current.contains(where: { $0.value > .preview }) else { continue }
            for (url, goal) in h.current { h.current[url] = min(goal, .preview) }
            held[s.id] = h
            sum = total()
        }
        for s in order where sum > share && !s.isActive && !s.isVisible {
            guard let h = held[s.id], !h.current.isEmpty else { continue }
            held[s.id] = Held()
            sum = total()
        }
        for s in order where s.isActive { dropNeighbours(s) }
        return held.mapValues(\.set)
    }

    /// The union of the sessions' keep sets: every URL held by any of them, at the highest level any asks.
    public static func kept(_ sets: [CacheSessionID: KeepSet]) -> [URL: CacheGoal] {
        var union: [URL: CacheGoal] = [:]
        for set in sets.values { union.merge(set) { max($0, $1) } }
        return union
    }

    private static func currentURL(of s: CacheOwnerFacts) -> URL? {
        if let url = s.currentURL { return url }
        guard let current = s.current else { return nil }
        return s.fileIndex.first(where: { $0.value == current })?.key
    }

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
        evictionOrder(urls, sessions: sessions, kept: protected(sessions))
    }

    /// As above, with `kept` (the keep sets' URLs, see `keepSets`) in place of `protected`.
    public static func evictionOrder(_ urls: [URL], sessions: [CacheOwnerFacts], kept keep: Set<URL>) -> [URL] {
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
