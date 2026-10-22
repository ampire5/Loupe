import FilmstripModel

/// The strip's current cells for what the viewer shows (spread spec, «Положение»): the current photo's cell, or both
/// cells of the pair on screen. The strip expands them together and puts the middle of the pair under its centre
/// (`FilmstripLayout.cells(offset:current:expansion:)` with a run, `offset(in:)`). A pair's pages are neighbours in the
/// playlist (`SpreadPlan`), so they are one run of cells whatever the reading order.
public struct StripPages: Equatable, Sendable {
    /// The current cells, in playlist order: one or two items.
    public let items: Range<Int>

    /// One cell.
    public init(item: Int) {
        items = item..<(item + 1)
    }

    /// The pages of `ViewerSession.currentPages` (playlist indices, `second` nil for one page), or the current photo
    /// alone without them.
    public init(current: Int, pages: (first: Int, second: Int?)?) {
        let first = pages?.first ?? current, second = pages?.second ?? first
        self.init(items: min(first, second)..<(max(first, second) + 1))
    }

    private init(items: Range<Int>) {
        self.items = items
    }

    /// Whether `item` is one of the pages on screen: a click or a scrub reaching it has nothing new to show.
    public func contains(_ item: Int) -> Bool { items.contains(item) }

    /// The base offset that puts these cells in the middle of the strip.
    public func offset(in layout: FilmstripLayout) -> Double { layout.centre(of: items) }

    /// Whether the strip moving here from `old` is a step to a neighbour (animated): the two runs touch or overlap (the
    /// next pair, the next photo, or a pair growing from or shrinking to one of its pages). A jump farther moves at once.
    public func isStep(from old: StripPages?) -> Bool {
        guard let old else { return false }
        return items.lowerBound <= old.items.upperBound && old.items.lowerBound <= items.upperBound
    }

    /// The same cells in a new playlist (`FilmstripItems.indexMap`): nil when one of them left it, or they are no
    /// longer neighbours.
    public func remapped(_ map: [Int: Int]) -> StripPages? {
        guard let first = map[items.lowerBound], let last = map[items.upperBound - 1],
              last - first == items.count - 1 else { return nil }
        return StripPages(items: first..<(last + 1))
    }
}
