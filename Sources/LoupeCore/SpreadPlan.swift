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

/// Why `D` shows one page where the user may expect two (the toast after `D` says it).
public enum SpreadRefusal: Equatable, Sendable {
    /// The page is wide (`spread-landscape = alone`).
    case widePage
    /// The page it would pair with is wide.
    case wideNext
    /// The view is taller than wide (`SpreadLayout.showsTwo`).
    case narrowWindow
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
    /// A page stands alone (`landscapeAlone`) only when it is clearly wide: wider than this times its height. Square
    /// and near-square pages pair: scans keep a margin of their own (a portrait page scanned with the glass's edge comes
    /// out 1.0–1.1), and 1:1 photos are not landscape. 5:4 (1.25), 4:3 (1.33) and 3:2 (1.5) photos and a magazine's
    /// double page (~1.4) stay alone. Not measured: chosen between the widest near-square scans (~1.1) and 5:4.
    public static let landscapeAspect = 1.15

    /// Whether a page of `size` stands alone as landscape (nil: unknown, portrait).
    public static func isLandscape(_ size: PixelSize?) -> Bool {
        guard let size, size.height > 0 else { return false }
        return Double(size.width) > Double(size.height) * landscapeAspect
    }

    private let count: Int
    /// First page of each spread, ascending.
    private let starts: [Int]
    /// Parallel to `starts`: the spread holds two pages.
    private let isPair: [Bool]
    /// The pages standing alone as landscape, by index ([] with `landscapeAlone` off).
    private let wide: [Bool]
    /// The first page stands alone as a cover.
    private let shift: Bool

    /// `sizes` are the visible sizes after orientation; nil (unknown) counts as portrait.
    public init(sizes: [PixelSize?], options: SpreadOptions) {
        count = sizes.count
        shift = options.shift
        let wide = options.landscapeAlone ? sizes.map(Self.isLandscape) : []
        self.wide = wide
        // `i` is in range (the caller checks `i + 1 < count` first).
        func landscape(_ i: Int) -> Bool { !wide.isEmpty && wide[i] }
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

    /// The page at `index` stands alone because it is wide (`landscapeAlone`).
    public func isWide(_ index: Int) -> Bool { wide.indices.contains(index) && wide[index] }

    /// Why the page at `index` stands alone when the reason is not on screen: it is wide, or the page it would pair with
    /// is. Nil for a page in a pair, a cover (`shift`) or the folder's last page.
    public func refusal(at index: Int) -> SpreadRefusal? {
        guard let pair = pair(containing: index), pair.second == nil, !(shift && index == 0) else { return nil }
        if isWide(index) { return .widePage }
        return isWide(index + 1) ? .wideNext : nil
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
