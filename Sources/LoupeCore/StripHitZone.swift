import Foundation

/// Where the thumbnail strip takes the mouse (spec §4.1, §4.3), in the strip view's coordinates: `width` × `height`
/// is the band, `padding` its inset above and below the cells. The grab band for resizing is the band's top
/// `padding`, just above the cells; the hover zone is the rest of the band. A cell's body is never the grab band, so
/// a press on a cell always opens it, and a cursor coming down from the photo starts no hover before it reaches the
/// cells.
public struct StripHitZone {
    public let width: Double
    public let height: Double
    public let padding: Double

    public init(width: Double, height: Double, padding: Double) {
        self.width = width
        self.height = height
        self.padding = padding
    }

    public func inResizeBand(x: Double, y: Double) -> Bool {
        x >= 0 && x < width && y >= height - padding && y < height
    }

    public func inHoverZone(x: Double, y: Double) -> Bool {
        x >= 0 && x < width && y >= 0 && y < height - padding
    }
}
