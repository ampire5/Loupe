import Foundation

/// Stateless production composition, with immutable detector context for off-main fitting.
public enum FramingReplay {
    public static func transform(reference: FramingReference, profile: FramingProfile) -> ViewTransform {
        transform(input: reference.input.transform, boxes: reference.boxes, evidence: reference.evidence,
                  profile: profile, behavior: reference.behavior)
    }
    public static func transform(input: ViewTransform, boxes: SubjectBoxes, evidence: FramingEvidence,
                                 profile: FramingProfile, behavior: FramingReference.Behavior) -> ViewTransform {
        let framing = evidence.framing
        for kind in profile.chain {
            if let composition = SubjectFraming.composition(boxes, kind: kind, options: profile.composition,
                imageSize: input.imageSize, framing: framing) {
                return composition.resolve(input, autoZoom: behavior == .auto, size: profile.size).transform
            }
        }
        return behavior == .auto ? input.withMode(.fit) : input
    }
}

public struct FramingElementError: Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: SubjectKind
    public var dx: Double
    public var dy: Double
    public var logScale: Double
    public var referenceCenter: CGPoint
    public var predictedCenter: CGPoint
    public var referenceVisibility: Double
    public var predictedVisibility: Double
    /// Left, top, right, bottom: positive means more was cut than in the reference.
    public var edgeCuts: [Double]
    public var loss: Double
    public var summary: String {
        var notes: [String] = []
        if abs(dx) > 0.01 { notes.append(String(format: "%@ %.1f%%", dx > 0 ? "right" : "left", abs(dx) * 100)) }
        if abs(dy) > 0.01 { notes.append(String(format: "%@ %.1f%%", dy > 0 ? "down" : "up", abs(dy) * 100)) }
        if abs(logScale) > 0.02 { notes.append(logScale > 0 ? "too large" : "too small") }
        for (i, edge) in ["left", "top", "right", "bottom"].enumerated() where edgeCuts[i] > 0.02 {
            notes.append(String(format: "extra %@ cut %.1f%%", edge, edgeCuts[i] * 100))
        }
        return kind.title + ": " + (notes.isEmpty ? "matches reference" : notes.joined(separator: ", "))
    }
}

public struct FramingErrorReport: Equatable, Sendable {
    public var dx: Double
    public var dy: Double
    public var logScale: Double
    public var overlap: Double
    public var groupDX: Double
    public var groupDY: Double
    public var elements: [FramingElementError]
    public var globalLoss: Double
    public var objectLoss: Double
    public var loss: Double { globalLoss + objectLoss }
}

public enum FramingEvaluation {
    /// Full boxes in normalized viewport space; never clip before measuring position.
    public static func project(_ rect: CGRect, in view: ViewTransform) -> CGRect {
        let origin = view.viewPoint(forImage: .init(x: rect.minX * view.imageSize.width, y: rect.minY * view.imageSize.height))
        return CGRect(x: origin.x / view.viewSize.width, y: origin.y / view.viewSize.height,
                      width: rect.width * view.imageSize.width * view.scale / view.viewSize.width,
                      height: rect.height * view.imageSize.height * view.scale / view.viewSize.height)
    }
    public static func visibility(_ rect: CGRect) -> Double {
        let clipped = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clipped.isNull, rect.width > 0, rect.height > 0 else { return 0 }
        return min(1, max(0, clipped.width * clipped.height / (rect.width * rect.height)))
    }
    private static func cuts(_ r: CGRect) -> [Double] {
        [min(1, max(0, -r.minX / r.width)), min(1, max(0, -r.minY / r.height)),
         min(1, max(0, (r.maxX - 1) / r.width)), min(1, max(0, (r.maxY - 1) / r.height))]
    }
    private static func robust(_ x: Double) -> Double { min(4, abs(x)) }
    public static func measure(reference: FramingReference, predicted: ViewTransform) -> FramingErrorReport {
        let target = reference.target.transform
        let dx = (predicted.clamped.center.x - target.center.x) * target.imageSize.width * target.scale / target.viewSize.width
        let dy = (predicted.clamped.center.y - target.center.y) * target.imageSize.height * target.scale / target.viewSize.height
        let scale = log(predicted.scale / target.scale)
        var errors: [FramingElementError] = []
        var groupA = CGRect.null, groupB = CGRect.null
        for instance in reference.instances {
            let a = project(instance.rect, in: target), b = project(instance.rect, in: predicted)
            let va = visibility(a), vb = visibility(b)
            let ex = b.midX - a.midX, ey = b.midY - a.midY
            let ca = cuts(a), cb = cuts(b), difference = zip(cb, ca).map(-)
            // Deliberately excluded objects are diagnostic context, not targets to pull inside the crop.
            let location = va * (robust(ex) + robust(ey) + robust(scale))
            let edge = difference.map { abs($0) }.reduce(0, +) / 4
            let loss = location + abs(vb - va) + va * edge
            errors.append(.init(id: instance.id, kind: instance.kind, dx: ex, dy: ey, logScale: scale,
                referenceCenter: .init(x: a.midX, y: a.midY), predictedCenter: .init(x: b.midX, y: b.midY),
                referenceVisibility: va, predictedVisibility: vb, edgeCuts: difference, loss: loss))
            if reference.capturedGroup?.parts.contains(instance.kind) ?? true {
                groupA = groupA.union(a); groupB = groupB.union(b)
            }
        }
        let byKind = Dictionary(grouping: errors, by: \.kind)
        let object = byKind.values.map { $0.map(\.loss).reduce(0, +) / Double($0.count) }.reduce(0, +) / Double(max(1, byKind.count))
        let bounds = CGRect(origin: .zero, size: target.imageSize)
        let a = target.visibleRect.intersection(bounds), b = predicted.visibleRect.intersection(bounds)
        let intersection = a.intersection(b)
        let area = intersection.isNull ? 0 : intersection.width * intersection.height
        let union = a.width * a.height + b.width * b.height - area
        let groupDX = groupA.isNull ? 0 : groupB.midX - groupA.midX
        let groupDY = groupA.isNull ? 0 : groupB.midY - groupA.midY
        return .init(dx: dx, dy: dy, logScale: scale, overlap: union > 0 ? area / union : 1,
            groupDX: groupDX, groupDY: groupDY, elements: errors,
            globalLoss: robust(dx) + robust(dy) + robust(scale) + 0.25 * (robust(groupDX) + robust(groupDY)), objectLoss: object)
    }
    /// Each series and each image within it have equal weight. Validation never enters search loss.
    public static func aggregate(_ references: [FramingReference], evaluate: (FramingReference) -> Double) -> Double {
        let series = Dictionary(grouping: references, by: \.group)
        guard !series.isEmpty else { return 0 }
        return series.keys.sorted().map { key in
            let rows = series[key]!
            return rows.map(evaluate).reduce(0, +) / Double(rows.count)
        }.reduce(0, +) / Double(series.count)
    }
}
