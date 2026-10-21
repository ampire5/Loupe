import CoreGraphics
import Foundation

/// Zoom while the right mouse button is held and the cursor moves vertically (spec §8.2).
/// Exponential, so equal drags always multiply the scale by the same factor: `pointsPerDoubling`
/// points of upward travel double it, the same distance downward halves it.
///
/// Everything is computed from the transform at the press and the *cumulative* cursor travel since,
/// never by chaining per-event factors, so the result is exact, does not drift, and dragging back to
/// the start returns to the starting transform. The anchor (view pixels) is the press point for the
/// whole drag. Zoom limits are applied by `ViewTransform.zoomed`.
public struct RMBZoom: Equatable, Sendable {
    /// Cursor travel, in points, that doubles the scale at speed 1 (the M1 rate). `rmb-zoom-speed` scales it
    /// (`pointsPerDoubling(speed:)`); `rmb-zoom-invert` flips the direction.
    public static let pointsPerDoubling = 200.0
    /// Travel per doubling at `rmb-zoom-speed` `speed`: a multiplier on the rate, so 2 needs half the travel.
    public static func pointsPerDoubling(speed: Double) -> Double { pointsPerDoubling / speed }
    /// A press-and-release moving less than this many points is a click, not a zoom (M4: context menu).
    public static let clickSlopPoints = 4.0

    public let anchor: CGPoint
    public let start: ViewTransform
    /// Cursor travel (points) per doubling for this drag.
    public let pointsPerDoubling: Double
    /// `rmb-zoom-invert`: dragging down zooms in, up zooms out.
    public let inverted: Bool
    private let startScale: Double

    /// Starts a drag at `anchor` (view pixels, top-left origin) from `transform`.
    public init(anchor: CGPoint, transform: ViewTransform, pointsPerDoubling: Double, inverted: Bool = false) {
        self.anchor = anchor
        self.inverted = inverted
        self.start = transform
        self.pointsPerDoubling = pointsPerDoubling
        self.startScale = transform.scale
    }

    /// Doublings of the scale asked for by `dyPoints` of cumulative cursor travel (screen y down): `-dy / ppd`,
    /// the other sign when inverted.
    public func doublings(dyPoints: Double) -> Double {
        let d = -dyPoints / pointsPerDoubling
        return inverted ? -d : d
    }

    /// The press scale times 2^`doublings`: the one exponential of the drag and its glide, so `rmb-zoom-invert`
    /// (applied in `doublings(dyPoints:)`) cannot be missed by either.
    public func scale(doublings: Double) -> Double {
        startScale * pow(2, doublings)
    }

    /// The scale for `dyPoints` of cumulative vertical cursor travel since the press (screen y down).
    public func scale(dyPoints: Double) -> Double { scale(doublings: doublings(dyPoints: dyPoints)) }

    /// The transform after the cursor has travelled `dyPoints` (screen y down) since the press.
    public func transform(dyPoints: Double) -> ViewTransform {
        transform(toScale: scale(dyPoints: dyPoints))
    }

    /// The press transform zoomed to `scale` around the anchor, a free zoom even on a stop: the view runs
    /// `scale(dyPoints:)` through `ZoomStopGesture` first.
    public func transform(toScale scale: Double) -> ViewTransform {
        start.zoomed(toScale: scale, anchor: anchor)
    }
}
