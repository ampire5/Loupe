import CoreGraphics
import Foundation

/// The rubber-band edge of a pan (M4a spec §2.1), per axis: a finger or cursor held past an image edge stretches the
/// picture under `RubberBand` resistance, a release or a glide into the edge springs it back (`EdgeSpring`). The
/// stretch is `ViewTransform.offset`; the clamped centre is never touched by it. Only an axis on which the photo is
/// larger than the view (`pannableAxes`) ever stretches.
///
/// Every operation takes the transform on screen and returns the one to show. The rubber remembers the offset it last
/// produced: a transform with another offset was replaced by something else (a zoom, a new photo, a resize all zero
/// it), and the rubber starts afresh from it.
public struct PanRubber: Sendable {
    /// One axis: the raw overshoot (view px, signed like the pan) of a finger or cursor past the edge, or a spring
    /// taking the stretch back to the edge.
    private enum Axis: Sendable {
        case held(raw: Double)
        case spring(EdgeSpring)

        static let rest = Axis.held(raw: 0)

        var isSpring: Bool { if case .spring = self { true } else { false } }

        /// The stretch shown, view px, for a view side `d`.
        func offset(_ d: Double) -> Double {
            switch self {
            case .held(let raw): RubberBand.offset(raw: raw, dimension: d)
            case .spring(let s): s.offset
            }
        }

        /// The raw overshoot that shows what this axis shows now: a spring caught where it is. Its offset counts as at
        /// most `PanRubber.catchLimit` of the view, so a catch never turns into a raw stretch so huge that the finger
        /// could no longer move it (near `d` the inverse runs off to infinity).
        func raw(_ d: Double) -> Double {
            switch self {
            case .held(let raw):
                return raw
            case .spring(let s):
                let limit = PanRubber.catchLimit * d
                return RubberBand.raw(offset: min(max(s.offset, -limit), limit), dimension: d)
            }
        }
    }

    /// A pan's leftover this small (view px) is rounding, not an edge.
    static let edgeSlop = 0.01
    /// Momentum events closer together than this (s) count as this far apart, so a duplicate timestamp does not make
    /// an absurd bounce speed; an unknown interval (≤ 0) counts as `momentumFrame`.
    static let minMomentumInterval = 1.0 / 240
    /// The interval of a gesture's first momentum event, which has no momentum event before it: one display frame
    /// (the gap since the fingers' last event says nothing about the momentum's pace).
    static let momentumFrame = 1.0 / 60
    /// A spring's overshoot past where it starts is held to at most this much of the view side (`d`): the stretch a
    /// finger pulled one whole view past the edge shows, `RubberBand.offset(raw: d, dimension: d)` ≈ 0.355·d, so a
    /// fast flick into an edge never throws the photo out of the view.
    static let maxBounce = RubberBand.offset(raw: 1, dimension: 1)
    /// A spring caught (`grab`, `pan`) counts its offset as at most this much of the view side.
    static let catchLimit = 0.9

    /// false: `pan` and `momentum` are plain `panned(by:)`, nothing stretches, bounces are ignored. Turning it off
    /// forgets any stretch (the caller shows the transform without it).
    public var enabled: Bool { didSet { if !enabled { reset() } } }

    private var x = Axis.rest, y = Axis.rest
    /// Axes that bounced off an edge during this gesture's momentum: the rest of it is ignored on them.
    private var spentX = false, spentY = false
    /// The offset of the transform last returned.
    private var produced = CGVector.zero
    /// The time of this gesture's previous momentum event (`momentum(_:at:on:)`); nil before its first one.
    private var lastMomentumTime: TimeInterval?

    public init(enabled: Bool) { self.enabled = enabled }

    /// A spring runs on some axis.
    public var isAnimating: Bool { x.isSpring || y.isSpring }

    /// A finger or cursor pan of `delta` view px. Inward movement first undoes the stretch, then pans; outward
    /// movement past an edge on a pannable axis grows the raw stretch. Catches a running spring.
    public mutating func pan(by delta: CGVector, on t: ViewTransform) -> ViewTransform {
        lastMomentumTime = nil
        guard enabled else { return t.panned(by: delta) }
        adopt(t)
        let axes = t.pannableAxes, size = t.viewSize
        var rawX = axes.x ? x.raw(size.width) : 0, rawY = axes.y ? y.raw(size.height) : 0
        let mx: Double, my: Double
        (rawX, mx) = Self.undo(raw: rawX, by: delta.dx)
        (rawY, my) = Self.undo(raw: rawY, by: delta.dy)
        let move = CGVector(dx: mx, dy: my)
        let left = t.panLeftover(move)
        if axes.x, abs(left.dx) > Self.edgeSlop { rawX += left.dx }
        if axes.y, abs(left.dy) > Self.edgeSlop { rawY += left.dy }
        x = .held(raw: rawX)
        y = .held(raw: rawY)
        return shown(t.panned(by: move))
    }

