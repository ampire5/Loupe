import Foundation

/// The cell height for a drag of the strip's grab band (spec §4.1), as a pure function of how far the cursor has
/// moved since the press: the band's top follows the cursor 1:1, so back to the press point is back to the start
/// height. Past the height range it goes on; the caller clamps it (`Config.clampedStripHeight`).
public struct StripResizeDrag {
    public let startHeight: Double

    public init(startHeight: Double) {
        self.startHeight = startHeight
    }

    /// The cell height for the cursor `delta` points above the press (negative: below).
    public func height(forDrag delta: Double) -> Double { startHeight + delta }
}
