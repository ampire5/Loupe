import Foundation

public struct SubjectComposition: Equatable, Sendable {
    public struct Region: Equatable, Sendable {
        public var kind: SubjectKind
        public var rect: CGRect
    }
    public var frame: CGRect
    public var desiredCenter: CGPoint
    public var maxZoom: Double
    public var panOverflow = CompositionOptions.PanOverflow.fit
    public var objects: [CGRect] = []
    public var support: CGRect? = nil
    public var circles: [Region] = []
    public var protectedRegions: [Region] = []

    /// The desired center projected onto the range preserving every selected box where it fits.
    /// An oversized axis keeps the weighted center; photo bounds always take precedence.
    public func transform(_ t: ViewTransform, autoZoom: Bool, size: Double) -> ViewTransform {
        resolve(t, autoZoom: autoZoom, size: size).transform
    }

    func proposedTransform(_ t: ViewTransform, autoZoom: Bool, size: Double) -> ViewTransform {
        guard t.imageSize.width > 0, t.imageSize.height > 0, t.viewSize.width > 0, t.viewSize.height > 0 else { return t }
        var result = t
        if autoZoom {
            let q = min(max(size, 0.2), 1)
            let s = min(t.viewSize.width * q / (frame.width * t.imageSize.width),
                        t.viewSize.height * q / (frame.height * t.imageSize.height), maxZoom)
            // Fit is the useful lower bound, even when a tiny source exceeds the native cap at Fit.
            result = s <= t.fitScale ? t.withMode(.fit) : t.withMode(.actual(s))
        }
        func project(_ target: Double, _ lo: Double, _ hi: Double, _ window: Double) -> Double {
            guard window < 1 else { return 0.5 }
            var lower = window / 2, upper = 1 - window / 2
            if hi - lo <= window + 1e-12 {
                lower = max(lower, hi - window / 2)
                upper = min(upper, lo + window / 2)
            }
            if lower > upper { return min(max(target, window / 2), 1 - window / 2) }
            return min(max(target, lower), upper)
        }
        let window = CGSize(width: result.viewSize.width / (result.scale * result.imageSize.width),
                            height: result.viewSize.height / (result.scale * result.imageSize.height))
        result.center = CGPoint(x: project(desiredCenter.x, frame.minX, frame.maxX, window.width),
                                y: project(desiredCenter.y, frame.minY, frame.maxY, window.height))
        result = result.clamped
        if !autoZoom && panOverflow == .keep && !objects.isEmpty {
            let visible = CGRect(x: result.center.x - window.width / 2, y: result.center.y - window.height / 2,
                                 width: window.width, height: window.height)
            if !objects.contains(where: { visible.intersects($0) }),
               let nearest = objects.min(by: {
                   hypot($0.midX - desiredCenter.x, $0.midY - desiredCenter.y)
                       < hypot($1.midX - desiredCenter.x, $1.midY - desiredCenter.y)
               }) {
                result.center = CGPoint(x: nearest.midX, y: nearest.midY)
            }
        }
        return result.clamped
    }
}

extension SubjectFraming {
    public static func composition(_ boxes: SubjectBoxes, kind: SubjectKind,
                                   options: CompositionOptions, imageSize: CGSize) -> SubjectComposition? {
        guard imageSize.width.isFinite, imageSize.height.isFinite, imageSize.width > 0, imageSize.height > 0 else { return nil }
        var objects: [CGRect] = []
        var circles: [SubjectComposition.Region] = []
        var union = CGRect.null, sx = 0.0, sy = 0.0, total = 0.0
        for part in kind.parts {
            let rects = boxes.boxes(part).compactMap(validRect)
            guard !rects.isEmpty else { return nil }
            let configured = options.weights[part] ?? 1
            let weight = (configured.isFinite && configured > 0 ? configured : 1)
                / (options.normalization == .class ? Double(rects.count) : 1)
            objects += rects
            for r in rects {
                sx += r.midX * weight; sy += r.midY * weight; total += weight
                let box = kind.parts.count == 1 && framesHead(part) ? head(r) : r
                let radius = options.radius(for: part) * min(box.width * imageSize.width, box.height * imageSize.height) / 2
                let circle = CGRect(x: box.midX - radius / imageSize.width, y: box.midY - radius / imageSize.height,
                                    width: radius * 2 / imageSize.width, height: radius * 2 / imageSize.height)
                circles.append(.init(kind: part, rect: circle))
                union = union.union(circle)
            }
        }
        let margin = options.margin.isFinite ? min(max(options.margin, 0), 1) : 0.08
        let frame = union.insetBy(dx: -union.width * margin, dy: -union.height * margin)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard total > 0, let valid = validRect(frame) else { return nil }
        var result = SubjectComposition(frame: valid, desiredCenter: CGPoint(x: sx / total, y: sy / total),
                                        maxZoom: options.maxZoom.isFinite ? min(max(options.maxZoom, 0.25), 4) : 1,
                                        panOverflow: options.panOverflow, objects: objects)
        result.support = validRect(union)
        result.circles = circles
        let protectedKinds = options.protectionScope == .selected ? kind.parts : Array(Set(boxes.kinds)).sorted { $0.rawValue < $1.rawValue }
        for protectedKind in protectedKinds {
            guard let cut = options.cropLimit(for: protectedKind) else { continue }
            let padding = options.protectionPadding(for: protectedKind)
            for raw in boxes.boxes(protectedKind).compactMap(validRect) {
                guard let padded = validRect(raw.insetBy(dx: -raw.width * padding, dy: -raw.height * padding)) else { continue }
                let required = padded.insetBy(dx: padded.width * cut, dy: padded.height * cut)
                result.protectedRegions.append(.init(kind: protectedKind, rect: required))
            }
        }
        return result
    }
}
