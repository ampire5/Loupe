/// The dark band behind the strip's cells (M2.5 spec §4.2, rounded corners): the view's full width, square, when the
/// cells fill it, else only behind the cells with `margin` on each side, where the view rounds its ends.
public struct StripBand: Equatable {
    /// Free space at an edge below this is rounding noise, not a gap.
    public static let gapThreshold = 0.5

    public let x: Double
    public let width: Double
    /// The cells fill the view's width: the band is full width and square.
    public let isFull: Bool

    /// `leftEdge` and `rightEdge` are the first cell's left and the last cell's right as shown (magnified frames
    /// included, so the band follows a growing row); nil without cells. The band is `margin` wider on each side and
    /// is full when that reaches both edges of the view.
    public init(leftEdge: Double?, rightEdge: Double?, viewWidth: Double, margin: Double) {
        let full = (x: 0.0, width: viewWidth, isFull: true)
        guard let l = leftEdge, let r = rightEdge, r > l else {
            (x, width, isFull) = full
            return
        }
        let left = l - margin, right = r + margin
        if left <= Self.gapThreshold && right >= viewWidth - Self.gapThreshold {
            (x, width, isFull) = full
        } else {
            let start = min(max(left, 0), viewWidth)
            x = start
            width = max(0, min(right, viewWidth) - start)
            isFull = false
        }
    }
}

/// The cells' corner radius.
public enum StripCorners {
    /// `base` is the radius at `baseHeight`; a magnified cell scales it with its height. Never more than half the
    /// cell's shorter side (a layer would clamp it anyway; stated so the pictures and the border agree).
    public static func radius(base: Double, height: Double, baseHeight: Double, width: Double) -> Double {
        guard base > 0, height > 0, width > 0 else { return 0 }
        return min(base * height / max(1, baseHeight), min(width, height) / 2)
    }
}
