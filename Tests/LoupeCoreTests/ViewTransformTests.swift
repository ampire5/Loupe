import Testing
import Foundation
@testable import LoupeCore

private let img = CGSize(width: 10502, height: 14000), view = CGSize(width: 6144, height: 3456)

@Test func fitScale() { #expect(abs(ViewTransform(imageSize: img, viewSize: view).scale - 3456.0/14000) < 1e-9) }
@Test func fillScale() { #expect(abs(ViewTransform(imageSize: img, viewSize: view, mode: .fill).scale - 6144.0/10502) < 1e-9) }
@Test func actualCentreVisibleRect() {
    let t = ViewTransform(imageSize: img, viewSize: view, mode: .actual(1))
    #expect(t.visibleRect == CGRect(x: (10502 - 6144) / 2.0, y: (14000 - 3456) / 2.0, width: 6144, height: 3456))
}
@Test func roundTripPoints() {
    let t = ViewTransform(imageSize: img, viewSize: view, mode: .actual(2), center: CGPoint(x: 0.3, y: 0.7)).clamped
    let p = CGPoint(x: 1234, y: 567)
    let back = t.imagePoint(forView: t.viewPoint(forImage: p))
    #expect(abs(back.x - p.x) < 1e-6 && abs(back.y - p.y) < 1e-6)
}
@Test func zoomKeepsAnchor() {
    let t = ViewTransform(imageSize: img, viewSize: view, mode: .actual(1))
    let anchor = CGPoint(x: 1000, y: 800), before = t.imagePoint(forView: anchor)
    let z = t.zoomed(toScale: 2, anchor: anchor), after = z.imagePoint(forView: anchor)
    #expect(abs(after.x - before.x) < 1e-6 && abs(after.y - before.y) < 1e-6)
    #expect(z.mode == .free(2 / t.fitScale))
}
@Test func panClampsAtEdge() {
    let t = ViewTransform(imageSize: img, viewSize: view, mode: .actual(1)).panned(by: CGVector(dx: 1e6, dy: 0))
    #expect(abs(t.visibleRect.minX) < 1e-6)       // content moved right as far as it can: left edge at the view's left
}
@Test func panMovesContentWithDelta() {
    let t = ViewTransform(imageSize: img, viewSize: view, mode: .actual(1))
    let p = t.panned(by: CGVector(dx: 100, dy: -50))
    #expect(abs(p.visibleRect.minX - (t.visibleRect.minX - 100)) < 1e-6 && abs(p.visibleRect.minY - (t.visibleRect.minY + 50)) < 1e-6)
}
@Test func smallImageCentred() {      // Review Focus: tiny image, smaller than the view
    let t = ViewTransform(imageSize: CGSize(width: 300, height: 200), viewSize: view, mode: .actual(1), center: CGPoint(x: 0.1, y: 0.9)).clamped
    #expect(t.center == CGPoint(x: 0.5, y: 0.5))
    #expect(ViewTransform(imageSize: CGSize(width: 300, height: 200), viewSize: view).scale == 3456.0 / 200)   // fit upscales
}
@Test func zoomLimits() {
    let t = ViewTransform(imageSize: img, viewSize: view)
    #expect(t.zoomed(toScale: 1000, anchor: .zero).scale == 64)
    #expect(abs(t.zoomed(toScale: 1e-6, anchor: .zero).scale - t.fitScale * 0.25) < 1e-12)
}
@Test func nextPhotoKeepsModeAndRelativeCenter() {
    let t = ViewTransform(imageSize: img, viewSize: view, mode: .actual(1), center: CGPoint(x: 0.6, y: 0.2)).clamped
    let n = t.withImageSize(CGSize(width: 13468, height: 10100))
    #expect(n.mode == .actual(1) && n.center == CGPoint(x: 0.6, y: 0.2))
}
@Test func nextPhotoClampsCenterToNewImage() {
    // x = 0.8 is out of range already for the first image (max 1 - 3072/10502); the displayed centre is clamped,
    // the stored (desired) centre is preserved.
    let t = ViewTransform(imageSize: img, viewSize: view, mode: .actual(1), center: CGPoint(x: 0.8, y: 0.2))
    #expect(abs(t.clamped.center.x - (1 - 3072.0 / 10502)) < 1e-12)
    let n = t.withImageSize(CGSize(width: 13468, height: 10100))
    #expect(n.center == CGPoint(x: 0.8, y: 0.2))
    #expect(abs(n.clamped.center.x - (1 - 3072.0 / 13468)) < 1e-12)
}
@Test func centreSurvivesSmallPhotoRoundTrip() {      // spec §7: stored centre is the desired position
    let big = ViewTransform(imageSize: img, viewSize: view, mode: .actual(1), center: CGPoint(x: 0.6, y: 0.6))
    let small = big.withImageSize(CGSize(width: 300, height: 200))
    #expect(small.clamped.center == CGPoint(x: 0.5, y: 0.5))
    #expect(small.withImageSize(img).center == CGPoint(x: 0.6, y: 0.6))
}
@Test func fitWidthAndHeightScale() {
    #expect(abs(ViewTransform(imageSize: img, viewSize: view, mode: .fitWidth).scale - 6144.0 / 10502) < 1e-12)
    #expect(abs(ViewTransform(imageSize: img, viewSize: view, mode: .fitHeight).scale - 3456.0 / 14000) < 1e-12)
}
@Test func freeScaleIsRelativeToFit() {
    let t = ViewTransform(imageSize: img, viewSize: view, mode: .free(3))
    #expect(abs(t.scale - 3 * t.fitScale) < 1e-12)
}
@Test func panClampsAtAllEdges() {
    let t = ViewTransform(imageSize: img, viewSize: view, mode: .actual(1))
    #expect(abs(t.panned(by: CGVector(dx: 0, dy: 1e6)).visibleRect.minY) < 1e-6)                  // top
    #expect(abs(t.panned(by: CGVector(dx: -1e6, dy: 0)).visibleRect.maxX - 10502) < 1e-6)        // right
    #expect(abs(t.panned(by: CGVector(dx: 0, dy: -1e6)).visibleRect.maxY - 14000) < 1e-6)        // bottom
}
@Test func oneAxisFitsOtherDoesNot() {
    let t = ViewTransform(imageSize: CGSize(width: 3000, height: 14000), viewSize: view, mode: .actual(1), center: CGPoint(x: 0.1, y: 0.1)).clamped
    #expect(t.center.x == 0.5)
    #expect(abs(t.center.y - 1728.0 / 14000) < 1e-12)
}
@Test func withModeKeepsCentre() {
    let t = ViewTransform(imageSize: img, viewSize: view, mode: .actual(1), center: CGPoint(x: 0.3, y: 0.6))
    let f = t.withMode(.fit)
    #expect(f.mode == .fit && f.center == CGPoint(x: 0.3, y: 0.6))
    #expect(f.clamped.center == CGPoint(x: 0.5, y: 0.5))     // whole image visible: displayed centred
    #expect(f.withMode(.actual(1)).center == CGPoint(x: 0.3, y: 0.6))
}
@Test func withViewSizeKeepsModeAndCentre() {
    let t = ViewTransform(imageSize: img, viewSize: view, mode: .actual(1), center: CGPoint(x: 0.3, y: 0.6))
    let r = t.withViewSize(CGSize(width: 3000, height: 2000))
    #expect(r.viewSize == CGSize(width: 3000, height: 2000) && r.mode == .actual(1) && r.center == CGPoint(x: 0.3, y: 0.6))
    #expect(r.visibleRect.size == CGSize(width: 3000, height: 2000))
    let f = ViewTransform(imageSize: img, viewSize: view).withViewSize(CGSize(width: 3000, height: 2000))
    #expect(abs(f.scale - 2000.0 / 14000) < 1e-12)
}
@Test func degenerateViewSizeStaysFinite() {
    for v in [CGSize.zero, CGSize(width: 0, height: 500), CGSize(width: 500, height: 0), CGSize(width: -3, height: -3)] {
        for m in [ZoomMode.fit, .fitWidth, .fitHeight, .fill, .actual(1), .free(2)] {
            let t = ViewTransform(imageSize: img, viewSize: v, mode: m)
            let z = t.zoomed(toScale: 2, anchor: CGPoint(x: 10, y: 10))
            let p = t.panned(by: CGVector(dx: 5, dy: 5))
            let ip = t.imagePoint(forView: CGPoint(x: 10, y: 10)), vp = t.viewPoint(forImage: CGPoint(x: 10, y: 10))
            let r = t.visibleRect
            var all = [t.fitScale, t.scale, z.scale, z.center.x, z.center.y, p.center.x, p.center.y,
                       ip.x, ip.y, vp.x, vp.y, r.minX, r.minY, r.width, r.height]
            if case .free(let f) = z.mode { all.append(f) }
            #expect(all.allSatisfy { $0.isFinite }, "view \(v) mode \(m)")
            #expect(t.scale > 0)
        }
    }
    // an empty image must not produce NaN either
    let e = ViewTransform(imageSize: .zero, viewSize: view, mode: .actual(1)).zoomed(toScale: 2, anchor: .zero)
    #expect(e.center.x.isFinite && e.center.y.isFinite && e.scale.isFinite)
}

// MARK: Keyboard zoom and pan (Task 11d)

@Test func zoomStepUpDown() {
    let t = ViewTransform(imageSize: img, viewSize: view, mode: .actual(1))
    let up = t.zoomedStep(1).zoomedStep(1)
    #expect(abs(up.scale - 2) < 1e-9)
    if case .free = up.mode {} else { Issue.record("zoomedStep must produce a .free mode") }
    let down = up.zoomedStep(-1).zoomedStep(-1)
    #expect(abs(down.scale - 1) < 1e-9)
}

@Test func zoomStepAboutViewCentre() {
    let t = ViewTransform(imageSize: img, viewSize: view, mode: .actual(1), center: CGPoint(x: 0.3, y: 0.6))
    let c = CGPoint(x: view.width / 2, y: view.height / 2)
    let before = t.imagePoint(forView: c), after = t.zoomedStep(3).imagePoint(forView: c)
    #expect(abs(after.x - before.x) < 1e-6 && abs(after.y - before.y) < 1e-6)
}

@Test func zoomStepClamped() {
    let top = ViewTransform(imageSize: img, viewSize: view, mode: .actual(64))
    #expect(top.zoomedStep(1).scale == 64)
    #expect(top.zoomedStep(1).visibleRect == top.visibleRect)
    let bottom = ViewTransform(imageSize: img, viewSize: view, mode: .free(0.25))
    #expect(bottom.zoomedStep(-1).scale == bottom.scaleLimits.lowerBound)
    #expect(top.zoomedStep(0).scale == 64)
}

@Test func panByViewFraction() {
    let t = ViewTransform(imageSize: img, viewSize: view, mode: .actual(2))
    let p = t.pannedByViewFraction(dx: 0.1, dy: -0.1)
    // The visible rect moves right by 10 % of the view width (in image px at scale 2), and up for negative dy.
    #expect(abs(p.visibleRect.minX - (t.visibleRect.minX + 0.1 * view.width / 2)) < 1e-6)
    #expect(abs(p.visibleRect.minY - (t.visibleRect.minY - 0.1 * view.height / 2)) < 1e-6)
    // Clamped like any pan.
    let far = t.pannedByViewFraction(dx: -1000, dy: 0)
    #expect(abs(far.visibleRect.minX) < 1e-6)
}

@Test func toggleFitActualAnchored() {
    let t = ViewTransform(imageSize: img, viewSize: view)
    // On the image (fit shows it as a 2592 px wide strip centred in the view): off the image the centre clamp would move it.
    let anchor = CGPoint(x: 2500, y: 700), before = t.imagePoint(forView: anchor)
    let a = t.toggledFitActual(anchor: anchor)
    #expect(a.mode == .actual(1))
    let after = a.imagePoint(forView: anchor)
    #expect(abs(after.x - before.x) < 1e-6 && abs(after.y - before.y) < 1e-6)
    #expect(a.toggledFitActual(anchor: anchor).mode == .fit)
    // From another mode (here .free) it also goes to 100 %.
    #expect(t.zoomedStep(2).toggledFitActual(anchor: anchor).mode == .actual(1))
}

@Test func canPanOnlyWhenTheImageOverflowsTheView() {
    #expect(!ViewTransform(imageSize: img, viewSize: view).canPan)
    #expect(ViewTransform(imageSize: img, viewSize: view, mode: .fitWidth).canPan)
    #expect(ViewTransform(imageSize: img, viewSize: view, mode: .actual(1)).canPan)
    // A small image at 100 % fits on both axes.
    #expect(!ViewTransform(imageSize: CGSize(width: 800, height: 600), viewSize: view, mode: .actual(1)).canPan)
}

/// Review focus 4: `exif-orientation` toggled live while zoomed: the photo's laid-out size swaps, the zoom mode stays
/// and the centre goes back to the middle (the old relative centre names another spot of the turned picture).
@Test func reorientedKeepsMode() {
    let turned = CGSize(width: img.height, height: img.width)
    for mode in [ZoomMode.fit, .fitWidth, .fitHeight, .fill, .actual(2), .free(3)] {
        let t = ViewTransform(imageSize: img, viewSize: view, mode: mode, center: CGPoint(x: 0.8, y: 0.1))
        let r = t.reoriented(to: turned)
        #expect(r == ViewTransform(imageSize: turned, viewSize: view, mode: mode, center: CGPoint(x: 0.5, y: 0.5)), "\(mode)")
    }
    // 100 % stays 100 %, and a free zoom keeps its ratio to fit (so its scale follows the new fit).
    let actual = ViewTransform(imageSize: img, viewSize: view, mode: .actual(1)).reoriented(to: turned)
    #expect(actual.scale == 1)
    let free = ViewTransform(imageSize: img, viewSize: view, mode: .free(2)).reoriented(to: turned)
    #expect(abs(free.scale - 2 * free.fitScale) < 1e-12)
}

@Test func offsetShiftsGeometry() {
    let t = ViewTransform(imageSize: img, viewSize: view, mode: .actual(2), center: CGPoint(x: 0.3, y: 0.7))
    let o = t.withOffset(CGVector(dx: 30, dy: -20))
    let p = CGPoint(x: 1234, y: 567)
    let a = t.viewPoint(forImage: p), b = o.viewPoint(forImage: p)
    #expect(abs(b.x - (a.x + 30)) < 1e-9 && abs(b.y - (a.y - 20)) < 1e-9)
    let back = o.imagePoint(forView: b)
    #expect(abs(back.x - p.x) < 1e-6 && abs(back.y - p.y) < 1e-6)
    let s = t.scale
    #expect(abs(o.visibleRect.origin.x - (t.visibleRect.origin.x - 30 / s)) < 1e-9)
    #expect(abs(o.visibleRect.origin.y - (t.visibleRect.origin.y + 20 / s)) < 1e-9)
    #expect(o.visibleRect.size == t.visibleRect.size)
    #expect(o.clamped.offset == o.offset)
}
@Test func operationsDropOffset() {
    let t = ViewTransform(imageSize: img, viewSize: view, mode: .actual(1), center: CGPoint(x: 0.4, y: 0.4))
        .withOffset(CGVector(dx: 30, dy: 0))
    let anchor = CGPoint(x: 100, y: 100)
    let results: [ViewTransform] = [
        t.zoomed(toScale: 2, anchor: anchor), t.panned(by: CGVector(dx: 5, dy: 5)), t.withMode(.fit),
        t.withImageSize(CGSize(width: 100, height: 100)), t.withViewSize(CGSize(width: 800, height: 600)),
        t.reoriented(to: CGSize(width: 10, height: 20)), t.toggledFitActual(anchor: anchor), t.zoomedStep(1),
        t.pannedByViewFraction(dx: 0.1, dy: 0),
    ]
    for r in results { #expect(r.offset == .zero) }
    #expect(t.offset == CGVector(dx: 30, dy: 0))
}
@Test func pannableAxesAndCanPan() {
    let fit = ViewTransform(imageSize: CGSize(width: 4000, height: 3000), viewSize: CGSize(width: 1000, height: 2000))
    #expect(fit.pannableAxes.x == false && fit.pannableAxes.y == false)
    #expect(!fit.canPan)
    let full = ViewTransform(imageSize: CGSize(width: 4000, height: 3000), viewSize: CGSize(width: 1000, height: 1000), mode: .actual(1))
    #expect(full.pannableAxes.x && full.pannableAxes.y)
    let wide = ViewTransform(imageSize: CGSize(width: 4000, height: 300), viewSize: CGSize(width: 1000, height: 1000), mode: .actual(1))
    #expect(wide.pannableAxes.x && !wide.pannableAxes.y)
    #expect(wide.canPan)
}
@Test func panLeftoverAtEdgeAndInMiddle() {
    let size = CGSize(width: 4000, height: 3000), vs = CGSize(width: 1000, height: 1000)
    let left = ViewTransform(imageSize: size, viewSize: vs, mode: .actual(1), center: CGPoint(x: 0, y: 0.5))
    let l = left.panLeftover(CGVector(dx: 500, dy: 0))
    #expect(abs(l.dx - 500) < 1e-6 && abs(l.dy) < 1e-6)
    let mid = ViewTransform(imageSize: size, viewSize: vs, mode: .actual(1))
    let m = mid.panLeftover(CGVector(dx: 500, dy: 0))
    #expect(abs(m.dx) < 1e-6 && abs(m.dy) < 1e-6)
    // partly applied: 300 px of room to the edge, 500 asked
    let near = ViewTransform(imageSize: size, viewSize: vs, mode: .actual(1), center: CGPoint(x: 0.125 + 300.0 / 4000, y: 0.5))
    let n = near.panLeftover(CGVector(dx: 500, dy: 0))
    #expect(abs(n.dx - 200) < 1e-6)
    // an axis that fits cannot move: the whole delta is left over; offset does not matter
    let fit = ViewTransform(imageSize: CGSize(width: 4000, height: 3000), viewSize: CGSize(width: 1000, height: 2000))
        .withOffset(CGVector(dx: 9, dy: 9))
    #expect(fit.panLeftover(CGVector(dx: 7, dy: -3)) == CGVector(dx: 7, dy: -3))
}

// MARK: fit-upscale and the zoom stretch (M4b spec §3, §4.3)

@Test func fitUpscaleOffKeepsSmallImagesAt100() {
    let view = CGSize(width: 1600, height: 1200)
    let small = ViewTransform(imageSize: CGSize(width: 400, height: 300), viewSize: view, fitUpscale: false)
    #expect(small.fitScale == 1)
    #expect(small.scale == 1)
    #expect(small.withMode(.free(2)).scale == 2)
    #expect(small.withMode(.fitWidth).scale == 4)
    #expect(small.scaleLimits.lowerBound == 0.25)
    // on: the same photo is enlarged to the view
    #expect(ViewTransform(imageSize: small.imageSize, viewSize: view).fitScale == 4)
    // a photo larger than the view fits the same way with the flag on or off
    let big = CGSize(width: 6000, height: 4000)
    #expect(ViewTransform(imageSize: big, viewSize: view, fitUpscale: false).fitScale
            == ViewTransform(imageSize: big, viewSize: view).fitScale)
}

@Test func withFitUpscaleKeepsAFreeZoomsScale() {
    let view = CGSize(width: 1600, height: 1200)
    let small = ViewTransform(imageSize: CGSize(width: 400, height: 300), viewSize: view, center: CGPoint(x: 0.3, y: 0.6))
    let zoomed = small.withMode(.free(3 / small.fitScale))   // 300 % with the flag on (fit 400 %)
    #expect(abs(zoomed.scale - 3) < 1e-12)
    let off = zoomed.withFitUpscale(false)
    #expect(!off.fitUpscale && abs(off.scale - 3) < 1e-12 && off.center == zoomed.center)
    let back = off.withFitUpscale(true)
    #expect(back.fitUpscale && abs(back.scale - 3) < 1e-12)
    // the named modes keep their meaning: Fit goes 400 % -> 100 %, the others do not depend on the flag
    #expect(small.withFitUpscale(false).mode == .fit && small.withFitUpscale(false).scale == 1)
    for mode in [ZoomMode.fitWidth, .fitHeight, .fill, .actual(2)] {
        let t = small.withMode(mode).withFitUpscale(false)
        #expect(t.mode == mode && t.scale == small.withMode(mode).scale, "\(mode)")
    }
    // a photo larger than the view: Fit is the same either way, so is a free zoom
    let big = ViewTransform(imageSize: CGSize(width: 6000, height: 4000), viewSize: view, mode: .free(1.7))
    #expect(big.withFitUpscale(false).mode == .free(1.7))
}

@Test func flagSurvivesOperations() {
    let t = ViewTransform(imageSize: CGSize(width: 400, height: 300), viewSize: CGSize(width: 800, height: 600),
                          fitUpscale: false)
    let a = CGPoint(x: 100, y: 100)
    #expect(!t.withImageSize(CGSize(width: 10, height: 10)).fitUpscale)
    #expect(!t.withViewSize(CGSize(width: 10, height: 10)).fitUpscale)
    #expect(!t.zoomed(toScale: 2, anchor: a).fitUpscale)
    #expect(!t.panned(by: CGVector(dx: 5, dy: 5)).fitUpscale)
    #expect(!t.withMode(.fill).fitUpscale)
    #expect(!t.reoriented(to: CGSize(width: 300, height: 400)).fitUpscale)
    #expect(!t.zoomedStep(1).fitUpscale)
    #expect(!t.withStretch(ZoomStretch(factor: 1.1, anchor: a)).fitUpscale)
    #expect(!t.withOffset(CGVector(dx: 1, dy: 1)).fitUpscale)
    #expect(!ViewTransform(imageSize: t.imageSize, viewSize: t.viewSize).withFitUpscale(false).fitUpscale)
}

@Test func stretchKeepsAnchorAndScalesAroundIt() {
    let base = ViewTransform(imageSize: CGSize(width: 1000, height: 800), viewSize: CGSize(width: 800, height: 600),
                             mode: .actual(64), center: CGPoint(x: 0.4, y: 0.6))
    #expect(base.scale == 64)
    let anchor = CGPoint(x: 300, y: 200)
    let t = base.withStretch(ZoomStretch(factor: 1.2, anchor: anchor))
    #expect(abs(t.drawnScale - 76.8) < 1e-9)
    #expect(t.scale == 64)
    #expect(t.scaleLimits == base.scaleLimits && t.mode == base.mode && t.clamped.center == base.clamped.center)
    let p0 = base.imagePoint(forView: anchor), p1 = t.imagePoint(forView: anchor)
    #expect(abs(p0.x - p1.x) < 1e-9 && abs(p0.y - p1.y) < 1e-9)
    #expect(abs(t.visibleRect.width - base.visibleRect.width / 1.2) < 1e-9)
    #expect(abs(t.visibleRect.height - base.visibleRect.height / 1.2) < 1e-9)
    // the anchor's image point sits at the same fraction of the visible rect before and after
    #expect(abs((p1.x - t.visibleRect.minX) / t.visibleRect.width - anchor.x / 800) < 1e-9)
    #expect(abs((p1.y - t.visibleRect.minY) / t.visibleRect.height - anchor.y / 600) < 1e-9)
    // the visible rect is what the view's corners map to
    let tl = t.imagePoint(forView: .zero), br = t.imagePoint(forView: CGPoint(x: 800, y: 600))
    #expect(abs(tl.x - t.visibleRect.minX) < 1e-9 && abs(br.y - t.visibleRect.maxY) < 1e-9)
    for p in [CGPoint(x: 10, y: 20), CGPoint(x: 500.5, y: 400.25)] {
        let back = t.imagePoint(forView: t.viewPoint(forImage: p))
        #expect(abs(back.x - p.x) < 1e-9 && abs(back.y - p.y) < 1e-9)
    }
    // below one: smaller than plain, the same invariants
    let s = base.withStretch(ZoomStretch(factor: 0.8, anchor: anchor))
    #expect(abs(s.drawnScale - 51.2) < 1e-9)
    let q = s.imagePoint(forView: anchor)
    #expect(abs(q.x - p0.x) < 1e-9 && abs(s.visibleRect.width - base.visibleRect.width / 0.8) < 1e-9)
    // no stretch: drawnScale is the scale
    #expect(base.drawnScale == base.scale)
}

@Test func operationsDropTheStretch() {
    let base = ViewTransform(imageSize: CGSize(width: 4000, height: 3000), viewSize: CGSize(width: 1000, height: 800),
                             mode: .actual(2))
    let t = base.withStretch(ZoomStretch(factor: 1.1, anchor: CGPoint(x: 5, y: 5)))
    #expect(t.stretch != nil)
    #expect(t.panned(by: CGVector(dx: 3, dy: 3)).stretch == nil)
    #expect(t.zoomed(toScale: 3, anchor: .zero).stretch == nil)
    #expect(t.withMode(.fit).stretch == nil)
    #expect(t.withImageSize(CGSize(width: 10, height: 10)).stretch == nil)
    #expect(t.withViewSize(CGSize(width: 10, height: 10)).stretch == nil)
    #expect(t.reoriented(to: CGSize(width: 3000, height: 4000)).stretch == nil)
    #expect(t.withOffset(CGVector(dx: 4, dy: 0)).stretch == nil)
    let o = base.withOffset(CGVector(dx: 4, dy: 7)).withStretch(ZoomStretch(factor: 1.1, anchor: .zero))
    #expect(o.offset == .zero)
    #expect(base.withOffset(CGVector(dx: 4, dy: 7)).withStretch(nil).offset == .zero)
}

// Owner, 2026-10-28: a zoom at the pointer keeps the normal centring. A portrait photo in a landscape view, side bars
// at Fit: grown but still narrower than the view, it stays in the middle across; the tall axis keeps the pointer's spot.
@Test func zoomAtPointerKeepsNarrowAxisCentred() {
    let t = ViewTransform(imageSize: CGSize(width: 2000, height: 3000), viewSize: CGSize(width: 3000, height: 1500))
    let anchor = CGPoint(x: 1200, y: 400), before = t.imagePoint(forView: anchor)
    let z = t.zoomed(toScale: t.fitScale * 1.4, anchor: anchor)   // 1400 wide: still narrower
    #expect(abs(z.visibleRect.midX - 1000) < 1e-6)
    #expect(abs(z.imagePoint(forView: anchor).y - before.y) < 1e-6)
}

// Smart zoom spec §1: the share of the view the picture covers, by area, and carrying it (`keep-zoom-as=screen`).

@Test func screenShareIsTheClippedAreaOverTheView() {
    let fit = ViewTransform(imageSize: CGSize(width: 1000, height: 1000), viewSize: CGSize(width: 2000, height: 1000))
    #expect(abs(fit.screenShare - 0.5) < 1e-9)                         // a square at Fit: half the view
    #expect(abs(fit.withMode(.fill).screenShare - 1) < 1e-9)
    #expect(abs(fit.withMode(.free(0.5)).screenShare - 0.125) < 1e-9)   // half the side: a quarter of the area
}

@Test func screenCarryKeepsTheShareAcrossShapes() {
    let view = CGSize(width: 2000, height: 1000)
    let landscape = ViewTransform(imageSize: CGSize(width: 3000, height: 1500), viewSize: view, mode: .free(0.8))
    let portrait = ViewTransform(imageSize: CGSize(width: 1000, height: 1500), viewSize: view, mode: .free(1))
    let carried = portrait.carryingZoom(from: landscape, .screen)
    #expect(abs(landscape.screenShare - 0.64) < 1e-9)
    #expect(abs(carried.screenShare - 0.64) < 1e-9)                    // the portrait is cut to cover as much
}

@Test func screenCarryCutsAndFillsAtAFullShare() {
    let view = CGSize(width: 2000, height: 1000)
    let full = ViewTransform(imageSize: CGSize(width: 3000, height: 1500), viewSize: view, mode: .free(1))   // fills
    let portrait = ViewTransform(imageSize: CGSize(width: 1000, height: 1500), viewSize: view, mode: .free(1))
    let carried = portrait.carryingZoom(from: full, .screen)
    #expect(abs(carried.scale - portrait.withMode(.fill).scale) < 1e-9)
}

@Test func screenCarryKeepsAZoomOutSmall() {
    let view = CGSize(width: 2000, height: 1000)
    let small = ViewTransform(imageSize: CGSize(width: 2000, height: 1000), viewSize: view, mode: .free(0.5))   // 25 %
    let next = ViewTransform(imageSize: CGSize(width: 1000, height: 1000), viewSize: view, mode: .free(1))
    #expect(abs(next.carryingZoom(from: small, .screen).screenShare - 0.25) < 1e-9)
}

@Test func screenCarryStaysWithinTheZoomLimitsAndNamedModesStay() {
    let view = CGSize(width: 2000, height: 1000)
    let full = ViewTransform(imageSize: CGSize(width: 2000, height: 1000), viewSize: view, mode: .free(1))
    let tiny = ViewTransform(imageSize: CGSize(width: 10, height: 1000), viewSize: view, mode: .free(1))
    #expect(tiny.carryingZoom(from: full, .screen).scale <= tiny.scaleLimits.upperBound)
    let empty = ViewTransform(imageSize: .zero, viewSize: view, mode: .free(1)).carryingZoom(from: full, .screen)
    #expect(empty.scale.isFinite)
    let fitted = ViewTransform(imageSize: CGSize(width: 1000, height: 1500), viewSize: view)   // .fit
    #expect(fitted.carryingZoom(from: full, .screen).mode == .fit)
}

@Test func resizeUnderScreenKeepsTheShareAndTheCentre() {
    var t = ViewTransform(imageSize: CGSize(width: 1000, height: 1500), viewSize: CGSize(width: 2000, height: 1000),
                          mode: .free(1.6), center: CGPoint(x: 0.5, y: 0.3))
    let share = t.screenShare
    t = t.withViewSize(CGSize(width: 1200, height: 1000), carry: .screen)
    #expect(abs(t.screenShare - share) < 1e-9)
    #expect(t.center == CGPoint(x: 0.5, y: 0.3))
}

// Owner, 2026-10-28: a view framed past the photo's edge (a subject near it) stands where the normal centring lets it:
// half a view from the edge, not exactly on the subject.
@Test func framingNearTheEdgeKeepsTheNormalCentring() {
    let t = ViewTransform(imageSize: CGSize(width: 1000, height: 1000), viewSize: CGSize(width: 1000, height: 1000),
                          mode: .free(4), center: CGPoint(x: 0.5, y: 0.05))
    #expect(abs(t.clamped.center.y - 0.125) < 1e-9)
    let out = t.panned(by: CGVector(dx: 0, dy: 400))   // dragging down past the top edge: refused
    #expect(abs(out.center.y - 0.125) < 1e-9)
}

// Owner's report: after Zoom to Subject near the photo's edge, a right-button zoom out jerked. Zooming out from a view
// at the photo's corner moves the picture smoothly, the press's way (each frame from the press) and a pinch's (each
// from the last), and ends centred at Fit.
@Test func zoomOutFromTheCornerStaysSmoothToFit() {
    let start = ViewTransform(imageSize: CGSize(width: 1000, height: 1000), viewSize: CGSize(width: 2000, height: 1000),
                              mode: .free(4), center: CGPoint(x: 0.05, y: 0.05))
    let anchor = CGPoint(x: 1000, y: 500), middle = CGPoint(x: 500, y: 500)
    for incremental in [false, true] {
        var t = start, last = start.viewPoint(forImage: middle)
        for i in 1...120 {
            let s = 4 - 3 * Double(i) / 120   // 4 → 1 (Fit)
            t = (incremental ? t : start).zoomed(toScale: s, anchor: anchor)
            let p = t.viewPoint(forImage: middle)
            #expect(hypot(p.x - last.x, p.y - last.y) < 100, "\(incremental ? "pinch" : "press") step \(i): \(last) → \(p)")
            last = p
        }
        let p = t.viewPoint(forImage: middle)
        #expect(abs(p.x - 1000) < 1e-6 && abs(p.y - 500) < 1e-6, "\(incremental ? "pinch" : "press") at Fit: \(p)")
    }
}

// Owner's report: with keep-zoom-as=screen every zoom past Fill showed `Screen 100 %` and the next photo opened at
// Fill. Past Fill the share goes on growing with the picture's area from Fill's, so it shows and carries the zoom.
@Test func screenShareGrowsPastFill() {
    let t = ViewTransform(imageSize: CGSize(width: 2000, height: 1000), viewSize: CGSize(width: 1000, height: 1000))
    // Fill: scale 1 (the height fits); twice that scale is four times the area.
    var fill = t
    fill.mode = .free(1 / t.fitScale)
    #expect(abs(fill.screenShare - 1) < 1e-9)
    var twice = t
    twice.mode = .free(2 / t.fitScale)
    #expect(abs(twice.screenShare - 4) < 1e-9)
    #expect(abs(t.scaleCovering(screenShare: 4) - 2) < 1e-9)
    #expect(abs(t.scaleCovering(screenShare: 1) - 1) < 1e-9)
    // Below Fill as before: the covered part of the view.
    #expect(abs(t.scaleCovering(screenShare: 0.5) - 0.5) < 1e-9)
    // The next photo, of another shape, keeps the zoom past its own Fill.
    let next = ViewTransform(imageSize: CGSize(width: 1000, height: 2000), viewSize: CGSize(width: 1000, height: 1000),
                             mode: .free(1)).carryingZoom(from: twice, .screen)
    #expect(abs(next.screenShare - 4) < 1e-9)
}
