import Testing
@testable import LoupeCore

private func input(
    _ mode: StripWindowMode, fullScreen: Bool = false, hidden: Bool = false, pinned: Bool = false,
    over: Bool = false, nearBottom: Bool = false, edge: Bool = false
) -> StripPlacement.Input {
    StripPlacement.Input(
        mode: mode, fullScreen: fullScreen, hidden: hidden, pinned: pinned,
        pointerOverStrip: over, pointerNearBottom: nearBottom, revealedByEdge: edge)
}

@Test func besideShownReservesSpace() {
    for over in [false, true] {
        let p = StripPlacement(input(.beside, pinned: true, over: over))
        #expect(p.visible)
        #expect(p.reservesSpace)
        #expect(p.placeButton)
        #expect(p.pin == .hide)
        #expect(p.showsCapsule == over)
        #expect(!p.showsReveal)
    }
}

@Test func besideHiddenShowsRevealNearBottom() {
    for near in [false, true] {
        let p = StripPlacement(input(.beside, hidden: true, over: true, nearBottom: near))
        #expect(!p.visible)
        #expect(!p.reservesSpace)
        #expect(!p.placeButton)
        #expect(p.pin == nil)
        #expect(!p.showsCapsule)
        #expect(p.showsReveal == near)
    }
}

@Test func overFollowsTheEdgeOrPin() {
    for pinned in [false, true] {
        for edge in [false, true] {
            let p = StripPlacement(input(.over, pinned: pinned, over: true, nearBottom: true, edge: edge))
            #expect(p.visible == (pinned || edge))
            #expect(!p.reservesSpace)
            #expect(p.placeButton)
            #expect(p.pin == .pin(on: pinned))
            #expect(!p.showsReveal)
            #expect(p.showsCapsule == p.visible)
        }
    }
}

@Test func hiddenModeShowsNothing() {
    let p = StripPlacement(input(.hidden, pinned: true, over: true, nearBottom: true, edge: true))
    #expect(!p.visible)
    #expect(!p.reservesSpace)
    #expect(!p.placeButton)
    #expect(p.pin == nil)
    #expect(!p.showsCapsule)
    #expect(!p.showsReveal)
}

@Test func fullScreenIsAlwaysOver() {
    for mode in [StripWindowMode.over, .beside, .hidden] {
        for pinned in [false, true] {
            for edge in [false, true] {
                let p = StripPlacement(input(mode, fullScreen: true, pinned: pinned, nearBottom: true, edge: edge))
                #expect(p.visible == (pinned || edge))
                #expect(!p.reservesSpace)
                #expect(!p.placeButton)
                #expect(p.pin == .pin(on: pinned))
                #expect(!p.showsReveal)
            }
        }
    }
}

@Test func hiddenAndPinnedStayApart() {
    let beside = StripPlacement(input(.beside, hidden: true, pinned: false))
    #expect(!beside.visible)
    // The same flags in over: `hidden` does not hide it, only `pinned` and the edge decide.
    #expect(!StripPlacement(input(.over, hidden: true, pinned: false)).visible)
    #expect(StripPlacement(input(.over, hidden: true, pinned: false, edge: true)).visible)
    #expect(StripPlacement(input(.over, hidden: true, pinned: true)).visible)
    #expect(!StripPlacement(input(.over, hidden: false, pinned: false)).visible)
    // And `pinned` does not show a hidden beside strip.
    #expect(!StripPlacement(input(.beside, hidden: true, pinned: true)).visible)
}

@Test func toggledModes() {
    #expect(StripPlacement.toggledMode(.beside, fullScreen: false) == .over)
    #expect(StripPlacement.toggledMode(.over, fullScreen: false) == .beside)
    #expect(StripPlacement.toggledMode(.hidden, fullScreen: false) == .beside)
    for mode in [StripWindowMode.over, .beside, .hidden] {
        #expect(StripPlacement.toggledMode(mode, fullScreen: true) == nil)
    }
}

@Test func placementInvariantsHoldForEveryCombination() {
    let bools = [false, true]
    for mode in [StripWindowMode.over, .beside, .hidden] {
        for fullScreen in bools { for hidden in bools { for pinned in bools {
            for over in bools { for near in bools { for edge in bools {
                let p = StripPlacement(input(
                    mode, fullScreen: fullScreen, hidden: hidden, pinned: pinned,
                    over: over, nearBottom: near, edge: edge))
                #expect(!p.reservesSpace || p.visible)
                #expect(!(fullScreen && p.showsReveal))
                #expect(!(fullScreen && p.reservesSpace))
                #expect(!p.showsCapsule || over)
                #expect(!p.showsCapsule || (p.visible && p.pin != nil))
                #expect(!p.showsReveal || (!p.visible && near))
                #expect(!(p.visible && p.showsReveal))
                if !fullScreen && mode == .hidden {
                    #expect(!p.visible && !p.placeButton && p.pin == nil && !p.showsReveal)
                }
            } } }
        } } }
    }
}