    /// A press or a finger landing during a spring: the springs stop where they show (held there, as a pan by
    /// nothing would leave them), and the next `release` springs back from there.
    public mutating func grab(on t: ViewTransform) -> ViewTransform {
        guard enabled else { return t }
        adopt(t)
        let size = t.viewSize
        x = .held(raw: x.raw(size.width))
        y = .held(raw: y.raw(size.height))
        return shown(t)
    }

    /// Fingers lifted / button released: axes with an offset spring back with `velocity` (px/s; .zero for fingers).
    /// A spring already running keeps its course.
    public mutating func release(velocity: CGVector, on t: ViewTransform) -> ViewTransform {
        guard enabled else { return t }
        adopt(t)
        let size = t.viewSize
        if case .held(let raw) = x, raw != 0 { x = .spring(Self.spring(from: x.offset(size.width), velocity: velocity.dx, dimension: size.width)) }
        if case .held(let raw) = y, raw != 0 { y = .spring(Self.spring(from: y.offset(size.height), velocity: velocity.dy, dimension: size.height)) }
        return shown(t)
    }

    /// A glide (mouse inertia or the system's momentum) reached an edge on an axis: that axis springs with `velocity`.
    public mutating func bounce(x vx: Double?, y vy: Double?, on t: ViewTransform) -> ViewTransform {
        guard enabled else { return t }
        adopt(t)
        let axes = t.pannableAxes, size = t.viewSize
        if let vx, axes.x { x = .spring(Self.spring(from: x.offset(size.width), velocity: vx, dimension: size.width)) }
        if let vy, axes.y { y = .spring(Self.spring(from: y.offset(size.height), velocity: vy, dimension: size.height)) }
        return shown(t)
    }

    /// Trackpad: the momentum part of a gesture. Pans like `pan` until an axis meets an edge; that axis bounces
    /// with `delta / interval` and ignores the gesture's further momentum (it is spent) until `beginGesture()`.
    /// An axis still stretched by the fingers (or springing back from them) springs back with the momentum's speed
    /// and takes none of it either: the momentum never stretches.
    public mutating func momentum(_ delta: CGVector, interval: TimeInterval, on t: ViewTransform) -> ViewTransform {
        guard enabled else { return t.panned(by: delta) }
        adopt(t)
        let axes = t.pannableAxes, size = t.viewSize
        let dt = interval > 0 ? max(interval, Self.minMomentumInterval) : Self.momentumFrame
        let v = CGVector(dx: delta.dx / dt, dy: delta.dy / dt)
        var mx = Double(delta.dx), my = Double(delta.dy)
        Self.settle(&x, spent: &spentX, move: &mx, velocity: v.dx, dimension: size.width)
        Self.settle(&y, spent: &spentY, move: &my, velocity: v.dy, dimension: size.height)
        let move = CGVector(dx: mx, dy: my)
        let left = t.panLeftover(move)
        if axes.x, !spentX, abs(left.dx) > Self.edgeSlop {
            x = .spring(Self.spring(from: 0, velocity: v.dx, dimension: size.width))
            spentX = true
        }
        if axes.y, !spentY, abs(left.dy) > Self.edgeSlop {
            y = .spring(Self.spring(from: 0, velocity: v.dy, dimension: size.height))
            spentY = true
        }
        return shown(t.panned(by: move))
    }

    /// `momentum(_:interval:on:)` for an event at `time` (s, any monotonic clock): the interval is the one since this
    /// gesture's previous momentum event, and one display frame (`momentumFrame`) for its first, never the gap since
    /// the fingers' last event.
    public mutating func momentum(_ delta: CGVector, at time: TimeInterval, on t: ViewTransform) -> ViewTransform {
        let interval = lastMomentumTime.map { time - $0 } ?? 0
        let moved = momentum(delta, interval: interval, on: t)
        lastMomentumTime = time
        return moved
    }

    /// A new trackpad gesture: its momentum may move every axis again.
    public mutating func beginGesture() {
        spentX = false
        spentY = false
        lastMomentumTime = nil
    }

