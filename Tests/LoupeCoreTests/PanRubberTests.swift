import CoreGraphics
import Foundation
import Testing
@testable import LoupeCore

// A 1000×1000 view on a 4000×3000 photo at 100 %, at its left edge (x can pan right no further), vertically centred.
private func atLeftEdge() -> ViewTransform {
    ViewTransform(imageSize: CGSize(width: 4000, height: 3000), viewSize: CGSize(width: 1000, height: 1000),
                  mode: .actual(1), center: CGPoint(x: 0, y: 0.5)).clamped
}

private func stretch(_ raw: Double) -> Double { RubberBand.offset(raw: raw, dimension: 1000) }

@Test func outwardPanStretches() {
    var r = PanRubber(enabled: true)
    let t0 = atLeftEdge()
    let t = r.pan(by: CGVector(dx: 300, dy: 0), on: t0)
    #expect(abs(t.offset.dx - stretch(300)) < 1e-9)
    #expect(t.offset.dy == 0)
    #expect(t.center == t0.center)
    #expect(!r.isAnimating)
    // Further out keeps adding to the raw overshoot, under the same resistance.
    let t2 = r.pan(by: CGVector(dx: 200, dy: 0), on: t)
    #expect(abs(t2.offset.dx - stretch(500)) < 1e-9)
}

@Test func inwardPanUndoesStretchFirst() {
    var r = PanRubber(enabled: true)
    let t0 = atLeftEdge()
    var t = r.pan(by: CGVector(dx: 300, dy: 0), on: t0)
    t = r.pan(by: CGVector(dx: -300, dy: 0), on: t)
    #expect(abs(t.offset.dx) < 1e-9)
    #expect(t.center == t0.center)
    t = r.pan(by: CGVector(dx: -100, dy: 0), on: t)
    #expect(t.offset == .zero)
    #expect(abs(t.center.x - (t0.center.x + 100.0 / 4000)) < 1e-12)
    // A single inward move larger than the stretch undoes it and pans by the rest.
    var r2 = PanRubber(enabled: true)
    var u = r2.pan(by: CGVector(dx: 300, dy: 0), on: t0)
    u = r2.pan(by: CGVector(dx: -400, dy: 0), on: u)
    #expect(u.offset == .zero)
    #expect(abs(u.center.x - (t0.center.x + 100.0 / 4000)) < 1e-12)
}

@Test func releaseSpringsBack() {
    var r = PanRubber(enabled: true)
    var t = r.pan(by: CGVector(dx: 300, dy: 0), on: atLeftEdge())
    let start = t.offset.dx
    t = r.release(velocity: .zero, on: t)
    #expect(t.offset.dx == start)   // the release itself does not move the picture
    #expect(r.isAnimating)
    for _ in 0..<30 {
        guard let next = r.step(dt: 1.0 / 60, on: t) else { Issue.record("step returned nil"); return }
        t = next
        #expect(t.offset.dx >= 0)
    }
    #expect(t.offset.dx < 0.01 * start)
    #expect(!r.isAnimating)
    #expect(t.offset == .zero)
}

@Test func releaseWithInwardVelocityNeverCrossesTheEdge() {
    var r = PanRubber(enabled: true)
    var t = r.pan(by: CGVector(dx: 100, dy: 0), on: atLeftEdge())
    t = r.release(velocity: CGVector(dx: -20000, dy: 0), on: t)
    while r.isAnimating, let next = r.step(dt: 1.0 / 120, on: t) {
        t = next
        #expect(t.offset.dx >= 0)
    }
    #expect(t.offset == .zero)
}

@Test func releaseWithoutStretchDoesNothing() {
    var r = PanRubber(enabled: true)
    let t0 = atLeftEdge()
    let t = r.release(velocity: CGVector(dx: 3000, dy: 500), on: r.pan(by: CGVector(dx: -50, dy: 10), on: t0))
    #expect(!r.isAnimating)
    #expect(t.offset == .zero)
}

