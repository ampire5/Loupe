import Testing
@testable import LoupeCore

@Suite struct ButtonGesturesTests {
    func make() -> ButtonGestures {
        ButtonGestures(kinds: [
            .panel: [.tap, .long, .wheel, .move],
            .forward: [.tap],
            .middle: [.tap, .long, .withRight],
        ], longPress: 0.4, moveStep: 20)
    }

    /// A button with a long press and nothing to scroll with: the timer fires it (the pre-§10 behaviour).
    func plainLong() -> ButtonGestures {
        ButtonGestures(kinds: [.middle: [.tap, .long]], longPress: 0.4, moveStep: 20)
    }

    func panelThumb() -> ButtonGestures {
        ButtonGestures(kinds: [.panel: [.tap, .thumbWheel]], longPress: 0.4, moveStep: 20)
    }

    @Test func tapFiresOnReleaseBeforeThreshold() {
        var g = make()
        #expect(g.press(.panel, at: 0) == [])
        #expect(g.release(.panel, at: 0.3) == [.init(button: .panel, kind: .tap, steps: 1)])
    }

    @Test func longFiresAtThresholdAndReleaseIsQuiet() {
        var g = plainLong()
        _ = g.press(.middle, at: 0)
        #expect(g.nextDeadline == 0.4)
        #expect(g.tick(at: 0.39).fires == [])
        #expect(g.tick(at: 0.4).fires == [.init(button: .middle, kind: .long, steps: 1)])
        #expect(g.tick(at: 0.5).fires == [])
        #expect(g.nextDeadline == nil)
        #expect(g.release(.middle, at: 1.0) == [])
    }

    @Test func lateReleaseWithoutTickStillFiresLongNotTap() {
        var g = plainLong()
        _ = g.press(.middle, at: 0)
        #expect(g.release(.middle, at: 0.9) == [.init(button: .middle, kind: .long, steps: 1)])
    }

    @Test func longPressDeadlineIsConsistentWithRealTimestamps() {
        var g = plainLong()
        for base in [123456.789, 98765.4321, 500000.123456] {
            _ = g.press(.middle, at: base)
            let d = g.nextDeadline!
            #expect(g.tick(at: d).fires == [.init(button: .middle, kind: .long, steps: 1)])
            #expect(g.release(.middle, at: d + 1) == [])
            _ = g.press(.middle, at: base)
            #expect(g.release(.middle, at: g.nextDeadline!) == [.init(button: .middle, kind: .long, steps: 1)])
        }
    }

    @Test func longOnAButtonWithWheelOrMoveWaitsForTheRelease() {
        for extra: PressKind in [.wheel, .thumbWheel, .move] {
            var g = ButtonGestures(kinds: [.panel: [.tap, .long, extra]], longPress: 0.4, moveStep: 20)
            _ = g.press(.panel, at: 0)
            #expect(g.nextDeadline == 0.4, "\(extra)")             // only to arm the haptic, not to fire the long press
            #expect(g.tick(at: 5).fires == [], "\(extra)")
            #expect(g.release(.panel, at: 0.4) == [.init(button: .panel, kind: .long, steps: 1)], "\(extra)")
            _ = g.press(.panel, at: 10)
            #expect(g.release(.panel, at: 10.39) == [.init(button: .panel, kind: .tap, steps: 1)], "\(extra)")
        }
    }

    // MARK: Long armed (the haptic that says "release now and the long press counts")

    @Test func longOnReleaseButtonIsArmedOnceAtTheDeadline() {
        var g = make()
        _ = g.press(.panel, at: 0)
        #expect(g.nextDeadline == 0.4)
        let early = g.tick(at: 0.39)
        #expect(early.fires == [] && early.armed == [])
        let due = g.tick(at: 0.4)
        #expect(due.fires == [] && due.armed == [.panel])
        #expect(g.nextDeadline == nil)
        let again = g.tick(at: 0.5)
        #expect(again.fires == [] && again.armed == [])
        #expect(g.release(.panel, at: 0.6) == [.init(button: .panel, kind: .long, steps: 1)])   // as before
    }

