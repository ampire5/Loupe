import CoreGraphics
import Foundation

/// A discrete zoom played out over time (M4b spec §2.2): keys, smart zoom, the spring-back of the zoom rubber band.
/// Per axis both ends map image pixels to the view as `view = s·p + b` with one scale `s` for both axes, so when the
/// scales differ there is one view point `f` under which both ends show the same image pixel; every frame keeps that
/// pixel under `f` at the scale `s0^(1−e)·s1^e` (log, so ×2 feels the same at any level), `e` the ease-out of the
/// time. Then `b` is linear in `s`, so the visible rect's edges move monotonically between the ends. With (almost)
/// equal scales only the place changes, linearly.
///
/// Frames are `.free` with the residual of `clamped` in `offset` and, past a zoom limit (a spring-back), the excess
/// scale in `stretch`, so each draws exactly that similarity; the last frame is `to` itself, its mode and stored
/// centre included. The ends are read as they draw (`drawnScale`, `viewPoint(forImage: .zero)`): a stretched or
/// offset `from` (the current frame of an interrupted animation) starts where it is.
public struct ZoomAnimation: Sendable {
    public let from, to: ViewTransform
    public let start, duration: TimeInterval

    /// Ends that draw within these of each other are the same: nothing to animate.
    private static let sameScale = 1e-12, samePoint = 1e-9
    /// Scales closer than this in log only move the place (spec §2.2).
    private static let equalLogScale = 1e-6

    private let s0, s1: Double
    private let b0, b1: CGPoint
    private let still: Bool

    public init(from: ViewTransform, to: ViewTransform, start: TimeInterval, duration: TimeInterval) {
        self.from = from
        self.to = to
        self.start = start
        self.duration = duration
        s0 = from.drawnScale
        s1 = to.drawnScale
        b0 = from.viewPoint(forImage: .zero)
        b1 = to.viewPoint(forImage: .zero)
        still = abs(s1 - s0) <= Self.sameScale * s1 && abs(b1.x - b0.x) <= Self.samePoint
            && abs(b1.y - b0.y) <= Self.samePoint
    }

    /// The ease-out `1 − (1 − t)³` of the time fraction `t`, clamped to 0…1.
    public static func ease(_ t: Double) -> Double {
        let u = 1 - min(max(t, 0), 1)
        return 1 - u * u * u
    }

    /// At and after the end; at once when there is nothing to animate (no duration, or ends that draw alike).
    public func isFinished(at time: TimeInterval) -> Bool {
        duration <= 0 || still || time >= start + duration
    }

    /// The frame to show at `time`: `to` once finished, otherwise the eased similarity (before `start`, the first one).
    public func transform(at time: TimeInterval) -> ViewTransform {
        if isFinished(at: time) { return to }
        let e = Self.ease((time - start) / duration)
        if abs(log(s1 / s0)) < Self.equalLogScale {
            return frame(scale: s1, origin: lerp(e), anchor: nil)
        }
        let s = s0 * pow(s1 / s0, e)
        // b is linear in s between the ends; the fixed point f = (s1·b0 − s0·b1) / (s1 − s0) only anchors a stretch.
        let w = (s - s0) / (s1 - s0)
        let f = CGPoint(x: (s1 * b0.x - s0 * b1.x) / (s1 - s0), y: (s1 * b0.y - s0 * b1.y) / (s1 - s0))
        return frame(scale: s, origin: lerp(w), anchor: f)
    }

    /// The frame at `time` as a resting transform: the clamp residual (`offset`) dropped, the stored centre kept, so
    /// geometry reads it clamped. A gesture interrupting the animation goes on from this.
    public func settled(at time: TimeInterval) -> ViewTransform {
        var t = transform(at: time)
        t.offset = .zero
        return t
    }

    private func lerp(_ w: Double) -> CGPoint {
        CGPoint(x: b0.x + (b1.x - b0.x) * w, y: b0.y + (b1.y - b0.y) * w)
    }

    /// The transform drawing image pixel p at `s·p + origin`: `.free` at `s` within the zoom limits; past them at the
    /// limit with the rest as a stretch about `anchor` (the view centre without one). What `clamped` moves goes into
    /// `offset`.
    private func frame(scale s: Double, origin b: CGPoint, anchor: CGPoint?) -> ViewTransform {
        let fit = to.fitScale
        var t = to.withMode(.free(s / fit))
        let limit = t.scale
        var k = s / limit
        if abs(k - 1) <= 1e-12 { k = 1 }
        if k != 1 { t.mode = .free(limit / fit) }   // the mode within the limits, the rest in the stretch
        var plain = b
        var stretch: ZoomStretch?
        if k != 1 {
            // view = A + k·(q − A) for the unstretched view point q, so q's origin is (b − A·(1 − k)) / k.
            let a = anchor ?? CGPoint(x: to.viewSize.width / 2, y: to.viewSize.height / 2)
            plain = CGPoint(x: (b.x - a.x * (1 - k)) / k, y: (b.y - a.y * (1 - k)) / k)
            stretch = ZoomStretch(factor: k, anchor: a)
        }
        // b = V/2 − c·I·scale for a centre c (relative) at no offset.
        let vw = to.viewSize.width > 0 ? to.viewSize.width : 1, vh = to.viewSize.height > 0 ? to.viewSize.height : 1
        let w = to.imageSize.width * limit, h = to.imageSize.height * limit
        t.center = CGPoint(x: w > 0 ? (vw / 2 - plain.x) / w : 0.5, y: h > 0 ? (vh / 2 - plain.y) / h : 0.5)
        let drawn = t.viewPoint(forImage: .zero)
        var residual = CGVector(dx: plain.x - drawn.x, dy: plain.y - drawn.y)
        if abs(residual.dx) < 1e-9 { residual.dx = 0 }
        if abs(residual.dy) < 1e-9 { residual.dy = 0 }
        t = t.withOffset(residual)
        t.stretch = stretch
        return t
    }
}
