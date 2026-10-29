import Foundation

/// Framing while browsing's memory from photo to photo (`step-zoom=subject`, owner, 2026-10-28): how big each kind of
/// subject was shown, so the next photo shows its subject as big; and the photo left, so a next photo with its subject
/// in about the same place (a burst) keeps the view as it was.
public struct BrowseFraming: Equatable, Sendable {
    /// How big each kind's frame was on screen (`subject-size`'s share of the view).
    public private(set) var sizes: [SubjectKind: Double] = [:]
    /// The view framing gave a photo, until it is left: while the view is still it the sizes are kept as they were
    /// rather than measured again (the framing's clamps would otherwise drift them from photo to photo).
    public var framed: (url: URL, view: ViewTransform)? {
        get { framedView.map { ($0.url, $0.view) } }
        set { framedView = newValue.map { Framed(url: $0.url, view: $0.view) } }
    }
    private var framedView: Framed?
    /// The photo left: what its framing looked at and the view it had.
    private var left: Left?

    private struct Framed: Equatable, Sendable { var url: URL; var view: ViewTransform }
    private struct Left: Equatable, Sendable { var target: Target; var view: ViewTransform }

    /// What a photo's framing looks at: a kind's frame (`SubjectFraming.frame`), or a head guessed on a person.
    public struct Target: Equatable, Sendable {
        public var kind: SubjectKind
        public var frame: CGRect
        /// The head is guessed from a person's box (`guessedHead`), no face was found.
        public var guessed: Bool
    }

    /// A person's frame is about this many of its head's frames high (the face's head as `SubjectFraming.head` grows it,
    /// with the margin): about 6 for a standing person, 3 from the waist up; between, so a guess is never far off.
    public static let headsPerPerson = 4.0
    /// The next photo's subject about where the photo left had it: its frame's centre moved by at most this share of
    /// the frame's size on each axis…
    public static let steadyShift = 0.05
    /// …and its size within this factor. Chosen, not measured yet: a burst's boxes should wander less, a recomposed shot
    /// move farther; to be checked on the owner's bursts.
    public static let steadyScale = 1.08

    /// The kind `⇧Z` chose to follow (owner, 2026-10-28): framed ahead of the chain on every photo that has it; nil:
    /// the chain's choice.
    public var followed: SubjectKind?

    private var profile = "vision"
    private var profileSizes: [String: [SubjectKind: Double]] = [:]
    private func key(_ kind: SubjectKind) -> SubjectKind {
        SubjectKind(rawValue: kind.parts.map(\.rawValue).sorted().joined(separator: "+")) ?? kind
    }
    public mutating func useProfile(_ name: String) {
        guard name != profile else { return }
        profileSizes[profile] = sizes
        sizes = profileSizes[name] ?? [:]
        profile = name; left = nil; framedView = nil
    }
    public init() {}

    /// `chain` with the kind followed first.
    public func chain(_ chain: [SubjectKind]) -> [SubjectKind] {
        guard let followed else { return chain }
        return [followed] + chain.filter { $0 != followed }
    }

    /// `⇧Z` under framing while browsing: follows the next of the kinds found on the photo shown at `t`, in the order of
    /// ⇧Z's steps (`PhotoSwitchView.subjectSteps`: narrow to wide, one framing about the same as the one before left
    /// out), round, at subject-size again. The kind, its place from 0 and the count; nil when nothing was found.
    public mutating func followNext(_ t: ViewTransform, boxes: SubjectBoxes,
                                    rules: ZoomRules) -> (kind: SubjectKind, index: Int, count: Int)? {
        let kinds = PhotoSwitchView.subjectSteps(t, boxes: boxes, rules: rules).map(\.kind)
        guard !kinds.isEmpty else { return nil }
        let now = target(boxes, chain: rules.chain, imageSize: t.imageSize)
        let next = now.flatMap { n in n.guessed ? nil : kinds.firstIndex(of: n.kind) }.map { ($0 + 1) % kinds.count } ?? 0
        followed = kinds[next]
        // The kind followed now is framed at subject-size (the mode's under the detector), not at the size it happened
        // to have on screen while another was framed (owner, 2026-10-28: after N the target stayed smaller).
        forgetSizes()
        return (kinds[next], next, kinds.count)
    }

    /// Forgets the sizes and the photo left (another mode of the custom detector, or the same chosen again): the next
    /// frame is the mode's size.
    public mutating func forgetSizes() {
        sizes = [:]
        profileSizes[profile] = [:]
        left = nil
    }

    /// Forgets the photo left (the folder changed, the mode was left): the sizes stay.
    public mutating func forgetLeft() { left = nil }

    /// What `boxes`' framing looks at under `chain` (the kind followed first): the chain's first kind found; a head guessed on the people when a
    /// face was being followed (`sizes` has one), the chain puts faces first and none was found.
    public func target(_ boxes: SubjectBoxes, chain: [SubjectKind], imageSize: CGSize) -> Target? {
        let chain = self.chain(chain)
        guard let kind = chain.first(where: { !boxes.boxes($0).isEmpty }),
              let frame = SubjectFraming.frame(boxes, chain: [kind]) else { return nil }
        if kind != .face, sizes[.face] != nil, let face = chain.firstIndex(of: .face), face < chain.firstIndex(of: kind)!,
           let head = Self.guessedHead(boxes.people, imageSize: imageSize) {
            return Target(kind: .face, frame: head, guessed: true)
        }
        return Target(kind: kind, frame: frame, guessed: false)
    }

