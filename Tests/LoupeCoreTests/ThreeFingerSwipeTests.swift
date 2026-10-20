import Testing
import CoreGraphics
@testable import LoupeCore

/// Three fingers side by side, centred on (x, y), in normalised trackpad coordinates.
private func three(_ x: Double, _ y: Double = 0.5) -> [CGPoint] {
    [CGPoint(x: x - 0.05, y: y), CGPoint(x: x, y: y + 0.02), CGPoint(x: x + 0.05, y: y)]
}

@Test func leftSwipeIsNextOnce() {
    var s = ThreeFingerSwipe()
    #expect(s.update(touches: three(0.6)) == nil)    // the third finger lands: baseline
    #expect(s.update(touches: three(0.55)) == nil)   // 0.05 < 0.08
    #expect(s.update(touches: three(0.50)) == .next) // 0.10 to the left
}

@Test func rightSwipeIsPrevious() {
    var s = ThreeFingerSwipe()
    _ = s.update(touches: three(0.3))
    #expect(s.update(touches: three(0.45)) == .previous)
}

@Test func mostlyVerticalMovementDoesNotFire() {
    var s = ThreeFingerSwipe()
    _ = s.update(touches: three(0.5, 0.3))
    #expect(s.update(touches: three(0.42, 0.42)) == nil)  // dx 0.08, dy 0.12: neither way 2:1
    #expect(s.update(touches: three(0.4, 0.45)) == nil)   // dx 0.1, dy 0.15: still not 2:1
    #expect(s.update(touches: three(0.3, 0.35)) == .next) // dx 0.2 vs dy 0.05
}

@Test func belowThresholdDoesNotFire() {
    var s = ThreeFingerSwipe()
    _ = s.update(touches: three(0.5))
    #expect(s.update(touches: three(0.43)) == nil)
    #expect(s.update(touches: three(0.421)) == nil)   // 0.079
}

@Test func firesOnceUntilAllFingersAreLifted() {
    var s = ThreeFingerSwipe()
    _ = s.update(touches: three(0.8))
    #expect(s.update(touches: three(0.6)) == .next)
    #expect(s.update(touches: three(0.3)) == nil)     // keeps moving: latched
    #expect(s.update(touches: three(0.8)) == nil)     // and back: still latched
    #expect(s.update(touches: Array(three(0.8).prefix(2))) == nil)   // one lifted, not all
    #expect(s.update(touches: three(0.1)) == nil)     // three again, but never fully lifted
    #expect(s.update(touches: []) == nil)             // all lifted: re-armed
    _ = s.update(touches: three(0.3))
    #expect(s.update(touches: three(0.5)) == .previous)
}

@Test func twoOrFourFingersNeverFire() {
    var s = ThreeFingerSwipe()
    let a = [CGPoint(x: 0.7, y: 0.5), CGPoint(x: 0.75, y: 0.5)]
    let b = [CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.15, y: 0.5)]
    #expect(s.update(touches: a) == nil)
    #expect(s.update(touches: b) == nil)
    let c = three(0.8) + [CGPoint(x: 0.9, y: 0.5)]
    let d = three(0.2) + [CGPoint(x: 0.3, y: 0.5)]
    #expect(s.update(touches: c) == nil)
    #expect(s.update(touches: d) == nil)
    #expect(s.update(touches: [CGPoint(x: 0.5, y: 0.5)]) == nil)
}

@Test func fingerCountChangeResetsBaseline() {
    var s = ThreeFingerSwipe()
    _ = s.update(touches: three(0.9))
    #expect(s.update(touches: three(0.85) + [CGPoint(x: 0.5, y: 0.5)]) == nil)  // a fourth lands
    // Back to three at 0.3: the old baseline (0.9) must not count, this is the new one.
    #expect(s.update(touches: three(0.3)) == nil)
    #expect(s.update(touches: three(0.25)) == nil)    // only 0.05 since the new baseline
    #expect(s.update(touches: three(0.18)) == .next)
}

@Test func liftingOneFingerBeforeFiringResetsBaseline() {
    var s = ThreeFingerSwipe()
    _ = s.update(touches: three(0.9))
    #expect(s.update(touches: Array(three(0.5).prefix(2))) == nil)
    #expect(s.update(touches: three(0.5)) == nil)     // new baseline, not a 0.4 jump
    #expect(s.update(touches: three(0.45)) == nil)
}

@Test func resetClearsLatchAndBaseline() {
    var s = ThreeFingerSwipe()
    _ = s.update(touches: three(0.6))
    #expect(s.update(touches: three(0.5)) == .next)
    #expect(s.update(touches: three(0.2)) == nil)          // latched: no second step
    s.reset()
    #expect(s.update(touches: three(0.9)) == nil)          // latch gone; this is a fresh baseline
    #expect(s.update(touches: three(0.8)) == .next)
    // A baseline from before the reset must not survive it.
    s.reset()
    var t = ThreeFingerSwipe()
    _ = t.update(touches: three(0.9))
    t.reset()
    #expect(t.update(touches: three(0.3)) == nil)          // would be a 0.6 jump from the old baseline
}

@Test func upAndDownSwipesFireOnce() {
    var s = ThreeFingerSwipe()
    #expect(s.update(touches: three(0.5, 0.5), at: 0) == nil)
    #expect(s.update(touches: three(0.5, 0.6), at: 0.05) == .up)       // fingers up: y grows
    #expect(s.update(touches: three(0.5, 0.8), at: 0.1) == nil)        // latched
    #expect(s.update(touches: [], at: 0.2) == nil)
    #expect(s.update(touches: three(0.5, 0.5), at: 1) == nil)
    #expect(s.update(touches: three(0.52, 0.4), at: 1.05) == .down)
}

@Test func diagonalSwipeIsNeither() {
    var s = ThreeFingerSwipe()
    #expect(s.update(touches: three(0.5, 0.5), at: 0) == nil)
    #expect(s.update(touches: three(0.41, 0.41), at: 0.05) == nil)     // as much across as up
}

@Test func quickStillThreeFingersAreATap() {
    var s = ThreeFingerSwipe()
    #expect(s.update(touches: [three(0.5)[0]], at: 0) == nil)
    #expect(s.update(touches: three(0.5), at: 0.03) == nil)
    #expect(s.update(touches: three(0.505), at: 0.1) == nil)
    #expect(s.update(touches: Array(three(0.505).prefix(1)), at: 0.15) == nil)
    #expect(s.update(touches: [], at: 0.17) == .tap)
}

@Test func slowOrMovingOrFourFingersAreNoTap() {
    var slow = ThreeFingerSwipe()
    _ = slow.update(touches: three(0.5), at: 0)
    #expect(slow.update(touches: [], at: 0.6) == nil)
    var moving = ThreeFingerSwipe()
    _ = moving.update(touches: three(0.5), at: 0)
    _ = moving.update(touches: three(0.53), at: 0.05)                 // 0.03 moved, not yet a swipe
    #expect(moving.update(touches: [], at: 0.1) == nil)
    var four = ThreeFingerSwipe()
    _ = four.update(touches: three(0.5), at: 0)
    _ = four.update(touches: three(0.5) + [CGPoint(x: 0.7, y: 0.5)], at: 0.05)
    #expect(four.update(touches: [], at: 0.1) == nil)
    var swiped = ThreeFingerSwipe()
    _ = swiped.update(touches: three(0.5), at: 0)
    _ = swiped.update(touches: three(0.4), at: 0.05)                  // .next
    #expect(swiped.update(touches: [], at: 0.1) == nil)
}
