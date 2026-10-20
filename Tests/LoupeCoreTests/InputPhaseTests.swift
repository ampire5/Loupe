import Foundation
import Testing
@testable import LoupeCore

private let p60 = 1.0 / 60
private let p120 = 1.0 / 120
private let ms = 0.001

/// Reference wrapper: `#expect` cannot call mutating methods on a local value.
private final class Phase {
    var phase = InputPhase()
    func input(_ t: Double) { phase.recordInput(at: t) }
    func delay(_ c: Double, _ p: Double) -> Double { phase.latchDelay(callbackAt: c, period: p) }
}

/// Feeds one input per period at `callback(k) + offset(k)` for the half-second before `end`, where
/// callbacks fall on `base + k·p`. Returns the time of the next callback.
@discardableResult
private func feed(_ phase: Phase, base: Double, period p: Double, count: Int,
                  offset: (Int) -> Double) -> Double {
    for k in 0..<count { phase.input(base + Double(k) * p + offset(k)) }
    return base + Double(count) * p
}

private func circularDistance(_ a: Double, _ b: Double, _ p: Double) -> Double {
    let d = abs((a - b).truncatingRemainder(dividingBy: p))
    return min(d, p - d)
}

@Test func inputsJustAfterTheCallbackLatchHalfAPeriodLater() {
    let s = Phase()
    let c = feed(s, base: 1000, period: p60, count: 25) { _ in 0.2 * ms }
    let d = s.delay(c, p60)
    #expect(abs(d - (p60 / 2 + 0.2 * ms)) < 0.5 * ms)
}

@Test func inputsMidwayBetweenCallbacksLatchAtOnce() {
    // Inputs at callback + 8 ms: half a period away from them is (almost) the callback itself. The ideal
    // delay (16.3 ms) is past the clamp, so the latch falls back to the end of the allowed window that is
    // farther from the inputs: right away.
    let s = Phase()
    let c = feed(s, base: 1000, period: p60, count: 25) { _ in 8 * ms }
    let d = s.delay(c, p60)
    #expect(d >= 0 && d <= 0.6 * p60)
    #expect(d < 0.5 * ms)
    #expect(circularDistance(d, 8 * ms, p60) > 7 * ms)
}

@Test func inputsStraddlingTheCallbackLatchHalfAPeriodLater() {
    // The full-screen case: events alternate just before and just after the callback.
    let s = Phase()
    let c = feed(s, base: 1000, period: p60, count: 25) { k in k % 2 == 0 ? 0.5 * ms : -0.5 * ms }
    let d = s.delay(c, p60)
    #expect(abs(d - p60 / 2) < 1 * ms)
}

@Test func inputsJustBeforeTheCallbackWrapAround() {
    // Inputs at p − 0.2 ms after a callback, i.e. 0.2 ms before the next one.
    let s = Phase()
    let c = feed(s, base: 1000, period: p60, count: 25) { _ in p60 - 0.2 * ms }
    let d = s.delay(c, p60)
    #expect(abs(d - (p60 / 2 - 0.2 * ms)) < 0.5 * ms)
}

@Test func spreadOutPhasesLatchAtOnce() {
    // A deterministic pseudo-random phase per input: no consistent phase to avoid.
    let s = Phase()
    var seed: UInt64 = 0x2545_F491_4F6C_DD1D
    let c = feed(s, base: 1000, period: p60, count: 30) { _ in
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double(seed >> 11) / Double(1 << 53) * p60
    }
    #expect(s.delay(c, p60) == 0)
}

@Test func evenlySpreadPhasesLatchAtOnce() {
    let s = Phase()
    let c = feed(s, base: 1000, period: p60, count: 24) { k in Double(k % 8) / 8 * p60 }
    #expect(s.delay(c, p60) == 0)
}

@Test func noRecentInputLatchesAtOnce() {
    let s = Phase()
    let c = feed(s, base: 1000, period: p60, count: 25) { _ in 0.2 * ms }
    #expect(s.delay(c + 0.6, p60) == 0)
    #expect(s.delay(c + 0.5 + p60, p60) == 0)
}

@Test func neverAnyInputLatchesAtOnce() {
    #expect(Phase().delay(1000, p60) == 0)
}

