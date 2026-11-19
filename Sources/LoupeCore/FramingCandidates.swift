import Foundation

/// Finite proposals, including arbitrary category mixtures and individual instances of the same category.
public enum FramingCandidates {
    public static func generate(reference: FramingReference, profile: FramingProfile, limit: Int) -> [ViewTransform] {
        generate(input: reference.input.transform, boxes: reference.boxes, evidence: reference.evidence,
                 profile: profile, behavior: reference.behavior, limit: limit)
    }
    public static func generate(input: ViewTransform, boxes: SubjectBoxes, evidence: FramingEvidence,
                                profile: FramingProfile, behavior: FramingReference.Behavior, limit: Int) -> [ViewTransform] {
        guard limit > 0 else { return [] }
        let framing = evidence.framing
        var result: [ViewTransform] = []
        var seen = Set<String>()
        func add(_ t: ViewTransform) {
            guard result.count < limit else { return }
            let t = t.clamped
            let key = String(format: "%.5f:%.5f:%.5f", t.center.x, t.center.y, log(t.scale))
            if seen.insert(key).inserted { result.append(t) }
        }
        add(FramingReplay.transform(input: input, boxes: boxes, evidence: evidence, profile: profile, behavior: behavior))
        if behavior == .auto { add(input.withMode(.fit)) }
        // Later configured groups remain alternatives even when an earlier group already matched.
        // Bound their share so arbitrary spatial combinations retain proposal capacity too.
        for kind in profile.chain.prefix(max(1, limit / 3)) {
            if let composition = SubjectFraming.composition(boxes, kind: kind, options: profile.composition,
                imageSize: input.imageSize, framing: framing) {
                add(composition.resolve(input, autoZoom: behavior == .auto, size: profile.size).transform)
            }
        }
        var instances: [SubjectComposition.Region] = []
        for kind in (SubjectKind.vision + Array(Set(boxes.detections.map(\.kind))).sorted { $0.rawValue < $1.rawValue }) {
            for rect in boxes.boxes(kind, framing: framing).compactMap(SubjectFraming.validRect) {
                instances.append(.init(kind: kind, rect: rect))
            }
        }
        // Input is bounded before neighbor search. Round-robin by kind keeps dense categories from starving others.
        let byKind = Dictionary(grouping: instances, by: \.kind)
        let kinds = byKind.keys.sorted { $0.rawValue < $1.rawValue }
        instances = []
        for rank in 0..<min(32, byKind.values.map(\.count).max() ?? 0) {
            for kind in kinds where rank < byKind[kind]!.count {
                instances.append(byKind[kind]![rank])
                if instances.count == 32 { break }
            }
            if instances.count == 32 { break }
        }
        func propose(_ group: [SubjectComposition.Region], size: Double) {
            if let c = SubjectFraming.composition(boxes, selected: group, expandHeads: group.count == 1,
                options: profile.composition, imageSize: input.imageSize, framing: framing) {
                add(c.resolve(input, autoZoom: behavior == .auto, size: size).transform)
            }
        }
        let neighbors = instances.enumerated().map { index, root in
            instances.enumerated().sorted {
                let a = hypot($0.element.rect.midX - root.rect.midX, $0.element.rect.midY - root.rect.midY)
                let b = hypot($1.element.rect.midX - root.rect.midX, $1.element.rect.midY - root.rect.midY)
                return a == b ? $0.offset < $1.offset : a < b
            }.map(\.element)
        }
        // Reserve proposals for multiple families before refining any singleton. A dense scene cannot starve pairs.
        let remaining = max(0, limit - result.count - 1)
        for (count, quota) in [(1, max(1, remaining / 3)), (2, max(1, remaining / 3)),
                               (3, max(1, remaining / 6)), (4, max(1, remaining / 6))] {
            for group in neighbors.prefix(quota) { propose(Array(group.prefix(count)), size: profile.size) }
        }
        propose(instances, size: profile.size)
        for size in [0.45, 0.7, 0.95] {
            for group in neighbors {
                for count in [1, 2, 4, 8] { propose(Array(group.prefix(count)), size: size) }
                if result.count >= limit { return result }
            }
        }
        return result
    }
}

