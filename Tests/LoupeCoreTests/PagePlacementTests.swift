import CoreGraphics
import Testing
@testable import LoupeCore

/// Two pages of 1000 x 1500 and 500 x 750 side by side: a virtual picture of 2000 x 1500, the second page scaled 2x.
private let layout = SpreadLayout(first: CGSize(width: 1000, height: 1500), second: CGSize(width: 500, height: 750),
                                  rightToLeft: false)
private let pages = [CGSize(width: 1000, height: 1500), CGSize(width: 500, height: 750)]

private func near(_ a: CGPoint, _ b: CGPoint, _ eps: Double = 1e-6) -> Bool {
    abs(a.x - b.x) <= eps && abs(a.y - b.y) <= eps
}

/// Each page's own transform puts its corners where the shared one puts its rect's, at the shared scale times the
/// page's share of the virtual picture.
@Test(arguments: [ZoomMode.fit, .actual(1), .actual(3.7), .free(0.3)])
func pageTransformFillsItsRect(mode: ZoomMode) {
    let shared = ViewTransform(imageSize: layout.virtualSize, viewSize: CGSize(width: 1600, height: 1000), mode: mode,
                               center: CGPoint(x: 0.43, y: 0.61))
    for i in 0..<2 {
        let rect = layout.rects[i], size = pages[i]
        let p = PagePlacement(rect: rect, pageSize: size, shared: shared)
        #expect(near(p.transform.viewPoint(forImage: .zero), shared.viewPoint(forImage: rect.origin)))
        #expect(near(p.transform.viewPoint(forImage: CGPoint(x: size.width, y: size.height)),
                     shared.viewPoint(forImage: CGPoint(x: rect.maxX, y: rect.maxY))))
        #expect(abs(p.transform.drawnScale - shared.drawnScale * rect.height / size.height) < 1e-12)
        #expect(p.transform.viewSize == shared.viewSize)
        #expect(p.transform.imageSize == size)
        // The visible part the tile pass picks tiles from is the view's own, in this page's pixels.
        let visible = p.transform.visibleRect
        #expect(near(visible.origin, p.transform.imagePoint(forView: .zero)))
        #expect(abs(visible.width - shared.viewSize.width / p.transform.drawnScale) < 1e-6)
    }
}

/// Past the zoom limits of a page (64x, here 50x on the virtual picture is 100x on the half-height page), and under
/// a zoom stretch, the page still lands on its rect.
@Test func pageTransformBeyondItsZoomLimits() {
    let base = ViewTransform(imageSize: layout.virtualSize, viewSize: CGSize(width: 1600, height: 1000), mode: .actual(50),
                             center: CGPoint(x: 0.5, y: 0.5))
    for shared in [base, base.withStretch(ZoomStretch(factor: 1.3, anchor: CGPoint(x: 700, y: 300)))] {
        let rect = layout.rects[1], size = pages[1]
        let p = PagePlacement(rect: rect, pageSize: size, shared: shared)
        #expect(abs(p.transform.drawnScale - shared.drawnScale * 2) < 1e-9)
        #expect(near(p.transform.viewPoint(forImage: CGPoint(x: 13, y: 17)),
                     shared.viewPoint(forImage: CGPoint(x: rect.minX + 26, y: 34)), 1e-6))
    }
}

/// The viewports are the drawable px whose centre lies in the page's rect: the two pages' never overlap and, where the
/// pages touch, leave no column between them; both are inside the view.
@Test(arguments: [1599.0, 1600, 1601, 1777])
func viewportsTileTheSeam(width: Double) {
    for mode in [ZoomMode.fit, .actual(0.37), .free(2.5)] {
        let shared = ViewTransform(imageSize: layout.virtualSize, viewSize: CGSize(width: width, height: 900), mode: mode)
        let a = PagePlacement(rect: layout.rects[0], pageSize: pages[0], shared: shared).viewport
        let b = PagePlacement(rect: layout.rects[1], pageSize: pages[1], shared: shared).viewport
        #expect(a.maxX == b.minX || a.isEmpty || b.isEmpty)
        #expect(!a.intersects(b))
        let view = CGRect(origin: .zero, size: shared.viewSize)
        #expect(view.contains(a) && view.contains(b))
        for r in [a, b] where !r.isEmpty {
            #expect(r.minX == r.minX.rounded() && r.maxX == r.maxX.rounded())
            #expect(r.minY == r.minY.rounded() && r.maxY == r.maxY.rounded())
        }
        // By pixel centre, as every path cuts the picture.
        let seam = shared.viewPoint(forImage: CGPoint(x: layout.rects[1].minX, y: 0)).x
        if seam > 0.5, seam < width - 0.5 {
            #expect(Double(b.minX) + 0.5 >= seam - 1e-3 && Double(b.minX) - 0.5 < seam + 1e-3)
        }
    }
}

/// A page off screen has an empty viewport; one partly off screen is clipped to the view.
@Test func viewportClippedToTheView() {
    let shared = ViewTransform(imageSize: layout.virtualSize, viewSize: CGSize(width: 800, height: 600), mode: .actual(1),
                               center: CGPoint(x: 0, y: 0.5))
    let a = PagePlacement(rect: layout.rects[0], pageSize: pages[0], shared: shared).viewport
    let b = PagePlacement(rect: layout.rects[1], pageSize: pages[1], shared: shared).viewport
    #expect(a == CGRect(x: 0, y: 0, width: 800, height: 600))
    #expect(b.isEmpty)
}

/// A degenerate page (no size yet) or view gives an empty viewport and finite numbers, never NaN.
@Test func degeneratePage() {
    let shared = ViewTransform(imageSize: layout.virtualSize, viewSize: CGSize(width: 800, height: 600))
    let p = PagePlacement(rect: layout.rects[1], pageSize: .zero, shared: shared)
    #expect(p.viewport.isEmpty)
    #expect(p.transform.drawnScale.isFinite)
}
