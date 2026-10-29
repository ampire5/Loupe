import CoreGraphics

/// The crop check (owner, 2026-10-28: «по мере кропа может меняться субъект»): with Show Subjects on, a zoom that came
/// to rest has Vision look at the visible part of the photo alone, at up to `SubjectFinder.proxySide` px of it, and
/// the overlay draws what it found there over the crop. Nothing moves the view by it. Rects normalised to the oriented
/// photo, as `SubjectBoxes`.
public enum SubjectCrop {
    /// A crop smaller than this share of the photo's area is looked at; above it the photo's own boxes say the same.
    public static let largestShare = 0.8

    /// The visible part of the photo, nil when it is (most of) the whole.
    public static func region(_ t: ViewTransform) -> CGRect? {
        let size = t.imageSize
        guard size.width > 0, size.height > 0 else { return nil }
        let v = t.visibleRect
        let r = CGRect(x: v.minX / size.width, y: v.minY / size.height, width: v.width / size.width, height: v.height / size.height)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !r.isNull, r.width > 0, r.height > 0, r.width * r.height < largestShare else { return nil }
        return r
    }

    /// The proxy's size for `region` of a photo of `imageSize`: its long side at most `side`, never more pixels than
    /// the photo has there.
    public static func proxySize(_ region: CGRect, imageSize: CGSize, side: Int) -> CGSize {
        let w = region.width * imageSize.width, h = region.height * imageSize.height
        let k = min(1, Double(side) / max(w, h))
        return CGSize(width: max(1, (w * k).rounded()), height: max(1, (h * k).rounded()))
    }

    /// The transform that draws `region` of the photo over the whole of a `proxy`-sized target.
    public static func proxyTransform(_ region: CGRect, imageSize: CGSize, proxy: CGSize) -> ViewTransform {
        var t = ViewTransform(imageSize: imageSize, viewSize: proxy)
        let scale = proxy.width / (region.width * imageSize.width)
        t.mode = .free(scale / t.fitScale)
        t.center = CGPoint(x: region.midX, y: region.midY)
        return t
    }

    /// Boxes found on the crop's proxy, in the whole photo's space.
    public static func inPhoto(_ boxes: SubjectBoxes, region: CGRect) -> SubjectBoxes {
        func map(_ r: CGRect) -> CGRect {
            CGRect(x: region.minX + r.minX * region.width, y: region.minY + r.minY * region.height,
                   width: r.width * region.width, height: r.height * region.height)
        }
        var out = boxes
        out.faces = boxes.faces.map(map)
        out.people = boxes.people.map(map)
        out.objects = boxes.objects.map(map)
        out.saliency = boxes.saliency.map(map)
        out.detections = boxes.detections.map { .init(kind: $0.kind, rect: map($0.rect), score: $0.score) }
        return out
    }
}
