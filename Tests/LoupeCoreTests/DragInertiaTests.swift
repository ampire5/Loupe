import Testing
import CoreGraphics
import Foundation
@testable import LoupeCore

/// Samples every `interval` s from t0 for `duration` s, moving at `v` px/s.
private func tracker(velocity v: CGVector, duration: Double = 0.2, interval: Double = 1.0 / 120, t0: Double = 10) -> DragVelocityTracker {
    var tr = DragVelocityTracker()
    var t = 0.0
    while t <= duration + 1e-9 {
        tr.add(CGPoint(x: 100 + v.dx * t, y: 50 + v.dy * t), at: t0 + t)
        t += interval
    }
    return tr
}

private func coastDistance(velocity: CGVector, hz: Double) -> CGVector {
    var c = InertiaCoast(velocity: velocity)
    var total = CGVector.zero
    var frames = 0
    while !c.isFinished && frames < 100_000 {
        let d = c.step(dt: 1 / hz)
        total.dx += d.dx
        total.dy += d.dy
        frames += 1
    }
    return total
}

@Test func constantSpeedSamplesGiveThatVelocity() {
    let tr = tracker(velocity: CGVector(dx: 1200, dy: -400))
    let v = tr.releaseVelocity(at: 10.2 + 0.01)
    #expect(abs(v.dx - 1200) < 1)
    #expect(abs(v.dy + 400) < 1)
}

@Test func onlyTheLastEightyMillisecondsCount() {
    var tr = DragVelocityTracker()
    // Slow first (100 px/s), then fast (2000 px/s) for the last 80 ms.
    var t = 0.0
    var x = 0.0
    while t < 0.3 { tr.add(CGPoint(x: x, y: 0), at: t); x += 100.0 / 120; t += 1.0 / 120 }
    let start = t
    while t < start + 0.08 { tr.add(CGPoint(x: x, y: 0), at: t); x += 2000.0 / 120; t += 1.0 / 120 }
    let v = tr.releaseVelocity(at: t)
    #expect(v.dx > 1800 && v.dx < 2100)
}

@Test func pausingBeforeReleaseGivesZero() {
    let tr = tracker(velocity: CGVector(dx: 1200, dy: 0))
    let last = 10.2
    #expect(tr.releaseVelocity(at: last + 0.049).dx > 1000)
    #expect(tr.releaseVelocity(at: last + 0.051) == .zero)
}

@Test func slowDragGivesZero() {
    let tr = tracker(velocity: CGVector(dx: 30, dy: 30))   // 42 px/s
    #expect(tr.releaseVelocity(at: 10.2) == .zero)
}

@Test func justAboveTheMinimumStartSpeedStarts() {
    let tr = tracker(velocity: CGVector(dx: 60, dy: 0))
    #expect(tr.releaseVelocity(at: 10.2).dx > 50)
}

@Test func tooFewSamplesGiveZero() {
    var tr = DragVelocityTracker()
    #expect(tr.releaseVelocity(at: 1) == .zero)
    tr.add(CGPoint(x: 0, y: 0), at: 1)
    #expect(tr.releaseVelocity(at: 1.01) == .zero)
}

@Test func jitterClickDoesNotGlide() {
    var tr = DragVelocityTracker()
    tr.add(CGPoint(x: 0, y: 0), at: 0)
    tr.add(CGPoint(x: 1, y: 0), at: 0.003)
    #expect(tr.releaseVelocity(at: 0.004) == .zero)
}

@Test func threeSamplesOver20msGlide() {
    var tr = DragVelocityTracker()
    tr.add(CGPoint(x: 0, y: 0), at: 0)
    tr.add(CGPoint(x: 10, y: 0), at: 0.010)
    tr.add(CGPoint(x: 20, y: 0), at: 0.020)
    #expect(abs(tr.releaseVelocity(at: 0.021).dx - 1000) < 1)
}

@Test func resetForgetsSamples() {
    var tr = tracker(velocity: CGVector(dx: 1200, dy: 0))
    tr.reset()
    #expect(tr.releaseVelocity(at: 10.2) == .zero)
}

