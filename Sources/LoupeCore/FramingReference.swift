import Foundation

public enum FramingLearningError: String, Error, LocalizedError {
    case geometry = "Wait for the image to settle before saving a reference."
    case schema = "This reference dataset needs a newer version of Loupe."
    case stale = "References or profile changed. Fit again before applying."
    case empty = "Save training references before fitting."
    case invalid = "The reference contains invalid geometry or profile values."
    case capture = "Use Auto framing or Pan on a decoded local photo before remembering its crop."
    case source = "The source file changed. Reload it and remember the crop again."
    case detection = "Subject detection failed. The reference was not saved."
    case split = "A photo appears in both training and validation. Keep its references in one series."
    case capacity = "Reference storage reached its safety limit. Remove older references before saving more."
    public var errorDescription: String? { rawValue }
}

/// A settled displayed transform, including letterboxing and the actual pixel scale.
public struct FramingGeometry: Codable, Equatable, Sendable {
    public var imageSize: CGSize
    public var viewSize: CGSize
    public var center: CGPoint
    public var scale: Double
    public var fitUpscale: Bool
    public var isFit: Bool
    public init(_ view: ViewTransform) throws {
        guard view.center.x.isFinite, view.center.y.isFinite else { throw FramingLearningError.geometry }
        imageSize = view.imageSize; viewSize = view.viewSize; center = view.clamped.center
        scale = view.scale; fitUpscale = view.fitUpscale; isFit = view.mode == .fit
        // The renderer clamps the stored centre too; a different stored centre is not ongoing motion.
        guard isValid, view.offset == .zero, view.stretch == nil else { throw FramingLearningError.geometry }
    }
    public var isValid: Bool {
        [imageSize.width, imageSize.height, viewSize.width, viewSize.height, scale].allSatisfy { $0.isFinite && $0 > 0 }
            && center.x.isFinite && center.y.isFinite && (0...1).contains(center.x) && (0...1).contains(center.y)
    }
    public var transform: ViewTransform {
        ViewTransform(imageSize: imageSize, viewSize: viewSize, mode: isFit ? .fit : .actual(scale),
                      center: center, fitUpscale: fitUpscale).clamped
    }
}

/// Profile serialization deliberately uses the same textual values as the existing editor.
public struct FramingProfile: Equatable, Sendable, Codable {
    public var name: String
    public var chain: [SubjectKind]
    public var size: Double
    public var composition: CompositionOptions
    public init(name: String, chain: [SubjectKind], size: Double = 0.6, composition: CompositionOptions = .init()) {
        self.name = name.lowercased(); self.chain = chain; self.size = size; self.composition = composition
    }
    public var draft: DetectorProfileDraft {
        var draft = DetectorProfileDraft(name: name, chain: chain)
        draft.size = size; draft.composition = composition; return draft
    }
    public var values: [String: String] {
        var v = composition.values
        v["size"] = "\(size * 100)%"; v["chain"] = chain.map(\.rawValue).joined(separator: ",")
        return v
    }
    public var fingerprint: String {
        name + "|" + values.keys.sorted().map { $0 + "=" + values[$0]! }.joined(separator: "|")
    }
    public var isValid: Bool {
        !name.isEmpty && !chain.isEmpty && size.isFinite && (0.2...1).contains(size)
            && composition.isValid && composition.margin.isFinite && (0...1).contains(composition.margin)
            && composition.maxZoom.isFinite && (0.25...4).contains(composition.maxZoom)
            && composition.weights.values.allSatisfy { $0.isFinite && (0.25...4).contains($0) }
    }
    private enum Keys: String, CodingKey { case name, chain, size, composition }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        name = try c.decode(String.self, forKey: .name); chain = try c.decode([SubjectKind].self, forKey: .chain)
        size = try c.decode(Double.self, forKey: .size); composition = CompositionOptions()
        for (key, value) in try c.decode([String: String].self, forKey: .composition) {
            guard composition.set(key, value) == true else { throw FramingLearningError.invalid }
        }
        guard isValid else { throw FramingLearningError.invalid }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(name, forKey: .name); try c.encode(chain, forKey: .chain)
        try c.encode(size, forKey: .size); try c.encode(composition.values, forKey: .composition)
    }
}

public struct FramingEvidence: Codable, Equatable, Sendable {
    public var analysisID = "vision"
    public var classes: [String: SubjectKind] = [:]
    public var heads: Set<SubjectKind> = []
    public var selectionThreshold = 0.5
    public var collectionFloor = ModelDetector.keptScore
    public init() {}
    public init(_ setup: DetectorSetup) {
        analysisID = setup.analysisID; classes = Dictionary(setup.classes.map { ($0.label, $0.kind) }, uniquingKeysWith: { a, _ in a })
        heads = Set(setup.heads); selectionThreshold = setup.score
    }
    public var framing: DetectorFraming {
        var f = DetectorFraming(); f.score = selectionThreshold; f.heads = heads
        f.kinds = Array(Set(classes.values)).sorted { $0.rawValue < $1.rawValue }; return f
    }
}