@Test func aLoneInputIsNotAStream() {
    // A key press or a finished load: draw immediately rather than guess a phase from one event.
    let s = Phase()
    s.input(1000 + 0.2 * ms)
    #expect(s.delay(1000 + p60, p60) == 0)
}

@Test func onlyTheLastHalfSecondCounts() {
    // An old stream at +8 ms, then a fresh one at +0.2 ms: the fresh phase wins.
    let s = Phase()
    let c1 = feed(s, base: 1000, period: p60, count: 30) { _ in 8 * ms }
    let c2 = feed(s, base: c1 + 1, period: p60, count: 25) { _ in 0.2 * ms }
    #expect(abs(s.delay(c2, p60) - (p60 / 2 + 0.2 * ms)) < 0.5 * ms)
}

@Test func worksAt120Hz() {
    let s = Phase()
    let c = feed(s, base: 1000, period: p120, count: 50) { _ in 0.2 * ms }
    #expect(abs(s.delay(c, p120) - (p120 / 2 + 0.2 * ms)) < 0.5 * ms)

    let w = Phase()
    let cw = feed(w, base: 1000, period: p120, count: 50) { _ in p120 - 0.2 * ms }
    #expect(abs(w.delay(cw, p120) - (p120 / 2 - 0.2 * ms)) < 0.5 * ms)
}

@Test func delayIsAlwaysWithinTheClamp() {
    for p in [p60, p120] {
        for step in 0..<40 {
            let s = Phase()
            let offset = Double(step) / 40 * p
            let c = feed(s, base: 1000, period: p, count: 25) { _ in offset }
            let d = s.delay(c, p)
            #expect(d >= 0 && d <= 0.6 * p + 1e-12)
            // Wherever the inputs are, the latch stays at least 0.2 p away from them.
            #expect(circularDistance(d, offset, p) >= 0.2 * p - 1e-9)
        }
    }
}

@Test func callbackPhaseNeedNotBeAMultipleOfThePeriod() {
    // Callbacks do not start at a multiple of p in absolute time; only inputs relative to them matter.
    let s = Phase()
    let c = feed(s, base: 1234.0071, period: p60, count: 25) { _ in 0.2 * ms }
    #expect(abs(s.delay(c, p60) - (p60 / 2 + 0.2 * ms)) < 0.5 * ms)
}

// MARK: FramePeriod

private final class Period {
    var period = FramePeriod()
    func target(_ t: Double) -> Double { period.record(targetTimestamp: t) }
}

@Test func periodFallsBackTo60HzUntilTwoTimestamps() {
    #expect(abs(Period().target(500) - p60) < 1e-12)
}

@Test func periodIsTheTimestampDelta() {
    let f = Period()
    _ = f.target(500)
    #expect(abs(f.target(500 + p120) - p120) < 1e-9)
    #expect(abs(f.target(500 + 2 * p120) - p120) < 1e-9)
}

@Test func periodIgnoresAGapAfterAPause() {
    let f = Period()
    _ = f.target(500)
    _ = f.target(500 + p60)
    #expect(abs(f.target(503) - p60) < 1e-9)          // the link was paused for 3 s
    #expect(abs(f.target(503 + p60) - p60) < 1e-9)
}

@Test func periodFollowsARefreshRateDrop() {
    // 120 Hz to 60 Hz doubles the delta: the first long delta could be a skipped frame, but two in a
    // row are the new rate.
    let f = Period()
    var t = 500.0
    _ = f.target(t)
    for _ in 0..<5 { t += p120; _ = f.target(t) }
    t += p60
    _ = f.target(t)
    t += p60
    #expect(abs(f.target(t) - p60) < 1e-9)
}

@Test func periodIgnoresOneSkippedFrame() {
    let f = Period()
    _ = f.target(500)
    _ = f.target(500 + p60)
    #expect(abs(f.target(500 + 3 * p60) - p60) < 1e-9)   // one vsync without a callback
    #expect(abs(f.target(500 + 4 * p60) - p60) < 1e-9)
}

@Test func periodFollowsARefreshRateRiseAtOnce() {
    let f = Period()
    _ = f.target(500)
    _ = f.target(500 + p60)
    #expect(abs(f.target(500 + p60 + p120) - p120) < 1e-9)
}

