import Foundation

/// Where the thumbnail strip takes the mouse (spec §4.1, §4.3), in the strip view's coordinates: `width` × `height`
/// is the band, `padding` its inset above and below the cells, and `frames` the cells as shown (magnified while
/// `hovering`, base otherwise; heights grow upwards from `padding`).
///
/// - The grab band for resizing is the `padding` just above the shown top edge: the band's top `padding` where no
///   cell is shown magnified, and `[padding + h, padding + h + padding)` over a magnified cell of shown height `h`,
///   outside the band (Build 1.1 trial: a cursor moving at a human pace overshot the 4 pt above the base cells, and
///   the cell growing under it then covered them, so the edge could never be caught). A cell's body is never the
///   grab band, so a press on a cell always scrubs.
/// - The hover zone is the band minus the grab band and, once hovering, the magnified cells above the band and the
///   grab band over them too, so neither a cell nor the grab band on its top collapses under a cursor that moves up
///   into it. Without a hover the frames are the base ones, which never reach the grab band or above the band, so a
///   cursor coming down from the photo starts no hover before it reaches the cells.
public struct StripHitZone {
    public let frames: [(x: Double, width: Double, height: Double)]
    public let width: Double
    public let height: Double
    public let padding: Double
    public let hovering: Bool

    public init(frames: [(x: Double, width: Double, height: Double)], width: Double, height: Double,
                padding: Double, hovering: Bool) {
        self.frames = frames
        self.width = width
        self.height = height
        self.padding = padding
        self.hovering = hovering
    }

    private func inBand(x: Double, y: Double) -> Bool { x >= 0 && x < width && y >= 0 && y < height }

    /// Inside a cell's shown frame while hovering.
    public func overMagnifiedCell(x: Double, y: Double) -> Bool {
        guard hovering, y >= padding, x >= 0, x < width else { return false }
        return frames.contains { x >= $0.x && x < $0.x + $0.width && y < padding + $0.height }
    }

    /// The shown height of the cell under `x` while hovering; nil without a hover or beside the cells. A press in
    /// the grab band drags this cell's top (`StripResizeDrag`).
    public func shownCellHeight(atX x: Double) -> Double? {
        guard hovering else { return nil }
        return frames.first { x >= $0.x && x < $0.x + $0.width }?.height
    }

    public func inResizeBand(x: Double, y: Double) -> Bool {
        guard x >= 0, x < width else { return false }
        let top = shownCellHeight(atX: x).map { padding + $0 + padding } ?? height
        return y >= top - padding && y < top
    }

    public func inHoverZone(x: Double, y: Double) -> Bool {
        if inResizeBand(x: x, y: y) { return shownCellHeight(atX: x) != nil }
        return inBand(x: x, y: y) || overMagnifiedCell(x: x, y: y)
    }
}