    /// Advances the springs; nil (and the state reset) when `t.offset` is not what this rubber last produced,
    /// i.e. something else replaced the transform.
    public mutating func step(dt: TimeInterval, on t: ViewTransform) -> ViewTransform? {
        guard t.offset == produced else {
            reset()
            return nil
        }
        Self.advance(&x, dt: dt)
        Self.advance(&y, dt: dt)
        return shown(t)
    }

    public mutating func reset() {
        x = .rest
        y = .rest
        beginGesture()
        produced = .zero
    }

    // MARK: Helpers

    /// Starts from `t`: a transform whose offset is not the one last produced was replaced by something else, so the
    /// state goes, and a stretch it carries anyway is taken as held where it shows.
    private mutating func adopt(_ t: ViewTransform) {
        guard t.offset != produced else { return }
        reset()
        x = .held(raw: RubberBand.raw(offset: t.offset.dx, dimension: t.viewSize.width))
        y = .held(raw: RubberBand.raw(offset: t.offset.dy, dimension: t.viewSize.height))
        produced = t.offset
    }

    /// `t` with the stretch the axes show, remembered as produced.
    private mutating func shown(_ t: ViewTransform) -> ViewTransform {
        let size = t.viewSize
        produced = CGVector(dx: x.offset(size.width), dy: y.offset(size.height))
        return t.withOffset(produced)
    }

    /// Splits a finger move against a held stretch: movement back toward the edge first eats the stretch, and only
    /// what is left of it pans. Movement outward (or with no stretch) all goes to the pan, whose leftover at the edge
    /// becomes stretch.
    private static func undo(raw: Double, by d: Double) -> (raw: Double, move: Double) {
        guard raw != 0, d != 0, (raw > 0) != (d > 0) else { return (raw, d) }
        let r = raw + d
        return (r > 0) == (raw > 0) ? (r, 0) : (0, r)
    }

    /// Momentum on one axis: nothing on a spent axis; an axis with a stretch or a spring takes none of it and is spent
    /// (a held stretch springs back with the momentum's speed).
    private static func settle(_ a: inout Axis, spent: inout Bool, move: inout Double, velocity: Double, dimension d: Double) {
        if spent { move = 0; return }
        switch a {
        case .spring:
            spent = true
            move = 0
        case .held(let raw) where raw != 0:
            a = .spring(spring(from: a.offset(d), velocity: velocity, dimension: d))
            spent = true
            move = 0
        case .held:
            break
        }
    }

    private static func advance(_ a: inout Axis, dt: TimeInterval) {
        guard case .spring(var s) = a else { return }
        s.step(dt: dt)
        a = s.isFinished ? .rest : .spring(s)
    }

    /// A spring from `offset` with `velocity` on a view side `dimension`. Back toward the edge it is never faster than
    /// `ω · offset`: faster, the critically damped spring would swing past the edge to the other side. Away from the
    /// edge it is never fast enough to carry the picture more than `maxBounce · dimension` past the edge (a stretch
    /// already beyond that gets no outward speed at all).
    static func spring(from offset: Double, velocity: Double, dimension: Double) -> EdgeSpring {
        // Work with the stretch on the positive side.
        let sign: Double = offset < 0 || (offset == 0 && velocity < 0) ? -1 : 1
        let x0 = offset * sign
        var v = velocity * sign
        if v < 0 {
            v = max(v, -EdgeSpring.omega * x0)
        } else if v > 0 {
            let limit = maxBounce * max(dimension, 0)
            if x0 >= limit {
                v = 0
            } else if peak(x0: x0, v0: v) > limit {
                // The peak grows with the speed: bisect for the speed that just reaches the limit.
                var lo = 0.0, hi = v
                for _ in 0..<60 {
                    let mid = (lo + hi) / 2
                    if peak(x0: x0, v0: mid) > limit { hi = mid } else { lo = mid }
                }
                v = lo
            }
        }
        return EdgeSpring(offset: offset, velocity: v * sign)
    }

    /// The furthest a critically damped spring from `x0 ≥ 0` with outward speed `v0 ≥ 0` gets: its speed is zero at
    /// `t* = v0 / (ω·(v0 + ω·x0))`, where `x = (x0 + v0/ω) · e^(−v0/(v0 + ω·x0))`.
    static func peak(x0: Double, v0: Double) -> Double {
        let w = EdgeSpring.omega, b = v0 + w * x0
        guard b > 0 else { return x0 }
        return (x0 + v0 / w) * exp(-v0 / b)
    }
}
