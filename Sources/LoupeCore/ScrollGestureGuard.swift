import FilmstripModel

/// The phases of a scroll event (`NSEvent.phase` / `momentumPhase`): the kit's, which the strip's motion takes too.
/// The view converts with `ScrollPhase(rawValue: event.phase.rawValue)`, and this type stays AppKit-free.
public typealias ScrollPhase = FilmstripModel.ScrollPhase

/// Keeps a three-finger swipe from also panning. Fingers land one after another, and as soon as two are
/// down macOS delivers precise two-finger scroll events, which pan the picture; only the third finger
/// makes the swipe recognisable. This decides which scroll events may pan and remembers where the
/// picture was when the scroll gesture began, so the swipe can put it back before navigating (the
/// relative centre carries over to the next photo, so a leftover shift would show there too).
///
/// - While three or more fingers touch the pad, scroll does not pan.
/// - A swipe that fires ignores the rest of that scroll gesture, momentum included, until a new gesture
///   begins (`.began` without momentum): the system keeps coasting after the fingers lift.
/// - `Start` is whatever the view needs to restore (its centre and mode); the view hands it in at the
///   first event of each gesture and gets it back from `swipeFired()`.
public struct ScrollGestureGuard<Start> {
    /// Between the first event of a scroll gesture and its `.ended`/`.cancelled` (momentum comes after).
    private var inGesture = false
    private var latched = false
    private var start: Start?

    public init() {}

    /// Call for every precise scroll event. Returns whether it may pan. `start` is only evaluated at the
    /// first event of a gesture.
    ///
    /// A gesture that begins with three fingers already down (the system may end the two-finger scroll
    /// and begin another when the third lands) keeps the start recorded earlier, which predates the
    /// accidental pan; with fewer fingers a fresh start is recorded.
    public mutating func scroll(phase: ScrollPhase, momentum: ScrollPhase, touches: Int,
                                start snapshot: @autoclosure () -> Start) -> Bool {
        if momentum.isEmpty {
            // `.mayBegin` carries no movement and no gesture yet.
            if phase.contains(.mayBegin), !phase.contains(.began) { return false }
            let isNew = phase.contains(.began) || phase.isEmpty || !inGesture
            if isNew {
                // Only a real beginning (or a device that has no phases) ends the latch.
                if phase.contains(.began) || phase.isEmpty { latched = false }
                if touches < 3 || start == nil { start = snapshot() }
            }
            inGesture = !(phase.contains(.ended) || phase.contains(.cancelled)) && !phase.isEmpty
        }
        return !latched && touches < 3
    }

    /// Every finger left the pad: a start recorded so far belongs to a touch session that is over, and
    /// must not be restored by a later swipe that had no scroll of its own.
    public mutating func fingersLifted() { start = nil }

    /// A three-finger swipe fired. Returns the start of the scroll gesture to restore (nil when there was
    /// none), and ignores the rest of that gesture and its momentum.
    public mutating func swipeFired() -> Start? {
        latched = true
        defer { start = nil }
        return start
    }
}
