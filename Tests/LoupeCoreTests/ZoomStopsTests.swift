import Testing
import CoreGraphics
@testable import LoupeCore

private func at(_ stop: ZoomStop, _ scale: Double) -> ZoomStopScale { ZoomStopScale(stop: stop, scale: scale) }
/// 50 %, 100 %, 200 % as ready-made stop scales.
private let half = at(.percent(50), 0.5), one = at(.percent(100), 1), two = at(.percent(200), 2)

// MARK: Gesture rules

@Test func crossingAStopClampsAtItAndReportsTheHit() {
    var g = ZoomStopGesture(startScale: 0.7, stops: [half, one, two])
    let free = g.constrain(0.9)
    #expect(free.scale == 0.9 && free.hitStop == nil && !g.justHit)
    let hit = g.constrain(1.3)
    #expect(hit.scale == 1 && hit.hitStop == .percent(100) && g.justHit)
}

@Test func motionPastTheStopIsAbsorbed() {
    var g = ZoomStopGesture(startScale: 0.7, stops: [half, one, two])
    _ = g.constrain(1.3)
    let further = g.constrain(3.5)   // past the 200 % stop too: still held at 100 %
    #expect(further.scale == 1 && further.hitStop == .percent(100))
    #expect(!g.justHit)              // the hit is reported once, on the way in
}

@Test func reversingLeavesTheStopAtOnceWithoutUnwindingTheOvershoot() {
    var g = ZoomStopGesture(startScale: 0.7, stops: [half, one, two])
    _ = g.constrain(1.3)
    _ = g.constrain(2.0)             // 2× of absorbed overshoot
    let back = g.constrain(1.8)      // 10 % back
    #expect(abs(back.scale - 0.9) < 1e-12 && back.hitStop == nil && !g.justHit)
}

@Test func reversingRunsToTheStopOnTheOtherSideAndClampsThere() {
    var g = ZoomStopGesture(startScale: 0.7, stops: [half, one, two])
    _ = g.constrain(1.3)
    let low = g.constrain(0.4)       // rebased: 0.4 × (1 / 1.3) ≈ 0.31, below 50 %
    #expect(low.scale == 0.5 && low.hitStop == .percent(50) && g.justHit)
    let lower = g.constrain(0.1)
    #expect(lower.scale == 0.5 && lower.hitStop == .percent(50) && !g.justHit)
}

@Test func comingBackToALeftStopHitsItAgain() {
    var g = ZoomStopGesture(startScale: 0.7, stops: [half, one, two])
    _ = g.constrain(1.3)
    _ = g.constrain(1.2)
    #expect(g.constrain(1.4).hitStop == .percent(100) && g.justHit)
}

@Test func aGestureStartingOnAStopPassesItInEitherDirection() {
    var up = ZoomStopGesture(startScale: 1, stops: [half, one, two])
    let passed = up.constrain(1.5)
    #expect(passed.scale == 1.5 && passed.hitStop == nil)
    let next = up.constrain(3)
    #expect(next.scale == 2 && next.hitStop == .percent(200) && up.justHit)

    var down = ZoomStopGesture(startScale: 1, stops: [half, one, two])
    let below = down.constrain(0.8)
    #expect(below.scale == 0.8 && below.hitStop == nil)
    // The start stop stays transparent for the whole gesture, so coming back over it does not stop there.
    #expect(down.constrain(1.4).scale == 1.4)
    let low = down.constrain(0.2)
    #expect(low.scale == 0.5 && low.hitStop == .percent(50))
}

@Test func startingWithinToleranceOfAStopCountsAsOnIt() {
    var g = ZoomStopGesture(startScale: 1.003, stops: [half, one, two])
    #expect(g.constrain(0.9).scale == 0.9)
    var off = ZoomStopGesture(startScale: 1.02, stops: [half, one, two])
    #expect(off.constrain(0.9).scale == 1)
}

@Test func noStopsMeansNoClamping() {
    var g = ZoomStopGesture(startScale: 1, stops: [])
    #expect(g.constrain(10).scale == 10 && g.constrain(10).hitStop == nil)
    #expect(g.constrain(0.01).scale == 0.01)
}