    /// The head's frame guessed on `people` (normalised): a square of the person's height over `headsPerPerson` at the
    /// top of its box, in the middle of it; of several people, all their heads. Nil without people.
    public static func guessedHead(_ people: [CGRect], imageSize: CGSize) -> CGRect? {
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }
        let heads = people.map { p -> CGRect in
            let h = p.height / headsPerPerson
            let w = min(h * imageSize.height / imageSize.width, p.width)
            return CGRect(x: p.midX - w / 2, y: p.minY, width: w, height: h)
        }
        guard let first = heads.first else { return nil }
        return heads.dropFirst().reduce(first) { $0.union($1) }
    }

    /// The photo `url`, shown at `view`, is left with its `boxes` (nil: not known): the size of every kind found on it
    /// is taken from the view when the user changed it since it was framed, else only the kinds not known yet are added.
    public mutating func leave(_ url: URL, view: ViewTransform, boxes: SubjectBoxes?, chain: [SubjectKind], options: CompositionOptions? = nil, manualZoom: Bool? = nil) {
        guard let boxes else { left = nil; return }
        let chosen: Target?
        if let options {
            chosen = self.chain(chain).lazy.compactMap { kind -> Target? in
                SubjectFraming.composition(boxes, kind: kind, options: options).map { Target(kind: kind, frame: $0.frame, guessed: false) }
            }.first
        } else { chosen = target(boxes, chain: chain, imageSize: view.imageSize) }
        guard let target = chosen else {
            left = nil
            return
        }
        // An untouched automatic result never teaches a new size. Only the active group can learn.
        let changedScale: Bool
        if let previous = framedView, previous.url == url {
            changedScale = previous.view.imageSize == view.imageSize && previous.view.viewSize == view.viewSize
                && abs(previous.view.scale - view.scale) > 1e-9
        } else { changedScale = true }
        if manualZoom != false && changedScale {
            sizes[key(target.kind)] = min(max(Self.size(view, frame: target.frame), 0.2), 1)
        }
        left = Left(target: target, view: view)
    }

    /// How big `frame` (normalised) is on screen in `t`: the share of the view it takes on the side that binds, as
    /// `subject-size` (the inverse of `SubjectFraming.scale` before its clamps; above 1 when larger than the view).
    public static func size(_ t: ViewTransform, frame: CGRect) -> Double {
        guard t.viewSize.width > 0, t.viewSize.height > 0 else { return 0 }
        return t.scale * max(frame.width * t.imageSize.width / t.viewSize.width,
                             frame.height * t.imageSize.height / t.viewSize.height)
    }

    /// The size `kind` is framed at: its own carried; a face's from a person's and back by `headsPerPerson`; else the
    /// size of what the photo left looked at, else `rules.subjectSize`.
    public func size(of kind: SubjectKind, rules: ZoomRules) -> Double {
        if let size = sizes[key(kind)] { return size }
        return rules.subjectSize
    }

    /// The view framing while browsing gives the photo shown at `shown`: the view of the photo left when its subject is
    /// about where it was there (`steadyShift`, `steadyScale`); else the target at its size, panned by
    /// `SubjectFraming.pan`. Nil when nothing of the chain was found.
    public func frame(_ shown: ViewTransform, boxes: SubjectBoxes, rules: ZoomRules) -> ViewTransform? {
        guard let target = target(boxes, chain: rules.chain, imageSize: shown.imageSize) else { return nil }
        if target.guessed {
            let c = SubjectComposition(frame: target.frame, desiredCenter: CGPoint(x: target.frame.midX, y: target.frame.midY),
                                       maxZoom: rules.composition.maxZoom)
            return c.transform(shown, autoZoom: true, size: size(of: target.kind, rules: rules))
        }
        guard let c = SubjectFraming.composition(boxes, kind: target.kind, options: rules.composition) else { return nil }
        return c.transform(shown, autoZoom: true, size: size(of: target.kind, rules: rules))
    }

    /// The same subject about in the same place: the same kind, its frame's centre and size close.
    static func steady(_ a: Target, _ b: Target) -> Bool {
        guard a.kind == b.kind, a.guessed == b.guessed, a.frame.width > 0, a.frame.height > 0,
              b.frame.width > 0, b.frame.height > 0 else { return false }
        let ratio = max(a.frame.width / b.frame.width, b.frame.width / a.frame.width,
                        a.frame.height / b.frame.height, b.frame.height / a.frame.height)
        return abs(a.frame.midX - b.frame.midX) <= steadyShift * max(a.frame.width, b.frame.width)
            && abs(a.frame.midY - b.frame.midY) <= steadyShift * max(a.frame.height, b.frame.height)
            && ratio <= steadyScale
    }

    /// The status bar's name for a view under framing while browsing: what it looks at and how big that is on screen
    /// ("Face 60 %"; a head guessed on a person reads "Head"). Nil when nothing of the chain was found.
    public func indicator(_ t: ViewTransform, boxes: SubjectBoxes, rules: ZoomRules) -> (name: String, size: Double)? {
        guard let target = target(boxes, chain: rules.chain, imageSize: t.imageSize) else { return nil }
        return (target.guessed ? "Head" : target.kind.title, Self.size(t, frame: target.frame))
    }
}
