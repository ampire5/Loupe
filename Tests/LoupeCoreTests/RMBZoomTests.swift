import Testing
import CoreGraphics
@testable import LoupeCore

private let imgSize = CGSize(width: 10502, height: 14000), viewSz = CGSize(width: 6144, height: 3456)
private func start(_ mode: ZoomMode = .actual(1)) -> ViewTransform {
    ViewTransform(imageSize: imgSize, viewSize: viewSz, mode: mode, center: CGPoint(x: 0.4, y: 0.6))
}
private let anchor = CGPoint(x: 1500, y: 900)

@Test func rmbUpTwoHundredPointsDoublesScale() {
    let z = RMBZoom(anchor: anchor, transform: start(), pointsPerDoubling: RMBZoom.pointsPerDoubling)
    #expect(abs(z.transform(dyPoints: -200).scale - 2) < 1e-9)
}

@Test func rmbDownTwoHundredPointsHalvesScale() {
    let z = RMBZoom(anchor: anchor, transform: start(), pointsPerDoubling: RMBZoom.pointsPerDoubling)
    #expect(abs(z.transform(dyPoints: 200).scale - 0.5) < 1e-9)
}

@Test func invertedDownZoomsIn() {
    let ppd = RMBZoom.pointsPerDoubling
    let inv = RMBZoom(anchor: anchor, transform: start(), pointsPerDoubling: ppd, inverted: true)
    #expect(abs(inv.transform(dyPoints: 200).scale - 2) < 1e-9)
    #expect(abs(inv.transform(dyPoints: -200).scale - 0.5) < 1e-9)
    #expect(inv.doublings(dyPoints: 100) == 0.5)
    let plain = RMBZoom(anchor: anchor, transform: start(), pointsPerDoubling: ppd)
    #expect(abs(plain.transform(dyPoints: 200).scale - 0.5) < 1e-9)
    #expect(plain.doublings(dyPoints: 100) == -0.5)
}

@Test func rmbIsExponentialFromTheStartScale() {
    let z = RMBZoom(anchor: anchor, transform: start(.actual(3)), pointsPerDoubling: RMBZoom.pointsPerDoubling)
    #expect(abs(z.transform(dyPoints: -100).scale - 3 * 2.0.squareRoot()) < 1e-9)
    #expect(abs(z.transform(dyPoints: -400).scale - 12) < 1e-9)
}

@Test func rmbKeepsImagePointUnderAnchor() {
    let t0 = start()
    let z = RMBZoom(anchor: anchor, transform: t0, pointsPerDoubling: RMBZoom.pointsPerDoubling)
    let p = t0.imagePoint(forView: anchor)
    for dy in [-300.0, -120.0, 50.0, 150.0] {
        let t = z.transform(dyPoints: dy)
        let back = t.viewPoint(forImage: p)
        #expect(abs(back.x - anchor.x) < 1e-6 && abs(back.y - anchor.y) < 1e-6)
    }
}

@Test func rmbZeroMovementKeepsTheView() {
    let t0 = start()
    let t = RMBZoom(anchor: anchor, transform: t0, pointsPerDoubling: RMBZoom.pointsPerDoubling).transform(dyPoints: 0)
    #expect(abs(t.scale - t0.scale) < 1e-12)
    #expect(abs(t.center.x - t0.clamped.center.x) < 1e-12 && abs(t.center.y - t0.clamped.center.y) < 1e-12)
}

@Test func rmbDraggingBackReturnsToTheStart() {
    let t0 = start()
    let z = RMBZoom(anchor: anchor, transform: t0, pointsPerDoubling: RMBZoom.pointsPerDoubling)
    _ = z.transform(dyPoints: -137)
    let t = z.transform(dyPoints: 0)   // cumulative, so no drift from the detour
    #expect(abs(t.scale - t0.scale) < 1e-12)
}

@Test func rmbRespectsZoomLimits() {
    let z = RMBZoom(anchor: anchor, transform: start(), pointsPerDoubling: RMBZoom.pointsPerDoubling)
    #expect(z.transform(dyPoints: -5000).scale == 64)
    let lo = min(start().fitScale, 1) * 0.25
    #expect(abs(z.transform(dyPoints: 5000).scale - lo) < 1e-12)
}

@Test func rmbScaleFormula() {
    let one = RMBZoom(anchor: anchor, transform: start(.actual(1)), pointsPerDoubling: RMBZoom.pointsPerDoubling)
    let four = RMBZoom(anchor: anchor, transform: start(.actual(4)), pointsPerDoubling: RMBZoom.pointsPerDoubling)
    #expect(one.scale(dyPoints: -200) == 2)
    #expect(four.scale(dyPoints: 200) == 2)
    #expect(one.scale(dyPoints: 0) == 1)
    #expect(one.scale(doublings: -1) == 0.5)
    // Inverted: the same travel the other way, through the same exponential.
    let inv = RMBZoom(anchor: anchor, transform: start(.actual(1)), pointsPerDoubling: RMBZoom.pointsPerDoubling,
                      inverted: true)
    #expect(inv.scale(dyPoints: 200) == 2)
    #expect(inv.scale(dyPoints: -200) == 0.5)
}

/// A drag halting on 100 % keeps the anchor and stays a free zoom at exactly 100 % (a gesture gives a scale, not a mode).
@Test func rmbTransformToAStopScaleKeepsTheAnchorAndStaysFree() {
    let t0 = start(.actual(0.4))
    let mid = CGPoint(x: 3000, y: 1700)
    let z = RMBZoom(anchor: mid, transform: t0, pointsPerDoubling: RMBZoom.pointsPerDoubling)
    let p = t0.imagePoint(forView: mid)
    let t = z.transform(toScale: 1)
    #expect(t.mode == .free(1 / t0.fitScale) && abs(t.scale - 1) < 1e-12)
    let back = t.viewPoint(forImage: p)
    #expect(abs(back.x - mid.x) < 1e-6 && abs(back.y - mid.y) < 1e-6)
    #expect(abs(z.transform(toScale: 2).scale - z.transform(dyPoints: -200 * log2(2 / 0.4)).scale) < 1e-12)
}

@Test func speedScalesTravelPerDoubling() {
    // Speed 2 halves the travel per doubling: 100 pt double the scale, and 200 pt quadruple it.
    #expect(RMBZoom.pointsPerDoubling(speed: 2) == 100)
    #expect(RMBZoom.pointsPerDoubling(speed: 1) == RMBZoom.pointsPerDoubling)
    #expect(abs(RMBZoom.pointsPerDoubling(speed: 1.5) - 200 / 1.5) < 1e-12)
    let z = RMBZoom(anchor: anchor, transform: start(), pointsPerDoubling: 100)
    #expect(z.scale(dyPoints: -100) == 2)
    #expect(z.scale(dyPoints: -200) == 4)
    #expect(abs(z.transform(dyPoints: -100).scale - 2) < 1e-9)
    #expect(abs(z.transform(dyPoints: 100).scale - 0.5) < 1e-9)
}
