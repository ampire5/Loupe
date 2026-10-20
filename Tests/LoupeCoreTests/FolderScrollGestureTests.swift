import Testing
@testable import LoupeCore

// dx < 0 is "towards next" (fingers moving left, as the three-finger swipe); the view converts device deltas.

@Test func folderScrollFiresAtTheThreshold() {
    var g = FolderScrollGesture()
    #expect(g.scroll(dx: -15, dy: 0, threshold: 40) == nil)
    #expect(g.scroll(dx: -20, dy: 0, threshold: 40) == nil)   // Σ 35 < 40
    #expect(!g.hasFired)
    #expect(g.scroll(dx: -5, dy: 0, threshold: 40) == .next)  // Σ 40
    #expect(g.hasFired)
}

@Test func folderScrollRightIsPrevious() {
    var g = FolderScrollGesture()
    #expect(g.scroll(dx: 50, dy: 3, threshold: 40) == .previous)
}

@Test func folderScrollHonoursTheConfiguredThreshold() {
    var g = FolderScrollGesture()
    #expect(g.scroll(dx: -60, dy: 0, threshold: 100) == nil)
    #expect(g.scroll(dx: -40, dy: 0, threshold: 100) == .next)
    var small = FolderScrollGesture()
    #expect(small.scroll(dx: 10, dy: 0, threshold: 10) == .previous)
}

@Test func folderScrollNeedsHorizontalDominance() {
    var g = FolderScrollGesture()
    #expect(g.scroll(dx: -50, dy: 30, threshold: 40) == nil)   // 50 < 2·30
    #expect(g.scroll(dx: -10, dy: 0, threshold: 40) == nil)    // 60 = 2·30, not more
    #expect(g.scroll(dx: -10, dy: 0, threshold: 40) == .next)  // 70 > 60
}

