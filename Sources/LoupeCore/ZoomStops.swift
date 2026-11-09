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

public enum ZoomStopMode: String, CaseIterable, Sendable {
    case fixed, adaptive, off

    public var next: Self {
        switch self {
        case .fixed: .adaptive
        case .adaptive: .off
        case .off: .fixed
        }
    }

    public var title: String {
        switch self {
        case .fixed: "Fixed"
        case .adaptive: "Adaptive"
        case .off: "Off"
        }
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

/// Stop state for one continuous pinch, right-button drag or thumb-wheel turn. Feed the cumulative
/// scale proposed by the input. Timed input can capture on approach or bypass at speed. Untimed input
/// (including the mouse coast) captures on crossing the exact scale.
public struct ZoomStopGesture: Sendable {
    /// Relative distance within which an approximate start counts as on a stop.
    public static let startTolerance = 0.005
    /// Signed travel from capture required to release an Adaptive stop, in scale doublings.
    public static let defaultBreakaway = 0.04

    private static let captureDistance = 0.045  // scale doublings
    private static let rearmMargin = 0.01       // beyond the capture zone, in scale doublings
    private static let fullCaptureSpeed = 1.2  // scale doublings per second
    private static let bypassSpeed = 3.0        // scale doublings per second
    private static let reachTolerance = 1e-12

    private enum State: Sendable {
        case tracking
        case held(index: Int, inputAtCapture: Double, threshold: Double)
        case departing(index: Int)
        case fixed(increasing: Bool)
    }

    private let stops: [ZoomStopScale]
    private let limits: ClosedRange<Double>?
    private let fixed: Bool
    private let breakaway: Double
    private var state = State.tracking
    private var startStop: ZoomStopScale?
    private var current: Double
    private var lastProposed: Double
    /// Free motion uses proposed × rebase. Consumed travel changes the origin, preserving sensitivity.
    private var rebase = 1.0
    private var resting: ZoomStop?
    private var lastTime: TimeInterval?
    private var velocity: Double?
    var isRestingOnStop: Bool {
        resting != nil || stops.contains { abs($0.scale - current) <= Self.reachTolerance * current }
    }

    /// True when an event lands on or passes a stop, for one haptic tick.
    public private(set) var justHit = false
    /// Whether the zoom limits stretch instead of absorbing. The mouse coast turns this off.
    public var rubber: Bool {
        didSet { if !rubber { stretch = 1 } }
    }
    /// Stretch to draw at a zoom limit, or 1 for ordinary zoom.
    public private(set) var stretch = 1.0

    /// `stops` ascending (as `ZoomStops.scales` gives them). `breakaway` is in scale doublings.
    public init(startScale: Double, stops: [ZoomStopScale], limits: ClosedRange<Double>? = nil, rubber: Bool = false,
                fixed: Bool = false, breakaway: Double = Self.defaultBreakaway, at timestamp: TimeInterval? = nil) {
        self.stops = stops
        self.limits = limits
        self.fixed = fixed
        self.breakaway = breakaway.isFinite && breakaway > 0 ? breakaway : Self.defaultBreakaway
        self.rubber = rubber
        current = startScale
        lastProposed = startScale
        lastTime = timestamp
        // Exact starts can already move away by the strict crossing check. An approximate start
        // gets the same free departure even if its first movement crosses the exact mark.
        startStop = stops.first {
            let distance = abs($0.scale - startScale)
            return distance > Self.reachTolerance * startScale && distance <= Self.startTolerance * startScale
        }
    }

    public init(transform: ViewTransform, stops: [ZoomStop], rubber: Bool = false,
                fixed: Bool = false, breakaway: Double = Self.defaultBreakaway, at timestamp: TimeInterval? = nil) {
        self.init(startScale: transform.scale, stops: ZoomStops.scales(of: stops, for: transform),
                  limits: transform.scaleLimits, rubber: rubber, fixed: fixed, breakaway: breakaway, at: timestamp)
    }

    /// The scale to show, and the stop it rests on (nil between stops). Invalid input keeps the current value.
    public mutating func constrain(_ proposedScale: Double, at timestamp: TimeInterval? = nil)
        -> (scale: Double, hitStop: ZoomStop?) {
        justHit = false
        let tol = Self.reachTolerance
        guard proposedScale.isFinite, proposedScale > 0 else { return (current, resting) }
        let speed = fixed ? nil : inputSpeed(proposedScale, at: timestamp)
        guard proposedScale != lastProposed else { return (current, resting) }
        // A one-ulp reversal must not release a Fixed stop.
        if resting != nil, abs(proposedScale - lastProposed) <= lastProposed * tol { return (current, resting) }
        let increasing = proposedScale > lastProposed
        lastProposed = proposedScale

        let rawWanted = proposedScale * rebase
        var wanted = rawWanted
        switch state {
        case let .held(index, inputAtCapture, threshold):
            let displacement = log2(proposedScale) - log2(inputAtCapture)
            let excess = abs(displacement) - threshold
            guard excess > tol else { return (current, resting) }
            // The threshold is the new origin. At breakaway the output starts at the exact stop;
            // the current sample contributes only the travel beyond that origin.
            wanted = current * pow(2, displacement > 0 ? excess : -excess)
            state = .departing(index: index)
        case let .fixed(entryIncreasing):
            if increasing == entryIncreasing {
                rebase = current / proposedScale
                return (current, resting)
            }
            state = .tracking
        case .tracking, .departing:
            break
        }

        let strength = speed.map {
            min(1, max(0, (Self.bypassSpeed - $0) / (Self.bypassSpeed - Self.fullCaptureSpeed)))
        } ?? 1
        let direction = increasing ? 1.0 : -1.0
        var stop: ZoomStop?
        for offset in stops.indices {
            let index = increasing ? offset : stops.count - 1 - offset
            if case let .departing(released) = state, index == released { continue }
            let point = stops[index]
            guard point != startStop else { continue }
            let s = point.scale
            let atLimit = limits.map { s <= $0.lowerBound * (1 + tol) || s >= $0.upperBound * (1 - tol) } ?? false
            let radius = speed != nil && !atLimit ? captureRadius(at: index, above: !increasing) * strength : 0
            let edge = s * pow(2, -direction * radius)
            let approaching = increasing ? current < s * (1 - tol) : current > s * (1 + tol)
            let crossedMark = increasing ? wanted >= s * (1 - tol) : wanted <= s * (1 + tol)
            // Fine adjustment already inside the approach zone is free up to the exact mark.
            let enteredZone = increasing
                ? current <= edge * (1 + tol) && wanted >= edge * (1 - tol)
                : current >= edge * (1 - tol) && wanted <= edge * (1 + tol)
            guard approaching, crossedMark || enteredZone else { continue }

            justHit = true
            if atLimit {
                stop = point.stop   // keep the overshoot for the rubber band
                break
            }
            if strength == 0 { continue }  // crossing feedback with the full raw travel
            if fixed {
                state = .fixed(increasing: increasing)
            } else {
                let threshold = breakaway * strength
                // A timed sample can cross both the mark and breakaway. Count its travel past
                // the exact mark so a brisk crossing loses progressively less as strength fades.
                let overshoot = speed == nil ? 0 : max(0, direction * log2(wanted / s))
                if overshoot > threshold + tol {
                    wanted *= pow(2, -direction * threshold)
                    state = .departing(index: index)
                    continue
                }
                state = .held(index: index, inputAtCapture: proposedScale * pow(2, -direction * overshoot),
                              threshold: threshold)
            }
            wanted = s
            stop = point.stop
            break
        }

        var scale = wanted
        if let limits {
            if wanted >= limits.upperBound * (1 - tol) {
                scale = limits.upperBound
            } else if wanted <= limits.lowerBound * (1 + tol) {
                scale = limits.lowerBound
            }
        }

        // A rubber band leaves the raw overshoot intact, so the way back from the limit is exact.
        stretch = 1
        let stretching = rubber && scale != wanted && limits != nil
        if stretching {
            let factor = RubberBand.zoomFactor(proposed: wanted, limit: scale)
            stretch = wanted > scale ? max(1, factor) : min(1, factor)
        }
        let effectiveScale = stretching ? wanted : scale
        if effectiveScale != rawWanted { rebase = effectiveScale / proposedScale }
        if let startStop, abs(startStop.scale - scale) > Self.startTolerance * scale
            || (current < startStop.scale) != (scale < startStop.scale) {
            self.startStop = nil
        }
        if case let .departing(index) = state {
            let s = stops[index].scale
            let above = scale > s
            let clearance = captureRadius(at: index, above: above) + Self.rearmMargin
            let distance = abs(log2(scale) - log2(s))
            if distance >= clearance - tol { state = .tracking }
        }
        if stop == nil, scale == current { stop = resting }
        resting = stop
        current = scale
        return (scale, stop)
    }

    private func captureRadius(at index: Int, above: Bool) -> Double {
        let neighbor = index + (above ? 1 : -1)
        guard stops.indices.contains(neighbor) else { return Self.captureDistance }
        let halfGap = abs(log2(stops[neighbor].scale) - log2(stops[index].scale)) / 2
        return min(Self.captureDistance, halfGap)
    }

    /// Estimate raw speed independent of the displayed scale, even during a hold. Respond quickly to a
    /// flick and forget the previous speed after a pause or a discontinuity in the event clock.
    private mutating func inputSpeed(_ proposal: Double, at timestamp: TimeInterval?) -> Double? {
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
        return abs(filtered)
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
