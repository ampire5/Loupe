import CoreGraphics
import Foundation

/// A zoom stop (spec §8.4): a scale where continuous zoom pauses, so fit width,
/// fit height and 100 % are easy to land on exactly. Listed in `zoom-stops` in loupe.conf.
public enum ZoomStop: Hashable, Sendable {
    case fitWidth, fitHeight
    /// Physical-pixel percent: 100 = one image pixel per screen pixel.
    case percent(Double)

    /// The mode the stop's scale is taken from. A gesture resting on the stop does not switch to it: a gesture gives a
    /// scale, a key a mode, so a pinch that halts on fit width is carried to the next photo by `keep-zoom-as` like any
    /// other pinch (a turned photo would otherwise jump to its own fit width); W asks for the mode itself. The stats
    /// bar still names the stop (`StatsLine.modeText`).
    public var mode: ZoomMode {
        switch self {
        case .fitWidth: return .fitWidth
        case .fitHeight: return .fitHeight
        case .percent(let p): return .actual(p / 100)
        }
    }
}

/// A stop and the scale it stands for in one transform (image and view size).
public struct ZoomStopScale: Equatable, Sendable {
    public let stop: ZoomStop
    public let scale: Double

    public init(stop: ZoomStop, scale: Double) {
        self.stop = stop
        self.scale = scale
    }
}

public enum ZoomStops {
    /// Stops closer than this (relative) are one stop: two detents a hair apart would make the second
    /// feel like a stuck gesture.
    public static let mergeTolerance = 0.015

    /// The scales of `stops` for `transform`, ascending, merged within `mergeTolerance`; of stops that
    /// merge, the one listed first wins (it decides the mode). A stop the zoom limits would distort is
    /// dropped, as is everything when no image is shown. Each scale is exactly what the transform shows
    /// in the stop's mode, so landing on a stop and switching to its mode never moves the picture.
    public static func scales(of stops: [ZoomStop], for transform: ViewTransform) -> [ZoomStopScale] {
        guard transform.imageSize.width > 0, transform.imageSize.height > 0 else { return [] }
        var kept: [ZoomStopScale] = []
        for stop in stops {
            let t = transform.withMode(stop.mode)
            let raw = t.rawScale, scale = t.scale
            guard raw.isFinite, raw > 0, abs(scale - raw) <= raw * 1e-9 else { continue }
            guard !kept.contains(where: { abs($0.scale - scale) <= mergeTolerance * min($0.scale, scale) }) else { continue }
            kept.append(ZoomStopScale(stop: stop, scale: scale))
        }
        return kept.sorted { $0.scale < $1.scale }
    }
}

/// The stops for one continuous pinch, right-button drag or thumb-wheel turn. Feed the cumulative scale
/// proposed by the input and the event time. Slow motion snaps into the detent on approach and stays
/// there through small reversals. A flick keeps its excess motion and may cross in one event, still reporting the detent.
/// Untimed input (mouse coast) lands exactly on the first stop.
public struct ZoomStopGesture: Sendable {
    /// Relative distance within which the start counts as on a stop. Below half `mergeTolerance`, so it
    /// can only ever be on one.
    public static let startTolerance = 0.005

    // Speeds are in doublings/s, and detent travel is in doublings, independent of the current scale.
    private static let slowSpeed = 1.2
    private static let fastSpeed = 3.0
    private static let slowTravel = 0.16
    private static let fastTravel = 0.018
    private static let captureDistance = 0.045
    private static let reverseTravelFraction = 0.35
    private static let reachTolerance = 1e-12

    private let stops: [ZoomStopScale]
    private let limits: ClosedRange<Double>?
    /// Starting on a stop lets the user leave it; once away, crossing it again gives the normal detent.
    private var startStop: ZoomStopScale?
    private var current: Double
    private var lastProposed: Double
    /// Output = proposed × rebase. Rebase when travel is consumed, so reversing needs no unwind.
    private var rebase = 1.0
    private var resting: ZoomStop?
    private struct DetentHold: Sendable {
        let entryIncreasing: Bool
        var increasing: Bool
        var remaining: Double
    }
    private var hold: DetentHold?
    private var lastTime: TimeInterval?
    private var velocity: Double?
    var isRestingOnStop: Bool {
        resting != nil || stops.contains { abs($0.scale - current) <= Self.reachTolerance * current }
    }