public enum FramingFeatures {
    public static let version = 1
    /// Category means plus scene-conditioned pair co-visibility. Absence is explicit; weights are not universal priorities.
    public static func values(input: ViewTransform, boxes: SubjectBoxes, evidence: FramingEvidence,
                              crop: ViewTransform, kinds: [SubjectKind]) -> [Double] {
        func bounded(_ v: Double) -> Double { max(-2, min(2, v)) }
        let framing = evidence.framing
        var values = [log(crop.scale / input.fitScale), crop.center.x - 0.5, crop.center.y - 0.5]
        var visible: [Double] = [], sceneArea: [Double] = []
        for kind in kinds {
            let rects = boxes.boxes(kind, framing: framing).compactMap(SubjectFraming.validRect)
            let projected = rects.map { FramingEvaluation.project($0, in: crop) }
            let n = Double(max(1, rects.count))
            let visibility = projected.map(FramingEvaluation.visibility).reduce(0, +) / n
            visible.append(visibility)
            let area = rects.map { $0.width * $0.height }.reduce(0, +) / n
            sceneArea.append(area)
            var row = Array(repeating: 0.0, count: 10)
            for r in projected {
                let v = FramingEvaluation.visibility(r), x = bounded(r.midX - 0.5), y = bounded(r.midY - 0.5)
                row[0] += v; row[1] += v * x; row[2] += v * y; row[3] += v * x * x; row[4] += v * y * y
                row[5] += v * bounded(log(max(1e-6, sqrt(r.width * r.height))))
                row[6] += min(1, max(0, -r.minX / r.width)); row[7] += min(1, max(0, -r.minY / r.height))
                row[8] += min(1, max(0, (r.maxX - 1) / r.width)); row[9] += min(1, max(0, (r.maxY - 1) / r.height))
            }
            values += row.map { $0 / n }
            let cx = rects.map(\.midX).reduce(0, +) / n, cy = rects.map(\.midY).reduce(0, +) / n
            values += [rects.isEmpty ? 0 : 1, min(1, Double(rects.count) / 8), area,
                       visibility * area, visibility * cx, visibility * cy,
                       log(crop.scale / input.fitScale) * area]
        }
        for i in kinds.indices {
            for j in kinds.indices where i != j {
                values.append(visible[i] * visible[j])
                values.append(visible[i] * sceneArea[j])
            }
        }
        return values
    }
}

public struct FramingPolicy: Codable, Equatable, Sendable {
    public var version = FramingFeatures.version
    public var baseline: FramingProfile
    public var profile: FramingProfile
    public var intent: FramingIntent
    public var analysisID: String
    public var evidence: FramingEvidence
    public var kinds: [SubjectKind]
    public var coefficients: [Double]
    public var candidateLimit: Int
    public func predict(input: ViewTransform, boxes: SubjectBoxes, evidence: FramingEvidence,
                        profile: FramingProfile, behavior: FramingReference.Behavior) -> ViewTransform? {
        guard version == FramingFeatures.version, self.baseline.fingerprint == profile.fingerprint,
              evidence == self.evidence, evidence.analysisID == analysisID,
              (1...256).contains(candidateLimit), kinds.count <= 64,
              coefficients.count <= 20000, coefficients.allSatisfy(\.isFinite) else { return nil }
        let candidates = FramingCandidates.generate(input: input, boxes: boxes, evidence: evidence,
                                                    profile: self.profile, behavior: behavior, limit: candidateLimit)
        var best: ViewTransform?, score = Double.infinity
        for crop in candidates {
            let features = FramingFeatures.values(input: input, boxes: boxes, evidence: evidence, crop: crop, kinds: kinds)
            guard features.count == coefficients.count else { return nil }
            let next = zip(features, coefficients).map(*).reduce(0, +)
            if next < score - 1e-10 { score = next; best = crop }
        }
        return best
    }
}
