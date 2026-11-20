import LoupeCore
import Testing

struct MediaScrubGestureTests {
    @Test func aPressKeepsItsPreciseScrollAndConsumesTheTailAfterRelease() {
        var gesture = MediaScrubGesture()
        #expect(gesture.scroll(delta: 6, precise: true, phase: .began, momentum: [], canStart: true) == 0)
        #expect(gesture.scroll(delta: 7, precise: true, phase: .changed, momentum: [], canStart: false) == 1)
        #expect(gesture.scroll(delta: -13, precise: true, phase: .changed, momentum: [], canStart: false) == -1)
        gesture.release()
        #expect(gesture.scroll(delta: 50, precise: true, phase: [], momentum: .changed, canStart: false) == 0)
        #expect(gesture.scroll(delta: 5, precise: true, phase: .began, momentum: [], canStart: false) == nil)
    }

    @Test func changingMediaDiscardsTravelUntilTheButtonIsReleased() {
        var gesture = MediaScrubGesture()
        #expect(gesture.scroll(delta: 1, precise: false, phase: [], momentum: [], canStart: true) == 1)
        gesture.cancel()
        #expect(gesture.scroll(delta: 1, precise: false, phase: [], momentum: [], canStart: true) == 0)
        gesture.release()
        #expect(gesture.scroll(delta: 1, precise: false, phase: [], momentum: [], canStart: true) == 1)
    }

    @Test func aNotchNeedsAnEligiblePressAndDoesNotCaptureZeroTravel() {
        var gesture = MediaScrubGesture()
        #expect(gesture.scroll(delta: 1, precise: false, phase: [], momentum: [], canStart: false) == nil)
        #expect(gesture.scroll(delta: 0, precise: false, phase: [], momentum: [], canStart: true) == nil)
        #expect(gesture.scroll(delta: -3, precise: false, phase: [], momentum: [], canStart: true) == -3)
        #expect(gesture.scroll(delta: 1, precise: false, phase: [], momentum: [], canStart: false) == 1)
        gesture.release()
        #expect(gesture.scroll(delta: 1, precise: false, phase: [], momentum: [], canStart: false) == nil)
    }
}