@Test func fitAxisNeverStretches() {
    // 1000×500 in Fit: neither axis is larger than the view.
    let fit = ViewTransform(imageSize: CGSize(width: 1000, height: 500), viewSize: CGSize(width: 1000, height: 1000))
    var r = PanRubber(enabled: true)
    var t = r.pan(by: CGVector(dx: 0, dy: 400), on: fit)
    #expect(t.offset == .zero)
    t = r.pan(by: CGVector(dx: 0, dy: -400), on: t)
    #expect(t.offset == .zero)
    t = r.pan(by: CGVector(dx: 300, dy: -400), on: t)
    #expect(t.offset == .zero)
    t = r.release(velocity: CGVector(dx: 0, dy: 3000), on: t)
    r.beginGesture()
    t = r.momentum(CGVector(dx: 50, dy: 50), interval: 1.0 / 60, on: t)
    t = r.bounce(x: 3000, y: 3000, on: t)
    #expect(!r.isAnimating)
    if let next = r.step(dt: 1.0 / 60, on: t) { t = next }
    #expect(t.offset == .zero)
    #expect(t.center == fit.clamped.center)

    // A photo wider than the view but shorter: x stretches at its edge, y never does.
    var r2 = PanRubber(enabled: true)
    let wide = ViewTransform(imageSize: CGSize(width: 4000, height: 500), viewSize: CGSize(width: 1000, height: 1000),
                             mode: .actual(1), center: CGPoint(x: 0, y: 0.5)).clamped
    var u = r2.pan(by: CGVector(dx: 300, dy: 400), on: wide)
    #expect(u.offset.dx > 0)
    #expect(u.offset.dy == 0)
    u = r2.bounce(x: nil, y: -3000, on: u)
    u = r2.release(velocity: .zero, on: u)
    while r2.isAnimating, let next = r2.step(dt: 1.0 / 60, on: u) {
        u = next
        #expect(u.offset.dy == 0)
    }
    r2.beginGesture()
    u = r2.momentum(CGVector(dx: 0, dy: 80), interval: 1.0 / 60, on: u)
    #expect(u.offset.dy == 0)
    #expect(!r2.isAnimating)
}

@Test func disabled() {
    var r = PanRubber(enabled: true)
    let t0 = atLeftEdge()
    var t = r.pan(by: CGVector(dx: 300, dy: 0), on: t0)
    #expect(t.offset != .zero)
    r.enabled = false
    #expect(!r.isAnimating)
    // The stretch of an enabled rubber is gone with it: what was produced counts no more.
    t = t.withOffset(.zero)
    for d in [CGVector(dx: 300, dy: 0), CGVector(dx: -120, dy: 40), CGVector(dx: 50, dy: -5000)] {
        let p = r.pan(by: d, on: t)
        #expect(p == t.panned(by: d))
        t = p
    }
    t = r.momentum(CGVector(dx: 5000, dy: 0), interval: 1.0 / 60, on: t)
    #expect(t.offset == .zero)
    t = r.bounce(x: 3000, y: 3000, on: t)
    t = r.release(velocity: CGVector(dx: 3000, dy: 0), on: t)
    #expect(t.offset == .zero)
    #expect(!r.isAnimating)
    #expect(r.step(dt: 1.0 / 60, on: t).map(\.offset) ?? .zero == .zero)
}

@Test func disablingDropsAStretch() {
    var r = PanRubber(enabled: true)
    var t = r.pan(by: CGVector(dx: 300, dy: 0), on: atLeftEdge())
    t = r.release(velocity: .zero, on: t)
    #expect(r.isAnimating)
    r.enabled = false
    #expect(!r.isAnimating)
}

