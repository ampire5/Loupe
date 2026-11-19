import Foundation

/// Explicit feedback about one frozen detection, independent of viewport visibility.
public struct FramingObjectFeedback: Codable, Equatable, Sendable, Identifiable {
    public enum Reason: String, Codable, CaseIterable, Sendable {
        case inspect, avoidCenter, blurred, detectorMistake
        public var title: String {
            switch self {
            case .inspect: "Inspect this object"
            case .avoidCenter: "Do not use as centre"
            case .blurred: "Object is blurred"
            case .detectorMistake: "Detector mistake"
            }
        }
    }
    public var id = UUID()
    public var source: URL
    public var sourceRevision: FramingSourceRevision
    public var evidence: FramingEvidence
    public var boxes: SubjectBoxes
    public var instance: FramingInstance
    public var intent: FramingIntent
    public var reason: Reason
    public var created = Date()
    public init(source: URL, sourceRevision: FramingSourceRevision, evidence: FramingEvidence,
                boxes: SubjectBoxes, instance: FramingInstance, intent: FramingIntent, reason: Reason) {
        self.source = source; self.sourceRevision = sourceRevision; self.evidence = evidence
        self.boxes = boxes; self.instance = instance; self.intent = intent; self.reason = reason
    }
    public var isValid: Bool {
        source.isFileURL && sourceRevision.bytes >= 0 && sourceRevision.modified.timeIntervalSince1970.isFinite
            && (boxes.analysisID ?? "vision") == evidence.analysisID && FramingInstance.all(in: boxes).contains(instance)
            && instance.score.isFinite && (0...1).contains(instance.score)
            && SubjectFraming.validRect(instance.rect) != nil
    }
    public func replaces(_ other: Self) -> Bool {
        source.standardizedFileURL == other.source.standardizedFileURL && sourceRevision == other.sourceRevision
            && evidence == other.evidence && instance == other.instance && intent == other.intent && reason == other.reason
    }
}

extension FramingInstance {
    public static func all(in boxes: SubjectBoxes) -> [Self] {
        var result: [FramingInstance] = []
        let vision: [(SubjectKind, [CGRect])] = [(.face, boxes.faces), (.person, boxes.people), (.object, boxes.objects), (.saliency, boxes.saliency)]
        for (kind, rects) in vision {
            for (i, rect) in rects.enumerated() { result.append(.init(id: kind.rawValue + ":\(i)", kind: kind, rect: rect, score: 1)) }
        }
        for (i, d) in boxes.detections.enumerated() {
            result.append(.init(id: "detected:\(i)", kind: d.kind, rect: d.rect, score: d.score))
        }
        return result
    }
    /// Source-normalized, top-left coordinates, matching ViewTransform and frozen detections.
    public static func at(_ point: CGPoint, in boxes: SubjectBoxes) -> [Self] {
        guard point.x.isFinite, point.y.isFinite, CGRect(x: 0, y: 0, width: 1, height: 1).contains(point) else { return [] }
        return all(in: boxes).filter { SubjectFraming.validRect($0.rect) != nil && $0.rect.contains(point) }
            .sorted {
                let a = $0.rect.width * $0.rect.height, b = $1.rect.width * $1.rect.height
                return a == b ? $0.id < $1.id : a < b
            }
    }
}
