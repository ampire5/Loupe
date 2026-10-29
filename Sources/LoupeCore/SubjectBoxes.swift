import CoreGraphics

/// What a photo's subjects are and where (smart zoom spec §5): rects normalised to the oriented photo, origin top-left,
/// y down, as `ViewTransform.center`. Found by `SubjectDetector`, kept in memory and in `Loupe.db`; `version` voids
/// stored boxes when the detection changes.
public struct SubjectBoxes: Codable, Equatable, Sendable {
    public static let version = 8

    public var analysisID: String? = nil
    public var version: Int
    public var faces: [CGRect]
    public var people: [CGRect]
    /// Animals and the things in front (Vision's foreground instances).
    public var objects: [CGRect]
    /// Where the eye goes (attention saliency), also without a subject.
    public var saliency: [CGRect]
    /// What the custom detector found (`ModelDetector`, detector.conf's model and classes), each with its
    /// confidence; empty when it was not looked for. `boxes(_:)` gives those at `SubjectFraming.detector.score` or more.
    public var detections: [Detection] = []
    /// A box of a class of the custom detector and how sure the model is of it.
    public struct Detection: Codable, Equatable, Sendable {
        public var kind: SubjectKind
        public var rect: CGRect
        public var score: Double
        public init(kind: SubjectKind, rect: CGRect, score: Double) {
            self.kind = kind
            self.rect = rect
            self.score = score
        }
    }
    /// The chain they were looked for with (`subject-target`): a kind it does not name was not looked for, so boxes
    /// found for another chain are looked for again.
    public var searched: [SubjectKind]
    /// Whether the photo was drawn with its EXIF orientation applied (`exif-orientation`): boxes of the other layout
    /// would land on a turned spot, so they are looked for again.
    public var applied: Bool
    /// The long side of the proxy they were found on: boxes from a coarse level are kept in memory only and looked for
    /// again once a finer level is in (`SubjectFinder.minimumProxy`).
    public var proxySide: Int

    public init(faces: [CGRect], people: [CGRect], objects: [CGRect], saliency: [CGRect],
                searched: [SubjectKind] = SubjectKind.vision, applied: Bool = true, proxySide: Int = 1536,
                detections: [Detection] = []) {
        version = Self.version
        self.detections = detections
        self.searched = searched
        self.applied = applied
        self.proxySide = proxySide
        self.faces = faces
        self.people = people
        self.objects = objects
        self.saliency = saliency
    }

    public var isEmpty: Bool { faces.isEmpty && people.isEmpty && objects.isEmpty && saliency.isEmpty && detections.isEmpty }

    /// The boxes of `kind`: a custom class's at the detector's score or more; a target of several classes, the ones
    /// `SubjectFraming.pick` frames (empty when they are not all found or too far apart).
    public func boxes(_ kind: SubjectKind) -> [CGRect] {
        if kind.isCombination { return SubjectFraming.pick(self, kind) ?? [] }
        switch kind {
        case .face: return faces
        case .person: return people
        case .object: return objects
        case .saliency: return saliency
        default:
            let score = SubjectFraming.detector.score
            return detections.filter { $0.kind == kind && $0.score >= score }.map(\.rect)
        }
    }

    /// Replaces the boxes of `kind` (one kind, not a combination); a detection keeps its score.
    public mutating func set(_ kind: SubjectKind, _ rects: [CGRect]) {
        switch kind {
        case .face: faces = rects
        case .person: people = rects
        case .object: objects = rects
        case .saliency: saliency = rects
        default: detections.removeAll { $0.kind == kind && !rects.contains($0.rect) }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version, faces, people, objects, saliency, detections, searched, applied, proxySide, analysisID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        analysisID = try c.decodeIfPresent(String.self, forKey: .analysisID)
        version = try c.decode(Int.self, forKey: .version)
        faces = try c.decode([CGRect].self, forKey: .faces)
        people = try c.decode([CGRect].self, forKey: .people)
        objects = try c.decode([CGRect].self, forKey: .objects)
        saliency = try c.decode([CGRect].self, forKey: .saliency)
        detections = try c.decodeIfPresent([Detection].self, forKey: .detections) ?? []
        searched = try c.decode([SubjectKind].self, forKey: .searched)
        applied = try c.decode(Bool.self, forKey: .applied)
        proxySide = try c.decode(Int.self, forKey: .proxySide)
    }
}

/// A kind of subject, as `subject-target` and detector.conf name it: one of Vision's (`face`, `person`, `object`,
/// `saliency`), a class of the custom detector by the name detector.conf gives it, or several of those joined by `+`,
/// framed together.
public struct SubjectKind: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    /// Nil for a name that is no kind: a class's name is lower-case letters, digits and `-`, starting with a letter; a
    /// combination joins distinct classes (not Vision's kinds). Whether a class is the detector's is detector.conf's to
    /// check (`DetectorSetup.parse`).
    public init?(rawValue: String) {
        let names = rawValue.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard names.allSatisfy(Self.isName) else { return nil }
        if names.count > 1 {
            guard names.allSatisfy({ n in !Self.vision.contains { $0.rawValue == n } }), Set(names).count == names.count
            else { return nil }
        }
        self.rawValue = names.joined(separator: "+")
    }

    private init(_ name: String) { rawValue = name }

    static func isName(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, ("a"..."z").contains(first) else { return false }
        return s.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    public init(from decoder: Decoder) throws {
        let name = try decoder.singleValueContainer().decode(String.self)
        guard let kind = Self(rawValue: name) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "no kind \(name)"))
        }
        self = kind
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public static let face = Self("face"), person = Self("person"), object = Self("object"), saliency = Self("saliency")

    /// Vision's kinds, found on every photo.
    public static let vision: [SubjectKind] = [.face, .person, .object, .saliency]

    /// The kinds a combination joins; one kind is itself.
    public var parts: [SubjectKind] { rawValue.split(separator: "+").map { Self(String($0)) } }
    public var isCombination: Bool { rawValue.contains("+") }
    /// A class of the custom detector, or a combination of them.
    public var isCustom: Bool { !Self.vision.contains(self) }

    /// The name the status bar and the toasts use ("Face", "Cat+Ball").
    public var title: String {
        let names: [String: String] = ["face": "Face", "person": "Person", "object": "Object", "saliency": "Eye"]
        return parts.map { names[$0.rawValue] ?? $0.rawValue.capitalized }.joined(separator: "+")
    }

    public var description: String { rawValue }
}
