import CoreGraphics
import Testing
@testable import LoupeCore

@Test func renderTuningKeepsSystemDefaultsWithoutEnvironment() {
    #expect(RenderTuning(environment: [:]) == RenderTuning(frameLatency: nil, drawableCount: nil))
}

@Test func renderTuningReadsValidOverrides() {
    let t = RenderTuning(environment: ["LOUPE_FRAME_LATENCY": "1", "LOUPE_DRAWABLES": "2"])
    #expect(t == RenderTuning(frameLatency: 1, drawableCount: 2))
}

@Test func renderTuningIgnoresInvalidOverrides() {
    let t = RenderTuning(environment: ["LOUPE_FRAME_LATENCY": "3", "LOUPE_DRAWABLES": "x"])
    #expect(t == RenderTuning(frameLatency: nil, drawableCount: nil))
    #expect(RenderTuning(environment: ["LOUPE_DRAWABLES": "2"]) == RenderTuning(frameLatency: nil, drawableCount: 2))
}

@Test func autoPanSecondsParsing() {
    #expect(AutoPanPath.seconds(environment: ["LOUPE_AUTOPAN": "10"]) == 10)
    #expect(AutoPanPath.seconds(environment: ["LOUPE_AUTOPAN": "0"]) == nil)
    #expect(AutoPanPath.seconds(environment: ["LOUPE_AUTOPAN": "abc"]) == nil)
    #expect(AutoPanPath.seconds(environment: [:]) == nil)
}

@Test func autoPanScaleParsing() {
    #expect(AutoPanPath.scale(environment: ["LOUPE_AUTOPAN_SCALE": "0.3"]) == 0.3)
    #expect(AutoPanPath.scale(environment: ["LOUPE_AUTOPAN_SCALE": "0"]) == 1)
    #expect(AutoPanPath.scale(environment: ["LOUPE_AUTOPAN_SCALE": "x"]) == 1)
    #expect(AutoPanPath.scale(environment: [:]) == 1)
}

@Test func autoPanPathStartsAtZeroAndStaysWithinAmplitude() {
    let path = AutoPanPath(viewSize: CGSize(width: 1200, height: 600))
    #expect(path.offset(at: 0) == CGVector(dx: 0, dy: 0))
    for i in 0...600 {
        let o = path.offset(at: Double(i) / 60)
        #expect(abs(o.dx) <= 300.0001 && abs(o.dy) <= 100.0001)
    }
    // Smooth: at 120 Hz consecutive offsets differ by at most the peak speed × 1/120 s.
    let step = path.offset(at: 1.0 / 120).dx - path.offset(at: 0).dx
    #expect(step > 0 && step <= 300 * .pi / 120 + 0.001)   // peak speed W/4 · 2π/2 s = π/4 W per second
}

@Test func autoPanModeParsing() {
    #expect(AutoPanPath.mode(environment: [:]) == .pan)
    #expect(AutoPanPath.mode(environment: ["LOUPE_AUTOPAN_MODE": "zoom"]) == .zoom)
    #expect(AutoPanPath.mode(environment: ["LOUPE_AUTOPAN_MODE": "glide"]) == .glide)
    #expect(AutoPanPath.mode(environment: ["LOUPE_AUTOPAN_MODE": "step"]) == .step)
    #expect(AutoPanPath.mode(environment: ["LOUPE_AUTOPAN_MODE": "Zoom"]) == .pan)
}

@Test func autoZoomPathGoesFromLowToHighAndBack() {
    let path = AutoZoomPath(low: 0.5, high: 2)
    #expect(abs(path.scale(at: 0) - 0.5) < 1e-12)
    #expect(abs(path.scale(at: AutoZoomPath.period / 2) - 2) < 1e-12)
    #expect(abs(path.scale(at: AutoZoomPath.period) - 0.5) < 1e-12)
    // Even in log scale: a quarter period is the geometric mean, 1.
    #expect(abs(path.scale(at: AutoZoomPath.period / 4) - 1) < 1e-12)
    for i in 0...400 {
        let s = path.scale(at: Double(i) / 100)
        #expect(s >= 0.5 - 1e-12 && s <= 2 + 1e-12)
    }
}