public struct FramingInstance: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: SubjectKind
    public var rect: CGRect
    public var score: Double
}

public struct FramingSourceRevision: Codable, Equatable, Sendable {
    public var bytes: Int64
    public var modified: Date
    public init(bytes: Int64, modified: Date) { self.bytes = bytes; self.modified = modified }
    /// Call off-main; URL resource lookup can block on remote volumes.
    public static func read(_ url: URL) throws -> Self {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        let v = try fresh.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let bytes = v.fileSize, let modified = v.contentModificationDate else { throw FramingLearningError.invalid }
        return .init(bytes: Int64(bytes), modified: modified)
    }
}

public struct FramingReference: Codable, Equatable, Sendable, Identifiable {
    public enum Behavior: String, Codable, Sendable { case auto, pan }
    public var id = UUID()
    public var source: URL
    public var bookmark: Data?
    public var sourceRevision: FramingSourceRevision?
    public var profile: FramingProfile
    public var behavior: Behavior
    public var intent = FramingIntent.detail
    public var input: FramingGeometry
    public var target: FramingGeometry
    public var automatic: FramingGeometry?
    public var boxes: SubjectBoxes
    public var evidence: FramingEvidence
    public var capturedGroup: SubjectKind?
    public var group: String
    public var validation = false
    public var created = Date()
    public var resolverVersion = 1
    public init(source: URL, profile: FramingProfile, behavior: Behavior, input: ViewTransform,
                target: ViewTransform, boxes: SubjectBoxes, evidence: FramingEvidence = .init()) throws {
        self.source = source; self.profile = profile; self.behavior = behavior
        self.input = try FramingGeometry(input); self.target = try FramingGeometry(target)
        self.boxes = boxes; self.evidence = evidence; group = source.deletingLastPathComponent().path
        guard isValid else { throw FramingLearningError.invalid }
    }
    public var isValid: Bool {
        input.isValid && target.isValid && input.imageSize == target.imageSize && input.viewSize == target.viewSize
            && profile.isValid && evidence.selectionThreshold.isFinite && (0...1).contains(evidence.selectionThreshold)
            && instances.allSatisfy { $0.score.isFinite && (0...1).contains($0.score) && SubjectFraming.validRect($0.rect) != nil }
    }
    public var instances: [FramingInstance] {
        FramingInstance.all(in: boxes)
    }

    public func replaces(_ other: Self) -> Bool {
        profile.name == other.profile.name && source.standardizedFileURL == other.source.standardizedFileURL
            && target.viewSize == other.target.viewSize && behavior == other.behavior && intent == other.intent
    }
}

public enum FramingIntent: String, Codable, CaseIterable, Sendable {
    case detail, overview
    public var title: String { self == .detail ? "Detail" : "Overview" }
}

public struct FramingComparisonVote: Codable, Equatable, Sendable, Identifiable {
    public enum Choice: String, Codable, Sendable { case first, second, equal, bothPoor }
    public var id = UUID()
    public var referenceID: UUID
    public var runID: UUID
    public var candidateFirst: Bool
    public var choice: Choice
    public var referenceSnapshot: FramingReference?
    public var baseline: FramingGeometry?
    public var candidate: FramingGeometry?
    public var datasetRevision: UInt64?
    public init(referenceID: UUID, runID: UUID, candidateFirst: Bool, choice: Choice,
                referenceSnapshot: FramingReference? = nil, baseline: FramingGeometry? = nil,
                candidate: FramingGeometry? = nil, datasetRevision: UInt64? = nil) {
        self.referenceID = referenceID; self.runID = runID; self.candidateFirst = candidateFirst; self.choice = choice
        self.referenceSnapshot = referenceSnapshot; self.baseline = baseline; self.candidate = candidate; self.datasetRevision = datasetRevision
    }
}

public struct FramingDataset: Codable, Equatable, Sendable {
    public var schema = 1
    public var revision: UInt64 = 0
    public var references: [FramingReference] = []
    public var votes: [FramingComparisonVote] = []
    public var policies: [FramingPolicy] = []
    private var feedback: [FramingObjectFeedback]?
    public var objectFeedback: [FramingObjectFeedback] {
        get { feedback ?? [] }
        set { feedback = newValue }
    }
    public init() {}
}
