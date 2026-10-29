import CoreGraphics

/// A gesture zooming in towards the subject (`zoom-anchor=subject`, `zoom-anchor-center`): where the subject's point
/// goes on screen. From where it was at the gesture's start to the view's centre, in proportion to the doublings made
/// of those to the framing's scale (`subject-size`; one doubling when the view is already past it); a zoom out leaves
/// it where it was. Any scale of the gesture gives one place, so a pinch's steps and a right-button drag agree.
public enum SubjectCentring {
    public static func point(start: CGPoint, centre: CGPoint, scale: Double, startScale: Double,
                             targetScale: Double) -> CGPoint {
        guard scale > startScale, startScale > 0 else { return start }
        let end = max(targetScale, startScale * 2)
        let t = min(1, log(scale / startScale) / log(end / startScale))
        return CGPoint(x: start.x + (centre.x - start.x) * t, y: start.y + (centre.y - start.y) * t)
    }
}

/// The subject's frame in a photo (smart zoom spec §4): the boxes of the first kind of the chain that has any, faces
/// grown to the head with its hair, all of them together, with a margin; in the photo's normalised space.
public enum SubjectFraming {
    /// A face box grows this much about its centre, to the head with its hair…
    public static let faceGrowth = 1.8
    /// …and moves up by this share of its height (the hair is above the face, the chin is in it).
    public static let faceLift = 0.15
    /// Room round the frame, each side, as a share of its size.
    public static let margin = 0.08