@Test func momentumBouncesOnceAndSpendsAxis() {
    var r = PanRubber(enabled: true)
    let t0 = atLeftEdge()
    let dt = 1.0 / 60
    r.beginGesture()
    var t = r.momentum(CGVector(dx: 50, dy: 20), interval: dt, on: t0)
    // x met the edge on the first event: it bounces from offset 0 with 50 px / (1/60 s) = 3000 px/s; y pans on.
    #expect(r.isAnimating)
    #expect(t.offset.dx == 0)
    #expect(t.center.x == t0.center.x)
    #expect(abs(t.center.y - (0.5 - 20.0 / 3000)) < 1e-12)
    guard let s1 = r.step(dt: dt, on: t) else { Issue.record("step returned nil"); return }
    var expected = EdgeSpring(offset: 0, velocity: 3000)
    #expect(abs(s1.offset.dx - expected.step(dt: dt)) < 1e-9)
    t = s1
    // Further momentum moves neither x's offset nor its centre; y keeps panning.
    var peak = t.offset.dx
    for _ in 0..<40 {
        let before = t
        t = r.momentum(CGVector(dx: 50, dy: 20), interval: dt, on: t)
        #expect(t.offset.dx == before.offset.dx)
        #expect(t.center.x == before.center.x)
        #expect(t.center.y < before.center.y)
        if let next = r.step(dt: dt, on: t) { t = next }
        peak = max(peak, t.offset.dx)
    }
    // Overshoot of v0 / (ω e) ≈ 58 px, then back.
    #expect(abs(peak - 3000 / (EdgeSpring.omega * M_E)) < 2)
    #expect(!r.isAnimating)
    #expect(t.offset == .zero)
    // Still the same gesture: x stays spent, even pointing inward.
    let spent = r.momentum(CGVector(dx: -50, dy: 0), interval: dt, on: t)
    #expect(spent.center.x == t.center.x)
    // A new gesture pans x normally again: inward moves the photo, and momentum outward bounces anew.
    r.beginGesture()
    let moved = r.pan(by: CGVector(dx: -100, dy: 0), on: t)
    #expect(abs(moved.center.x - (t.center.x + 100.0 / 4000)) < 1e-12)
    let coasted = r.momentum(CGVector(dx: -40, dy: 0), interval: dt, on: moved)
    #expect(abs(coasted.center.x - (moved.center.x + 40.0 / 4000)) < 1e-12)
    #expect(!r.isAnimating)
    _ = r.momentum(CGVector(dx: 500, dy: 0), interval: dt, on: coasted)
    #expect(r.isAnimating)
}

@Test func momentumOnAFingerStretchSpringsItBack() {
    // Fingers lifted past the edge with momentum to follow: the stretch springs back and the axis takes no momentum.
    var r = PanRubber(enabled: true)
    r.beginGesture()
    var t = r.pan(by: CGVector(dx: 200, dy: 0), on: atLeftEdge())
    let stretched = t.offset.dx
    t = r.momentum(CGVector(dx: 30, dy: 0), interval: 1.0 / 60, on: t)
    #expect(r.isAnimating)
    #expect(t.offset.dx == stretched)
    while r.isAnimating, let next = r.step(dt: 1.0 / 60, on: t) {
        t = r.momentum(CGVector(dx: 30, dy: 0), interval: 1.0 / 60, on: next)
        #expect(t.offset.dx >= 0)
    }
    #expect(t.offset == .zero)
    #expect(t.center == atLeftEdge().center)
}

@Test func momentumWithAZeroIntervalStaysFinite() {
    var r = PanRubber(enabled: true)
    var t = r.momentum(CGVector(dx: 50, dy: 0), interval: 0, on: atLeftEdge())
    for _ in 0..<5 { if let next = r.step(dt: 1.0 / 60, on: t) { t = next } }
    #expect(t.offset.dx.isFinite)
    #expect(t.offset.dx > 0)
}

@Test func bounceFromAGlide() {
    var r = PanRubber(enabled: true)
    var t = r.bounce(x: 3000, y: nil, on: atLeftEdge())
    #expect(r.isAnimating)
    #expect(t.offset == .zero)
    var peak = 0.0
    while r.isAnimating, let next = r.step(dt: 1.0 / 120, on: t) {
        t = next
        #expect(t.offset.dy == 0)
        #expect(t.offset.dx >= 0)
        peak = max(peak, t.offset.dx)
    }
    #expect(abs(peak - 3000 / (EdgeSpring.omega * M_E)) < 1)
    #expect(t.offset == .zero)
}

@Test func catchDuringSpring() {
    var r = PanRubber(enabled: true)
    var t = r.pan(by: CGVector(dx: 300, dy: 0), on: atLeftEdge())
    t = r.release(velocity: .zero, on: t)
    for _ in 0..<5 { t = r.step(dt: 1.0 / 60, on: t) ?? t }
    let shown = t.offset.dx
    #expect(shown > 0)
    #expect(r.isAnimating)
    t = r.pan(by: CGVector(dx: -10, dy: 0), on: t)
    #expect(!r.isAnimating)
    let raw = RubberBand.raw(offset: shown, dimension: 1000)
    #expect(abs(t.offset.dx - stretch(raw - 10)) < 1e-6)
    // Held there: nothing moves until the release.
    let held = r.step(dt: 1.0 / 60, on: t)
    #expect(held?.offset == t.offset)
}

