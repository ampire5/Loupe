import CoreGraphics
import Foundation

/// The recent samples of a dragged quantity (a position, or a zoom in doublings) and their release velocity: the
/// least-squares slope over the last `window` seconds. Times are seconds on any monotonic clock (`NSEvent.timestamp`).
/// One or two components, so the left-button drag (x, y) and the right-button zoom (one value) share it.
struct VelocitySamples: Sendable {
    /// Only samples this close (s) to the newest one are used.
    static let window: TimeInterval = 0.080
    /// A release more than this long (s) after the newest sample means the user stopped before letting go.
    static let staleAfter: TimeInterval = 0.050
    /// A fit needs at least this many samples in the window, spanning at least `minSpan` seconds: a click with a
    /// twitch of the hand (two samples a few ms apart) is a huge slope over no time and must not glide.
    static let minSamples = 3
    static let minSpan: TimeInterval = 0.015

    private var samples: [(v: SIMD2<Double>, t: TimeInterval)] = []

    mutating func reset() { samples.removeAll(keepingCapacity: true) }

    mutating func add(_ v: SIMD2<Double>, at t: TimeInterval) {
        // Time must not go backwards; a stray earlier sample would corrupt the fit.
        if let last = samples.last, t < last.t { reset() }
        samples.append((v, t))
        // Keep only what a later query can use (the window, with some slack).
        let cutoff = t - 2 * Self.window
        if let first = samples.firstIndex(where: { $0.t >= cutoff }), first > 0 { samples.removeFirst(first) }
    }

    /// Units per second at `release`, or nil when there is nothing to fit: too few samples in the window, they
    /// span too short a time, or the newest one is stale.
    func slope(at release: TimeInterval) -> SIMD2<Double>? {
        guard let newest = samples.last, release - newest.t <= Self.staleAfter else { return nil }
        let used = samples.filter { $0.t >= newest.t - Self.window }
        guard used.count >= Self.minSamples, let oldest = used.first, newest.t - oldest.t >= Self.minSpan else { return nil }
        let n = Double(used.count)
        let meanT = used.reduce(0) { $0 + $1.t } / n
        let meanV = used.reduce(SIMD2<Double>.zero) { $0 + $1.v } / n
        var stt = 0.0, stv = SIMD2<Double>.zero
        for s in used {
            let dt = s.t - meanT
            stt += dt * dt
            stv += dt * (s.v - meanV)
        }
        guard stt > 0 else { return nil }
        return stv / stt
    }
}

/// Release velocity of a left-button drag (spec §8.2), from the cursor samples the drag produced.
/// Positions are view pixels, times are seconds on any monotonic clock (`NSEvent.timestamp`).
public struct DragVelocityTracker: Sendable {
    /// Only samples this close (s) to the newest one are used.
    public static let window = VelocitySamples.window
    /// A release more than this long (s) after the newest sample means the user stopped before letting go.
    public static let staleAfter = VelocitySamples.staleAfter
    /// Slower releases (px/s) do not coast.
    public static let minStartSpeed: Double = 50

    private var samples = VelocitySamples()

    public init() {}

    public mutating func reset() { samples.reset() }

    public mutating func add(_ p: CGPoint, at t: TimeInterval) {
        samples.add(SIMD2(Double(p.x), Double(p.y)), at: t)
    }

    /// Velocity in px/s at the moment of release, or `.zero` when there is nothing to coast with: too few
    /// samples, the newest one is stale, or the speed is below `minStartSpeed`.
    public func releaseVelocity(at release: TimeInterval) -> CGVector {
        guard let s = samples.slope(at: release) else { return .zero }
        let v = CGVector(dx: s.x, dy: s.y)
        return hypot(v.dx, v.dy) < Self.minStartSpeed ? .zero : v
    }
}

/// The glide after a drag is released: exponential decay `v *= decay^(dt in ms)` (0.998 by default, UIScrollView's
/// normal deceleration rate; `inertia-deceleration`), integrated exactly over each frame so 60 and 120 Hz follow
/// the same trajectory.
public struct InertiaCoast: Sendable {
    /// The default velocity multiplier per millisecond.
    public static let decayPerMillisecond: Double = 0.998
    /// The coast ends once the speed (px/s) falls below this.
    public static let stopSpeed: Double = 20

    /// Decay rate in 1/s at the default decay: `v(t) = v0 * exp(-rate * t)`. The zoom glide uses it as is.
    static let rate = -log(decayPerMillisecond) * 1000

    /// This coast's own decay rate in 1/s.
    private let decayRate: Double

    private var vx: Double, vy: Double

    public init(velocity: CGVector, decayPerMillisecond: Double = InertiaCoast.decayPerMillisecond) {
        vx = velocity.dx
        vy = velocity.dy
        decayRate = -log(decayPerMillisecond) * 1000
    }

    public var velocity: CGVector { CGVector(dx: vx, dy: vy) }
    public var isFinished: Bool { hypot(vx, vy) < Self.stopSpeed }

    /// Advances by `dt` seconds and returns how far the picture moves this frame (view px). Closed form:
    /// the distance covered over `dt` is `v * (1 - e^(-rate dt)) / rate`.
    public mutating func step(dt: TimeInterval) -> CGVector {
        guard dt > 0 else { return .zero }
        let decay = exp(-decayRate * dt)
        let k = (1 - decay) / decayRate
        let d = CGVector(dx: vx * k, dy: vy * k)
        vx *= decay
        vy *= decay
        return d
    }

    /// Zeroes the velocity along the axes flagged (the picture hit an image edge on them).
    public mutating func stopAxis(x: Bool = false, y: Bool = false) {
        if x { vx = 0 }
        if y { vy = 0 }
    }
}
