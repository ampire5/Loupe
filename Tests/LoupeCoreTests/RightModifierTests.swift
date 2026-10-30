import Testing
@testable import LoupeCore

@Suite struct RightModifierTests {
    func make() -> ButtonGestures {
        ButtonGestures(kinds: [.right: [.wheel], .panel: [.tap, .wheel, .withRight, .withRightWheel],
            .gesture: [.tap, .withRight], .back: [.tap, .withRight]], longPress: 0.4, moveStep: 20)
    }
    @Test func rightDragRemainsAvailableUntilModifierInputIsUsed() {
        var g = make()
        _ = g.press(.right, at: 0)
        #expect(!g.rightZoomSuppressed)
        _ = g.move(dx: 0, dy: 20)
        #expect(g.rightDragged)
        #expect(!g.rightZoomSuppressed)
        #expect(g.wheel(dy: 1, precise: false, momentum: false, at: 0.1).consumed)
        #expect(g.rightZoomSuppressed)
        _ = g.release(.right, at: 0.2)
        _ = g.press(.right, at: 1)
        #expect(!g.rightZoomSuppressed)
    }

    @Test func standardPanelLongTogglesVibranceOnReleaseButWheelDoesNot() {
        let kinds = Dictionary(uniqueKeysWithValues: MouseButton.allCases.map { ($0, InputMap.standard.kinds(of: $0)) })
        var g = ButtonGestures(kinds: kinds, longPress: 0.4, moveStep: 20)
        #expect(g.press(.panel, at: 0).isEmpty)
        #expect(g.tick(at: 0.5).fires.isEmpty)
        #expect(g.release(.panel, at: 0.6) == [.init(button: .panel, kind: .long, steps: 1)])
        _ = g.press(.panel, at: 1)
        #expect(!g.wheel(dy: 1, precise: false, momentum: false, at: 1.5).fires.isEmpty)
        #expect(g.release(.panel, at: 1.6).isEmpty)
    }

    @Test func modifiedInputsRoundTrip() {
        for (name, button, kind) in [("MBTN_RIGHT+WHEEL", MouseButton.right, PressKind.wheel),
            ("MBTN_RIGHT+MX_PANEL+WHEEL", .panel, .withRightWheel),
            ("MBTN_RIGHT+MX_GESTURE", .gesture, .withRight),
            ("MBTN_RIGHT+MBTN_BACK", .back, .withRight)] {
            #expect(InputConf.trigger(name) == .mouse(button, kind))
            #expect(InputConf.text(of: .mouse(button, kind)) == name)
        }
    }
    @Test func modifiedWheelSuppressesBothTapsEvenWhenRightIsReleasedFirst() {
        var g = make()
        _ = g.press(.right, at: 0)
        #expect(g.press(.panel, at: 0.01).isEmpty)
        #expect(g.wheel(dy: 1, precise: false, momentum: false, at: 0.1).fires == [.init(button: .panel, kind: .withRightWheel, steps: 1)])
        #expect(g.rightZoomSuppressed)
        #expect(g.release(.right, at: 0.2).isEmpty)
        #expect(g.wheel(dy: -1, precise: false, momentum: false, at: 0.21).fires == [.init(button: .panel, kind: .withRightWheel, steps: -1)])
        #expect(g.release(.panel, at: 0.3).isEmpty)
    }
    @Test func panelChordWithoutWheelTogglesOnlyVibrance() {
        var g = make()
        _ = g.press(.right, at: 0)
        #expect(g.press(.panel, at: 0.01).isEmpty)
        #expect(g.release(.panel, at: 0.1) == [.init(button: .panel, kind: .withRight, steps: 1)])
        #expect(g.release(.right, at: 0.2).isEmpty)
    }
    @Test func rightWheelConsumesMomentumAndDoesNotLeakIntoPhotoNavigation() {
        var g = make()
        _ = g.press(.right, at: 0)
        let step = g.wheel(dy: -1, precise: false, momentum: false, at: 0.1)
        #expect(step.consumed && step.fires == [.init(button: .right, kind: .wheel, steps: -1)])
        _ = g.release(.right, at: 0.2)
        let coast = g.wheel(dy: -40, precise: true, momentum: true, at: 0.21)
        #expect(coast.consumed && coast.fires.isEmpty)
        #expect(!g.wheel(dy: 1, precise: false, momentum: false, at: 1).consumed)
    }
    @Test func panelMayBeHeldBeforeRightAndUsedChordDoesNotBecomeFolderScrolling() {
        var g = make()
        #expect(g.press(.panel, at: 0).isEmpty)
        #expect(g.press(.right, at: 0.01).isEmpty)
        #expect(g.wheel(dy: 1, precise: false, momentum: false, at: 0.1).fires == [.init(button: .panel, kind: .withRightWheel, steps: 1)])
        #expect(g.release(.panel, at: 0.2).isEmpty)
        let remaining = g.wheel(dy: 1, precise: false, momentum: false, at: 0.21)
        #expect(remaining.consumed && remaining.fires.isEmpty)
        #expect(g.release(.right, at: 0.3).isEmpty)
    }

    @Test func rightPressedAfterColourScrollingDoesNotStealTheWheel() {
        var g = make()
        _ = g.press(.panel, at: 0)
        #expect(g.wheel(dy: 1, precise: false, momentum: false, at: 0.1).fires == [.init(button: .panel, kind: .wheel, steps: 1)])
        _ = g.press(.right, at: 0.2)
        #expect(g.wheel(dy: 1, precise: false, momentum: false, at: 0.3).fires == [.init(button: .panel, kind: .wheel, steps: 1)])
        #expect(g.release(.panel, at: 0.4).isEmpty)
        #expect(g.release(.right, at: 0.5).isEmpty)
    }

    @Test func gestureDragDoesNotToggleSmartZoomAndModifiedClicksWaitForRelease() {
        var g = ButtonGestures(kinds: [.right: [.wheel], .gesture: [.tap, .withRight]],
            longPress: 0.4, moveStep: 20, tapOnRelease: [.gesture])
        #expect(g.press(.gesture, at: 0).isEmpty)
        _ = g.move(dx: 20, dy: 0)
        #expect(g.release(.gesture, at: 0.2).isEmpty)
        _ = g.press(.right, at: 1)
        #expect(g.press(.gesture, at: 1.1).isEmpty)
        #expect(g.release(.gesture, at: 1.2) == [.init(button: .gesture, kind: .withRight, steps: 1)])
        #expect(g.release(.right, at: 1.3).isEmpty)
    }

}
