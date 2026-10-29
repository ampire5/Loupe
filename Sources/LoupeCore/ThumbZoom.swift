import Foundation

/// `thumb-zoom-stops`: what the thumb-wheel zoom does at a `zoom-stops` stop. `tick`: it goes through, the mouse ticks
/// (`haptic-zoom-stop`); `halt` (the default): one turn of the wheel halts on each stop, as a pinch does, and the
/// next turn goes on past it.
public enum ThumbZoomStops: String, CaseIterable, Sendable {
    case tick, halt
}

/// The smooth zoom of the MX Master's thumb wheel turned with no button held (`thumb-wheel-zoom`): right zooms in,
/// left out, at the pointer, by `thumb-zoom-speed` doublings per turn of the wheel. One gesture is one turn (the
/// mouse's `began` … `ended`); the caller starts a new one at `began` and when something else changed the transform
/// in between, as for a pinch. It feeds the wheel's deltas and shows the scale that comes back; `bump` says what the
/// mouse plays: a limit reached (`haptic-limit`) before a stop reached or crossed (`haptic-zoom-stop`).
public struct ThumbZoom: Sendable {
    private let mode: ThumbZoomStops
    /// `halt`: the pinch's stop rules, fed the scale the turn alone would give.
    private var halting: ZoomStopGesture
    private let stops: [ZoomStopScale]
    private let limits: ClosedRange<Double>
    private var proposed: Double
    private var current: Double
    private var atLimit: Bool

    public init(transform: ViewTransform, stops: [ZoomStop], mode: ThumbZoomStops) {
        self.mode = mode
        self.stops = ZoomStops.scales(of: stops, for: transform)
        limits = transform.scaleLimits
        halting = ZoomStopGesture(startScale: transform.scale, stops: self.stops, limits: limits)
        proposed = transform.scale
        current = transform.scale
        atLimit = Self.onLimit(transform.scale, limits)
    }

    /// Doublings of the scale for `delta` wheel units of `stepsPerRevolution` per turn (right = positive) at `speed`
    /// doublings per turn. Zero without a turn size.
    public static func doublings(delta: Int, stepsPerRevolution: Int, speed: Double) -> Double {
        guard stepsPerRevolution > 0 else { return 0 }
        return Double(delta) / Double(stepsPerRevolution) * speed
    }

    /// The scale after `doublings` more, the stop it rests on (`halt` only; nil between stops and with `tick`), and
    /// the bump to play, if any.
    public mutating func turn(doublings: Double) -> (scale: Double, stop: ZoomStop?, bump: ZoomStepBump?) {
        guard doublings.isFinite, doublings != 0 else { return (current, nil, nil) }
        let old = current
        proposed *= pow(2, doublings)
        var stop: ZoomStop?
        var hitStop = false
        switch mode {
        case .halt:
            let r = halting.constrain(proposed)
            current = r.scale
            stop = r.hitStop
            hitStop = halting.justHit
        case .tick:
            current = min(max(proposed, limits.lowerBound), limits.upperBound)
            proposed = current   // the limits absorb the overshoot: turning back zooms at once
            hitStop = stops.contains { Self.reached($0.scale, from: old, to: current) }
        }
        let limit = Self.onLimit(current, limits)
        let hitLimit = limit && !atLimit
        atLimit = limit
        return (current, stop, hitLimit ? .limit : hitStop ? .stop : nil)
    }

    /// `old` → `new` moved onto or over `scale`, from off it: a scale the zoom rests on is left without a tick.
    private static func reached(_ scale: Double, from old: Double, to new: Double) -> Bool {
        let tol = 1e-9
        if new > old { return old < scale * (1 - tol) && new >= scale * (1 - tol) }
        if new < old { return old > scale * (1 + tol) && new <= scale * (1 + tol) }
        return false
    }

    private static func onLimit(_ scale: Double, _ limits: ClosedRange<Double>) -> Bool {
        scale >= limits.upperBound * (1 - 1e-9) || scale <= limits.lowerBound * (1 + 1e-9)
    }
}
