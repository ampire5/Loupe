import CoreGraphics

/// Where one page of a spread is drawn (spread spec, «Архитектура»): the pages share one `ViewTransform` laid out at
/// the virtual picture's size (`SpreadLayout.virtualSize`), and each page is drawn on its own, with the transform this
/// gives, into the drawable px of its rect. Pure, so the renderer and its tests share it.
public struct PagePlacement: Equatable, Sendable {
    /// The page's own transform: `imageSize` is the page's (oriented) size, `viewSize` the shared one, and image px p
    /// lands where the shared transform puts the virtual point `rect.origin + p * rect.height / pageSize.height`.
    public let transform: ViewTransform
    /// The drawable px that are this page's: those whose centre lies in its rect as the shared transform shows it,
    /// clipped to the view; whole px, empty when the page is off screen or has no size. Two pages that touch get
    /// viewports that touch too, with no column between them and none shared.
    public let viewport: CGRect

    /// `rect` is the page's rect in the shared transform's image (`SpreadLayout.rects`), `pageSize` the page's size as
    /// drawn (oriented).
    public init(rect: CGRect, pageSize: CGSize, shared: ViewTransform) {
        let origin = shared.viewPoint(forImage: rect.origin)
        let far = shared.viewPoint(forImage: CGPoint(x: rect.maxX, y: rect.maxY))
        let ratio = pageSize.height > 0 && rect.height > 0 ? rect.height / pageSize.height : 1
        transform = Self.placed(imageSize: pageSize, viewSize: shared.viewSize, fitUpscale: shared.fitUpscale,
                                scale: shared.drawnScale * ratio, origin: origin)
        guard pageSize.width > 0, pageSize.height > 0, rect.width > 0, rect.height > 0 else {
            viewport = .zero
            return
        }
        let x = Self.pixels(origin.x, far.x, limit: shared.viewSize.width)
        let y = Self.pixels(origin.y, far.y, limit: shared.viewSize.height)
        viewport = x.upper > x.lower && y.upper > y.lower
            ? CGRect(x: x.lower, y: y.lower, width: x.upper - x.lower, height: y.upper - y.lower) : .zero
    }

    /// A transform of an image of `imageSize` drawn at `scale` view px per image px with image px 0 at view px `origin`.
    /// Built from the transform's own parts: a centred image (the centre 0.5 is one `clamped` keeps) at `.actual` of the
    /// scale, within the zoom limits, and the rest as a zoom stretch about view px 0; the pan stretch (`offset`) puts
    /// the origin where it belongs.
    static func placed(imageSize: CGSize, viewSize: CGSize, fitUpscale: Bool, scale: Double,
                       origin: CGPoint) -> ViewTransform {
        let k = scale.isFinite && scale > 0 ? scale : 1
        var t = ViewTransform(imageSize: imageSize, viewSize: viewSize, mode: .actual(k), fitUpscale: fitUpscale)
        let s = t.scale
        let factor = k / s
        if factor != 1 { t.stretch = ZoomStretch(factor: factor, anchor: .zero) }
        // viewPoint is the stretch factor times a point that moves one for one with `offset`.
        let at = t.viewPoint(forImage: .zero)
        t.offset = CGVector(dx: (origin.x - at.x) / factor, dy: (origin.y - at.y) / factor)
        return t
    }

    /// The px `lower ..< upper` of one axis whose centre lies in `a ..< b` (view px), within `0 ..< limit`. The edges
    /// are taken as the GPU has them, rounded to `Float` (each path compares pixel centres with the picture's rect in
    /// `Float`), so a page edge that is exactly a pixel centre is decided as the page drawn there decides it.
    private static func pixels(_ a: Double, _ b: Double, limit: Double) -> (lower: Double, upper: Double) {
        let end = max(limit.rounded(.down), 0)
        func edge(_ v: Double) -> Double {
            guard v.isFinite else { return v > 0 ? end : 0 }
            return min(max((Double(Float(v)) - 0.5).rounded(.up), 0), end)
        }
        return (edge(min(a, b)), edge(max(a, b)))
    }
}