@Test func folderScrollVerticalNeverStepsAFolder() {
    var g = FolderScrollGesture()
    #expect(g.scroll(dx: 0, dy: -30, threshold: 40) == nil)
    #expect(g.scroll(dx: 0, dy: -30, threshold: 40) == .up)          // a vertical step, not a folder
    for _ in 0..<20 { #expect(g.scroll(dx: 0, dy: -30, threshold: 40) == nil) }
    #expect(g.notch(dx: 0, dy: -1) == nil)
}

@Test func folderScrollFiresOncePerPress() {
    var g = FolderScrollGesture()
    #expect(g.scroll(dx: -45, dy: 0, threshold: 40) == .next)
    #expect(g.scroll(dx: -100, dy: 0, threshold: 40) == nil)
    #expect(g.scroll(dx: 300, dy: 0, threshold: 40) == nil)    // back the other way: still the same press
    #expect(g.notch(dx: 1, dy: 0) == nil)
    #expect(g.hasFired)
}

@Test func folderScrollResetsOnRelease() {
    var g = FolderScrollGesture()
    #expect(g.scroll(dx: -45, dy: 0, threshold: 40) == .next)
    g.buttonsReleased()
    #expect(!g.hasFired)
    #expect(g.scroll(dx: 45, dy: 0, threshold: 40) == .previous)
}

@Test func folderScrollReleaseDropsAPartialSum() {
    var g = FolderScrollGesture()
    #expect(g.scroll(dx: -30, dy: 0, threshold: 40) == nil)
    g.buttonsReleased()
    #expect(g.scroll(dx: -30, dy: 0, threshold: 40) == nil)    // a fresh 30, not 60
    g.buttonsReleased()
    #expect(g.scroll(dx: 0, dy: 30, threshold: 40) == nil)
    g.buttonsReleased()
    #expect(g.scroll(dx: -45, dy: 20, threshold: 40) == .next)  // the vertical 30 was forgotten too
}

@Test func folderScrollNotchFiresOnTheFirstHorizontalNotch() {
    var g = FolderScrollGesture()
    #expect(g.notch(dx: -1, dy: 0) == .next)
    #expect(g.notch(dx: -1, dy: 0) == nil)
    g.buttonsReleased()
    #expect(g.notch(dx: 0.1, dy: 0) == .previous)
}

@Test func folderScrollNotchNeedsHorizontalDominance() {
    var g = FolderScrollGesture()
    #expect(g.notch(dx: -1, dy: 0.5) == nil)    // 1 = 2·0.5, not more
    #expect(g.notch(dx: -1, dy: 0.4) == .next)
}

@Test func folderScrollNotchAfterAPreciseFireDoesNothing() {
    var g = FolderScrollGesture()
    #expect(g.scroll(dx: 40, dy: 0, threshold: 40) == .previous)
    #expect(g.notch(dx: -1, dy: 0) == nil)
}

// MARK: Events, buttons and the latch

private extension FolderScrollGesture {
    /// The tests above are about one step per press: no repeat, so time does not matter.
    mutating func scroll(dx: Double, dy: Double, threshold: Double) -> Step? {
        scroll(dx: dx, dy: dy, began: false, threshold: threshold, repeatAfter: 0, at: 0)
    }
    mutating func notch(dx: Double, dy: Double) -> Step? {
        notch(dx: dx, dy: dy, repeatAfter: 0, at: 0)
    }
    /// The default `folder-scroll-repeat` (350 ms); `t` in seconds on the events' clock.
    mutating func trackpad(_ dx: Double, dy: Double = 0, momentum: Bool = false, began: Bool = false,
                           held: MouseButtons = .left, repeatAfter: Double = 0.35, at t: Double = 0) -> Outcome {
        event(dx: dx, dy: dy, precise: true, momentum: momentum, began: began, held: held, threshold: 40,
              repeatAfter: repeatAfter, at: t)
    }
    mutating func wheel(_ dx: Double, dy: Double = 0, held: MouseButtons = .right, repeatAfter: Double = 0.35,
                        at t: Double = 0) -> Outcome {
        event(dx: dx, dy: dy, precise: false, momentum: false, began: false, held: held, threshold: 40,
              repeatAfter: repeatAfter, at: t)
    }
}

@Test func folderScrollEventWithoutAButtonPasses() {
    var g = FolderScrollGesture()
    #expect(g.trackpad(-50, held: []) == .pass)
    #expect(g.wheel(-1, held: []) == .pass)
}

@Test func folderScrollEventPreciseIsConsumedUntilItSteps() {
    var g = FolderScrollGesture()
    #expect(g.trackpad(-30) == .consumed)
    #expect(g.trackpad(-10) == .step(.next))
    #expect(g.trackpad(-100) == .consumed)
    #expect(g.trackpad(0, held: .right) == .consumed)     // the right button counts for precise deltas too
}

@Test func folderScrollEventLeftButtonCountsOnlyForPreciseDeltas() {
    var g = FolderScrollGesture()
    #expect(g.wheel(-1, held: .left) == .pass)             // a plain mouse: only the right button
    #expect(g.wheel(-1, held: [.left, .right]) == .step(.next))
}

@Test func folderScrollEventNotches() {
    var g = FolderScrollGesture()
    #expect(g.wheel(0, dy: -1) == .pass)                   // vertical: steps photos as before
    #expect(g.wheel(-1, dy: -1) == .pass)                  // not mostly horizontal, nothing fired: as before
    #expect(g.wheel(1) == .step(.previous))
    #expect(g.wheel(1) == .consumed)
    #expect(g.wheel(-1, dy: -1) == .consumed)              // after the step, horizontal notches are swallowed
    #expect(g.wheel(0, dy: -1) == .pass)                   // a vertical notch still steps photos
}

@Test func folderScrollEventMomentumNeverSteps() {
    var g = FolderScrollGesture()
    // A pan was coasting when the button went down (a press that catches the picture): consumed, no pan, no step.
    for i in 0..<10 { #expect(g.trackpad(-20, momentum: true, at: Double(i) * 0.016) == .consumed) }
    #expect(!g.hasFired)
    // Fingers under the button, then their own coast: only the fingers' travel counts.
    #expect(g.trackpad(-30, at: 0.2) == .consumed)
    for i in 0..<10 { #expect(g.trackpad(-20, momentum: true, at: 0.22 + Double(i) * 0.016) == .consumed) }
    #expect(!g.hasFired)
    #expect(g.trackpad(-10, at: 1) == .step(.next))       // the fingers' 30 + 10
    // After a step, a coast never re-arms or steps, however long it goes on.
    for i in 1...10 { #expect(g.trackpad(-50, momentum: true, at: 1 + Double(i)) == .consumed) }
    #expect(g.trackpad(50, momentum: true, at: 20) == .consumed)
}

@Test func folderScrollEventWithNoButtonForgetsThePress() {
    var g = FolderScrollGesture()
    #expect(g.trackpad(-45) == .step(.next))
    #expect(g.trackpad(-10, held: []) == .pass)            // the release went elsewhere (the strip, another window)
    #expect(!g.hasFired)
    #expect(g.trackpad(-20, momentum: true) == .consumed)  // and "fingers scrolled" was forgotten with it
    #expect(!g.hasFired)
}

@Test func folderScrollPressWhileLatchedIsRefusedUntilRelease() {
    var g = FolderScrollGesture()
    #expect(g.press(.right, held: .right) == true)
    #expect(g.wheel(-1) == .step(.next))
    #expect(g.press(.left, held: [.left, .right]) == false)  // the right button is still down: no pan either
    g.release(.left, held: .right)
    #expect(g.hasFired)                                    // one button is still down
    g.release(.right, held: [])
    #expect(!g.hasFired)
    #expect(g.press(.left, held: .left) == true)
}

@Test func folderScrollPressClearsAStaleLatch() {
    var g = FolderScrollGesture()
    #expect(g.trackpad(-45) == .step(.next))
    // The left release was lost; the right press finds no other button down.
    #expect(g.press(.right, held: .right) == true)
    #expect(!g.hasFired)
}

@Test func folderScrollReleaseReadsHeldButtonsWithTheReleasedOneStillIn() {
    var g = FolderScrollGesture()
    #expect(g.trackpad(-45) == .step(.next))
    g.release(.left, held: .left)                          // the event may still report the button going up
    #expect(!g.hasFired)
}

// MARK: Repeated steps while the button stays held (`folder-scroll-repeat`)

@Test func folderScrollNotchesRepeatAfterTheGap() {
    var g = FolderScrollGesture()
    #expect(g.wheel(-1, at: 0) == .step(.next))
    #expect(g.wheel(-1, at: 0.1) == .consumed)             // inside the 350 ms gap: dropped
    #expect(g.wheel(-1, at: 0.349) == .consumed)
    #expect(g.wheel(-1, at: 0.35) == .step(.next))         // the gap counts from the last step
    #expect(g.wheel(1, at: 0.8) == .step(.previous))       // each repeat goes the way of its own notch
    #expect(g.wheel(-1, dy: -1, at: 1.5) == .consumed)     // not mostly horizontal: swallowed, as after any step
    #expect(g.wheel(0, dy: -1, at: 1.6) == .pass)          // a vertical notch still steps photos
}

@Test func folderScrollNotchesInsideTheGapAreDroppedNotQueued() {
    var g = FolderScrollGesture()
    #expect(g.wheel(-1, at: 0) == .step(.next))
    // A fast spin: a notch every 30 ms. One step per gap, none saved up for later.
    var steps = 0
    for i in 1...24 where g.wheel(-1, at: Double(i) * 0.03) != .consumed { steps += 1 }   // up to 0.72 s
    #expect(steps == 2)                                    // at 0.36 and 0.72
    #expect(g.wheel(-1, at: 0.75) == .consumed)            // nothing queued: the notch after them is dropped too
}

@Test func folderScrollNewSwipeReArms() {
    var g = FolderScrollGesture()
    #expect(g.trackpad(-45, at: 0) == .step(.next))
    #expect(g.trackpad(-45, at: 0.1) == .consumed)         // the same swipe: spent
    // The fingers lift and land again: `.began`, then the threshold again.
    #expect(g.trackpad(-30, began: true, at: 0.5) == .consumed)
    #expect(g.trackpad(-10, at: 0.52) == .step(.next))
    #expect(g.trackpad(-100, at: 0.6) == .consumed)        // one step per swipe
    // A new swipe soon after the last step waits for the gap; it is not dropped.
    #expect(g.trackpad(45, began: true, at: 0.7) == .consumed)
    #expect(g.trackpad(1, at: 0.86) == .consumed)          // 0.34 s since the step
    #expect(g.trackpad(1, at: 0.88) == .step(.previous))
}

@Test func folderScrollPauseReArms() {
    var g = FolderScrollGesture()
    #expect(g.trackpad(-45, at: 0) == .step(.next))
    #expect(g.trackpad(-10, at: 0.1) == .consumed)
    // Fingers rest on the pad without moving (a resting finger's empty events are not movement), then go on.
    #expect(g.trackpad(0, at: 0.3) == .consumed)
    #expect(g.trackpad(-45, at: 0.44) == .consumed)        // 0.34 s since the last movement: still the same swipe
    #expect(g.trackpad(0, at: 0.6) == .consumed)
    #expect(g.trackpad(-30, at: 0.8) == .consumed)         // 0.36 s since 0.44: re-armed, Σ 30 from here
    #expect(g.trackpad(-10, at: 0.82) == .step(.next))
}

@Test func folderScrollReversalReArmsForTheWayBack() {
    var g = FolderScrollGesture()
    #expect(g.trackpad(-45, at: 0) == .step(.next))
    #expect(g.trackpad(45, at: 0.1) == .consumed)          // back the other way: re-armed, but inside the gap
    #expect(g.trackpad(1, at: 0.36) == .step(.previous))
    // A twitch back re-arms only for the way back: going on the first way is still the spent swipe.
    var h = FolderScrollGesture()
    #expect(h.trackpad(-45, at: 0) == .step(.next))
    #expect(h.trackpad(2, at: 0.1) == .consumed)
    #expect(h.trackpad(-60, at: 0.42) == .consumed)        // 0.32 s after the twitch: no rest either
    #expect(h.trackpad(-60, at: 0.44) == .consumed)
    #expect(h.trackpad(30, at: 0.46) == .consumed)         // the way back counts from where it turned
    #expect(h.trackpad(0, dy: 2, at: 0.47) == .consumed)   // a sliver of vertical travel does not drop it
    #expect(h.trackpad(10, at: 0.48) == .step(.previous))
    // After a twitch back, a new swipe (or a rest) re-arms both ways again.
    var k = FolderScrollGesture()
    #expect(k.trackpad(-45, at: 0) == .step(.next))
    #expect(k.trackpad(2, at: 0.1) == .consumed)
    #expect(k.trackpad(-45, began: true, at: 0.5) == .step(.next))
    #expect(k.trackpad(2, at: 0.6) == .consumed)
    #expect(k.trackpad(-45, at: 1.0) == .step(.next))      // rested 0.4 s after the twitch
}

@Test func folderScrollRepeatZeroIsOneStepPerPress() {
    var g = FolderScrollGesture()
    #expect(g.wheel(-1, repeatAfter: 0, at: 0) == .step(.next))
    #expect(g.wheel(-1, repeatAfter: 0, at: 1) == .consumed)
    #expect(g.wheel(1, repeatAfter: 0, at: 5) == .consumed)
    #expect(g.trackpad(-45, began: true, held: .right, repeatAfter: 0, at: 6) == .consumed)
    #expect(g.trackpad(45, held: .right, repeatAfter: 0, at: 7) == .consumed)
    g.release(.right, held: [])
    #expect(g.wheel(1, repeatAfter: 0, at: 7.1) == .step(.previous))
}

@Test func folderScrollReleaseForgetsTheGap() {
    var g = FolderScrollGesture()
    #expect(g.wheel(-1, at: 0) == .step(.next))
    g.release(.right, held: [])
    #expect(g.wheel(-1, at: 0.05) == .step(.next))         // a new press steps at once
    g.release(.right, held: [])
    #expect(g.trackpad(-45, at: 0.1) == .step(.next))
}

@Test func folderScrollRepeatsKeepTheLatch() {
    var g = FolderScrollGesture()
    #expect(g.wheel(-1, at: 0) == .step(.next))
    #expect(g.wheel(-1, at: 0.4) == .step(.next))
    #expect(g.press(.left, held: [.left, .right]) == false)  // the right button's own action stays suppressed
    #expect(g.hasFired)
}

// MARK: Direction (`folder-scroll-direction`)

/// The view's delta factor: fingers moving left give `dx < 0` (next) with `natural` and `dx > 0` (previous) with
/// `reversed`, whatever "natural scrolling" says; a notch goes as the vertical wheel with `natural` and the other way
/// with `reversed`.
@Test func folderScrollDirectionTurnsFingersAndNotches() {
    for inverted in [false, true] {
        // Fingers moving left: the device delta is negative with natural scrolling on, positive with it off.
        let fingersLeft: Double = inverted ? -10 : 10
        let fingers = FingerDirection.sign(invertedFromDevice: inverted)
        #expect(FolderScrollDirection.natural.factor(precise: true, invertedFromDevice: inverted) * fingersLeft < 0)
        #expect(FolderScrollDirection.reversed.factor(precise: true, invertedFromDevice: inverted) * fingersLeft > 0)
        // A notch: tilt right is a negative device delta, "next" like wheel down with `natural`.
        #expect(FolderScrollDirection.natural.factor(precise: false, invertedFromDevice: inverted) == -fingers)
        #expect(FolderScrollDirection.reversed.factor(precise: false, invertedFromDevice: inverted) == fingers)
    }
}

// dy > 0 is "down" in the view's convention, as dx < 0 is "next".

@Test func folderScrollVerticalSwipeFiresOncePerSwipe() {
    var g = FolderScrollGesture()
    #expect(g.scroll(dx: 2, dy: 25, threshold: 40) == nil)
    #expect(g.scroll(dx: 0, dy: 20, threshold: 40) == .down)
    #expect(g.hasFired)
    #expect(g.scroll(dx: 0, dy: 80, threshold: 40) == nil)            // spent until a new swipe
    // With repeats on, a new swipe (began) after the gap goes the other way.
    #expect(g.scroll(dx: 0, dy: -50, began: true, threshold: 40, repeatAfter: 0.35, at: 1) == .up)
}

@Test func folderScrollVerticalNeedsDominance() {
    var g = FolderScrollGesture()
    #expect(g.scroll(dx: 30, dy: 50, threshold: 40) == nil)           // 50 < 2·30
}
