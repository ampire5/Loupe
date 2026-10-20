import Testing
import CoreGraphics
import Foundation
@testable import LoupeCore

private let imgSize = CGSize(width: 10502, height: 14000), viewSz = CGSize(width: 6144, height: 3456)
private func start(_ mode: ZoomMode = .actual(1)) -> ViewTransform {
    ViewTransform(imageSize: imgSize, viewSize: viewSz, mode: mode, center: CGPoint(x: 0.4, y: 0.6))
}
private let anchor = CGPoint(x: 1500, y: 900)

/// Samples every `interval` s from t0 for `duration` s, zooming at `v` doublings/s.
private func tracker(velocity v: Double, duration: Double = 0.2, interval: Double = 1.0 / 120, t0: Double = 10) -> ZoomVelocityTracker {
    var tr = ZoomVelocityTracker()
    var t = 0.0
    while t <= duration + 1e-9 {
        tr.add(0.3 + v * t, at: t0 + t)
        t += interval
    }
    return tr
}

private func coastTotal(velocity: Double, hz: Double) -> Double {
    var c = ZoomCoast(velocity: velocity)
    var total = 0.0, frames = 0
    while !c.isFinished && frames < 100_000 {
        total += c.step(dt: 1 / hz)
        frames += 1
    }
    return total
}

@Test func zoomVelocityIsTheSlopeOverTheWindow() {
    let tr = tracker(velocity: 2.5)
    #expect(abs(tr.releaseVelocity(at: 10.2) - 2.5) < 1e-9)
    #expect(abs(tracker(velocity: -1.2).releaseVelocity(at: 10.2) + 1.2) < 1e-9)
}

@Test func zoomVelocityUsesOnlyTheLastWindow() {
    // Fast, then slow for the last 80 ms: only the slow part counts.
    var tr = ZoomVelocityTracker()
    var t = 0.0, d = 0.0
    while t < 0.3 { tr.add(d, at: 10 + t); d += 4 / 120; t += 1.0 / 120 }
    while t < 0.4 { tr.add(d, at: 10 + t); d += 0.5 / 120; t += 1.0 / 120 }
    #expect(abs(tr.releaseVelocity(at: 10 + t - 1.0 / 120) - 0.5) < 0.05)
}

@Test func zoomVelocityIsZeroWhenStaleSlowOrTooFewSamples() {
    let tr = tracker(velocity: 3)
    #expect(tr.releaseVelocity(at: 10.2 + DragVelocityTracker.staleAfter + 0.01) == 0)
    #expect(tracker(velocity: 0.03).releaseVelocity(at: 10.2) == 0)
    // Below the start speed (0.2) a release does not coast, even though the coast itself runs down to 0.05.
    #expect(tracker(velocity: 0.15).releaseVelocity(at: 10.2) == 0)
    #expect(abs(tracker(velocity: 0.25).releaseVelocity(at: 10.2) - 0.25) < 1e-9)
    var one = ZoomVelocityTracker()
    one.add(1, at: 5)
    #expect(one.releaseVelocity(at: 5) == 0)
    var reset = tracker(velocity: 3)
    reset.reset()
    #expect(reset.releaseVelocity(at: 10.2) == 0)
}

@Test func zoomCoastDecaysAndStops() {
    // Total displacement is v / rate for the same decay as the pan coast, at any frame rate.
    let v = 3.0
    let rate = -log(InertiaCoast.decayPerMillisecond) * 1000
    // The coast ends below stopSpeed, so the analytic total is that of v running down to it.
    let expected = (v - ZoomCoast.stopSpeed) / rate
    for hz in [60.0, 120.0] {
        let got = coastTotal(velocity: v, hz: hz)
        #expect(abs(got - expected) / expected < 0.02, "\(hz) Hz: \(got) vs \(expected)")
    }
    #expect(coastTotal(velocity: -v, hz: 60) < 0)
    #expect(ZoomCoast(velocity: 0.04).isFinished)
    #expect(!ZoomCoast(velocity: 0.06).isFinished)
}

@Test func zoomCoastIsTheSameAt60And120Hz() {
    func after(hz: Double) -> Double {
        var c = ZoomCoast(velocity: 2)
        var d = 0.0
        for _ in 0..<Int(hz) { d += c.step(dt: 1 / hz) }
        return d
    }
    let rate = -log(InertiaCoast.decayPerMillisecond) * 1000
    #expect(abs(after(hz: 60) - after(hz: 120)) < 1e-9)
    #expect(abs(after(hz: 60) - 2 * (1 - exp(-rate)) / rate) < 1e-9)
}