// MARK: Clamp hysteresis

/// One callback per period: the input for callback k arrives at `offset(k)` after it, and the latch is
/// computed at the next callback. Returns every delay chosen.
private func run(_ phase: Phase, period p: Double, callbacks: Int, from start: Int = 0,
                 offset: (Int) -> Double) -> [Double] {
    var delays: [Double] = []
    for k in start..<(start + callbacks) {
        let c = 1000 + Double(k) * p
        phase.input(c + offset(k))
        delays.append(phase.delay(c + p, p))
    }
    return delays
}

@Test func inputsJitteringAroundTheClampSwitchPointDoNotFlipTheLatch() {
    // Inputs near 0.3 p: latching now and latching at 0.6 p are equally far from them. A small jitter in
    // the estimated phase must not make the latch jump between the two ends every few frames.
    for p in [p60, p120] {
        let s = Phase()
        let delays = run(s, period: p, callbacks: 300) { k in
            (0.3 + 0.02 * sin(Double(k) / 3)) * p      // individual inputs wander ±0.02 p around 0.3 p
        }.dropFirst(InputPhase.minInputs)
        let now = delays.filter { $0 == 0 }.count
        let latest = delays.filter { abs($0 - 0.6 * p) < 1e-9 }.count
        #expect(now + latest == delays.count)
        #expect(now == 0 || latest == 0)
    }
}

@Test func aClearPhaseShiftStillSwitchesTheClampEnd() {
    let s = Phase()
    let before = run(s, period: p60, callbacks: 60) { _ in 0.25 * p60 }
    #expect(abs(before.last! - 0.6 * p60) < 1e-9)     // inputs at 0.25 p: 0.6 p is farther (0.35 p vs 0.25 p)
    let after = run(s, period: p60, callbacks: 60, from: 60) { _ in 0.4 * p60 }
    #expect(after.last! == 0)                          // inputs at 0.4 p: now is farther (0.4 p vs 0.2 p)
}

@Test func theClampEndIsContinuousWithTheUnclampedLatch() {
    // Coming from inputs at 0.05 p (ideal 0.55 p, inside the clamp) to 0.2 p (ideal 0.7 p, past it):
    // the latch stays at the late end it was already near instead of jumping to 0.
    let s = Phase()
    _ = run(s, period: p60, callbacks: 60) { _ in 0.05 * p60 }
    let after = run(s, period: p60, callbacks: 60, from: 60) { _ in 0.2 * p60 }
    #expect(after.allSatisfy { $0 > 0.5 * p60 })
}

// MARK: Which snapshot a latched frame draws

private let small = CGSize(width: 800, height: 600)
private let big = CGSize(width: 820, height: 610)

@Test func theLatchedSnapshotIsDrawnWhenItFitsTheDrawable() {
    #expect(LatchedFrame.choose(drawable: small, latched: small, early: small, earlyIsNew: true) == .latched)
    #expect(LatchedFrame.choose(drawable: small, latched: small, early: nil, earlyIsNew: false) == .latched)
    // The drawable was vended after a resize the pre-latch read had not seen yet.
    #expect(LatchedFrame.choose(drawable: big, latched: big, early: small, earlyIsNew: true) == .latched)
}

@Test func aResizeDuringTheLatchDrawsThePreLatchSnapshot() {
    // Live resize: the drawable was vended at the callback with the old size, and the layout pass during
    // the latch changed both drawableSize and the view size. The pre-latch snapshot still fits.
    #expect(LatchedFrame.choose(drawable: small, latched: big, early: small, earlyIsNew: true) == .early)
}

@Test func aPreLatchSnapshotAlreadyOnScreenIsNotDrawnAgain() {
    #expect(LatchedFrame.choose(drawable: small, latched: big, early: small, earlyIsNew: false) == .latched)
}

@Test func whenNeitherFitsTheLatchedSnapshotIsTried() {
    // `draw` then skips it as a resize in flight, and the next callback draws.
    #expect(LatchedFrame.choose(drawable: small, latched: big, early: big, earlyIsNew: true) == .latched)
    #expect(LatchedFrame.choose(drawable: small, latched: big, early: nil, earlyIsNew: false) == .latched)
}
