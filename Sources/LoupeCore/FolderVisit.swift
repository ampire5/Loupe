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
        let grown = max(0, summary.photos - visit.count)
        guard let dates else { return grown }
        return max(grown, dates.reduce(0) { $0 + ($1 > visit.visited ? 1 : 0) })
    }
}