@Test func zoomCoastDecaysMonotonically() {
    var c = ZoomCoast(velocity: 2)
    var last = Double.infinity, frames = 0
    while !c.isFinished && frames < 5000 {
        let d = c.step(dt: 1.0 / 60)
        #expect(d > 0 && d < last)
        last = d
        frames += 1
    }
    #expect(c.isFinished && frames > 10)
}

/// Runs a whole coast of `RMBZoomCoast` at `hz` and returns the last transform, whether a frame landed on a stop,
/// and how many frames it ran.
private func run(_ coast: RMBZoomCoast, hz: Double) -> (transform: ViewTransform, landed: Bool, frames: Int) {
    var c = coast
    var t = c.zoom.start, landed = false, frames = 0
    while !c.isFinished && frames < 100_000 {
        let f = c.advance(dt: 1 / hz)
        t = f.transform
        landed = landed || f.landedOnStop
        frames += 1
    }
    return (t, landed, frames)
}

@Test func zoomCoastStopsAtLimit() {
    let t0 = start()
    let zoom = RMBZoom(anchor: anchor, transform: t0, pointsPerDoubling: RMBZoom.pointsPerDoubling)
    let up = RMBZoomCoast(zoom: zoom, stops: ZoomStopGesture(transform: t0, stops: []), doublings: 0, velocity: 20)
    let r = run(up, hz: 60)
    #expect(r.transform.scale == t0.scaleLimits.upperBound)
    #expect(!r.landed)
    // It ended when the limit was reached, not by running down: far fewer frames than a free coast would take.
    #expect(r.frames < 120)
    let down = RMBZoomCoast(zoom: zoom, stops: ZoomStopGesture(transform: t0, stops: []), doublings: 0, velocity: -20)
    #expect(abs(run(down, hz: 60).transform.scale - t0.scaleLimits.lowerBound) < 1e-12)
}

@Test func zoomCoastStartingAtALimitMovingAwayRuns() {
    let t0 = start().zoomed(toScale: 64, anchor: anchor)
    let zoom = RMBZoom(anchor: anchor, transform: t0, pointsPerDoubling: RMBZoom.pointsPerDoubling)
    let away = RMBZoomCoast(zoom: zoom, stops: ZoomStopGesture(transform: t0, stops: []), doublings: 0, velocity: -2)
    #expect(run(away, hz: 60).transform.scale < 64)
}

@Test func zoomCoastEndsOnTheFirstStopItLandsOn() {
    let t0 = start(.actual(0.4))
    let mid = CGPoint(x: 3000, y: 1700)   // mid-view, where the clamped picture can keep the pinned point
    let zoom = RMBZoom(anchor: mid, transform: t0, pointsPerDoubling: RMBZoom.pointsPerDoubling)
    let gesture = ZoomStopGesture(transform: t0, stops: [.percent(100)])
    let r = run(RMBZoomCoast(zoom: zoom, stops: gesture, doublings: 0, velocity: 3), hz: 60)
    #expect(r.landed)
    #expect(r.transform.mode == .actual(1))
    // It stays at the anchor-pinned stop transform.
    let p = t0.imagePoint(forView: mid)
    let back = r.transform.viewPoint(forImage: p)
    #expect(abs(back.x - mid.x) < 1e-6 && abs(back.y - mid.y) < 1e-6)
}

@Test func zoomCoastKeepsTheAnchorAndMatchesTheClosedForm() {
    let t0 = start()
    let zoom = RMBZoom(anchor: anchor, transform: t0, pointsPerDoubling: 100)
    var c = RMBZoomCoast(zoom: zoom, stops: ZoomStopGesture(transform: t0, stops: []), doublings: 0.5, velocity: 1)
    let p = t0.imagePoint(forView: anchor)
    var f = c.advance(dt: 1.0 / 60)
    for _ in 0..<59 { f = c.advance(dt: 1.0 / 60) }
    let rate = -log(InertiaCoast.decayPerMillisecond) * 1000
    let d = 0.5 + (1 - exp(-rate)) / rate
    #expect(abs(f.transform.scale - 1 * pow(2, d)) < 1e-9)
    let back = f.transform.viewPoint(forImage: p)
    #expect(abs(back.x - anchor.x) < 1e-6 && abs(back.y - anchor.y) < 1e-6)
}

