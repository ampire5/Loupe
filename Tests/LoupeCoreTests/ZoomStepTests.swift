import CoreGraphics
import Testing
@testable import LoupeCore

/// `zoom-step` (M4c spec §12.3): one wheel step of the gesture button's zoom — the keys' √2 step at the pointer, which
/// lands on a `zoom-stops` stop instead of jumping over it, and stops at the zoom limits.
@Suite struct ZoomStepTests {
    /// Fit = fit height = 1/3, fit width = 1/2, limits 1/12 … 64.
    let base = ViewTransform(imageSize: CGSize(width: 4000, height: 3000), viewSize: CGSize(width: 2000, height: 1000))
    let stops: [ZoomStop] = [.fitWidth, .fitHeight, .percent(100)]
    let centre = CGPoint(x: 1000, y: 500)

    func at(_ scale: Double) -> ViewTransform { base.zoomed(toScale: scale, anchor: centre) }

    func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= 1e-9 * max(a, b) }

    @Test func stepsByTheSquareRootOfTwoBetweenStops() {
        let up = base.zoomStepped(up: true, anchor: centre, stops: stops)
        #expect(close(up.transform.scale, 2.0.squareRoot() / 3) && up.bump == nil)
        let down = at(0.8).zoomStepped(up: false, anchor: centre, stops: stops)
        #expect(close(down.transform.scale, 0.8 / 2.0.squareRoot()) && down.bump == nil)
    }

    @Test func landsOnAStopInsteadOfJumpingOverIt() {
        var t = base
        var trail: [(Double, ZoomStepBump?)] = []
        for _ in 0..<4 {
            let r = t.zoomStepped(up: true, anchor: centre, stops: stops)
            t = r.transform
            trail.append((t.scale, r.bump))
        }
        #expect(close(trail[0].0, 2.0.squareRoot() / 3) && trail[0].1 == nil)
        #expect(close(trail[1].0, 0.5) && trail[1].1 == .stop)
        #expect(close(trail[2].0, 0.5 * 2.0.squareRoot()) && trail[2].1 == nil)
        #expect(trail[3].0 == 1 && trail[3].1 == .stop && t.mode == .actual(1))
    }

    @Test func aStopTakesItsModeBothWays() {
        let down = at(0.6).zoomStepped(up: false, anchor: centre, stops: stops)
        #expect(close(down.transform.scale, 0.5) && down.bump == .stop && down.transform.mode == .fitWidth)
        let fit = at(0.4).zoomStepped(up: false, anchor: centre, stops: stops)
        #expect(close(fit.transform.scale, 1.0 / 3) && fit.bump == .stop && fit.transform.mode == .fitHeight)
    }

    @Test func aStartOnAStopLeavesIt() {
        // 0.998 is on 100 % (within ZoomStopGesture.startTolerance): the step goes on to the next √2, not to 100 %.
        let r = at(0.998).zoomStepped(up: true, anchor: centre, stops: stops)
        #expect(close(r.transform.scale, 0.998 * 2.0.squareRoot()) && r.bump == nil)
        let back = at(1.002).zoomStepped(up: false, anchor: centre, stops: stops)
        #expect(close(back.transform.scale, 1.002 / 2.0.squareRoot()) && back.bump == nil)
    }

    @Test func withoutStopsItIsTheKeysStep() {
        let r = base.zoomStepped(up: true, anchor: centre, stops: [])
        #expect(close(r.transform.scale, base.zoomedStep(1).scale) && r.bump == nil)
    }

    @Test func zoomLimitsStopTheStepWithALimitBump() {
        let near = at(50).zoomStepped(up: true, anchor: centre, stops: stops)
        #expect(near.transform.scale == 64 && near.bump == .limit)
        let atMax = near.transform.zoomStepped(up: true, anchor: centre, stops: stops)
        #expect(atMax.transform == near.transform && atMax.bump == .limit)
        let low = at(0.1).zoomStepped(up: false, anchor: centre, stops: stops)
        #expect(close(low.transform.scale, 1.0 / 12) && low.bump == .limit)
        let atMin = low.transform.zoomStepped(up: false, anchor: centre, stops: stops)
        #expect(atMin.transform == low.transform && atMin.bump == .limit)
        // Away from the limit again: an ordinary step.
        #expect(atMax.transform.zoomStepped(up: false, anchor: centre, stops: stops).bump == nil)
    }

    @Test func thePointUnderThePointerStaysPut() {
        let t = at(1.5)
        let pointer = CGPoint(x: 1300, y: 400)
        let before = t.imagePoint(forView: pointer)
        let after = t.zoomStepped(up: true, anchor: pointer, stops: stops).transform.imagePoint(forView: pointer)
        #expect(abs(before.x - after.x) < 1e-6 && abs(before.y - after.y) < 1e-6)
    }
}
