import Testing
@testable import LoupeCore

@Suite struct InfoPanelHoldTests {
    /// `#expect` cannot take a mutating call.
    private func holds(_ hold: inout InfoPanelHold, ready: Bool, now: Double) -> Bool { hold.holds(ready: ready, now: now) }

    @Test func nothingHeldBeforeAPhotoChange() {
        var hold = InfoPanelHold()
        #expect(!holds(&hold, ready: false, now: 10))
        #expect(hold.deadline == nil)
    }

    @Test func holdsUntilTheNewPhotoIsReady() {
        var hold = InfoPanelHold()
        hold.photoChanged(at: 10)
        #expect(holds(&hold, ready: false, now: 10.05))
        #expect(hold.deadline == 10 + InfoPanelHold.limit)
        #expect(!holds(&hold, ready: true, now: 10.06))
        // Over: later updates (the diagnostics timer) show at once.
        #expect(!holds(&hold, ready: false, now: 10.07))
        #expect(hold.deadline == nil)
    }

    @Test func showsWhatIsKnownAtTheLimit() {
        var hold = InfoPanelHold()
        hold.photoChanged(at: 10)
        #expect(holds(&hold, ready: false, now: 10 + InfoPanelHold.limit - 0.001))
        #expect(!holds(&hold, ready: false, now: 10 + InfoPanelHold.limit))
    }

    @Test func fastStepsDoNotPushTheLimitBack() {
        // A held arrow key: a new photo every 0.1 s, none ready in time. The panel still catches up every `limit`.
        var hold = InfoPanelHold()
        hold.photoChanged(at: 10)
        hold.photoChanged(at: 10.1)
        hold.photoChanged(at: 10.2)
        #expect(hold.deadline == 10 + InfoPanelHold.limit)
        #expect(!holds(&hold, ready: false, now: 10 + InfoPanelHold.limit))
        // The next step starts a new hold.
        hold.photoChanged(at: 10.3)
        #expect(hold.deadline == 10.3 + InfoPanelHold.limit)
    }

    @Test func cancelEndsAHold() {
        var hold = InfoPanelHold()
        hold.photoChanged(at: 10)
        hold.cancel()
        #expect(!holds(&hold, ready: false, now: 10.01))
    }
}
