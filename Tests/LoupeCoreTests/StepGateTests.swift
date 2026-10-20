import Testing
@testable import LoupeCore

@Test func firstNotchPasses() {
    var g = StepGate()
    let first = g.request(now: 0)
    #expect(first)
}

@Test func secondNotchSameFrameDropped() {
    var g = StepGate()
    let first = g.request(now: 0), second = g.request(now: 0), third = g.request(now: 0)
    #expect(first)
    #expect(!second)
    #expect(!third)
}

@Test func notchAfterFramePasses() {
    var g = StepGate()
    _ = g.request(now: 0)
    let dropped = g.request(now: 0)
    g.frame()
    let next = g.request(now: 0)
    #expect(!dropped)
    #expect(next)
}

@Test func droppedNotchesAreNotQueued() {
    var g = StepGate()
    _ = g.request(now: 0)
    _ = g.request(now: 0)
    g.frame()
    // Only a fresh notch steps; the dropped one left nothing behind.
    let fresh = g.request(now: 0), extra = g.request(now: 0)
    #expect(fresh)
    #expect(!extra)
}

@Test func isActiveUntilAFramePasses() {
    var g = StepGate()
    #expect(!g.isActive)
    _ = g.request(now: 0)
    #expect(g.isActive)
    g.frame()
    #expect(!g.isActive)
}

// MARK: Waiting for the photo (`wheel-step`)

/// A gate that stepped at `t` = 10 s waiting for `wait`, one frame later.
private func stepped(_ wait: StepWait) -> StepGate {
    var g = StepGate()
    _ = g.request(now: 10)
    g.stepped(waitFor: wait, now: 10)
    g.frame()
    return g
}

