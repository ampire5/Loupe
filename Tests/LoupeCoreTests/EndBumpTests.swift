import Testing
@testable import LoupeCore

@Test func endBumpOncePerPush() {
    var b = EndBump()
    // Steps that move never bump.
    #expect(b.stepped(moved: true, direction: 1, fresh: true) == false)
    // The first blocked step bumps; auto-repeats and further notches into the same end do not.
    #expect(b.stepped(moved: false, direction: 1, fresh: true) == true)
    #expect(b.stepped(moved: false, direction: 1, fresh: false) == false)
    #expect(b.stepped(moved: false, direction: 1, fresh: false) == false)
    // A fresh press into the same end bumps again.
    #expect(b.stepped(moved: false, direction: 1, fresh: true) == true)
    #expect(b.stepped(moved: false, direction: 1, fresh: false) == false)
    // A step that moved re-arms it: the next blocked step bumps even if it is a repeat.
    #expect(b.stepped(moved: true, direction: -1, fresh: true) == false)
    #expect(b.stepped(moved: false, direction: 1, fresh: false) == true)
}

@Test func endBumpOtherDirection() {
    // A one-photo folder: both ends at once; the other direction is another end and bumps.
    var b = EndBump()
    #expect(b.stepped(moved: false, direction: -1, fresh: true) == true)
    #expect(b.stepped(moved: false, direction: -1, fresh: false) == false)
    #expect(b.stepped(moved: false, direction: 1, fresh: false) == true)
    #expect(b.stepped(moved: false, direction: 1, fresh: false) == false)
    // A new one is armed: its first blocked step bumps, a repeat or not.
    var r = EndBump()
    #expect(r.stepped(moved: false, direction: 1, fresh: false) == true)
}

@Test func endBumpWheelFreshness() {
    #expect(EndBump.isFreshNotch(at: 10, previous: nil))
    #expect(!EndBump.isFreshNotch(at: 10.1, previous: 10))
    #expect(EndBump.isFreshNotch(at: 10 + EndBump.wheelPause, previous: 10))
}