@Test func grabStopsTheSpringWhereItShows() {
    var r = PanRubber(enabled: true)
    var t = r.pan(by: CGVector(dx: 300, dy: 0), on: atLeftEdge())
    t = r.release(velocity: .zero, on: t)
    for _ in 0..<5 { t = r.step(dt: 1.0 / 60, on: t) ?? t }
    let shown = t.offset
    t = r.grab(on: t)
    #expect(!r.isAnimating)
    #expect(abs(t.offset.dx - shown.dx) < 1e-9 && t.offset.dy == 0)   // raw and back: equal to rounding
    t = r.release(velocity: .zero, on: t)
    #expect(r.isAnimating)
}

@Test func foreignTransformResets() {
    var r = PanRubber(enabled: true)
    var t = r.pan(by: CGVector(dx: 300, dy: 0), on: atLeftEdge())
    t = r.release(velocity: .zero, on: t)
    #expect(r.isAnimating)
    #expect(r.step(dt: 1.0 / 60, on: t.withOffset(.zero)) == nil)
    #expect(!r.isAnimating)
    // A zoom (any op but withOffset) zeroes the offset: the rubber starts afresh from it.
    var r2 = PanRubber(enabled: true)
    let s = r2.pan(by: CGVector(dx: 300, dy: 0), on: atLeftEdge())
    let zoomed = s.zoomedStep(1)
    #expect(zoomed.offset == .zero)
    #expect(r2.step(dt: 1.0 / 60, on: zoomed) == nil)
    let p = r2.pan(by: CGVector(dx: -10, dy: 0), on: zoomed)
    #expect(p.offset == .zero)
}

// MARK: Fix round 1: bounce cap, momentum timing, catch near the limit

private func smallView() -> ViewTransform {
    ViewTransform(imageSize: CGSize(width: 4000, height: 3000), viewSize: CGSize(width: 600, height: 600),
                  mode: .actual(1), center: CGPoint(x: 0, y: 0.5)).clamped
}

/// Steps until the springs settle (or `limit` frames), returning the largest |offset.dx| seen and the transform there.
private func runToPeak(_ r: inout PanRubber, _ t: ViewTransform, hz: Double = 120) -> (peak: Double, atPeak: ViewTransform) {
    var t = t, best = (Double(abs(t.offset.dx)), t)
    while r.isAnimating, let next = r.step(dt: 1 / hz, on: t) {
        t = next
        if abs(t.offset.dx) > best.0 { best = (Double(abs(t.offset.dx)), t) } else { break }
    }
    return best
}

@Test func fastBounceIsCappedAtAThirdOfTheView() {
    let limit = RubberBand.offset(raw: 600, dimension: 600)   // ≈ 0.355 · 600
    #expect(abs(limit - 0.3548 * 600) < 0.1)
    // A mouse glide into the edge at 36 000 px/s (uncapped: 36 000 / (ω e) ≈ 697 px, past the whole view).
    var r = PanRubber(enabled: true)
    var t = r.bounce(x: 36_000, y: nil, on: smallView())
    var peak = 0.0
    while r.isAnimating, let next = r.step(dt: 1.0 / 240, on: t) {
        t = next
        peak = max(peak, t.offset.dx)
    }
    #expect(peak <= limit + 1)
    #expect(peak >= limit - 2)   // capped to the limit, not far below it
    // The same through the momentum: 600 px in one 1/60 s frame.
    var m = PanRubber(enabled: true)
    m.beginGesture()
    var u = m.momentum(CGVector(dx: 600, dy: 0), at: 50, on: smallView())
    peak = 0
    while m.isAnimating, let next = m.step(dt: 1.0 / 240, on: u) {
        u = next
        peak = max(peak, u.offset.dx)
    }
    #expect(peak <= limit + 1)
    // A mouse released outward fast while already stretched.
    var h = PanRubber(enabled: true)
    var w = h.pan(by: CGVector(dx: 200, dy: 0), on: smallView())
    w = h.release(velocity: CGVector(dx: 36_000, dy: 0), on: w)
    peak = 0
    while h.isAnimating, let next = h.step(dt: 1.0 / 240, on: w) {
        w = next
        peak = max(peak, w.offset.dx)
    }
    #expect(peak <= limit + 1)
    // Slow bounces are untouched: 3000 px/s still peaks at v0 / (ω e) ≈ 58 px.
    #expect(PanRubber.spring(from: 0, velocity: 3000, dimension: 600).velocity == 3000)
    #expect(PanRubber.spring(from: 0, velocity: -3000, dimension: 600).velocity == -3000)
    // Already beyond the limit: no outward speed; inward speed is still bounded by ω · offset.
    #expect(PanRubber.spring(from: 300, velocity: 5000, dimension: 600).velocity == 0)
    #expect(PanRubber.spring(from: -300, velocity: -5000, dimension: 600).velocity == 0)
}