    @Test func wheelStepBeforeTheDeadlineMeansNeverArmed() {
        var g = make()
        _ = g.press(.panel, at: 0)
        _ = g.wheel(dy: 1, precise: false, momentum: false, at: 0.2)
        #expect(g.nextDeadline == nil)
        let due = g.tick(at: 0.5)
        #expect(due.fires == [] && due.armed == [])
    }

    @Test func moveBeforeTheDeadlineMeansNeverArmed() {
        var g = make()
        _ = g.press(.panel, at: 0)
        _ = g.move(dx: 0, dy: 5)
        #expect(g.nextDeadline == nil)
        #expect(g.tick(at: 0.5).armed == [])
    }

    @Test func wheelStepAfterArmedCancelsTheLongPressAsBefore() {
        var g = make()
        _ = g.press(.panel, at: 0)
        #expect(g.tick(at: 0.4).armed == [.panel])
        #expect(g.wheel(dy: 1, precise: false, momentum: false, at: 0.5).fires
                == [.init(button: .panel, kind: .wheel, steps: 1)])
        #expect(g.tick(at: 0.6).armed == [])                 // no further haptic
        #expect(g.release(.panel, at: 1.0) == [])
    }

    @Test func plainLongButtonIsNeverArmed() {
        var g = plainLong()
        _ = g.press(.middle, at: 0)
        let due = g.tick(at: 0.4)
        #expect(due.fires == [.init(button: .middle, kind: .long, steps: 1)] && due.armed == [])
    }

    @Test func buttonWithoutALongPressIsNeverArmed() {
        var g = ButtonGestures(kinds: [.panel: [.tap, .wheel]], longPress: 0.4, moveStep: 20)
        _ = g.press(.panel, at: 0)
        #expect(g.nextDeadline == nil && g.tick(at: 5).armed == [])
    }

    @Test func chordPressIsNeverArmed() {
        var g = ButtonGestures(kinds: [.panel: [.tap, .long, .wheel, .withRight]], longPress: 0.4, moveStep: 20)
        _ = g.press(.right, at: 0)
        _ = g.press(.panel, at: 0.1)                          // fires the chord and is dead
        #expect(g.nextDeadline == nil && g.tick(at: 5).armed == [])
    }

    @Test func holdThenScrollNeverTogglesOnRelease() {
        var g = make()
        _ = g.press(.panel, at: 0)
        #expect(g.tick(at: 0.5).fires == [])                       // the timer would have fired the toggle here
        #expect(g.wheel(dy: 1, precise: false, momentum: false, at: 0.6).fires
                == [.init(button: .panel, kind: .wheel, steps: 1)])
        #expect(g.release(.panel, at: 1.0) == [])
    }

    @Test func holdThenMoveNeverTogglesOnRelease() {
        var g = make()
        _ = g.press(.panel, at: 0)
        _ = g.move(dx: 0, dy: 5)
        #expect(g.release(.panel, at: 1.0) == [])
    }

    @Test func smallJitterDuringALongHoldStillFiresLongOnRelease() {
        var g = make()
        _ = g.press(.panel, at: 0)
        _ = g.move(dx: 1, dy: 2)
        #expect(g.release(.panel, at: 0.7) == [.init(button: .panel, kind: .long, steps: 1)])
    }

    @Test func tapOnlyButtonFiresOnPress() {
        var g = make()
        #expect(g.press(.forward, at: 0) == [.init(button: .forward, kind: .tap, steps: 1)])
        #expect(g.release(.forward, at: 5) == [])
        #expect(g.nextDeadline == nil)
    }

    @Test func tapWithoutLongIgnoresDuration() {
        var g = ButtonGestures(kinds: [.panel: [.tap, .wheel]], longPress: 0.4, moveStep: 20)
        _ = g.press(.panel, at: 0)
        #expect(g.nextDeadline == nil)
        #expect(g.release(.panel, at: 3) == [.init(button: .panel, kind: .tap, steps: 1)])
    }

    @Test func wheelStepsAndCancelsTap() {
        var g = make()
        _ = g.press(.panel, at: 0)
        let up = g.wheel(dy: 1, precise: false, momentum: false, at: 0.1)
        #expect(up.fires == [.init(button: .panel, kind: .wheel, steps: 1)] && up.consumed)
        let down = g.wheel(dy: -1, precise: false, momentum: false, at: 0.2)
        #expect(down.fires == [.init(button: .panel, kind: .wheel, steps: -1)] && down.consumed)
        #expect(g.release(.panel, at: 0.3) == [])
        #expect(g.tick(at: 0.5).fires == [])
        #expect(g.nextDeadline == nil)
    }

    @Test func preciseWheelStepsEvery12Points() {
        var g = make()
        _ = g.press(.panel, at: 0)
        #expect(g.wheel(dy: 5, precise: true, momentum: false, at: 0.1).fires == [])
        #expect(g.wheel(dy: 5, precise: true, momentum: false, at: 0.1).fires == [])
        let third = g.wheel(dy: 5, precise: true, momentum: false, at: 0.1)
        #expect(third.fires == [.init(button: .panel, kind: .wheel, steps: 1)] && third.consumed)
        // 3 points are left over: -30 makes -27, two whole steps.
        #expect(g.wheel(dy: -30, precise: true, momentum: false, at: 0.1).fires == [.init(button: .panel, kind: .wheel, steps: -2)])
    }

    @Test func wheelNotConsumedWithoutHoldOrBinding() {
        var g = make()
        #expect(g.wheel(dy: 1, precise: false, momentum: false, at: 0).consumed == false)
        _ = g.press(.forward, at: 0)
        let r = g.wheel(dy: 1, precise: false, momentum: false, at: 0.1)
        #expect(r.consumed == false && r.fires == [])
    }

    @Test func wheelWithoutBindingCancelsTapButPassesThrough() {   // M4c spec §12.2 (was: the tap stayed)
        var g = make()
        _ = g.press(.middle, at: 0)
        #expect(g.wheel(dy: 1, precise: false, momentum: false, at: 0.1).consumed == false)
        #expect(g.release(.middle, at: 0.2) == [])
    }

    @Test func wheelGoesToTheMostRecentButtonWithTheKind() {
        var g = ButtonGestures(kinds: [.panel: [.wheel], .gesture: [.wheel]], longPress: 0.4, moveStep: 20)
        _ = g.press(.panel, at: 0)
        _ = g.press(.gesture, at: 0.1)
        #expect(g.wheel(dy: 1, precise: false, momentum: false, at: 0.2).fires == [.init(button: .gesture, kind: .wheel, steps: 1)])
        _ = g.release(.gesture, at: 0.3)
        #expect(g.wheel(dy: 1, precise: false, momentum: false, at: 0.4).fires == [.init(button: .panel, kind: .wheel, steps: 1)])
    }

    @Test func releaseMidScrollAbsorbsTheTailOfTheGesture() {
        var g = make()
        _ = g.press(.panel, at: 0)
        #expect(g.wheel(dy: 20, precise: true, momentum: false, at: 0.1).consumed)
        _ = g.release(.panel, at: 0.2)
        // Same scroll: non-momentum events, then momentum, each within 0.25 s of the previous one.
        for (t, momentum) in [(0.3, false), (0.4, false), (0.5, true), (0.6, true), (0.7, true)] {
            let r = g.wheel(dy: 10, precise: true, momentum: momentum, at: t)
            #expect(r.consumed && r.fires == [])
        }
        let next = g.wheel(dy: 10, precise: true, momentum: false, at: 1.0)
        #expect(next.consumed == false && next.fires == [])
        #expect(g.wheel(dy: 10, precise: true, momentum: true, at: 1.05).consumed == false)
    }

    @Test func momentumNeverStepsWhileTheButtonIsHeld() {
        var g = make()
        _ = g.press(.panel, at: 0)
        let r = g.wheel(dy: 50, precise: true, momentum: true, at: 0.1)
        #expect(r.consumed && r.fires == [])
        #expect(g.release(.panel, at: 0.2) == [.init(button: .panel, kind: .tap, steps: 1)])   // the press stays alive
    }

    @Test func momentumIsNotAbsorbedWithoutAHeldGesture() {
        var g = make()
        #expect(g.wheel(dy: 10, precise: true, momentum: true, at: 0).consumed == false)
    }

    @Test func moveThresholdThenSteps() {
        var g = make()
        _ = g.press(.panel, at: 0)
        #expect(g.move(dx: 0, dy: 3) == [])
        #expect(g.release(.panel, at: 0.1) == [.init(button: .panel, kind: .tap, steps: 1)])

        _ = g.press(.panel, at: 1)
        #expect(g.move(dx: 0, dy: 5) == [])
        #expect(g.move(dx: 0, dy: 20) == [.init(button: .panel, kind: .move, steps: 1)])
        #expect(g.move(dx: 0, dy: -45) == [.init(button: .panel, kind: .move, steps: -2)])
        #expect(g.release(.panel, at: 1.1) == [])
        #expect(g.nextDeadline == nil)

        _ = g.press(.panel, at: 2)
        #expect(g.move(dx: 30, dy: 0) == [])
        #expect(g.release(.panel, at: 2.1) == [])
    }

    @Test func moveCancelsLongPress() {
        var g = make()
        _ = g.press(.panel, at: 0)
        _ = g.move(dx: 4, dy: 0)
        #expect(g.nextDeadline == nil)
        #expect(g.tick(at: 1).fires == [])
    }

    @Test func moveCancelsAButtonWithoutAMoveBinding() {
        var g = make()
        _ = g.press(.middle, at: 0)
        #expect(g.move(dx: 0, dy: 10) == [])
        #expect(g.release(.middle, at: 0.1) == [])
    }

    @Test func moveIsNotRoutedToAButtonWithoutTheKind() {
        var g = make()
        _ = g.press(.panel, at: 0)
        _ = g.press(.middle, at: 0.1)
        // The panel is the only button that can step, even though the middle one is newer.
        #expect(g.move(dx: 0, dy: 20) == [.init(button: .panel, kind: .move, steps: 1)])
    }

    @Test func thumbWheelStep() {
        var g = panelThumb()
        _ = g.press(.panel, at: 0)
        #expect(g.thumbWheel(delta: 3, stepsPerRevolution: 120) == [])
        #expect(g.thumbWheel(delta: 3, stepsPerRevolution: 120) == [.init(button: .panel, kind: .thumbWheel, steps: 1)])
        #expect(g.thumbWheel(delta: -16, stepsPerRevolution: 120) == [.init(button: .panel, kind: .thumbWheel, steps: -3)])
        #expect(g.release(.panel, at: 0.1) == [])
    }

    @Test func thumbWheelWithoutHeldButtonDoesNothing() {
        var g = panelThumb()
        #expect(g.thumbWheel(delta: 50, stepsPerRevolution: 120) == [])
        _ = g.press(.forward, at: 0)
        #expect(g.thumbWheel(delta: 50, stepsPerRevolution: 120) == [])
    }

    @Test func accumulatorsStartFreshOnEachPress() {
        var g = make()
        _ = g.press(.panel, at: 0)
        _ = g.wheel(dy: 10, precise: true, momentum: false, at: 0.1)
        _ = g.release(.panel, at: 0.2)
        _ = g.press(.panel, at: 1)
        #expect(g.wheel(dy: 10, precise: true, momentum: false, at: 1.1).fires == [])
    }

    @Test func momentumDuringAPressLeavesItsTapAndLongAlive() {
        var g = make()
        _ = g.press(.panel, at: 0)
        #expect(g.wheel(dy: 4, precise: true, momentum: true, at: 0.05) == ([], true))
        #expect(g.release(.panel, at: 0.2) == [.init(button: .panel, kind: .tap, steps: 1)])
        _ = g.press(.panel, at: 1)
        _ = g.wheel(dy: 4, precise: true, momentum: true, at: 1.05)
        #expect(g.release(.panel, at: 1.5) == [.init(button: .panel, kind: .long, steps: 1)])
    }

    @Test func chordWithRight() {
        var g = make()
        #expect(g.press(.right, at: 0) == [])
        #expect(g.press(.middle, at: 0.1) == [.init(button: .middle, kind: .withRight, steps: 1)])
        #expect(g.rightZoomSuppressed)
        #expect(g.nextDeadline == nil)
        #expect(g.release(.middle, at: 0.2) == [])
        #expect(g.rightZoomSuppressed)
        #expect(g.rightHeld)
        #expect(g.release(.right, at: 0.3) == [])
        #expect(g.rightZoomSuppressed == false)
        #expect(g.rightHeld == false)
    }

    @Test func chordPressIsDeadForWheelAndMove() {
        var g = ButtonGestures(kinds: [.middle: [.tap, .withRight, .wheel, .move]], longPress: 0.4, moveStep: 20)
        _ = g.press(.right, at: 0)
        _ = g.press(.middle, at: 0.1)
        #expect(g.wheel(dy: 1, precise: false, momentum: false, at: 0.2).consumed == false)
        #expect(g.move(dx: 0, dy: 40) == [])
    }

    @Test func draggedRightMakesTheNextPressItsOwn() {
        var g = make()
        _ = g.press(.right, at: 0)
        #expect(g.rightDragged == false)
        _ = g.move(dx: 0, dy: 3)
        #expect(g.rightDragged == false)
        _ = g.move(dx: 0, dy: 2)
        #expect(g.rightDragged)
        #expect(g.press(.middle, at: 0.1) == [])
        #expect(g.nextDeadline == 0.5)
        #expect(g.rightZoomSuppressed == false)
        #expect(g.release(.middle, at: 0.2) == [.init(button: .middle, kind: .tap, steps: 1)])
        _ = g.release(.right, at: 0.3)
        #expect(g.rightDragged == false)
    }

    @Test func rightDraggedLatchesEvenWhenTheCursorComesBack() {
        var g = make()
        _ = g.press(.right, at: 0)
        _ = g.move(dx: 0, dy: 10)
        _ = g.move(dx: 0, dy: -10)
        #expect(g.rightDragged)
        #expect(g.press(.middle, at: 0.1) == [])
        #expect(g.rightZoomSuppressed == false)
        _ = g.release(.right, at: 0.2)
        #expect(g.rightDragged == false)
    }

    @Test func rightDragIsMeasuredFromItsOwnPress() {
        var g = make()
        _ = g.move(dx: 0, dy: 50)
        _ = g.press(.right, at: 0)
        #expect(g.rightDragged == false)
        #expect(g.press(.middle, at: 0.1) == [.init(button: .middle, kind: .withRight, steps: 1)])
    }

    @Test func rightItselfNeverFires() {
        var g = make()
        #expect(g.press(.right, at: 0) == [])
        #expect(g.nextDeadline == nil)
        #expect(g.release(.right, at: 0.1) == [])
        #expect(g.rightZoomSuppressed == false)
    }

    @Test func middleWithoutRightIsNotAChord() {
        var g = make()
        #expect(g.press(.middle, at: 0) == [])
        #expect(g.rightZoomSuppressed == false)
    }

    @Test func cancelAllDropsEverything() {
        var g = make()
        _ = g.press(.panel, at: 0)
        _ = g.wheel(dy: 20, precise: true, momentum: false, at: 0.1)
        _ = g.press(.right, at: 0.1)
        _ = g.press(.middle, at: 0.2)
        #expect(g.rightZoomSuppressed)
        g.cancelAll()
        #expect(g.nextDeadline == nil)
        #expect(g.tick(at: 1).fires == [])
        #expect(g.release(.panel, at: 1.1) == [])
        #expect(g.release(.middle, at: 1.1) == [])
        #expect(g.wheel(dy: 1, precise: true, momentum: true, at: 1.2).consumed == false)
        #expect(g.wheel(dy: 1, precise: false, momentum: false, at: 1.2).consumed == false)
        #expect(g.rightZoomSuppressed == false)
        #expect(g.rightDragged == false)
    }

    // MARK: A press that moved is not a press (M4c spec §12.2)

    /// A no-`+MOVE` button: the middle one (long at the deadline) and the forward one (long on release, armed tick).
    func noMove() -> ButtonGestures {
        ButtonGestures(kinds: [.middle: [.tap, .long], .forward: [.tap, .long, .wheel], .panel: [.tap, .long, .move]],
                       longPress: 0.4, moveStep: 20)
    }

    @Test func driftOfEightPointsCancelsTheTapOfAButtonWithoutMove() {
        #expect(ButtonGestures.driftPoints == 8)
        for (dx, dy) in [(8.0, 0.0), (0.0, -8.0), (5.0, 5.0)] {
            var g = noMove()
            _ = g.press(.middle, at: 0)
            #expect(g.move(dx: dx, dy: dy / 2) == [])
            #expect(g.move(dx: 0, dy: dy / 2) == [])
            let cancelled = max(abs(dx), abs(dy)) >= 8
            #expect(g.release(.middle, at: 0.1) == (cancelled ? [] : [.init(button: .middle, kind: .tap, steps: 1)]),
                    "\(dx) \(dy)")
        }
    }

    @Test func driftBelowEightPointsKeepsThePress() {
        var g = noMove()
        _ = g.press(.middle, at: 0)
        _ = g.move(dx: 7.9, dy: -7.9)
        #expect(g.release(.middle, at: 0.1) == [.init(button: .middle, kind: .tap, steps: 1)])
        _ = g.press(.middle, at: 1)
        _ = g.move(dx: -7.9, dy: 7.9)
        #expect(g.nextDeadline == 1.4)
        #expect(g.tick(at: 1.4).fires == [.init(button: .middle, kind: .long, steps: 1)])
        _ = g.release(.middle, at: 2)
        _ = g.press(.forward, at: 3)
        _ = g.move(dx: 0, dy: 7.9)
        #expect(g.tick(at: 3.4).armed == [.forward])
        #expect(g.release(.forward, at: 3.5) == [.init(button: .forward, kind: .long, steps: 1)])
    }

    @Test func driftCancelsTheLongAtTheDeadline() {
        var g = noMove()
        _ = g.press(.middle, at: 0)
        _ = g.move(dx: 0, dy: 8)
        #expect(g.nextDeadline == nil)
        #expect(g.tick(at: 0.5).fires == [])
        #expect(g.release(.middle, at: 1) == [])
    }

    @Test func driftCancelsTheLongOnReleaseAndItsArmedTick() {
        var g = noMove()
        _ = g.press(.forward, at: 0)
        _ = g.move(dx: -8, dy: 0)
        #expect(g.nextDeadline == nil)
        #expect(g.tick(at: 0.5).armed == [])
        #expect(g.release(.forward, at: 1) == [])
        // After the tick: the drift still cancels the long press the release would give.
        _ = g.press(.forward, at: 2)
        #expect(g.tick(at: 2.4).armed == [.forward])
        _ = g.move(dx: 0, dy: -8)
        #expect(g.release(.forward, at: 3) == [])
    }

    @Test func driftCountsFromTheButtonsOwnPress() {
        var g = noMove()
        _ = g.press(.middle, at: 0)
        _ = g.move(dx: 0, dy: 7)
        _ = g.press(.forward, at: 0.1)
        _ = g.move(dx: 0, dy: 7)                                 // middle 14 pt, forward 7 pt
        #expect(g.release(.middle, at: 0.2) == [])
        #expect(g.release(.forward, at: 0.2) == [.init(button: .forward, kind: .tap, steps: 1)])
    }

    @Test func aButtonWithMoveKeepsItsFourPointThreshold() {
        var g = noMove()
        _ = g.press(.panel, at: 0)
        _ = g.move(dx: 0, dy: 4)
        #expect(g.release(.panel, at: 0.1) == [])
        _ = g.press(.panel, at: 1)
        #expect(g.move(dx: 0, dy: 5) == [])
        #expect(g.move(dx: 0, dy: 20) == [.init(button: .panel, kind: .move, steps: 1)])
        #expect(g.release(.panel, at: 1.1) == [])
    }

    // MARK: A wheel step cancels a held button without +WHEEL

    @Test func wheelCancelsAHeldButtonWithoutAWheelBinding() {
        let kinds: [MouseButton: Set<PressKind>] = [.back: [.tap, .long], .forward: [.tap, .long, .move]]
        // Tap.
        var g = ButtonGestures(kinds: kinds, longPress: 0.4, moveStep: 20)
        _ = g.press(.back, at: 0)
        let r = g.wheel(dy: 1, precise: false, momentum: false, at: 0.1)
        #expect(r.fires == [] && r.consumed == false)                  // the wheel still scrolls the photos
        #expect(g.release(.back, at: 0.2) == [])
        // Long at the deadline.
        _ = g.press(.back, at: 1)
        _ = g.wheel(dy: -3, precise: true, momentum: false, at: 1.1)
        #expect(g.nextDeadline == nil && g.tick(at: 1.5).fires == [])
        #expect(g.release(.back, at: 2) == [])
        // Long on release and its armed tick.
        _ = g.press(.forward, at: 3)
        _ = g.wheel(dy: 1, precise: false, momentum: false, at: 3.1)
        #expect(g.nextDeadline == nil && g.tick(at: 3.5).armed == [])
        #expect(g.release(.forward, at: 4) == [])
    }

    @Test func wheelMomentumOrNoVerticalDeltaLeavesAButtonWithoutAWheelBinding() {
        var g = ButtonGestures(kinds: [.back: [.tap, .long]], longPress: 0.4, moveStep: 20)
        _ = g.press(.back, at: 0)
        _ = g.wheel(dy: 5, precise: true, momentum: true, at: 0.1)     // the tail of a scroll begun before the press
        _ = g.wheel(dy: 0, precise: true, momentum: false, at: 0.15)   // a phase event with no delta
        #expect(g.release(.back, at: 0.2) == [.init(button: .back, kind: .tap, steps: 1)])
    }

    @Test func wheelGoesToTheWheelButtonAndCancelsTheOtherHeldOne() {
        var g = ButtonGestures(kinds: [.back: [.tap], .forward: [.tap, .wheel]], longPress: 0.4, moveStep: 20)
        _ = g.press(.forward, at: 0)
        #expect(g.press(.back, at: 0.05) == [.init(button: .back, kind: .tap, steps: 1)])   // tap-only: on the press
        _ = g.release(.back, at: 0.06)
        _ = g.press(.middle, at: 0.07)                                  // unbound: not held at all
        let r = g.wheel(dy: 1, precise: false, momentum: false, at: 0.1)
        #expect(r.fires == [.init(button: .forward, kind: .wheel, steps: 1)] && r.consumed)
    }

    /// A held button whose release was lost is dropped without firing: the plain wheel is free again.
    @Test func droppedPressFiresNothingAndFreesTheWheel() {
        var g = ButtonGestures(kinds: [.back: [.tap, .long, .wheel]], longPress: 0.4, moveStep: 20)
        _ = g.press(.back, at: 0)
        let held = g.wheel(dy: -1, precise: false, momentum: false, at: 0.1)
        #expect(held.consumed)
        g.drop(.back)
        let released = g.release(.back, at: 0.2)
        #expect(released == [])
        let plain = g.wheel(dy: -1, precise: false, momentum: false, at: 5)
        #expect(plain.fires.isEmpty && !plain.consumed)
        _ = g.press(.back, at: 6)
        g.drop(.back)
        let due = g.tick(at: 7)
        #expect(due.fires.isEmpty && due.armed.isEmpty && g.nextDeadline == nil)
    }
}