@Test func zoomCoastScaleIsTheSameAt60And120Hz() {
    let t0 = start()
    func after(hz: Double) -> Double {
        var c = RMBZoomCoast(zoom: RMBZoom(anchor: anchor, transform: t0, pointsPerDoubling: RMBZoom.pointsPerDoubling), stops: ZoomStopGesture(transform: t0, stops: []),
                             doublings: 0, velocity: 1.5)
        var f = c.advance(dt: 1 / hz)
        for _ in 1..<Int(hz) { f = c.advance(dt: 1 / hz) }
        return f.transform.scale
    }
    #expect(abs(after(hz: 60) / after(hz: 120) - 1) < 1e-9)
}

@Test func invertedZoomCoastGoesTheGesturesWay() {
    // `rmb-zoom-invert`: dragging down 100 pt zoomed in half a doubling; the coast seeded from the same doublings and a
    // velocity in their sense (positive = in) continues in, from where the drag left the picture.
    let t0 = start()
    let zoom = RMBZoom(anchor: anchor, transform: t0, pointsPerDoubling: RMBZoom.pointsPerDoubling, inverted: true)
    let ended = zoom.doublings(dyPoints: 100)
    #expect(ended == 0.5)
    var coast = RMBZoomCoast(zoom: zoom, stops: ZoomStopGesture(transform: t0, stops: []), doublings: ended, velocity: 1)
    let first = coast.advance(dt: 1.0 / 60).transform.scale
    #expect(first > zoom.transform(dyPoints: 100).scale)
    #expect(abs(zoom.transform(dyPoints: 100).scale - t0.scale * pow(2, 0.5)) < 1e-12)
}

@Test func coastDoesNotStretch() {
    let t0 = start().zoomed(toScale: 40, anchor: anchor)
    let zoom = RMBZoom(anchor: anchor, transform: t0, pointsPerDoubling: RMBZoom.pointsPerDoubling)
    var rubber = ZoomStopGesture(transform: t0, stops: [], rubber: true)
    // Released stretched past 6400 %, still flicking in.
    let ended = log2(80.0 / 40)
    _ = rubber.constrain(zoom.scale(doublings: ended))
    #expect(rubber.stretch > 1)
    var coast = RMBZoomCoast(zoom: zoom, stops: rubber, doublings: ended, velocity: 3)
    #expect(coast.stretch == 1)
    let f = coast.advance(dt: 1.0 / 60)
    #expect(f.transform.scale == 64 && f.transform.stretch == nil && coast.stretch == 1 && coast.isFinished)

    // Flicked back out from the stretch: the coast leaves the limit at once instead of first unwinding the overshoot.
    var away = RMBZoomCoast(zoom: zoom, stops: rubber, doublings: ended, velocity: -3)
    _ = away.advance(dt: 1.0 / 60)
    #expect(away.advance(dt: 1.0 / 60).transform.scale < 64)
}

@Test func zoomBumpsOncePerArrivalAtALimit() {
    var b = ZoomBumps()
    let limits = 0.25...64.0
    #expect(b.frame(scale: 2, stretch: 1, limits: limits, landedOnStop: false) == nil)
    #expect(b.frame(scale: 4, stretch: 1, limits: limits, landedOnStop: true) == .stop)
    // Without the rubber band the scale reaches the limit; a stop on the limit gives the limit bump only.
    #expect(b.frame(scale: 64, stretch: 1, limits: limits, landedOnStop: true) == .limit)
    #expect(b.frame(scale: 64, stretch: 1, limits: limits, landedOnStop: false) == nil)
    #expect(b.frame(scale: 64 * (1 - 1e-12), stretch: 1, limits: limits, landedOnStop: false) == nil)
    // Leaving re-arms it.
    #expect(b.frame(scale: 32, stretch: 1, limits: limits, landedOnStop: false) == nil)
    #expect(b.frame(scale: 64, stretch: 1, limits: limits, landedOnStop: false) == .limit)
    // With the rubber band: a stretch beginning past either limit.
    var r = ZoomBumps()
    #expect(r.frame(scale: 0.25, stretch: 0.97, limits: limits, landedOnStop: false) == .limit)
    #expect(r.frame(scale: 0.25, stretch: 0.9, limits: limits, landedOnStop: false) == nil)
    #expect(r.frame(scale: 0.3, stretch: 1, limits: limits, landedOnStop: false) == nil)
    #expect(r.frame(scale: 64, stretch: 1.05, limits: limits, landedOnStop: false) == .limit)
}

@Test func zoomLimitTolerance() {
    let limits = 0.25...64.0
    #expect(ZoomLimit.atUpper(64 * (1 - 1e-10), of: limits))
    #expect(!ZoomLimit.atUpper(63.9, of: limits))
    #expect(ZoomLimit.atLower(0.25 * (1 + 1e-10), of: limits))
    #expect(!ZoomLimit.atLower(0.26, of: limits))
}
