import Testing
@testable import LoupeCore

/// Reference wrapper: `#expect` cannot call mutating methods on a local value.
private final class Driver {
    private var guarded = ScrollGestureGuard<Int>()
    func scroll(phase: ScrollPhase, momentum: ScrollPhase, touches: Int, start: Int) -> Bool {
        guarded.scroll(phase: phase, momentum: momentum, touches: touches, start: start)
    }
    func fingersLifted() { guarded.fingersLifted() }
    func swipeFired() -> Int? { guarded.swipeFired() }
}

/// The event stream of one trackpad scroll as AppKit delivers it: mayBegin, began, changed…, ended, then
/// momentum begin/changed/ended with an empty `phase`.
private let began: ScrollPhase = .began, changed: ScrollPhase = .changed, ended: ScrollPhase = .ended
private let none: ScrollPhase = []

@Test func twoFingerPanIsAppliedWithSystemMomentum() {
    let g = Driver()
    #expect(g.scroll(phase: .mayBegin, momentum: none, touches: 2, start: 1) == false)   // no delta yet
    #expect(g.scroll(phase: began, momentum: none, touches: 2, start: 1))
    #expect(g.scroll(phase: changed, momentum: none, touches: 2, start: 2))
    #expect(g.scroll(phase: ended, momentum: none, touches: 2, start: 3))
    #expect(g.scroll(phase: none, momentum: .began, touches: 0, start: 3))
    #expect(g.scroll(phase: none, momentum: .changed, touches: 0, start: 4))
    #expect(g.scroll(phase: none, momentum: .ended, touches: 0, start: 5))
}

@Test func scrollIsBlockedWhileThreeFingersAreDown() {
    let g = Driver()
    #expect(g.scroll(phase: began, momentum: none, touches: 2, start: 1))
    #expect(g.scroll(phase: changed, momentum: none, touches: 3, start: 2) == false)
    #expect(g.scroll(phase: changed, momentum: none, touches: 4, start: 2) == false)
    // Back to two fingers (the third lifted, no swipe fired): panning resumes.
    #expect(g.scroll(phase: changed, momentum: none, touches: 2, start: 2))
}

@Test func afterSwipeTheRestOfTheGestureAndItsMomentumAreIgnored() {
    let g = Driver()
    _ = g.scroll(phase: began, momentum: none, touches: 2, start: 1)
    _ = g.swipeFired()
    #expect(g.scroll(phase: changed, momentum: none, touches: 2, start: 9) == false)   // even with fewer fingers
    #expect(g.scroll(phase: ended, momentum: none, touches: 0, start: 9) == false)
    #expect(g.scroll(phase: none, momentum: .began, touches: 0, start: 9) == false)
    #expect(g.scroll(phase: none, momentum: .changed, touches: 0, start: 9) == false)
    #expect(g.scroll(phase: none, momentum: .ended, touches: 0, start: 9) == false)
}

@Test func newGestureAfterSwipeReenablesPan() {
    let g = Driver()
    _ = g.scroll(phase: began, momentum: none, touches: 2, start: 1)
    _ = g.swipeFired()
    #expect(g.scroll(phase: none, momentum: .changed, touches: 0, start: 9) == false)
    #expect(g.scroll(phase: began, momentum: none, touches: 2, start: 5))
    #expect(g.scroll(phase: changed, momentum: none, touches: 2, start: 6))
}

@Test func momentumBeginIsNotANewGesture() {
    let g = Driver()
    _ = g.scroll(phase: began, momentum: none, touches: 2, start: 1)
    _ = g.swipeFired()
    // `.began` in the momentum phase belongs to the old gesture.
    #expect(g.scroll(phase: .began, momentum: .began, touches: 0, start: 9) == false)
}

@Test func swipeReturnsTheTransformRecordedAtGestureStart() {
    let g = Driver()
    _ = g.scroll(phase: began, momentum: none, touches: 2, start: 10)
    _ = g.scroll(phase: changed, momentum: none, touches: 2, start: 11)
    _ = g.scroll(phase: changed, momentum: none, touches: 2, start: 12)
    #expect(g.swipeFired() == 10)
}

@Test func startIsRecordedAgainByTheNextGesture() {
    let g = Driver()
    _ = g.scroll(phase: began, momentum: none, touches: 2, start: 10)
    _ = g.scroll(phase: ended, momentum: none, touches: 0, start: 12)
    g.fingersLifted()
    _ = g.scroll(phase: none, momentum: .ended, touches: 0, start: 15)
    _ = g.scroll(phase: began, momentum: none, touches: 2, start: 15)
    #expect(g.swipeFired() == 15)
}

@Test func eventAfterAnEndedGestureStartsOneEvenWithoutBegan() {
    let g = Driver()
    _ = g.scroll(phase: began, momentum: none, touches: 2, start: 1)
    _ = g.scroll(phase: ended, momentum: none, touches: 0, start: 2)
    g.fingersLifted()
    #expect(g.scroll(phase: changed, momentum: none, touches: 2, start: 7))
    #expect(g.swipeFired() == 7)
}

@Test func swipeWithoutAnyScrollHasNothingToRestore() {
    let g = Driver()
    #expect(g.swipeFired() == nil)
    // A stale start from an earlier gesture is not restored once every finger has been lifted.
    _ = g.scroll(phase: began, momentum: none, touches: 2, start: 1)
    _ = g.scroll(phase: ended, momentum: none, touches: 0, start: 2)
    g.fingersLifted()
    #expect(g.swipeFired() == nil)
}

@Test func gestureRestartedByTheThirdFingerKeepsTheOriginalStart() {
    // The system may end the two-finger scroll and begin another when the third finger lands; the new
    // one starts after the accidental pan and must not become the restore point.
    let g = Driver()
    _ = g.scroll(phase: began, momentum: none, touches: 2, start: 10)
    _ = g.scroll(phase: changed, momentum: none, touches: 2, start: 11)
    _ = g.scroll(phase: ended, momentum: none, touches: 3, start: 12)
    #expect(g.scroll(phase: began, momentum: none, touches: 3, start: 12) == false)
    #expect(g.swipeFired() == 10)
}

@Test func swipeIsRestoredOnlyOncePerGesture() {
    let g = Driver()
    _ = g.scroll(phase: began, momentum: none, touches: 2, start: 10)
    #expect(g.swipeFired() == 10)
    #expect(g.swipeFired() == nil)
}