@Test func coastTotalMatchesAnalyticDistance() {
    let v = CGVector(dx: 4000, dy: -3000)   // 5000 px/s
    let k = -log(InertiaCoast.decayPerMillisecond) * 1000
    let expected = 5000 / k
    for hz in [60.0, 120.0] {
        let total = coastDistance(velocity: v, hz: hz)
        let got = hypot(total.dx, total.dy)
        #expect(abs(got - expected) / expected < 0.01, "\(hz) Hz: \(got) vs \(expected)")
        #expect(total.dx > 0 && total.dy < 0)
    }
}

@Test func decayParameter() {
    var c = InertiaCoast(velocity: CGVector(dx: 1000, dy: 0), decayPerMillisecond: 0.99)
    var total = 0.0
    var frames = 0
    while !c.isFinished && frames < 100_000 { total += c.step(dt: 1.0 / 120).dx; frames += 1 }
    let rate = -log(0.99) * 1000
    // The coast stops at 20 px/s, so it falls short of 1000/rate by 20/rate.
    #expect(abs(total - 1000 / rate) < 1 + 20 / rate)
    // A stronger decay (smaller factor) glides a shorter way than the default.
    #expect(total < coastDistance(velocity: CGVector(dx: 1000, dy: 0), hz: 120).dx)
}

@Test func coastTrajectoryIsTheSameAt60And120Hz() {
    let v = CGVector(dx: 2500, dy: 900)
    let a = coastDistance(velocity: v, hz: 60), b = coastDistance(velocity: v, hz: 120)
    #expect(abs(a.dx - b.dx) < 0.5)
    #expect(abs(a.dy - b.dy) < 0.5)
}

@Test func coastPositionAfterOneSecondIsTheSameAtAnyFrameRate() {
    let v = CGVector(dx: 3000, dy: 0)
    func after(hz: Double) -> Double {
        var c = InertiaCoast(velocity: v)
        var x = 0.0
        for _ in 0..<Int(hz) { x += c.step(dt: 1 / hz).dx }
        return x
    }
    #expect(abs(after(hz: 60) - after(hz: 120)) < 1e-6)
}

@Test func coastDecaysMonotonicallyAndFinishes() {
    var c = InertiaCoast(velocity: CGVector(dx: 2000, dy: 0))
    var last = Double.infinity
    var frames = 0
    while !c.isFinished {
        let d = c.step(dt: 1.0 / 60).dx
        #expect(d > 0 && d < last)
        last = d
        frames += 1
        #expect(frames < 2000)
        if frames >= 2000 { break }
    }
    #expect(c.isFinished)
    #expect(frames > 10)
}

@Test func coastBelowStopSpeedIsFinishedImmediately() {
    #expect(InertiaCoast(velocity: CGVector(dx: 10, dy: 5)).isFinished)
    #expect(!InertiaCoast(velocity: CGVector(dx: 100, dy: 0)).isFinished)
}

@Test func stopAxisZeroesOneAxisOnly() {
    var c = InertiaCoast(velocity: CGVector(dx: 1000, dy: 800))
    c.stopAxis(x: true)
    let d = c.step(dt: 1.0 / 60)
    #expect(d.dx == 0)
    #expect(d.dy > 0)
    var c2 = InertiaCoast(velocity: CGVector(dx: 1000, dy: 800))
    c2.stopAxis(y: true)
    let d2 = c2.step(dt: 1.0 / 60)
    #expect(d2.dy == 0)
    #expect(d2.dx > 0)
}

@Test func stoppingBothAxesFinishesTheCoast() {
    var c = InertiaCoast(velocity: CGVector(dx: 1000, dy: 800))
    c.stopAxis(x: true)
    #expect(!c.isFinished)
    c.stopAxis(y: true)
    #expect(c.isFinished)
}

@Test func zeroDtMovesNothing() {
    var c = InertiaCoast(velocity: CGVector(dx: 1000, dy: 0))
    #expect(c.step(dt: 0) == .zero)
    #expect(!c.isFinished)
}