@Test func catchAtTheBouncePeakThenPanInward() {
    var r = PanRubber(enabled: true)
    let t = r.bounce(x: 36_000, y: nil, on: smallView())
    let (peak, atPeak) = runToPeak(&r, t, hz: 240)
    #expect(r.isAnimating)
    let caught = r.grab(on: atPeak)
    #expect(abs(caught.offset.dx - peak) < 1e-6)
    #expect(!r.isAnimating)
    let moved = r.pan(by: CGVector(dx: -50, dy: 0), on: caught)
    #expect(moved.offset.dx < caught.offset.dx - 5)   // the finger visibly undoes the stretch
    #expect(moved.offset.dx > 0)
    #expect(moved.center == caught.center)
}

@Test func catchNearTheViewSideStaysFinite() {
    // A spring showing almost the whole view (not reachable through the cap, but guarded): the catch stays usable.
    var r = PanRubber(enabled: true)
    var t = r.pan(by: CGVector(dx: 1e7, dy: 0), on: smallView())   // held almost at d
    t = r.release(velocity: .zero, on: t)
    let caught = r.grab(on: t)
    #expect(caught.offset.dx.isFinite)
    #expect(caught.offset.dx <= 0.9 * 600 + 1e-6)
    let moved = r.pan(by: CGVector(dx: -200, dy: 0), on: caught)
    #expect(moved.offset.dx < caught.offset.dx)
}

@Test func firstMomentumEventUsesAFrameNotTheGapSinceTheFingers() {
    // The fingers' last event came 1 ms before the first momentum event; the momentum's speed is over one 60 Hz frame:
    // 50 px → 3000 px/s, not 50 px over a 1/240 s clamp (12 000 px/s).
    var r = PanRubber(enabled: true)
    r.beginGesture()
    var t = r.pan(by: CGVector(dx: -10, dy: 0), on: atLeftEdge())
    t = r.release(velocity: .zero, on: t)
    t = r.momentum(CGVector(dx: 50, dy: 0), at: 100.001, on: t)
    #expect(r.isAnimating)
    guard let s = r.step(dt: 1.0 / 60, on: t) else { Issue.record("step returned nil"); return }
    var expected = EdgeSpring(offset: 0, velocity: 3000)
    #expect(abs(s.offset.dx - expected.step(dt: 1.0 / 60)) < 1e-9)
}

@Test func laterMomentumEventsUseTheGapSinceThePreviousOne() {
    var r = PanRubber(enabled: true)
    r.beginGesture()
    let start = r.pan(by: CGVector(dx: -200, dy: 0), on: atLeftEdge())
    var t = r.momentum(CGVector(dx: 50, dy: 0), at: 300, on: start)
    t = r.momentum(CGVector(dx: 50, dy: 0), at: 300 + 1.0 / 120, on: t)
    #expect(!r.isAnimating)
    // 100 px left to the edge; this event asks 120 px over 1/120 s: it bounces at 14 400 px/s.
    t = r.momentum(CGVector(dx: 120, dy: 0), at: 300 + 2.0 / 120, on: t)
    #expect(r.isAnimating)
    guard let s = r.step(dt: 1.0 / 120, on: t) else { Issue.record("step returned nil"); return }
    var expected = EdgeSpring(offset: 0, velocity: 14_400)
    #expect(abs(s.offset.dx - expected.step(dt: 1.0 / 120)) < 1e-9)
}