@Test func zoomLimitsAbsorbOvershootWithoutAHit() {
    var g = ZoomStopGesture(startScale: 1, stops: [], limits: 0.1...64)
    let top = g.constrain(100)
    #expect(top.scale == 64 && top.hitStop == nil && !g.justHit)
    #expect(abs(g.constrain(90).scale - 57.6) < 1e-9)   // pinching back zooms out at once
}

@Test func invalidProposedScaleKeepsTheCurrentOne() {
    var g = ZoomStopGesture(startScale: 0.7, stops: [one])
    _ = g.constrain(0.8)
    #expect(g.constrain(.nan).scale == 0.8)
    #expect(g.constrain(0).scale == 0.8)
}

// MARK: Stop scales for a transform

private let tall = ViewTransform(imageSize: CGSize(width: 10502, height: 14000), viewSize: CGSize(width: 6144, height: 3456))

@Test func stopScalesFollowTheTransform() {
    let s = ZoomStops.scales(of: [.fitWidth, .fitHeight, .percent(100)], for: tall)
    #expect(s.map(\.stop) == [.fitHeight, .fitWidth, .percent(100)])   // sorted by scale
    #expect(s[0].scale == tall.withMode(.fitHeight).scale && s[1].scale == tall.withMode(.fitWidth).scale)
    #expect(s[2].scale == 1)
}

@Test func arbitraryPercentStopsAreSorted() {
    let s = ZoomStops.scales(of: [.percent(200), .percent(50), .percent(33.3)], for: tall)
    #expect(s.map(\.stop) == [.percent(33.3), .percent(50), .percent(200)])
    #expect(abs(s[0].scale - 0.333) < 1e-12 && s[1].scale == 0.5 && s[2].scale == 2)
}

@Test func nearEqualStopsMergeIntoTheOneListedFirst() {
    // fit width = 6144 / 6100 ≈ 100.7 %: within 1.5 % of 100 %.
    let t = ViewTransform(imageSize: CGSize(width: 6100, height: 9000), viewSize: CGSize(width: 6144, height: 3456))
    #expect(ZoomStops.scales(of: [.fitWidth, .percent(100)], for: t).map(\.stop) == [.fitWidth])
    #expect(ZoomStops.scales(of: [.percent(100), .fitWidth], for: t).map(\.stop) == [.percent(100)])
    // 2 % apart stays two stops.
    #expect(ZoomStops.scales(of: [.percent(100), .percent(102)], for: t).count == 2)
    // Same aspect as the view: fit width and fit height are one stop.
    let same = ViewTransform(imageSize: CGSize(width: 12288, height: 6912), viewSize: CGSize(width: 6144, height: 3456))
    #expect(ZoomStops.scales(of: [.fitHeight, .fitWidth], for: same).map(\.stop) == [.fitHeight])
    #expect(ZoomStops.scales(of: [.percent(100), .percent(100)], for: same).count == 1)
}

@Test func emptyStopListGivesNoStops() {
    #expect(ZoomStops.scales(of: [], for: tall).isEmpty)
}

@Test func stopsOutsideTheZoomLimitsAreDropped() {
    #expect(ZoomStops.scales(of: [.percent(10000), .percent(1)], for: tall).isEmpty)   // > 64, < fit/4
    #expect(ZoomStops.scales(of: [.percent(6400)], for: tall).map(\.scale) == [64])
    let tiny = ViewTransform(imageSize: CGSize(width: 50, height: 50), viewSize: CGSize(width: 6144, height: 3456))
    #expect(ZoomStops.scales(of: [.fitWidth], for: tiny).isEmpty)                        // 122.88× > 64
}

@Test func noImageGivesNoStops() {
    let empty = ViewTransform(imageSize: .zero, viewSize: CGSize(width: 6144, height: 3456))
    #expect(ZoomStops.scales(of: [.fitWidth, .percent(100)], for: empty).isEmpty)
}

// MARK: Modes

@Test func stopsMapToTheirModes() {
    #expect(ZoomStop.fitWidth.mode == .fitWidth)
    #expect(ZoomStop.fitHeight.mode == .fitHeight)
    #expect(ZoomStop.percent(100).mode == .actual(1))
    #expect(ZoomStop.percent(250).mode == .actual(2.5))
}

