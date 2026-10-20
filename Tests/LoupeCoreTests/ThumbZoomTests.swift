import CoreGraphics
import Testing
@testable import LoupeCore

/// `thumb-wheel-zoom`: the MX Master's thumb wheel with no button held zooms smoothly; `thumb-zoom-stops` says whether
/// a stop only ticks (`tick`) or halts one turn of the wheel (`halt`).
@Suite struct ThumbZoomTests {
    /// Fit = fit height = 1/3, fit width = 1/2, limits 1/12 … 64.
    let base = ViewTransform(imageSize: CGSize(width: 4000, height: 3000), viewSize: CGSize(width: 2000, height: 1000))
    let stops: [ZoomStop] = [.fitWidth, .fitHeight, .percent(100)]
    let centre = CGPoint(x: 1000, y: 500)

    func at(_ scale: Double) -> ViewTransform { base.zoomed(toScale: scale, anchor: centre) }

    func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= 1e-9 * max(a, b) }

    @Test func doublingsPerTurnScaleTheDelta() {
        #expect(ThumbZoom.doublings(delta: 18, stepsPerRevolution: 18, speed: 2) == 2)
        #expect(ThumbZoom.doublings(delta: -9, stepsPerRevolution: 18, speed: 2) == -1)
        #expect(ThumbZoom.doublings(delta: 5, stepsPerRevolution: 0, speed: 2) == 0)
    }

    @Test func tickGoesThroughAStopAndTicksOnce() {
        var z = ThumbZoom(transform: at(0.4), stops: stops, mode: .tick)
        let a = z.turn(doublings: 0.5)   // 0.4 → 0.566: over fit width (0.5)
        #expect(close(a.scale, 0.4 * pow(2, 0.5)) && a.stop == nil && a.bump == .stop)
        let b = z.turn(doublings: 0.1)
        #expect(b.bump == nil)
        let c = z.turn(doublings: -0.6)  // back over it
        #expect(close(c.scale, 0.4) && c.bump == .stop)
    }

    @Test func tickLeavesAStopItRestsOnWithoutATick() {
        var z = ThumbZoom(transform: at(1), stops: stops, mode: .tick)
        #expect(z.turn(doublings: 0.2).bump == nil)
        var down = ThumbZoom(transform: at(1), stops: stops, mode: .tick)
        #expect(down.turn(doublings: -0.2).bump == nil)
    }

    @Test func haltStopsOnEachStopForTheTurn() {
        var z = ThumbZoom(transform: at(0.4), stops: stops, mode: .halt)
        let a = z.turn(doublings: 0.5)
        #expect(close(a.scale, 0.5) && a.stop == .fitWidth && a.bump == .stop)
        let b = z.turn(doublings: 1)     // absorbed: the turn stays on the stop
        #expect(close(b.scale, 0.5) && b.bump == nil)
        let c = z.turn(doublings: -0.2)  // turning back leaves it at once
        #expect(close(c.scale, 0.5 * pow(2, -0.2)) && c.stop == nil)
        // A new turn from the stop passes it.
        var next = ThumbZoom(transform: at(0.5), stops: stops, mode: .halt)
        #expect(close(next.turn(doublings: 0.5).scale, 0.5 * pow(2, 0.5)))
    }

    @Test func aLimitBumpsOnceAndTurningBackZoomsAtOnce() {
        for mode in ThumbZoomStops.allCases {
            var z = ThumbZoom(transform: at(50), stops: stops, mode: mode)
            let a = z.turn(doublings: 1)
            #expect(a.scale == 64 && a.bump == .limit)
            #expect(z.turn(doublings: 1).bump == nil)
            let back = z.turn(doublings: -1)
            #expect(close(back.scale, 32) && back.bump == nil)
        }
    }

    @Test func aLimitBeatsAStopInTheSameStep() {
        var z = ThumbZoom(transform: at(0.2), stops: [.fitHeight], mode: .tick)
        // 0.2 → under 1/12: crosses nothing, reaches the lower limit.
        #expect(z.turn(doublings: -2).bump == .limit)
        var up = ThumbZoom(transform: at(0.9), stops: [.percent(100)], mode: .tick)
        #expect(up.turn(doublings: 20).bump == .limit)
    }

    @Test func noTurnChangesNothing() {
        var z = ThumbZoom(transform: at(0.4), stops: stops, mode: .tick)
        let r = z.turn(doublings: 0)
        #expect(close(r.scale, 0.4) && r.bump == nil)
    }
}
