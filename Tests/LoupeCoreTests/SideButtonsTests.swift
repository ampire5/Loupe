import Testing
@testable import LoupeCore

/// `mx-side-buttons` (M4c spec §12.1): which side buttons LogiMouse watches or takes, and when AppKit's events of a
/// side button are dropped because the mouse's own events already bring it.
@Suite struct SideButtonsTests {
    @Test func modesWatchOrTakeTheTwoSideButtons() {
        #expect(SideButtonsMode.watch.watchedCIDs == [0x53, 0x56] && SideButtonsMode.watch.divertedCIDs.isEmpty)
        #expect(SideButtonsMode.take.watchedCIDs.isEmpty && SideButtonsMode.take.divertedCIDs == [0x53, 0x56])
        #expect(SideButtonsMode.system.watchedCIDs.isEmpty && SideButtonsMode.system.divertedCIDs.isEmpty)
    }

    @Test func sideButtonCIDsAndTheButtonOfACID() {
        #expect(MouseButton.back.sideCID == 0x53 && MouseButton.forward.sideCID == 0x56)
        for b in [MouseButton.middle, .right, .panel, .gesture, .shift] { #expect(b.sideCID == nil, "\(b)") }
        #expect(MouseButton(cid: 0x53) == .back && MouseButton(cid: 0x56) == .forward)
        #expect(MouseButton(cid: 0x01A0) == .panel && MouseButton(cid: 0x00C3) == .gesture && MouseButton(cid: 0x00C4) == .shift)
        #expect(MouseButton(cid: 0x52) == nil)
    }

    @Test func appKitEventOfAHeardButtonIsDropped() {
        let heard: Set<UInt16> = [0x53, 0x56]
        #expect(AppKitButtonFilter.drops(.back, heard: heard))
        #expect(AppKitButtonFilter.drops(.forward, heard: heard))
        #expect(!AppKitButtonFilter.drops(.middle, heard: heard))
        #expect(!AppKitButtonFilter.drops(.back, heard: []))
        #expect(!AppKitButtonFilter.drops(.back, heard: [0x56]))
        #expect(AppKitButtonFilter.drops(.forward, heard: [0x56]))
    }

    @Test func filterPassesPressesWhileNothingIsHeard() {
        var f = AppKitButtonFilter()
        #expect(f.down(.back, heard: [], at: 0) == true)
        #expect(f.up(.back, heard: []) == true)
        #expect(f.down(.middle, heard: [0x53, 0x56], at: 0) == true)
        #expect(f.up(.middle, heard: [0x53, 0x56]) == true)
    }

    @Test func filterDropsBothEventsOfAHeardButton() {
        var f = AppKitButtonFilter()
        #expect(f.down(.forward, heard: [0x56], at: 0) == false)
        #expect(f.up(.forward, heard: [0x56]) == false)
        // Heard at the press, not any more at the release (the app went inactive, the mouse left): still dropped, the
        // press never reached the recogniser.
        #expect(f.down(.back, heard: [0x53], at: 0) == false)
        #expect(f.up(.back, heard: []) == false)
    }

    @Test func releaseOfAPassedPressPassesEvenOnceTheButtonIsHeard() {
        var f = AppKitButtonFilter()
        #expect(f.down(.back, heard: [], at: 0) == true)          // before the mouse confirmed the watch
        #expect(f.up(.back, heard: [0x53]) == true)         // the recogniser holds that press: it gets its release
        #expect(f.up(.back, heard: [0x53]) == false)        // a second release is the mouse's again
    }

    @Test func resetForgetsPassedPresses() {
        var f = AppKitButtonFilter()
        #expect(f.down(.back, heard: [], at: 0) == true)
        f.reset()
        #expect(f.up(.back, heard: [0x53]) == false)
    }

    // MARK: Presses from LogiMouse's events (M4c spec §12.1)

    @Test func mousePressRightAfterAPassedAppKitPressIsADuplicate() {
        var f = AppKitButtonFilter()
        #expect(AppKitButtonFilter.duplicateWindow == 0.1)
        #expect(f.down(.back, heard: [], at: 10) == true)        // before the watch was confirmed: AppKit's tap
        #expect(f.up(.back, heard: []) == true)
        #expect(f.mousePress(.back, at: 10.05, watched: true, overOwnWindow: true) == false)
        #expect(f.mouseRelease(.back) == false)                     // its release goes with it
        #expect(f.mousePress(.back, at: 10.15, watched: true, overOwnWindow: true) == true)   // a new press
        #expect(f.mouseRelease(.back) == true)
    }

    @Test func mousePressLongAfterTheAppKitPressIsKept() {
        var f = AppKitButtonFilter()
        #expect(f.down(.forward, heard: [], at: 10) == true)
        #expect(f.up(.forward, heard: []) == true)
        #expect(f.mousePress(.forward, at: 10.15, watched: true, overOwnWindow: true) == true)
        #expect(f.mouseRelease(.forward) == true)
    }

    @Test func mousePressWhileTheAppKitPressIsHeldIsADuplicate() {
        var f = AppKitButtonFilter()
        #expect(f.down(.back, heard: [], at: 10) == true)
        #expect(f.mousePress(.back, at: 10.5, watched: true, overOwnWindow: true) == false)   // a long hold
        #expect(f.up(.back, heard: [0x53]) == true)       // AppKit's release ends AppKit's press
        #expect(f.mouseRelease(.back) == false)
    }

    @Test func aDroppedAppKitPressIsNoReasonToDropTheMousePress() {
        var f = AppKitButtonFilter()
        #expect(f.down(.back, heard: [0x53], at: 10) == false)
        #expect(f.mousePress(.back, at: 10.01, watched: true, overOwnWindow: true) == true)
        #expect(f.up(.back, heard: [0x53]) == false)
        #expect(f.mouseRelease(.back) == true)
    }

    @Test func watchedPressCountsOnlyOverLoupesWindows() {
        var f = AppKitButtonFilter()
        #expect(f.mousePress(.back, at: 1, watched: true, overOwnWindow: false) == false)
        #expect(f.mouseRelease(.back) == false)
        // Diverted (`take`): the system never gets it, wherever the pointer is.
        #expect(f.mousePress(.back, at: 2, watched: false, overOwnWindow: false) == true)
        #expect(f.mouseRelease(.back) == true)
    }

    @Test func divertedMXButtonsAlwaysPass() {
        var f = AppKitButtonFilter()
        for b in [MouseButton.panel, .gesture, .shift] {
            #expect(f.mousePress(b, at: 1, watched: false, overOwnWindow: false) == true, "\(b)")
            #expect(f.mouseRelease(b) == true, "\(b)")
        }
    }

    @Test func resetForgetsDroppedMousePresses() {
        var f = AppKitButtonFilter()
        #expect(f.mousePress(.back, at: 1, watched: true, overOwnWindow: false) == false)
        f.reset()
        #expect(f.mouseRelease(.back) == true)
    }

    /// A passed AppKit press whose button is up in fact (`NSEvent.pressedMouseButtons`: its release went to a hidden
    /// tab's view, or another app's window) is reported once and forgotten; one still down, a dropped one and a
    /// LogiMouse press are not.
    @Test func lostReleasesAreTheAppKitPressesNoLongerDown() {
        var f = AppKitButtonFilter()
        #expect(f.down(.back, heard: [], at: 0) == true)
        #expect(f.down(.middle, heard: [], at: 0) == true)
        #expect(f.down(.forward, heard: [0x56], at: 0) == false)     // LogiMouse brings it: not the recogniser's
        let middleDown = 1 << 2
        let none = f.lostReleases(pressedButtons: middleDown | 1 << 3)
        let back = f.lostReleases(pressedButtons: middleDown)
        let middle = f.lostReleases(pressedButtons: 0)
        let again = f.lostReleases(pressedButtons: 0)
        #expect(none == [] && back == [.back] && middle == [.middle] && again == [])
        #expect(f.up(.back, heard: [0x53]) == false)                 // forgotten: a late release is the mouse's again
        #expect(f.mousePress(.panel, at: 1, watched: false, overOwnWindow: true) == true)
        let logi = f.lostReleases(pressedButtons: 0)
        #expect(logi == [])
    }

    /// `hasHeld` is true only while a passed AppKit press is in flight: a dropped one, a LogiMouse press and a released
    /// or forgotten one do not count, so the caller skips reading the live button state when nothing is held.
    @Test func hasHeldIsTrueOnlyForPassedAppKitPresses() {
        var f = AppKitButtonFilter()
        #expect(!f.hasHeld)
        #expect(f.down(.forward, heard: [0x56], at: 0) == false)
        #expect(!f.hasHeld)
        #expect(f.mousePress(.panel, at: 1, watched: false, overOwnWindow: true) == true)
        #expect(!f.hasHeld)
        #expect(f.down(.back, heard: [], at: 2) == true)
        #expect(f.hasHeld)
        _ = f.up(.back, heard: [])
        #expect(!f.hasHeld)
        #expect(f.down(.middle, heard: [], at: 3) == true)
        _ = f.lostReleases(pressedButtons: 0)
        #expect(!f.hasHeld)
        #expect(f.down(.middle, heard: [], at: 4) == true)
        f.reset()
        #expect(!f.hasHeld)
    }
}