    /// True when an event lands on or passes a stop, for one haptic tick.
    public private(set) var justHit = false
    /// Whether the zoom limits stretch (`zoom-rubber-band`) instead of absorbing. Turning it off drops the
    /// stretch; from then on the gesture behaves as without it (the right-button coast does this).
    public var rubber: Bool {
        didSet { if !rubber { stretch = 1 } }
    }
    /// The zoom stretch factor to draw the returned scale with (`RubberBand.zoomFactor`): above 1 past the
    /// upper limit, below 1 past the lower one, 1 otherwise.
    public private(set) var stretch = 1.0

    /// `stops` ascending (as `ZoomStops.scales` gives them); `limits` are the zoom limits, if any.
    public init(startScale: Double, stops: [ZoomStopScale], limits: ClosedRange<Double>? = nil, rubber: Bool = false,
                at timestamp: TimeInterval? = nil) {
        self.stops = stops
        self.limits = limits
        self.rubber = rubber
        current = startScale
        lastProposed = startScale
        lastTime = timestamp
        // An exact match is already excluded by the strict crossing check. Treat only an approximate
        // match as a departure in progress.
        startStop = stops.first {
            let distance = abs($0.scale - startScale)
            return distance > Self.reachTolerance * startScale && distance <= Self.startTolerance * startScale
        }
    }

    /// A gesture from `transform` with the configured `stops` and the transform's zoom limits.
    public init(transform: ViewTransform, stops: [ZoomStop], rubber: Bool = false, at timestamp: TimeInterval? = nil) {
        self.init(startScale: transform.scale, stops: ZoomStops.scales(of: stops, for: transform),
                  limits: transform.scaleLimits, rubber: rubber, at: timestamp)
    }

    /// The scale to show for `proposedScale`, and the stop it rests on (nil between stops). An invalid
    /// proposal (non-positive, NaN) keeps the current scale.
    public mutating func constrain(_ proposedScale: Double, at timestamp: TimeInterval? = nil)
        -> (scale: Double, hitStop: ZoomStop?) {
        justHit = false
        let tol = Self.reachTolerance
        guard proposedScale.isFinite, proposedScale > 0 else { return (current, resting) }
        let previous = lastProposed
        let fast = speedBlend(proposedScale, at: timestamp)
        guard proposedScale != previous else { return (current, resting) }
        // An ulp of input noise must not release and immediately re-arm a held stop.
        if resting != nil, abs(proposedScale - previous) <= previous * tol {
            return (current, resting)
        }
        let increasing = proposedScale > previous
        let direction = increasing ? 1.0 : -1.0
        lastProposed = proposedScale
        let travel = fast.map { Self.slowTravel + (Self.fastTravel - Self.slowTravel) * $0 } ?? 0.08
        let rawWanted = proposedScale * rebase
        var wanted = rawWanted

        if var hold, increasing == hold.increasing || fast != nil {
            if increasing != hold.increasing {
                // Backing out is easier than continuing, but small reversals must stay in the pocket.
                // Changing direction starts fresh so alternating jitter cannot add up to an exit.
                hold.increasing = increasing
                hold.remaining = increasing == hold.entryIncreasing ? 1 : Self.reverseTravelFraction
            }
            let cost = hold.remaining * travel
            let motion = direction * (log2(proposedScale) - log2(previous))
            if motion <= cost + tol {
                hold.remaining = max(0, hold.remaining - motion / travel)
                self.hold = hold
                rebase = current / proposedScale
                return (current, resting)
            }
            wanted = current * pow(2, direction * (motion - cost))
        }
        hold = nil

        let capture = pow(2, Self.captureDistance * (fast.map { 1 - $0 } ?? 0))
        var stop: ZoomStop?
        for offset in stops.indices {
            let index = increasing ? offset : stops.count - 1 - offset
            let point = stops[index]
            guard point != startStop else { continue }
            let s = point.scale
            let atLimit = limits.map { s <= $0.lowerBound * (1 + tol) || s >= $0.upperBound * (1 - tol) } ?? false
            var window = atLimit ? 1 : capture
            if window > 1, offset > 0 {
                // Close stops each own their side of the logarithmic midpoint.
                let previousStop = stops[increasing ? index - 1 : index + 1].scale
                let halfGap = increasing ? (s / previousStop).squareRoot() : (previousStop / s).squareRoot()
                window = min(window, halfGap)
            }
            let reached = increasing
                ? s > current * (1 + tol) && wanted >= s * (1 - tol) / window
                : s < current * (1 - tol) && wanted <= s * (1 + tol) * window
            guard reached else { continue }

            justHit = true
            if atLimit {
                // Preserve the raw overshoot for the rubber band.
                stop = point.stop
                break
            }
            let overshoot = max(0, direction * (log2(wanted) - log2(s))) * (fast ?? 0)
            if overshoot <= travel + tol {
                wanted = s
                stop = point.stop
                hold = DetentHold(entryIncreasing: increasing, increasing: increasing,
                                  remaining: max(0, 1 - overshoot / travel))
                break
            }
            wanted = s * pow(2, direction * (overshoot - travel))
        }

        var scale = wanted
        if let limits {
            if wanted >= limits.upperBound * (1 - tol) {
                scale = limits.upperBound
            } else if wanted <= limits.lowerBound * (1 + tol) {
                scale = limits.lowerBound
            }
        }

        // With the rubber band, a scale held on a limit (a stop that sits on one included) stretches instead of
        // absorbing: no rebase, so the stretch is a function of the proposal and the way back is exact.
        stretch = 1
        var stretching = false
        if rubber, scale != wanted, let limits {
            if scale >= limits.upperBound * (1 - tol) {
                stretch = max(1, RubberBand.zoomFactor(proposed: wanted, limit: limits.upperBound))
                stretching = true
            } else if scale <= limits.lowerBound * (1 + tol) {
                stretch = min(1, RubberBand.zoomFactor(proposed: wanted, limit: limits.lowerBound))
                stretching = true
            }
        }
        let effectiveScale = stretching ? wanted : scale
        if effectiveScale != rawWanted { rebase = effectiveScale / proposedScale }
        if let startStop, abs(startStop.scale - scale) > Self.startTolerance * scale
            || (current < startStop.scale) != (scale < startStop.scale) {
            self.startStop = nil
        }
        if stop == nil, scale == current { stop = resting }
        resting = stop
        current = scale
        return (scale, stop)
    }

