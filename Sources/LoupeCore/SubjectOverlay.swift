import CoreGraphics

/// What Show Subjects (`⇧G`) draws over the photo: every box Vision found, in view space (the transform's: physical
/// pixels, origin top-left, y down); the boxes of the kind the chain chose bold, a face's head as the framing grows it,
/// the frame with its margin and its centre: the point `step-pan=subject`, `zoom-anchor=subject` and Zoom to Subject
/// aim at (`SubjectFraming`).
public struct SubjectOverlay: Equatable, Sendable {
    public enum Role: Sendable { case found, chosen, head, frame }

    public struct Mark: Equatable, Sendable {
        /// Nil for the frame.
        public var kind: SubjectKind?
        public var role: Role
        public var rect: CGRect
        /// What the box is, drawn by it: its kind's title, with the detector's score for its own classes ("Ball 87 %");
        /// nil for a head and the frame.
        public var label: String?

        public init(kind: SubjectKind?, role: Role, rect: CGRect, label: String? = nil) {
            self.kind = kind
            self.role = role
            self.rect = rect
            self.label = label
        }
    }

    public var marks: [Mark] = []
    /// The frame's centre; nil when no kind of the chain was found.
    public var centre: CGPoint?

    /// `guessedHead`: the head framing while browsing guessed on a person (`BrowseFraming.guessedHead`), drawn dashed as
    /// a face's head and framed instead of the person.
    public init(_ boxes: SubjectBoxes, chain: [SubjectKind], transform: ViewTransform, guessedHead: CGRect? = nil, composition: SubjectComposition? = nil) {
        let chosen = chain.first { !boxes.boxes($0).isEmpty }
        func view(_ r: CGRect) -> CGRect {
            let size = transform.imageSize
            let a = transform.viewPoint(forImage: CGPoint(x: r.minX * size.width, y: r.minY * size.height))
            let b = transform.viewPoint(forImage: CGPoint(x: r.maxX * size.width, y: r.maxY * size.height))
            return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
        }
        func box(_ kind: SubjectKind, _ role: Role, _ r: CGRect) -> Mark {
            let score = kind.isCustom ? boxes.detections.first { $0.kind == kind && $0.rect == r }?.score : nil
            return Mark(kind: kind, role: role, rect: view(r),
                        label: kind.title + (score.map { " \(Int(($0 * 100).rounded())) %" } ?? ""))
        }
        // The kinds not chosen first, so the chosen ones are drawn over them.
        for kind in boxes.kinds.reversed() where kind != chosen {
            marks += boxes.boxes(kind).map { box(kind, .found, $0) }
        }
        guard let chosen, let frame = composition?.frame ?? SubjectFraming.frame(boxes, chain: chain) else { return }
        if chosen.isCustom {
            // The detector's boxes in the frame, each of its own kind; with its head where it frames one.
            for part in chosen.parts {
                for r in boxes.boxes(part) where frame.intersects(r) {
                    marks.append(box(part, .chosen, r))
                    if !chosen.isCombination && SubjectFraming.framesHead(part) { marks.append(Mark(kind: part, role: .head, rect: view(SubjectFraming.head(r)))) }
                }
            }
        } else {
            marks += boxes.boxes(chosen).map { box(chosen, .chosen, $0) }
            if chosen == .face { marks += boxes.faces.map { Mark(kind: .face, role: .head, rect: view(SubjectFraming.head($0))) } }
        }
        if let guessedHead { marks.append(Mark(kind: .face, role: .head, rect: view(guessedHead))) }
        let f = view(guessedHead ?? frame)
        marks.append(Mark(kind: nil, role: .frame, rect: f))
        if let composition {
            centre = transform.viewPoint(forImage: CGPoint(x: composition.desiredCenter.x * transform.imageSize.width,
                                                           y: composition.desiredCenter.y * transform.imageSize.height))
        } else { centre = CGPoint(x: f.midX, y: f.midY) }
    }

    /// The overlay's caption: each kind's count (`—` not looked for, `✓` the chain's choice), the custom detector's
    /// classes found, the proxy's side.
    /// `guessedHead`: the frame is a head guessed on a person ("head guessed"); `mode`: the custom detector's mode, first.
    public static func caption(_ boxes: SubjectBoxes, chain: [SubjectKind], guessedHead: Bool = false,
                               mode: String? = nil) -> String {
        let chosen = chain.first { !boxes.boxes($0).isEmpty }
        // The custom detector's mode whose chain this is.
        var parts = mode.map { ["Mode \($0)"] } ?? []
        parts += SubjectKind.vision.map { kind -> String in
            guard boxes.searched.contains(kind) else { return "\(kind.title) —" }
            return "\(kind.title) \(boxes.boxes(kind).count)" + (kind == chosen ? " ✓" : "")
        }
        // The custom detector's kinds found, and the target framed when it is theirs.
        for kind in boxes.kinds where kind.isCustom {
            let n = boxes.boxes(kind).count
            if n > 0 { parts.append("\(kind.title) \(n)") }
        }
        if let chosen, chosen.isCustom { parts.append("\(chosen.title) ✓") }
        if guessedHead { parts.append("head guessed") }
        parts.append("\(boxes.proxySide) px")
        if chosen == nil { parts.append("no subject") }
        return parts.joined(separator: " · ")
    }
}
