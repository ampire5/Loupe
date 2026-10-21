import CoreGraphics
import Foundation

/// Release velocity of a right-button zoom drag, in doublings per second, from the doublings the cursor travel
/// amounted to (`RMBZoom.doublings(dyPoints:)`, cumulative from the press) at each event. Same window and stale rule
/// as `DragVelocityTracker`; times are seconds on any monotonic clock (`NSEvent.timestamp`).
public struct ZoomVelocityTracker: Sendable {
    private var samples = VelocitySamples()

    public init() {}

    public mutating func reset() { samples.reset() }

    public mutating func add(_ doublings: Double, at t: TimeInterval) {
        samples.add(SIMD2(doublings, 0), at: t)
    }

    /// Doublings/s at the moment of release (positive zooms in), or 0 when there is nothing to coast with: too few
    /// samples, the newest one is stale, or the speed is below `ZoomCoast.minStartSpeed`.
    public func releaseVelocity(at release: TimeInterval) -> Double {
        guard let v = samples.slope(at: release)?.x else { return 0 }
        return abs(v) < ZoomCoast.minStartSpeed ? 0 : v
    }
}

/// The zoom's glide after the right button is released: the speed in doublings/s decays like the pan coast
/// (`InertiaCoast.decayPerMillisecond`), integrated exactly over each frame so 60 and 120 Hz agree.
public struct ZoomCoast: Sendable {
    /// Slower releases (doublings/s) do not coast, like the pan coast's `minStartSpeed`: 0.2 is about 27 pt/s at the
    /// default rate, a hand that has stopped rather than a flick.
    public static let minStartSpeed: Double = 0.2
    /// The coast ends once the speed (doublings/s) falls below this.
    public static let stopSpeed: Double = 0.05

    public private(set) var velocity: Double

    public init(velocity: Double) { self.velocity = velocity }

    public var isFinished: Bool { abs(velocity) < Self.stopSpeed }

    /// Advances by `dt` seconds and returns the doublings gained this frame: `v * (1 - e^(-rate dt)) / rate`.
    public mutating func step(dt: TimeInterval) -> Double {
        guard dt > 0 else { return 0 }
        let decay = exp(-InertiaCoast.rate * dt)
        let d = velocity * (1 - decay) / InertiaCoast.rate
        velocity *= decay
        return d
    }

    /// Ends the coast (a stop or a zoom limit was reached).
    public mutating func halt() { velocity = 0 }
}

/// A right-button zoom that goes on after release: the drag's `RMBZoom` (press anchor and start transform) and
/// `ZoomStopGesture` carried over, so the glide pins the same image point and meets the same stops. It ends on the
/// first stop it lands on (the caller gives the haptic tick for that frame) and at a zoom limit.
public struct RMBZoomCoast: Sendable {
    public let zoom: RMBZoom
    private var stops: ZoomStopGesture
    private var coast: ZoomCoast
    /// Cumulative doublings the cursor travel (and then the coast) asks for since the press, as in the drag.
    private var doublings: Double

    /// `doublings` is where the drag ended (`zoom.doublings(dyPoints:)`, inversion included), `velocity` the release
    /// velocity in the same sense (positive zooms in).
    public init(zoom: RMBZoom, stops: ZoomStopGesture, doublings: Double, velocity: Double) {
        self.zoom = zoom
        self.stops = stops
        // The glide stops at a zoom limit; it never stretches past one (M4b spec §3).
        self.stops.rubber = false
        self.doublings = doublings
        coast = ZoomCoast(velocity: velocity)
    }

    public var isFinished: Bool { coast.isFinished }

    /// The carried-over gesture's zoom stretch: always 1, the coast does not stretch.
    public var stretch: Double { stops.stretch }

    /// One frame of `dt` seconds: the transform to show, and whether this frame landed on a zoom stop.
    public mutating func advance(dt: TimeInterval) -> (transform: ViewTransform, landedOnStop: Bool) {
        let heading = coast.velocity
        doublings += coast.step(dt: dt)
        let r = stops.constrain(zoom.scale(doublings: doublings))
        let limits = zoom.start.scaleLimits
        if r.hitStop != nil
            || (heading > 0 && ZoomLimit.atUpper(r.scale, of: limits))
            || (heading < 0 && ZoomLimit.atLower(r.scale, of: limits)) {
            coast.halt()
        }
        return (zoom.transform(toScale: r.scale), stops.justHit)
    }
}

/// Whether a zoom scale stands on a zoom limit, within the relative tolerance the right-button coast (which halts
/// there) and the mouse's limit haptic share.
public enum ZoomLimit {
    static let tolerance = 1e-9

    public static func atUpper(_ scale: Double, of limits: ClosedRange<Double>) -> Bool {
        scale >= limits.upperBound * (1 - tolerance)
    }

    public static func atLower(_ scale: Double, of limits: ClosedRange<Double>) -> Bool {
        scale <= limits.lowerBound * (1 + tolerance)
    }
}

/// The mouse's haptic answer to each frame of a right-button zoom, its drag and then its coast (M4c spec §5): `.limit`
/// when the zoom gets to a zoom limit (a stretch begins, or without `zoom-rubber-band` the scale reaches it), once until
/// it leaves the limit again; otherwise `.stop` when the frame landed on a zoom stop. A stop that sits on a limit gives
/// `.limit` only. One value per gesture, made at the right press.
public struct ZoomBumps: Sendable {
    public enum Bump: Equatable, Sendable { case limit, stop }

    private var atLimit = false

    public init() {}

    /// `stretch` is the gesture's zoom stretch factor (1 inside the limits; the coast passes 1).
    public mutating func frame(scale: Double, stretch: Double, limits: ClosedRange<Double>,
                               landedOnStop: Bool) -> Bump? {
        let now = stretch != 1 || ZoomLimit.atUpper(scale, of: limits) || ZoomLimit.atLower(scale, of: limits)
        defer { atLimit = now }
        if now, !atLimit { return .limit }
        return landedOnStop ? .stop : nil
    }
}