    /// Track the speed of the raw gesture, so holding the displayed scale does not slow the estimate.
    /// React quickly to a flick, smooth short fluctuations, and forget the speed after a pause.
    private mutating func speedBlend(_ proposal: Double, at timestamp: TimeInterval?) -> Double? {
        guard !stops.isEmpty, let timestamp, timestamp.isFinite else { return nil }
        defer { lastTime = timestamp }
        guard let lastTime, timestamp > lastTime, timestamp - lastTime <= 0.12 else {
            velocity = nil
            return 0
        }
        let dt = timestamp - lastTime
        let sample = (log2(proposal) - log2(lastProposed)) / max(dt, 0.001)
        let previous = velocity ?? sample
        let smoothing = abs(sample) > abs(previous) ? 0.006 : 0.018
        let filtered = sample * previous < 0 ? sample : sample + (previous - sample) * exp(-dt / smoothing)
        velocity = filtered
        let t = min(1, max(0, (abs(filtered) - Self.slowSpeed) / (Self.fastSpeed - Self.slowSpeed)))
        return t * t * (3 - 2 * t)
    }

}

/// What a `zoomStepped` step ran into, for the mouse's haptics (M4c spec §5, §12.3): a `zoom-stops` stop it landed on
/// (`haptic-zoom-stop`) or a zoom limit it reached or pushed against (`haptic-limit`).
public enum ZoomStepBump: Sendable { case stop, limit }

extension ViewTransform {
    /// One step of `zoom-step` (M4c spec §12.3; the gesture button + wheel): the zoom keys' √2 step (`zoomedStep`), at
    /// `anchor` (view pixels; the image point under it stays put), that never jumps over a stop of `stops`: a stop
    /// between the scale and the step's target is where it lands, at the stop's scale, as a right-button zoom halts on
    /// it. A scale already on a stop (within `ZoomStopGesture.startTolerance`) leaves it. At a zoom limit the step stops
    /// on the limit; one more the same way changes nothing and bumps again.
    public func zoomStepped(up: Bool, anchor: CGPoint, stops: [ZoomStop]) -> (transform: ViewTransform, bump: ZoomStepBump?) {
        let s = scale, limits = scaleLimits
        if up ? s >= limits.upperBound * (1 - 1e-9) : s <= limits.lowerBound * (1 + 1e-9) { return (self, .limit) }
        let target = up ? s * 2.0.squareRoot() : s / 2.0.squareRoot()
        let tolerance = ZoomStopGesture.startTolerance
        let between = ZoomStops.scales(of: stops, for: self).filter {
            up ? $0.scale > s * (1 + tolerance) && $0.scale <= target * (1 + tolerance)
               : $0.scale < s * (1 - tolerance) && $0.scale >= target * (1 - tolerance)
        }
        if let stop = up ? between.first : between.last {   // the nearest (`scales` ascend)
            return (zoomed(toScale: stop.scale, anchor: anchor), .stop)
        }
        let clamped = min(max(target, limits.lowerBound), limits.upperBound)
        return (zoomed(toScale: clamped, anchor: anchor), clamped == target ? nil : .limit)
    }
}