/// T flips the beside strip's `hidden`, a floating strip's `pinned`, and nothing in a window's hidden mode.
@Test func tFlipsOneFlagPerMode() {
    #expect(StripPlacement.flag(.beside, fullScreen: false) == .hidden)
    #expect(StripPlacement.flag(.over, fullScreen: false) == .pinned)
    #expect(StripPlacement.flag(.hidden, fullScreen: false) == nil)
    for mode in [StripWindowMode.over, .beside, .hidden] {
        #expect(StripPlacement.flag(mode, fullScreen: true) == .pinned)
    }
}

/// The menu checkmark reads only the current mode's flag.
@Test func holdsReadsTheModesFlagOnly() {
    #expect(StripPlacement.holds(.beside, fullScreen: false, hidden: false, pinned: false))
    #expect(!StripPlacement.holds(.beside, fullScreen: false, hidden: true, pinned: true))
    #expect(StripPlacement.holds(.over, fullScreen: false, hidden: true, pinned: true))
    #expect(!StripPlacement.holds(.over, fullScreen: false, hidden: false, pinned: false))
    #expect(StripPlacement.holds(.beside, fullScreen: true, hidden: true, pinned: true))
    #expect(!StripPlacement.holds(.beside, fullScreen: true, hidden: false, pinned: false))
    #expect(!StripPlacement.holds(.hidden, fullScreen: false, hidden: false, pinned: true))
}

@Test func capsuleToolsBeside() {
    let tools = StripPlacement(input(.beside, over: true)).tools(mode: .beside)
    #expect(tools.map(\.symbol) == ["rectangle.bottomthird.inset.filled", "chevron.down"])
    #expect(tools.map(\.help) == ["Let the strip float over the photo (⇧T)", "Hide the strip (T)"])
    #expect(tools.map(\.isOn) == [true, false])
    #expect(tools.map(\.action) == [.place, .pin])
}

@Test func capsuleToolsOver() {
    let loose = StripPlacement(input(.over, over: true, edge: true)).tools(mode: .over)
    #expect(loose.map(\.symbol) == ["rectangle.on.rectangle", "pin"])
    #expect(loose.map(\.help) == ["Keep the strip beside the photo (⇧T)", "Pin the strip (T)"])
    #expect(loose.map(\.isOn) == [false, false])
    let pinned = StripPlacement(input(.over, pinned: true, over: true)).tools(mode: .over)
    #expect(pinned.map(\.symbol) == ["rectangle.on.rectangle", "pin"])
    #expect(pinned.map(\.help) == ["Keep the strip beside the photo (⇧T)", "Unpin the strip (T)"])
    #expect(pinned.map(\.isOn) == [false, true])
}

/// Full screen: only T's pin, whatever the window's mode.
@Test func capsuleToolsFullScreenHaveNoPlaceButton() {
    for mode in [StripWindowMode.over, .beside, .hidden] {
        let tools = StripPlacement(input(mode, fullScreen: true, pinned: true, over: true)).tools(mode: mode)
        #expect(tools.map(\.symbol) == ["pin"])
        #expect(tools.map(\.action) == [.pin])
    }
}

@Test func noToolsWithoutACapsule() {
    #expect(StripPlacement(input(.hidden, over: true)).tools(mode: .hidden).isEmpty)
    #expect(StripPlacement(input(.beside, hidden: true, over: true)).tools(mode: .beside).isEmpty)
}

@Test func stripTexts() {
    #expect(StripPlacement.revealHelp == "Show the strip (T)")
    #expect(StripPlacement.fullScreenToast == "In full screen the strip is always over the photo")
}

@Test func leavingHiddenClearsTheBesideFlag() {
    #expect(StripPlacement.clearsBarHidden(from: .hidden, to: .beside))
    #expect(!StripPlacement.clearsBarHidden(from: .beside, to: .over))
    #expect(!StripPlacement.clearsBarHidden(from: .over, to: .beside))
    #expect(StripPlacement.flag(.hidden, fullScreen: false) == nil)
}
