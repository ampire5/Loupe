import Foundation
import Testing
@testable import LoupeCore

private final class Cube: Sendable {}

private let a = URL(fileURLWithPath: "/photos/a.jpg")
private let b = URL(fileURLWithPath: "/photos/b.jpg")

/// Another photo shows its cube at once (review focus 1: a frame never fades one photo's colour into another's).
@Test func otherPhotoNoFade() {
    let old = Cube(), new = Cube()
    let shown = ShownColor<Cube>.next(shown: nil, url: a, cube: old, now: 10, durationMs: 150)
    let next = ShownColor.next(shown: shown, url: b, cube: new, now: 20, durationMs: 150)
    #expect(next.url == b)
    #expect(next.cube === new)
    #expect(next.from == nil)
    #expect(next.mix(at: 20) == 1)
    #expect(!next.isRunning(at: 20))
    let none = ShownColor.next(shown: shown, url: b, cube: nil, now: 20, durationMs: 150)
    #expect(none.cube == nil)
    #expect(none.from == nil)
    #expect(none.mix(at: 20) == 1)
    #expect(!none.isRunning(at: 20))
}

@Test func firstPhotoNoFade() {
    let cube = Cube()
    let first = ShownColor.next(shown: nil, url: a, cube: cube, now: 5, durationMs: 150)
    #expect(first.cube === cube)
    #expect(first.mix(at: 5) == 1)
    #expect(!first.isRunning(at: 5))
}

/// The cube arrives after the photo: fades in from the identity over the configured time.
@Test func samePhotoFades() {
    let cube = Cube()
    let bare = ShownColor<Cube>.next(shown: nil, url: a, cube: nil, now: 10, durationMs: 200)
    let fading = ShownColor.next(shown: bare, url: a, cube: cube, now: 11, durationMs: 200)
    #expect(fading.cube === cube)
    #expect(fading.from == nil)
    #expect(fading.mix(at: 11) == 0)
    #expect(abs(fading.mix(at: 11.1) - 0.5) < 1e-9)
    #expect(fading.mix(at: 11.2) == 1)
    #expect(fading.mix(at: 12) == 1)
    #expect(fading.mix(at: 10) == 0)   // a clock a little behind never goes out of 0...1
    #expect(fading.isRunning(at: 11))
    #expect(fading.isRunning(at: 11.15))
    #expect(!fading.isRunning(at: 11.2))
}

@Test func zeroDurationInstant() {
    let old = Cube(), new = Cube()
    let shown = ShownColor.next(shown: nil, url: a, cube: old, now: 10, durationMs: 0)
    let next = ShownColor.next(shown: shown, url: a, cube: new, now: 11, durationMs: 0)
    #expect(next.cube === new)
    #expect(next.from == nil)
    #expect(next.mix(at: 11) == 1)
    #expect(!next.isRunning(at: 11))
}

@Test func sameCubeUnchanged() {
    let cube = Cube()
    let shown = ShownColor<Cube>.next(shown: nil, url: a, cube: nil, now: 10, durationMs: 150)
    let fading = ShownColor.next(shown: shown, url: a, cube: cube, now: 11, durationMs: 150)
    let again = ShownColor.next(shown: fading, url: a, cube: cube, now: 11.05, durationMs: 150)
    #expect(again == fading)   // the running fade is not restarted
    let none = ShownColor.next(shown: shown, url: a, cube: nil, now: 12, durationMs: 150)
    #expect(none == shown)     // no cube before and after: nothing to fade
}

/// A correction switched off on the photo on screen fades out to the identity: from the cube it had.
@Test func fadeOutToIdentity() {
    let cube = Cube()
    let shown = ShownColor<Cube>.next(shown: nil, url: a, cube: cube, now: 10, durationMs: 100)
    let out = ShownColor.next(shown: shown, url: a, cube: nil, now: 20, durationMs: 100)
    #expect(out.cube == nil)
    #expect(out.from === cube)
    #expect(out.mix(at: 20) == 0)
    #expect(abs(out.mix(at: 20.05) - 0.5) < 1e-9)
    #expect(!out.isRunning(at: 20.1))
}

/// Interrupted: restarts from the cube the fade was heading to (a small jump, accepted).
@Test func interruptedFadeRestartsFromTarget() {
    let first = Cube(), second = Cube()
    let shown = ShownColor<Cube>.next(shown: nil, url: a, cube: nil, now: 10, durationMs: 100)
    let fading = ShownColor.next(shown: shown, url: a, cube: first, now: 11, durationMs: 100)
    let changed = ShownColor.next(shown: fading, url: a, cube: second, now: 11.03, durationMs: 100)
    #expect(changed.cube === second)
    #expect(changed.from === first)
    #expect(changed.mix(at: 11.03) == 0)
}
