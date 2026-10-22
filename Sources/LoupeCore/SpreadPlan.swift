/// How pages are paired for a two-page spread.
public struct SpreadOptions: Equatable, Sendable {
    /// The first page stands alone (a cover) and pairs start from the second.
    public var shift: Bool
    /// Reading direction; the on-screen order is decided by the layout, not by the plan.
    public var rightToLeft: Bool
    /// A landscape page is shown alone instead of sharing a spread.
    public var landscapeAlone: Bool

    public init(shift: Bool, rightToLeft: Bool, landscapeAlone: Bool) {
        self.shift = shift
        self.rightToLeft = rightToLeft
        self.landscapeAlone = landscapeAlone
    }
}

/// One spread: a page or two consecutive pages.
public struct SpreadPair: Equatable, Sendable {
    public let first: Int
    public let second: Int?

    public init(first: Int, second: Int?) {
        self.first = first
        self.second = second
    }

    /// Pages in paging order (the on-screen order is up to the layout).
    public var pages: [Int] { second.map { [first, $0] } ?? [first] }
}

/// Pairs pages of a folder into spreads. Built once in a single O(n) pass;
/// queries are O(log n).
public struct SpreadPlan: Sendable {
    private let count: Int
    /// First page of each spread, ascending.
    private let starts: [Int]
    /// Parallel to `starts`: the spread holds two pages.
    private let isPair: [Bool]

    /// `sizes` are the visible sizes after orientation; nil (unknown) counts as portrait.
    public init(sizes: [PixelSize?], options: SpreadOptions) {
        count = sizes.count
        func landscape(_ i: Int) -> Bool {
            guard options.landscapeAlone, let s = sizes[i] else { return false }
            return s.width > s.height
        }
        var starts: [Int] = []
        var isPair: [Bool] = []
        starts.reserveCapacity(sizes.count / 2 + 1)
        isPair.reserveCapacity(sizes.count / 2 + 1)
        var i = 0
        if options.shift, sizes.count > 0 {
            starts.append(0)
            isPair.append(false)
            i = 1
        }
        while i < sizes.count {
            let pairs = i + 1 < sizes.count && !landscape(i) && !landscape(i + 1)
            starts.append(i)
            isPair.append(pairs)
            i += pairs ? 2 : 1
        }
        self.starts = starts
        self.isPair = isPair
    }

    public var first: SpreadPair? { starts.isEmpty ? nil : pair(at: 0) }
    public var last: SpreadPair? { starts.isEmpty ? nil : pair(at: starts.count - 1) }

    public func pair(containing index: Int) -> SpreadPair? {
        guard index >= 0, index < count else { return nil }
        // Last start <= index.
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= index { lo = mid } else { hi = mid - 1 }
        }
        return pair(at: lo)
    }

    public func next(after pair: SpreadPair) -> SpreadPair? {
        guard let p = self.pair(containing: pair.first) else { return nil }
        return self.pair(containing: (p.second ?? p.first) + 1)
    }

    public func previous(before pair: SpreadPair) -> SpreadPair? {
        self.pair(containing: pair.first - 1)
    }

    private func pair(at k: Int) -> SpreadPair {
        SpreadPair(first: starts[k], second: isPair[k] ? starts[k] + 1 : nil)
    }
}
