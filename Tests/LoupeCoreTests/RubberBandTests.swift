import Testing
import Foundation
@testable import LoupeCore

@Test func rubberBandZeroAndOdd() {
    #expect(RubberBand.offset(raw: 0, dimension: 1000) == 0)
    for x in [1.0, 37, 400, 3000] {
        #expect(RubberBand.offset(raw: -x, dimension: 1000) == -RubberBand.offset(raw: x, dimension: 1000))
    }
}
@Test func rubberBandIncreasesAndStaysBelowDimension() {
    var prev = RubberBand.offset(raw: 0, dimension: 1000)
    for raw in stride(from: 1.0, through: 10000, by: 1) {
        let o = RubberBand.offset(raw: raw, dimension: 1000)
        #expect(o > prev)
        prev = o
    }
    #expect(RubberBand.offset(raw: 1e9, dimension: 1000) < 1000)
}
@Test func rubberBandSlopeAtZero() {
    let slope = RubberBand.offset(raw: 0.01, dimension: 1000) / 0.01
    #expect(abs(slope - 0.55) < 0.01)
}
@Test func rubberBandRawInverts() {
    for x in [-3000.0, -1, 5, 400, 3000] {
        let back = RubberBand.raw(offset: RubberBand.offset(raw: x, dimension: 1000), dimension: 1000)
        #expect(abs(back - x) < 1e-6 * max(1, abs(x)))
    }
    #expect(RubberBand.raw(offset: 5000, dimension: 1000).isFinite)
    #expect(RubberBand.raw(offset: -5000, dimension: 1000) < 0)
}

@Test func edgeSpringSettlesWithoutOvershoot() {
    var s = EdgeSpring(offset: 80, velocity: 0)
    var t = 0.0
    while t < 0.35 - 1e-9 {
        let o = s.step(dt: 1.0 / 240)
        #expect(o >= 0)
        t += 1.0 / 240
    }
    #expect(abs(s.offset) < 0.8)
}
@Test func edgeSpringPeakFromVelocity() {
    var s = EdgeSpring(offset: 0, velocity: 3000)
    var peak = 0.0, peakT = 0.0, t = 0.0
    for _ in 0..<240 {
        let o = s.step(dt: 1.0 / 1200)
        t += 1.0 / 1200
        if o > peak { peak = o; peakT = t }
    }
    #expect(abs(peak - 3000 / (19 * M_E)) < 1)
    #expect(abs(peakT - 1.0 / 19) < 0.005)
}
@Test func edgeSpringStepSizeIndependent() {
    var a = EdgeSpring(offset: 120, velocity: -400), b = a
    var at = 0.0
    for check in [0.1, 0.2, 0.3] {
        while at < check - 1e-9 { _ = a.step(dt: 1.0 / 60); at += 1.0 / 60 }
        var bt = 0.0
        var bb = EdgeSpring(offset: 120, velocity: -400)
        while bt < check - 1e-9 { _ = bb.step(dt: 1.0 / 120); bt += 1.0 / 120 }
        b = bb
        #expect(abs(a.offset - b.offset) < 0.5)
    }
}
@Test func edgeSpringIsFinished() {
    #expect(EdgeSpring(offset: 0.1, velocity: 2).isFinished)
    #expect(!EdgeSpring(offset: 0.3, velocity: 0).isFinished)
    #expect(!EdgeSpring(offset: 0, velocity: 6).isFinished)
    #expect(!EdgeSpring(offset: -0.3, velocity: 0).isFinished)
}

@Test func zoomFactorIsOneAtTheLimitAndBoundedByAQuarterPast() {
    for limit in [0.1125, 1, 64] {
        #expect(RubberBand.zoomFactor(proposed: limit, limit: limit) == 1)
        var up = 1.0, down = 1.0, k = 1.001
        while k < 1e7 {
            let f = RubberBand.zoomFactor(proposed: limit * k, limit: limit)
            let g = RubberBand.zoomFactor(proposed: limit / k, limit: limit)
            #expect(f > up && f < RubberBand.zoomMaxFactor, "limit \(limit), ×\(k)")
            #expect(g < down && g > 1 / RubberBand.zoomMaxFactor, "limit \(limit), ÷\(k)")
            #expect(abs(f * g - 1) < 1e-12)   // the same resistance in log either way
            up = f
            down = g
            k *= 1.07
        }
    }
    #expect(RubberBand.zoomMaxFactor == 1.25)
    // Slope at the limit: the first part of the overshoot shows at 55 % in log.
    let u = 1e-6
    #expect(abs(log(RubberBand.zoomFactor(proposed: 64 * exp(u), limit: 64)) / u - 0.55) < 1e-3)
}