/// `any` waits for nothing: one step per display frame, as before `wheel-step`.
@Test func anyKeepsThePerFrameRule() {
    var g = stepped(.any)
    #expect(g.pending == nil)
    let next = g.request(now: 10.01), same = g.request(now: 10.01)
    #expect(next && !same)
    g.stepped(waitFor: .any, now: 10.01)
    g.frame()
    do { let stepped = g.request(now: 10.02); #expect(stepped) }
}

@Test func thumbWaitOpensOnTheThumbnail() {
    var g = stepped(.thumb)
    #expect(g.pending?.wait == .thumb)
    do { let stepped = g.request(now: 10.1); #expect(!stepped) }
    g.photoShown(nil)   // still the previous photo
    do { let stepped = g.request(now: 10.2); #expect(!stepped) }
    g.photoShown(.thumb)
    #expect(g.pending == nil)
    do { let stepped = g.request(now: 10.3); #expect(stepped) }
}

@Test func coarseWaitIgnoresTheThumbnail() {
    for opener in [ShownQuality.coarse, .sharp] {
        var g = stepped(.coarse)
        g.photoShown(.thumb)
        do { let stepped = g.request(now: 10.1); #expect(!stepped) }
        g.photoShown(opener)
        do { let stepped = g.request(now: 10.2); #expect(stepped, "\(opener)") }
    }
}

@Test func sharpWaitOpensOnlyWhenSharp() {
    var g = stepped(.sharp)
    g.photoShown(.thumb)
    do { let stepped = g.request(now: 10.1); #expect(!stepped) }
    g.photoShown(.coarse)
    do { let stepped = g.request(now: 10.2); #expect(!stepped) }
    g.photoShown(.sharp)
    do { let stepped = g.request(now: 10.3); #expect(stepped) }
}

/// A photo that never arrives holds the wheel one second at most.
@Test func waitLimitOpensTheGate() {
    #expect(StepGate.waitLimit == 1.0)
    var g = stepped(.sharp)
    do { let stepped = g.request(now: 10.999); #expect(!stepped) }
    do { let stepped = g.request(now: 11.0); #expect(stepped) }
    #expect(g.pending == nil)
}

/// A photo shown at once (a cached neighbour) opened the gate before the next notch came: that notch steps.
@Test func photoShownBeforeTheNextNotchCounts() {
    var g = StepGate()
    _ = g.request(now: 10)
    g.stepped(waitFor: .sharp, now: 10)
    g.photoShown(.sharp)
    g.frame()
    do { let stepped = g.request(now: 10.01); #expect(stepped) }
}

/// Notches dropped while waiting leave nothing behind: once the gate opens, each new notch steps once.
@Test func droppedWaitingNotchesAreNotQueued() {
    var g = stepped(.coarse)
    for t in [10.1, 10.2, 10.3] { let stepped = g.request(now: t); #expect(!stepped) }
    g.photoShown(.coarse)
    let first = g.request(now: 10.4), extra = g.request(now: 10.4)
    #expect(first && !extra)
    g.stepped(waitFor: .coarse, now: 10.4)
    g.frame()
    do { let stepped = g.request(now: 10.5); #expect(!stepped) }   // waits for the new photo
}

// MARK: Keys (`key-step`): no per-frame limit, the same wait

/// The keyboard's gate: a held key's auto-repeat is not limited to a frame (that is the wheel's rule), only
/// by the wait.
private func keyGate(stepped wait: StepWait? = nil) -> StepGate {
    var g = StepGate(oncePerFrame: false)
    if let wait {
        _ = g.request(now: 10)
        g.stepped(waitFor: wait, now: 10)
    }
    return g
}

/// With `any` every press and repeat steps, frame or no frame: key navigation was never limited before `key-step`.
@Test func keyGateWithoutWaitNeverLimits() {
    var g = keyGate()
    for t in [10.0, 10.0, 10.001, 10.002] {
        let ok = g.request(now: t)
        #expect(ok)
        g.stepped(waitFor: .any, now: t)
    }
    #expect(!g.isActive)
}

/// A fresh press and an auto-repeat are both held back until the photo is shown, and not remembered.
@Test func keyGateWaitsForFreshPressesAndRepeatsAlike() {
    var g = keyGate(stepped: .thumb)
    for t in [10.02, 10.04, 10.3] { let ok = g.request(now: t); #expect(!ok, "\(t)") }
    g.photoShown(.thumb)
    let first = g.request(now: 10.4)
    #expect(first)
    g.stepped(waitFor: .thumb, now: 10.4)
    let again = g.request(now: 10.41)   // waits for the new photo, nothing queued from the dropped ones
    #expect(!again)
}

/// A neighbour shown at once (prefetched) never holds a key: a normal tapping speed steps every time.
@Test func keyGateOpenedBeforeTheNextPress() {
    var g = keyGate(stepped: .sharp)
    g.photoShown(.sharp)
    let ok = g.request(now: 10.05)
    #expect(ok)
}

@Test func keyGateWaitLimit() {
    var g = keyGate(stepped: .coarse)
    do { let ok = g.request(now: 10.999); #expect(!ok) }
    do { let ok = g.request(now: 11.0); #expect(ok) }
    #expect(g.pending == nil)
}

/// The wheel's gate and the keys' gate are separate values: one waiting does not hold the other.
@Test func wheelAndKeyGatesAreIndependent() {
    var wheel = StepGate(), keys = StepGate(oncePerFrame: false)
    _ = wheel.request(now: 10)
    wheel.stepped(waitFor: .sharp, now: 10)
    wheel.frame()
    do { let ok = keys.request(now: 10.1); #expect(ok) }
    keys.stepped(waitFor: .sharp, now: 10.1)
    do { let ok = wheel.request(now: 10.2); #expect(!ok) }
    wheel.photoShown(.sharp)
    do { let ok = wheel.request(now: 10.3); #expect(ok) }
    do { let ok = keys.request(now: 10.3); #expect(!ok) }   // still waiting for its own photo
}

/// `isWaiting` is the cheap test before the screen's quality is read: set by a step that waits, cleared by the photo
/// showing, never set for `any`.
@Test func isWaitingFollowsThePendingWait() {
    var g = StepGate(oncePerFrame: false)
    #expect(!g.isWaiting)
    _ = g.request(now: 0)
    g.stepped(waitFor: .any, now: 0)
    #expect(!g.isWaiting)
    g.stepped(waitFor: .sharp, now: 0)
    #expect(g.isWaiting)
    g.photoShown(.coarse)
    #expect(g.isWaiting)
    g.photoShown(.sharp)
    #expect(!g.isWaiting)
}

/// A gate cancelled by the view's teardown holds nothing back: no wait, no step already made in the frame.
@Test func cancelClearsTheWaitAndTheFrame() {
    var g = StepGate()
    _ = g.request(now: 10)
    g.stepped(waitFor: .sharp, now: 10)
    g.cancel()
    #expect(!g.isWaiting)
    #expect(!g.isActive)
    let ok = g.request(now: 10.1)
    #expect(ok)
}
