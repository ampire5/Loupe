/// Owns vertical wheel travel once it has claimed a right-button press. Precise scrolling
/// accumulates in the same units as other button chords, and its tail never navigates or pans.
public struct MediaScrubGesture {
    public private(set) var isScrubbing = false
    private var absorbsScrollTail = false
    private var cancelled = false
    private var travel = 0.0

    public init() {}

    /// Nil passes the event on. Zero consumes it without seeking.
    public mutating func scroll(delta: Double, precise: Bool, phase: ScrollPhase,
                                momentum: ScrollPhase, canStart: Bool) -> Int? {
        if !momentum.isEmpty { return isScrubbing || absorbsScrollTail ? 0 : nil }
        if !precise || phase.contains(.began) || phase.isEmpty {
            absorbsScrollTail = false
            if phase.contains(.began) { travel = 0 }
        }
        let moved = delta.isFinite && delta != 0
        if !isScrubbing {
            guard canStart, moved else { return absorbsScrollTail ? 0 : nil }
            isScrubbing = true
        }
        if precise, !phase.isEmpty { absorbsScrollTail = true }
        guard moved, !cancelled else { return 0 }
        if !precise { return Int(min(10_000, max(-10_000, delta.rounded(.awayFromZero)))) }

        travel += delta
        let unit = ButtonGestures.preciseWheelPoints
        let steps = min(10_000, max(-10_000, (travel / unit).rounded(.towardZero)))
        travel.formTruncatingRemainder(dividingBy: unit)
        return Int(steps)
    }

    /// Media can change before the button comes up. Consume the rest of that press.
    public mutating func cancel() {
        cancelled = isScrubbing
        travel = 0
    }

    public mutating func release() {
        isScrubbing = false
        cancelled = false
        travel = 0
    }
}
