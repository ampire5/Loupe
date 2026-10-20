import Testing
@testable import LoupeCore

/// 60 Hz callbacks, as the display link delivers them.
private let frame = 1.0 / 60

/// Reference wrapper: `#expect` cannot call mutating methods on a local value.
private final class Driver {
    private var policy = IdlePolicy()
    func frame(changed: Bool, at time: Double) -> IdlePolicy.Action { policy.frame(changed: changed, at: time) }
}

@Test func aChangeDraws() {
    let p = Driver()
    #expect(p.frame(changed: true, at: 10) == .draw)
    #expect(p.frame(changed: true, at: 10 + frame) == .draw)
}

@Test func noChangeWithinGraceStaysAwake() {
    let p = Driver()
    #expect(p.frame(changed: true, at: 10) == .draw)
    var t = 10.0
    while t + frame < 10 + IdlePolicy.grace {
        t += frame
        #expect(p.frame(changed: false, at: t) == .skip)
    }
}

@Test func noChangeForTheGracePeriodPauses() {
    let p = Driver()
    #expect(p.frame(changed: true, at: 10) == .draw)
    #expect(p.frame(changed: false, at: 10 + IdlePolicy.grace - 0.001) == .skip)
    #expect(p.frame(changed: false, at: 10 + IdlePolicy.grace + 0.001) == .pause)
}

@Test func aChangeDuringGraceDrawsAndRestartsTheWindow() {
    let p = Driver()
    #expect(p.frame(changed: true, at: 10) == .draw)
    #expect(p.frame(changed: false, at: 10.2) == .skip)
    #expect(p.frame(changed: true, at: 10.25) == .draw)
    // 0.35 s after the first change but only 0.1 s after the second: still awake.
    #expect(p.frame(changed: false, at: 10.35) == .skip)
    #expect(p.frame(changed: false, at: 10.25 + IdlePolicy.grace + 0.001) == .pause)
}

@Test func aChangeAfterPausingDrawsAndRestartsTheGraceWindow() {
    let p = Driver()
    #expect(p.frame(changed: true, at: 10) == .draw)
    #expect(p.frame(changed: false, at: 11) == .pause)
    // The link resumes much later; its timestamps jump. The first frame with a change draws…
    #expect(p.frame(changed: true, at: 50) == .draw)
    // …and the grace window counts from there, not from the old change.
    #expect(p.frame(changed: false, at: 50 + frame) == .skip)
    #expect(p.frame(changed: false, at: 50 + IdlePolicy.grace + 0.001) == .pause)
}

@Test func aResumeWithNothingNewPausesAgainAtOnce() {
    // An `update` that raced with a callback that already drew it still queues a resume; the next
    // callback finds nothing new, long after the last change.
    let p = Driver()
    #expect(p.frame(changed: true, at: 10) == .draw)
    #expect(p.frame(changed: false, at: 20) == .pause)
    #expect(p.frame(changed: false, at: 20 + frame) == .pause)
}

@Test func nothingEverChangedPauses() {
    let p = Driver()
    #expect(p.frame(changed: false, at: 5) == .pause)
}

@Test func alternatingChangeAndNoChangeNeverPauses() {
    // A drag delivers an event every other callback when the display runs at twice the event rate.
    let p = Driver()
    var t = 10.0
    for i in 0..<600 {
        let changed = i % 2 == 0
        let action = p.frame(changed: changed, at: t)
        #expect(action == (changed ? .draw : .skip))
        t += frame
    }
}