/// A gesture landing on a stop stays a free zoom at exactly the stop's scale, the anchor kept: a gesture gives a scale,
/// a key a mode. The stats bar still names the stop.
@Test func zoomingOntoAStopStaysFreeAndKeepsTheAnchor() {
    let t0 = tall.withMode(.actual(0.4))
    let anchor = CGPoint(x: 3000, y: 1700)   // away from the edges, so clamping cannot move it
    let p = t0.imagePoint(forView: anchor)
    // 100 %: the image overflows the view on both axes, so clamping leaves the anchor alone.
    let t = t0.zoomed(toScale: 1, anchor: anchor)
    if case .free = t.mode {} else { Issue.record("expected .free") }
    #expect(abs(t.scale - 1) < 1e-12)
    #expect(StatsLine.modeText(t) == "100 %")
    let back = t.viewPoint(forImage: p)
    #expect(abs(back.x - anchor.x) < 1e-6 && abs(back.y - anchor.y) < 1e-6)
    let w = t0.withMode(.fitWidth).scale
    #expect(StatsLine.modeText(t0.zoomed(toScale: w, anchor: anchor)).hasPrefix("Fit width"))
}

@Test func gestureForATransformUsesItsStopsAndLimits() {
    // Fit = fit height here, so a gesture from Fit starts on that stop and passes it.
    var g = ZoomStopGesture(transform: tall, stops: [.fitWidth, .fitHeight, .percent(100)])
    let fitH = tall.scale, fitW = tall.withMode(.fitWidth).scale
    #expect(g.constrain(fitH * 0.9).hitStop == nil)
    #expect(g.constrain(fitH * 0.01).scale == tall.scaleLimits.lowerBound)
    let r = g.constrain(fitH * 10)
    #expect(r.scale == fitW && r.hitStop == .fitWidth)
}

// MARK: Rounding at a held stop (fix round 1)

/// `rebase = stop / p` then `p × rebase` lands an ulp below the stop for some p; a repeated proposal
/// (pinch `.ended` with magnification 0, a horizontal-only RMB move) or a tiny further step must keep
/// the stop instead of dropping to an anonymous scale and re-hitting it with a second tick.
@Test func aRepeatedOrTinyFurtherProposalKeepsTheHeldStopAbove() {
    for i in 1...400 {
        let p = 1 + Double(i) * 0.00731
        var g = ZoomStopGesture(startScale: 0.7, stops: [half, one, two])
        #expect(g.constrain(p).hitStop == .percent(100) && g.justHit)
        for q in [p, p, p.nextUp] {
            let r = g.constrain(q)
            #expect(r.scale == 1 && r.hitStop == .percent(100) && !g.justHit, "p = \(p), q = \(q)")
        }
    }
}

@Test func aRepeatedOrTinyFurtherProposalKeepsTheHeldStopBelow() {
    for i in 1...400 {
        let p = 0.5 - Double(i) * 0.00097
        var g = ZoomStopGesture(startScale: 0.7, stops: [half, one, two])
        #expect(g.constrain(p).hitStop == .percent(50) && g.justHit)
        for q in [p, p, p.nextDown] {
            let r = g.constrain(q)
            #expect(r.scale == 0.5 && r.hitStop == .percent(50) && !g.justHit, "p = \(p), q = \(q)")
        }
    }
}

@Test func aRepeatedProposalAtALimitStaysExactlyOnIt() {
    for i in 1...200 {
        let p = 64 + Double(i) * 0.731
        var g = ZoomStopGesture(startScale: 1, stops: [], limits: 0.1...64)
        #expect(g.constrain(p).scale == 64)
        #expect(g.constrain(p).scale == 64 && g.constrain(p.nextUp).scale == 64, "p = \(p)")
    }
}

// MARK: Rubber band at the zoom limits (M4b spec §3)

