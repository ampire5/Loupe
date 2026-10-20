import Foundation

/// Rubber-band resistance for a pan dragged past an image edge (M4a spec §2.1). The stretch grows
/// with the raw overshoot but never reaches `dimension`: `offset = (1 − 1/(raw·0.55/d + 1))·d`.
public enum RubberBand {
    /// Slope of the curve at zero: the first pixels past the edge follow the finger at 55 %.
    public static let resistance = 0.55

    /// The stretch (view px, signed like `raw`) for a raw overshoot `raw` of a view side `dimension`.
    public static func offset(raw: Double, dimension: Double) -> Double {
        guard dimension > 0 else { return 0 }
        let r = abs(raw)
        let o = (1 - 1 / (r * resistance / dimension + 1)) * dimension
        return raw < 0 ? -o : o
    }

    /// Inverse of `offset(raw:dimension:)`; a stretch at or beyond `dimension` clamps just below it.
    public static func raw(offset: Double, dimension: Double) -> Double {
        guard dimension > 0, offset != 0 else { return 0 }
        let o = min(abs(offset), dimension - 1e-9)
        let r = o * dimension / (resistance * (dimension - o))
        return offset < 0 ? -r : r
    }

    /// The zoom rubber band (M4b spec §3): at most this much past a zoom limit, ×1.25 above the top, ÷1.25 below the
    /// bottom.
    public static let zoomMaxFactor = 1.25

    /// The stretch factor shown for a gesture asking for `proposed` at a zoom limit `limit`: the same curve as the pan
    /// band in the log of the scale, `exp(shown(u))` with `u = ln(proposed / limit)` and `d = ln zoomMaxFactor`. 1 at the
    /// limit, above 1 past an upper limit and below it past a lower one (the caller knows which side is inside), never
    /// reaching `zoomMaxFactor` or its inverse.
    public static func zoomFactor(proposed: Double, limit: Double) -> Double {
        guard proposed > 0, limit > 0, proposed.isFinite, limit.isFinite else { return 1 }
        return exp(offset(raw: log(proposed / limit), dimension: log(zoomMaxFactor)))
    }
}

/// The stretch springing back to zero after release: a critically damped spring with ω = 19 1/s,
/// in closed form `x(t) = (x0 + (v0 + ω·x0)·t)·e^(−ω·t)`, so the result does not depend on the
/// frame step.
public struct EdgeSpring: Sendable {
    public static let omega = 19.0

    public private(set) var offset: Double
    public private(set) var velocity: Double       // px/s

    public init(offset: Double, velocity: Double) {
        self.offset = offset
        self.velocity = velocity
    }

    /// Advances by `dt` seconds and returns the new offset.
    @discardableResult
    public mutating func step(dt: TimeInterval) -> Double {
        guard dt > 0 else { return offset }
        let w = Self.omega, x0 = offset, v0 = velocity
        let b = v0 + w * x0
        let e = exp(-w * dt)
        offset = (x0 + b * dt) * e
        velocity = (b - w * (x0 + b * dt)) * e
        return offset
    }

    /// Settled: the picture is back within a quarter pixel and has almost stopped.
    public var isFinished: Bool { abs(offset) < 0.25 && abs(velocity) < 5 }
}
