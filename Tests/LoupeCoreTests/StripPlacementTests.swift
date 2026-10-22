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