/// A 1000×800 photo in a 2000×1600 view: Fit = 2, limits 0.25 … 64.
private func small(_ mode: ZoomMode) -> ViewTransform {
    ViewTransform(imageSize: CGSize(width: 1000, height: 800), viewSize: CGSize(width: 2000, height: 1600), mode: mode)
}

@Test func rubberStretchesPastTheUpperLimit() {
    var g = ZoomStopGesture(transform: small(.actual(32)), stops: [], rubber: true)
    #expect(g.rubber && g.stretch == 1)
    var r = g.constrain(64)
    #expect(r.scale == 64 && r.hitStop == nil && g.stretch == 1)
    var stretches: [Double] = []
    for p in [80.0, 128, 1e6] {
        r = g.constrain(p)
        #expect(r.scale == 64 && r.hitStop == nil && !g.justHit)
        stretches.append(g.stretch)
    }
    #expect(1 < stretches[0] && stretches[0] < stretches[1] && stretches[1] < stretches[2] && stretches[2] < 1.25)
    #expect(g.stretch == RubberBand.zoomFactor(proposed: 1e6, limit: 64))
    // The way back retraces the stretch exactly (nothing was absorbed), and leaves the limit without a dead zone.
    r = g.constrain(80)
    #expect(r.scale == 64 && g.stretch == stretches[0])
    r = g.constrain(64)
    #expect(r.scale == 64 && g.stretch == 1)
    r = g.constrain(50)
    #expect(r.scale == 50 && g.stretch == 1)
}

@Test func rubberStretchesPastTheLowerLimit() {
    var g = ZoomStopGesture(transform: small(.actual(0.5)), stops: [], rubber: true)
    var r = g.constrain(0.25)
    #expect(r.scale == 0.25 && g.stretch == 1)
    var stretches: [Double] = []
    for p in [0.2, 0.125, 1e-6] {
        r = g.constrain(p)
        #expect(r.scale == 0.25 && r.hitStop == nil)
        stretches.append(g.stretch)
    }
    #expect(1 > stretches[0] && stretches[0] > stretches[1] && stretches[1] > stretches[2] && stretches[2] > 0.8)
    r = g.constrain(0.2)
    #expect(r.scale == 0.25 && g.stretch == stretches[0])
    r = g.constrain(0.25)
    #expect(r.scale == 0.25 && g.stretch == 1)
    r = g.constrain(0.4)
    #expect(r.scale == 0.4 && g.stretch == 1)
}

@Test func withoutRubberTheLimitAbsorbsAsBefore() {
    var g = ZoomStopGesture(transform: small(.actual(32)), stops: [])
    #expect(!g.rubber)
    for p in [64.0, 80, 128] {
        #expect(g.constrain(p).scale == 64 && g.stretch == 1)
    }
    #expect(abs(g.constrain(100).scale - 50) < 1e-12)   // 100 × 64/128: the overshoot was absorbed
    #expect(g.stretch == 1)
}

@Test func rubberStillStopsAtAStopBelowTheLimit() {
    var g = ZoomStopGesture(transform: small(.actual(10)), stops: [.percent(1600)], rubber: true)
    let hit = g.constrain(20)
    #expect(hit.scale == 16 && hit.hitStop == .percent(1600) && g.justHit && g.stretch == 1)
    #expect(g.constrain(200).scale == 16 && g.stretch == 1)   // absorbed by the stop, as before
}

@Test func rubberStretchesPastAStopOnTheLimit() {
    var g = ZoomStopGesture(transform: small(.actual(32)), stops: [.percent(6400)], rubber: true)
    let hit = g.constrain(64)
    #expect(hit.scale == 64 && hit.hitStop == .percent(6400) && g.justHit && g.stretch == 1)
    let past = g.constrain(80)
    #expect(past.scale == 64 && past.hitStop == .percent(6400) && !g.justHit && g.stretch > 1)
    let back = g.constrain(50)
    #expect(back.scale == 50 && back.hitStop == nil && g.stretch == 1)
}

@Test func turningRubberOffDropsTheStretch() {
    var g = ZoomStopGesture(transform: small(.actual(32)), stops: [], rubber: true)
    _ = g.constrain(100)
    #expect(g.stretch > 1)
    g.rubber = false
    #expect(g.stretch == 1)
}
