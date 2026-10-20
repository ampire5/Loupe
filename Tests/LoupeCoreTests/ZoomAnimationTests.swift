import Testing
import CoreGraphics
import Foundation
@testable import LoupeCore

// A 6000×4000 photo in a 3000×1800 view: Fit = 0.45 (it fits by height, with margins left and right), limits
// 0.1125 … 64.
private let photo = CGSize(width: 6000, height: 4000), view = CGSize(width: 3000, height: 1800)
private func t(_ mode: ZoomMode, _ cx: Double = 0.5, _ cy: Double = 0.5) -> ViewTransform {
    ViewTransform(imageSize: photo, viewSize: view, mode: mode, center: CGPoint(x: cx, y: cy))
}
private let start = 100.0, duration = 0.15

private func anim(_ from: ViewTransform, _ to: ViewTransform) -> ZoomAnimation {
    ZoomAnimation(from: from, to: to, start: start, duration: duration)
}

/// The ten sampled frame times, strictly inside the animation.
private let samples = (0..<10).map { start + duration * (0.05 + 0.1 * Double($0)) }

private func near(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool { abs(a - b) <= tol * max(1, abs(b)) }
private func near(_ a: CGPoint, _ b: CGPoint, _ tol: Double = 1e-6) -> Bool { near(a.x, b.x, tol) && near(a.y, b.y, tol) }

/// Whether `a` draws the picture exactly like `b`: the same drawn scale and image origin.
private func drawsLike(_ a: ViewTransform, _ b: ViewTransform) -> Bool {
    near(a.drawnScale, b.drawnScale, 1e-12) && near(a.viewPoint(forImage: .zero), b.viewPoint(forImage: .zero))
}

/// The view point under which both ends show the same image pixel, and that pixel (s0 ≠ s1).
private func fixedPoint(_ from: ViewTransform, _ to: ViewTransform) -> (view: CGPoint, image: CGPoint) {
    let s0 = from.drawnScale, s1 = to.drawnScale
    let b0 = from.viewPoint(forImage: .zero), b1 = to.viewPoint(forImage: .zero)
    let f = CGPoint(x: (s1 * b0.x - s0 * b1.x) / (s1 - s0), y: (s1 * b0.y - s0 * b1.y) / (s1 - s0))
    return (f, CGPoint(x: (f.x - b0.x) / s0, y: (f.y - b0.y) / s0))
}

/// The four kinds of zoom the brief names: Fit → 100 %, 100 % → Fit, a `+` step and 100 % → 400 % about a cursor.
private let cursor = CGPoint(x: 700, y: 400)
private let cases: [(name: String, from: ViewTransform, to: ViewTransform)] = [
    ("Fit → 100 %", t(.fit, 0.3, 0.7), t(.fit, 0.3, 0.7).withMode(.actual(1))),
    ("100 % → Fit", t(.actual(1), 0.3, 0.7), t(.actual(1), 0.3, 0.7).withMode(.fit)),
    ("+ step", t(.free(0.8 / 0.45), 0.4, 0.6), t(.free(0.8 / 0.45), 0.4, 0.6).zoomedStep(1)),
    ("100 % → 400 % at the cursor", t(.actual(1)), t(.actual(1)).zoomed(toScale: 4, anchor: cursor)),
]

@Test func easeOutIsMonotonicFromZeroToOne() {
    #expect(ZoomAnimation.ease(0) == 0 && ZoomAnimation.ease(1) == 1)
    var prev = 0.0
    for i in 1...1000 {
        let e = ZoomAnimation.ease(Double(i) / 1000)
        #expect(e > prev)
        prev = e
    }
    #expect(near(ZoomAnimation.ease(0.5), 0.875, 1e-15))   // 1 − (1 − t)³
    #expect(ZoomAnimation.ease(-1) == 0 && ZoomAnimation.ease(2) == 1)
}

@Test func endFramesAreTheStartAndTheTarget() {
    for c in cases {
        let a = anim(c.from, c.to)
        #expect(drawsLike(a.transform(at: start), c.from), "\(c.name)")
        #expect(a.transform(at: start + duration) == c.to, "\(c.name)")
        #expect(a.transform(at: start + 5) == c.to, "\(c.name)")
        #expect(!a.isFinished(at: start + duration * 0.99) && a.isFinished(at: start + duration), "\(c.name)")
    }
}

@Test func theFixedPointKeepsItsImagePixelInEveryFrame() {
    for c in cases {
        let a = anim(c.from, c.to), fp = fixedPoint(c.from, c.to)
        for time in samples {
            let frame = a.transform(at: time)
            #expect(near(frame.imagePoint(forView: fp.view), fp.image), "\(c.name) at \(time)")
            if case .free = frame.mode {} else { Issue.record("\(c.name): frame mode \(frame.mode) is not .free") }
            #expect(frame.stretch == nil, "\(c.name)")
        }
    }
    // About the cursor (`Z`, smart zoom), the fixed point is the cursor itself.
    #expect(near(fixedPoint(cases[3].from, cases[3].to).view, cursor))
}

@Test func theScaleGoesInLogAlongTheEaseOut() {
    for c in cases {
        let a = anim(c.from, c.to), s0 = c.from.drawnScale, s1 = c.to.drawnScale
        for time in samples {
            let e = ZoomAnimation.ease((time - start) / duration)
            #expect(near(a.transform(at: time).drawnScale, s0 * pow(s1 / s0, e), 1e-12), "\(c.name)")
        }
    }
}

@Test func visibleRectEdgesMoveMonotonically() {
    for c in cases {
        let a = anim(c.from, c.to)
        let r0 = c.from.visibleRect, r1 = c.to.visibleRect
        var prev = r0
        for time in samples + [start + duration] {
            let r = a.transform(at: time).visibleRect
            for (edge, was, first, last) in [(r.minX, prev.minX, r0.minX, r1.minX), (r.maxX, prev.maxX, r0.maxX, r1.maxX),
                                             (r.minY, prev.minY, r0.minY, r1.minY), (r.maxY, prev.maxY, r0.maxY, r1.maxY)] {
                let dir = last - first
                #expect((edge - was) * dir >= -1e-6, "\(c.name): an edge went back at \(time)")
                #expect(min(first, last) - 1e-6 <= edge && edge <= max(first, last) + 1e-6, "\(c.name): outside the ends")
            }
            prev = r
        }
    }
}

@Test func equalScalesMoveTheCentreLinearly() {
    let from = t(.actual(1), 0.3, 0.3), to = t(.actual(1), 0.6, 0.65)
    let a = anim(from, to)
    let b0 = from.viewPoint(forImage: .zero), b1 = to.viewPoint(forImage: .zero)
    for time in samples {
        let e = ZoomAnimation.ease((time - start) / duration)
        let frame = a.transform(at: time)
        #expect(near(frame.drawnScale, 1, 1e-12))
        #expect(near(frame.viewPoint(forImage: .zero), CGPoint(x: b0.x + (b1.x - b0.x) * e, y: b0.y + (b1.y - b0.y) * e)))
    }
}

@Test func anAnimationToItsOwnStartIsFinishedAtOnce() {
    for from in [t(.fit), t(.actual(1), 0.3, 0.7), t(.actual(1), 0.3, 0.7).withMode(.fitWidth)] {
        let a = anim(from, from)
        #expect(a.isFinished(at: start))
        for time in [start - 1, start] + samples { #expect(a.transform(at: time) == from) }
    }
    // A zero duration (`zoom-animation=0`) is instant too.
    let instant = ZoomAnimation(from: t(.fit), to: t(.actual(1)), start: start, duration: 0)
    #expect(instant.isFinished(at: start) && instant.transform(at: start) == t(.actual(1)))
}

@Test func aTargetClampedAt6400PercentNeverGoesAboveIt() {
    let from = t(.actual(1)).zoomed(toScale: 45.255, anchor: cursor)
    let to = from.zoomedStep(2)          // ×2 asked, 64 given
    #expect(to.scale == 64)
    let a = anim(from, to)
    for time in samples + [start + duration] {
        let frame = a.transform(at: time)
        #expect(frame.stretch == nil && frame.drawnScale <= 64)
    }
}

@Test func aSpringBackFromAStretchEndsExactlyOnTheLimitAboutTheAnchor() {
    let anchor = CGPoint(x: 1100, y: 600)
    let top = t(.actual(1)).zoomed(toScale: 64, anchor: anchor), bottom = t(.fit).withMode(.free(0.25))
    #expect(bottom.scale == bottom.scaleLimits.lowerBound)
    for (limit, factor) in [(top, 1.2), (bottom, 0.8)] {
        let from = limit.withStretch(ZoomStretch(factor: factor, anchor: anchor))
        let a = anim(from, limit)
        #expect(drawsLike(a.transform(at: start), from))
        let pinned = from.imagePoint(forView: anchor)
        var prev = from.drawnScale
        for time in samples {
            let frame = a.transform(at: time)
            #expect(near(frame.imagePoint(forView: anchor), pinned), "factor \(factor) at \(time)")
            let s = frame.drawnScale
            let dir: Double = factor - 1
            let towards: Double = (s - prev) * dir, past: Double = (s - limit.scale) * dir
            #expect(towards < 0 && past > 0)   // on the way back, still past the limit
            prev = s
        }
        let end = a.transform(at: start + duration)
        #expect(end == limit && end.stretch == nil)
    }
}

@Test func aRestartFromTheCurrentFrameIsContinuous() {
    let first = anim(t(.fit, 0.3, 0.7), t(.fit, 0.3, 0.7).withMode(.actual(1)))
    let now = start + duration * 0.4
    let frame = first.transform(at: now)
    let second = ZoomAnimation(from: frame, to: frame.zoomedStep(1), start: now, duration: duration)
    #expect(drawsLike(second.transform(at: now), frame))
}

@Test func settledIsTheCurrentFrameWithoutTheOffset() {
    let a = anim(cases[0].from, cases[0].to)
    for time in samples {
        let frame = a.transform(at: time), settled = a.settled(at: time)
        #expect(settled.offset == .zero && settled.mode == frame.mode && settled.center == frame.center)
    }
    #expect(a.settled(at: start + duration) == cases[0].to)
}

@Test func aStretchedFrameKeepsItsModeWithinTheLimits() {
    let top = t(.actual(1)).zoomed(toScale: 64, anchor: cursor)
    let a = anim(top.withStretch(ZoomStretch(factor: 1.2, anchor: cursor)), top)
    let frame = a.transform(at: samples[3])
    #expect(frame.stretch != nil && frame.scale == 64)
    #expect(frame.withStretch(nil).mode == .free(64 / top.fitScale))
}
