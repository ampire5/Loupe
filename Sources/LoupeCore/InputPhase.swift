import CoreGraphics
import Foundation

/// Picks how long the render loop waits after a display-link callback before it reads what to draw
/// (a late latch), so the read falls half a refresh period away from where input events arrive.
///
/// In native full screen, drag and scroll events arrive within about a millisecond of the callback,
/// some just before it and some just after: a frame then gets either no event or two, and the motion
/// judders though every frame is on time. Reading half a period after the events' phase leaves a
/// margin of p/2 on both sides, so each frame picks up exactly one event.
///
/// The phase is the circular mean of the recent input times taken modulo the period (each time is an
/// angle on the period's circle; the mean of their unit vectors points at the phase). If the inputs
/// are spread around the circle there is no phase to avoid, and without a recent stream of inputs
/// (a key press, a finished load) there is nothing to wait for: both latch at once. Times are seconds
/// on one clock (the render loop uses `CACurrentMediaTime`); only differences matter.
public struct InputPhase {
    /// Inputs older than this, relative to the callback, are ignored.
    public static let window: TimeInterval = 0.5
    /// How many of the most recent inputs are kept: a half second of 60 Hz events.
    public static let capacity = 32
    /// Fewer inputs than this in the window are not a stream: latch at once.
    public static let minInputs = 4
    /// Mean resultant length (1 = all inputs at one phase, 0 = evenly spread) below which the inputs
    /// have no consistent phase.
    public static let minConcentration = 0.5
    /// The latch never waits longer than this fraction of the period, to leave time to draw.
    public static let maxDelayFraction = 0.6
    /// Past the clamp the latch sits at one end of the window (now or `maxDelayFraction`·period); it moves
    /// to the other end only once that end is farther from the inputs by more than this fraction of the
    /// period, so a phase estimate jittering around the switch point (inputs near 0.3 p) does not make the
    /// latch jump by 0.6 p every few frames.
    public static let switchMargin = 0.05

    private enum End { case now, latest }

    private var times: [TimeInterval] = []
    private var next = 0   // ring index of the oldest input once `times` is full
    private var end: End?   // the end of the window the latch was at or nearest to; nil without a stream

    public init() { times.reserveCapacity(Self.capacity) }

    public mutating func recordInput(at time: TimeInterval) {
        if times.count < Self.capacity {
            times.append(time)
        } else {
            times[next] = time
            next = (next + 1) % Self.capacity
        }
    }

    /// How long after the callback at `callback` to read the input, for a display with refresh
    /// `period`: in [0, `maxDelayFraction`·period]; 0 means read at once. Mutating only for the clamp's
    /// hysteresis: call it once per callback.
    public mutating func latchDelay(callbackAt callback: TimeInterval, period: TimeInterval) -> TimeInterval {
        guard period > 0 else { end = nil; return 0 }
        var x = 0.0, y = 0.0, n = 0
        for t in times where callback - t < Self.window {
            // Phase relative to the callback, so the callback sits at angle 0.
            let angle = 2 * Double.pi * (t - callback).truncatingRemainder(dividingBy: period) / period
            x += cos(angle)
            y += sin(angle)
            n += 1
        }
        guard n >= Self.minInputs, (x * x + y * y).squareRoot() / Double(n) >= Self.minConcentration else {
            end = nil
            return 0
        }
        let phase = Self.wrap(atan2(y, x) / (2 * Double.pi) * period, period)
        let ideal = Self.wrap(phase + period / 2, period)
        let maxDelay = Self.maxDelayFraction * period
        if ideal <= maxDelay {
            end = ideal <= maxDelay / 2 ? .now : .latest   // so leaving the window continues from the near end
            return ideal
        }
        // The ideal latch lies just before the callback, past the clamp: take whichever end of the
        // allowed window is farther from the inputs (at least 0.3 p away, since the ideal is past 0.6 p),
        // keeping the current end unless the other is clearly farther.
        let advantageOfNow = Self.circularDistance(0, phase, period) - Self.circularDistance(maxDelay, phase, period)
        let margin = Self.switchMargin * period
        switch end {
        case .now?: if advantageOfNow < -margin { end = .latest }
        case .latest?: if advantageOfNow > margin { end = .now }
        case nil: end = advantageOfNow >= 0 ? .now : .latest
        }
        return end == .now ? 0 : maxDelay
    }

    private static func wrap(_ value: Double, _ period: Double) -> Double {
        let r = value.truncatingRemainder(dividingBy: period)
        return r < 0 ? r + period : r
    }

    private static func circularDistance(_ a: Double, _ b: Double, _ period: Double) -> Double {
        let d = wrap(a - b, period)
        return min(d, period - d)
    }
}

/// The display's refresh period from successive display-link target timestamps. A delta that is not
/// a plausible refresh period, or over 1.5 times the current one (the link was paused, or a frame was
/// skipped: exactly twice), is ignored, unless the next delta repeats it: then the refresh rate really
/// dropped. A shorter delta is taken at once (the rate went up).
public struct FramePeriod {
    /// Until two timestamps are seen.
    public static let fallback: TimeInterval = 1.0 / 60
    /// Deltas outside this range are never a refresh period.
    public static let plausible: ClosedRange<TimeInterval> = (1.0 / 250)...(1.0 / 20)

    public private(set) var period = Self.fallback
    private var lastTarget: TimeInterval?
    private var lastDelta: TimeInterval?

    public init() {}

    /// Call once per callback; returns the current period estimate.
    public mutating func record(targetTimestamp: TimeInterval) -> TimeInterval {
        defer { lastTarget = targetTimestamp }
        guard let lastTarget else { return period }
        let delta = targetTimestamp - lastTarget
        defer { lastDelta = delta }
        guard Self.plausible.contains(delta) else { return period }
        let repeated = lastDelta.map { abs($0 - delta) < 0.1 * delta } ?? false
        if delta <= 1.5 * period || repeated { period = delta }
        return period
    }
}

/// Which snapshot a late-latched frame draws. The drawable is vended at the callback, with the
/// drawableSize of that moment, but the snapshot is read up to 0.6 p later; a live resize (or the full
/// screen animation) changes drawableSize and the view size together once per frame, often during the
/// latch, so the latched snapshot would never fit the drawable and every frame would be skipped. The
/// snapshot read at the callback, before the latch, was made for the drawable's size: draw that one
/// then, and the newer one on the next callback, as without a latch.
public enum LatchedFrame: Equatable {
    /// The snapshot read after the latch (the normal case).
    case latched
    /// The snapshot read at the callback, before the latch.
    case early

    /// `early` is nil when there was no latch; `earlyIsNew` says whether it is not on screen already.
    /// When neither fits, the latched one is chosen and the draw skips it as a resize in flight.
    public static func choose(drawable: CGSize, latched: CGSize, early: CGSize?, earlyIsNew: Bool) -> LatchedFrame {
        guard latched != drawable, let early, early == drawable, earlyIsNew else { return .latched }
        return .early
    }
}