    /// The frame, nil when no kind of `chain` has boxes. A custom detector's kind frames what `pick` chooses, with the
    /// detector's margin, grown about its centre to at least its `minFrame` of the photo's side.
    public static func frame(_ boxes: SubjectBoxes, chain: [SubjectKind]) -> CGRect? {
        guard let kind = chain.first(where: { !boxes.boxes($0).isEmpty }) else { return nil }
        let custom = kind.isCustom
        guard let rects = custom ? pick(boxes, kind) : boxes.boxes(kind).map({ kind == .face ? head($0) : $0 }),
              let first = rects.first else { return nil }
        let union = rects.dropFirst().reduce(first) { $0.union($1) }
        let m = custom ? detector.margin : margin
        let framed = union.insetBy(dx: -union.width * m, dy: -union.height * m)
        return framed.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// The frame's centre, nil when no kind of `chain` has boxes.
    public static func centre(_ boxes: SubjectBoxes, chain: [SubjectKind]) -> CGPoint? {
        frame(boxes, chain: chain).map { CGPoint(x: $0.midX, y: $0.midY) }
    }

    /// The scale at which `frame` (normalised) takes `size` (0.2…1) of the view: its height or width, whichever binds;
    /// never below `fit`, never past `limits`.
    public static func scale(frame: CGRect, size: Double, imageSize: CGSize, viewSize: CGSize,
                             limits: ClosedRange<Double>, fit: Double) -> Double {
        let w = frame.width * imageSize.width, h = frame.height * imageSize.height
        guard w > 0, h > 0, viewSize.width > 0, viewSize.height > 0 else { return fit }
        let s = min(viewSize.width * size / w, viewSize.height * size / h)
        return min(max(s, fit, limits.lowerBound), limits.upperBound)
    }

    /// Where framing while browsing centres a view showing `window` (normalised) of the photo: the subject's frame
    /// `main` whole in it, as much of `others` as then fits (the sum of each box's visible share; of equal ones the place
    /// nearest the frame's centre, inside the photo where it can be), then `pull` (0…1) of the way to the frame's centre.
    /// The visible shares are piecewise linear in the centre, bilinear between the breaks, so the best place is on a
    /// break: every box edge half a window away, and the ends of the range.
    public static func pan(main: CGRect, others: [CGRect], window: CGSize, pull: Double) -> CGPoint {
        func axis(_ lo: Double, _ hi: Double, _ w: Double, _ edges: [Double]) -> [Double] {
            // The range that keeps the frame whole (its centre when it is wider than the view), inside the photo if it can.
            // Its ends compared, not the widths: a view as wide as the frame can round them an ulp apart either way
            // (crash, owner, 2026-10-28).
            let from = hi - w / 2, to = lo + w / 2
            var range = from <= to ? from...to : ((lo + hi) / 2)...((lo + hi) / 2)
            let inside = (w / 2)...max(w / 2, 1 - w / 2)
            if range.overlaps(inside) { range = max(range.lowerBound, inside.lowerBound)...min(range.upperBound, inside.upperBound) }
            let breaks = edges.flatMap { [$0 - w / 2, $0 + w / 2] } + [range.lowerBound, range.upperBound, (lo + hi) / 2]
            // Clamped, many breaks fall on the range's ends: each place once, in the order first met (the ties go to
            // the first place met, as before).
            var seen = Set<Double>()
            return breaks.map { min(max($0, range.lowerBound), range.upperBound) }.filter { seen.insert($0).inserted }
        }
        let w = window.width, h = window.height
        let mid = CGPoint(x: main.midX, y: main.midY)
        // A window or frame not finite (a photo of no size, a null frame) has no place to choose.
        guard [w, h, main.minX, main.maxX, main.minY, main.maxY].allSatisfy(\.isFinite) else { return mid }
        let xs = axis(main.minX, main.maxX, w, others.flatMap { [$0.minX, $0.maxX] })
        let ys = axis(main.minY, main.maxY, h, others.flatMap { [$0.minY, $0.maxY] })
        // A box's visible share is the product of its overlaps on the two axes, so each axis is measured once per place
        // and box, not the view intersected with every box at every place (owner, 2026-10-28: on 80 boxes 44 ms a call,
        // docs/bench/2026-10-28-smart-zoom.md). Boxes of no area show nothing.
        let boxes = others.filter { $0.width * $0.height != 0 }
        let n = boxes.count
        func overlaps(_ places: [Double], _ size: Double, _ lo: (CGRect) -> CGFloat, _ hi: (CGRect) -> CGFloat) -> [Double] {
            var result = [Double](repeating: 0, count: places.count * n)
            for (i, c) in places.enumerated() {
                // As CGRect builds the view: its far edge is its near edge plus its size.
                let from = c - size / 2, to = from + size
                for (j, b) in boxes.enumerated() { result[i * n + j] = max(0, min(to, hi(b)) - max(from, lo(b))) }
            }
            return result
        }
        let ox = overlaps(xs, w, \.minX, \.maxX), oy = overlaps(ys, h, \.minY, \.maxY)
        let areas = boxes.map { $0.width * $0.height }
        var best = CGPoint(x: xs[0], y: ys[0]), bestShown = -1.0, bestDistance = Double.infinity
        var active: [Int] = []
        active.reserveCapacity(n)
        for (i, x) in xs.enumerated() {
            // Only the boxes the view overlaps across at this x count on any y.
            active.removeAll(keepingCapacity: true)
            for j in 0..<n where ox[i * n + j] > 0 { active.append(j) }
            for (k, y) in ys.enumerated() {
                var s = 0.0
                for j in active { s += ox[i * n + j] * oy[k * n + j] / areas[j] }
                let d = hypot(x - mid.x, y - mid.y)
                if s > bestShown + 1e-9 || (abs(s - bestShown) <= 1e-9 && d < bestDistance) {
                    best = CGPoint(x: x, y: y); bestShown = s; bestDistance = d
                }
            }
        }
        return CGPoint(x: best.x + (mid.x - best.x) * pull, y: best.y + (mid.y - best.y) * pull)
    }

    /// Validate before intersecting: CGRect can standardize negative dimensions and hide malformed model output.
    public static func validRect(_ rect: CGRect) -> CGRect? {
        guard [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height].allSatisfy(\.isFinite),
              rect.size.width > 0, rect.size.height > 0 else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        if bounds.contains(rect) { return rect }
        let clipped = rect.intersection(bounds)
        return clipped.isNull || clipped.isEmpty ? nil : clipped
    }

    static func head(_ face: CGRect) -> CGRect {
        let w = face.width * faceGrowth, h = face.height * faceGrowth
        return CGRect(x: face.midX - w / 2, y: face.midY - h / 2 - face.height * faceLift, width: w, height: h)
    }
}
