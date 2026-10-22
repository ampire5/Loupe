import Foundation

/// A visit to a folder, as `FolderPositions` remembers it: which photo was on screen, of how many, and when. A folder
/// card shows progress, a check mark and "+N new" from it.
public struct FolderVisit: Equatable, Sendable {
    /// Zero-based index of the photo shown last.
    public var index: Int
    /// How many photos the folder had then.
    public var count: Int
    /// When the folder was last on screen.
    public var visited: Date

    public init(index: Int, count: Int, visited: Date) {
        self.index = index
        self.count = count
        self.visited = visited
    }

    /// (index + 1) / count, at most 1; 0 for an empty folder.
    public func progress() -> Double {
        guard count > 0 else { return 0 }
        return min(1, max(0, Double(index + 1) / Double(count)))
    }

    /// The last photo was reached.
    public var done: Bool { count > 0 && index >= count - 1 }

    /// Photos that came since `visit` (ruling R2b): the more of those dated after the visit (`dates`, the photos'
    /// modification dates from a local listing) and the growth in the photo count since it (never negative: deleted
    /// files do not count as new). Both, as copied photos keep their old dates; a photo edited in place counts by its
    /// date alone.
    public static func new(since visit: FolderVisit, summary: FolderSummary, dates: [Date]?) -> Int {
        new(since: visit, summary: summary, newer: dates.map { NewPhotoDates($0, since: .distantPast) })
    }

    /// `new(since:summary:dates:)` from the dates a card keeps (`NewPhotoDates`): a binary search.
    public static func new(since visit: FolderVisit, summary: FolderSummary, newer: NewPhotoDates?) -> Int {
        let grown = max(0, summary.photos - visit.count)
        guard let newer else { return grown }
        return max(grown, newer.count(after: visit.visited))
    }
}

/// The modification dates of a folder's photos that may still count as new on its card: those after `since` (the
/// folder's visit when they were listed, or the listing's time without one: a visit recorded later is never earlier),
/// sorted. A folder's card keeps these rather than every photo's date, mostly none or a few, and "+N new" for any
/// later visit is a binary search, not a scan on the main thread.
public struct NewPhotoDates: Equatable, Sendable {
    public let since: Date
    public private(set) var dates: [Date]

    public init(_ all: [Date], since: Date) {
        self.since = since
        dates = all.filter { $0 > since }.sorted()
    }

    /// The photos dated after `date`; for a `date` before `since`, those after `since` (all it knows).
    public func count(after date: Date) -> Int {
        var low = 0, high = dates.count
        while low < high {
            let middle = (low + high) / 2
            if dates[middle] > date { high = middle } else { low = middle + 1 }
        }
        return dates.count - low
    }
}
