import CoreGraphics

/// The view a newly shown photo gets when the session has no remembered or saved framing to apply.
/// The rules belong to the destination photo's folder.
public enum PhotoSwitchView {
    /// How the photo comes on screen: it is the photo the view is laid out for already (a finer level of it arrived,
    /// the cache asks about it again), another photo stepped to, or the photo `open` brought (a launch, Finder's Open).
    public enum Arrival: Sendable {
        case laidOut, switched, opened
    }

    /// The photo laid out already keeps its view whatever the rules (only its size is taken anew, as before); a switch
    /// follows `next`, an opened photo `opened`. `rules` is read only for those two: the session asks about the photo
    /// on screen on every change, and its folder's settings need not be looked up for it.
    public static func shown(_ arrival: Arrival, current: ViewTransform, imageSize: CGSize,
                             rules: @autoclosure () -> ZoomRules, subject: SubjectBoxes? = nil,
                             manualReference: ViewTransform? = nil) -> ViewTransform {
        switch arrival {
        case .laidOut: return current.withImageSize(imageSize)
        case .switched:
            return next(current: current, imageSize: imageSize, rules: rules(), subject: subject,
                        manualReference: manualReference)
        case .opened: return opened(viewSize: current.viewSize, imageSize: imageSize, rules: rules())
        }
    }

    /// A switch to another photo from `current`. With `keep`, use the mode from `manualReference` or the current view,
    /// and translate free zoom by `keep-zoom-as`. Otherwise use `defaultMode`. Where the view lands is `step-pan`'s
    /// either way (`pan`: `keep` keeps the relative centre also when the zoom is not kept).
    /// It takes `fit-upscale` from the rules, and the transient offset and stretch go. `subject`:
    /// the new photo's boxes when they are known already, for `step-pan=subject`.
    public static func next(current: ViewTransform, imageSize: CGSize, rules: ZoomRules,
                            subject: SubjectBoxes? = nil, manualReference: ViewTransform? = nil) -> ViewTransform {
        var t: ViewTransform
        if rules.keep {
            let reference = manualReference ?? current
            t = current.withImageSize(imageSize).withMode(reference.mode)
            t.fitUpscale = rules.fitUpscale
            t = t.carryingZoom(from: reference, rules.carry)
            // A small file can otherwise get a much larger pixel scale than the user chose.
            // This applies to automatic manual carry; fixed percentage presets and SmartZoom keep their own rules.
            if manualReference != nil, rules.carry == .share, case .free = reference.mode {
                let maximum = max(reference.scale, 1)
                if t.scale > maximum { t.mode = .free(maximum / t.fitScale) }
            }
        } else {
            t = opened(viewSize: current.viewSize, imageSize: imageSize, rules: rules)
        }
        switch rules.pan {
        case .keep: t.center = current.center   // the place, also when the photo opens in the default mode
        case .center: t.center = CGPoint(x: 0.5, y: 0.5)
        case .subject: t.center = subjectCentre(subject, rules: rules, imageSize: imageSize, viewSize: current.viewSize)
        }
        return t
    }

    /// Zoom to Subject's view of `t`'s photo (smart zoom spec §3, §4): the subject's frame at `rules.subjectSize` of the
    /// view, centred on it as near as the photo's edges let it (`ViewTransform.clamped`); nil when no kind of
    /// `rules.chain` was found.
    public static func subjectTransform(_ t: ViewTransform, boxes: SubjectBoxes, rules: ZoomRules) -> ViewTransform? {
        guard let kind = rules.chain.first(where: { SubjectFraming.composition(boxes, kind: $0, options: rules.composition, imageSize: t.imageSize) != nil }),
              let c = SubjectFraming.composition(boxes, kind: kind, options: rules.composition, imageSize: t.imageSize) else { return nil }
        return c.transform(t, autoZoom: true, size: rules.subjectSize)
    }

    /// Framing while browsing (`step-zoom=subject`): `subjectTransform`'s scale, centred by `SubjectFraming.pan` so the
    /// subject's frame is whole and as much of every other box found shows as fits, drawn to the frame's centre by
    /// `rules.subjectPull`; nil when no kind of the chain was found.
    public static func subjectFraming(_ t: ViewTransform, boxes: SubjectBoxes, rules: ZoomRules) -> ViewTransform? {
        subjectTransform(t, boxes: boxes, rules: rules)
    }

    /// `frame` (normalised) framed as `subjectFraming` frames a subject: at `size` of the view, panned by
    /// `SubjectFraming.pan` with `others` and `pull` (`BrowseFraming`).
    public static func subjectFraming(_ t: ViewTransform, frame: CGRect, others: [CGRect], size: Double,
                                      pull: Double) -> ViewTransform {
        let scale = SubjectFraming.scale(frame: frame, size: size, imageSize: t.imageSize, viewSize: t.viewSize,
                                         limits: t.scaleLimits, fit: t.fitScale)
        var framed = t.withMode(.free(scale / t.fitScale))
        let window = CGSize(width: t.viewSize.width / (framed.scale * t.imageSize.width),
                            height: t.viewSize.height / (framed.scale * t.imageSize.height))
        framed.center = SubjectFraming.pan(main: frame, others: others, window: window, pull: pull)
        return framed
    }

    /// One of ⇧Z's steps: a kind found in the photo and its framing.
    public struct SubjectStep: Equatable, Sendable {
        public var kind: SubjectKind
        public var transform: ViewTransform
    }

    /// A step framing about what the one before did is left out: its scale within this factor…
    public static let sameStepScale = 1.15
    /// …and its centre within this share of the view's short side.
    public static let sameStepCentre = 0.1

    /// ⇧Z's steps (owner, 2026-10-28): every kind found, each framed as `subjectTransform` frames it at `subject-size`,
    /// narrow (the largest scale) to wide; one that frames about what the step before did is left out. Under the custom
    /// detector, the targets of its mode's chain found, in the chain's order.
    public static func subjectSteps(_ t: ViewTransform, boxes: SubjectBoxes, rules: ZoomRules) -> [SubjectStep] {
        var one = rules
        let kinds = rules.stepKinds
        let found = kinds.compactMap { kind -> SubjectStep? in
            one.chain = [kind]
            return subjectTransform(t, boxes: boxes, rules: one).map { SubjectStep(kind: kind, transform: $0) }
        }
        return found
    }

    /// Where `step-pan=subject` lands: the centre of the subject's frame (`SubjectFraming`, the kinds of `rules.chain`),
    /// else `fallbackCentre`.
    public static func subjectCentre(_ boxes: SubjectBoxes?, rules: ZoomRules, imageSize: CGSize,
                                     viewSize: CGSize) -> CGPoint {
        boxes.flatMap { boxes in
            rules.chain.lazy.compactMap { SubjectFraming.composition(boxes, kind: $0, options: rules.composition, imageSize: imageSize)?.desiredCenter }.first
        }
            ?? fallbackCentre(imageSize: imageSize, viewSize: viewSize)
    }

    /// Where `step-pan=subject` lands while the photo's subjects are not known: the top of a photo taller than the
    /// view's shape (a face is usually there; `clamped` pulls 0 to the top edge), else the middle.
    public static func fallbackCentre(imageSize: CGSize, viewSize: CGSize) -> CGPoint {
        guard imageSize.width > 0, viewSize.width > 0,
              imageSize.height / imageSize.width > viewSize.height / viewSize.width else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: 0.5, y: 0)
    }

    /// The first photo at launch, or one opened from Finder: `defaultMode`, centred, whatever `keep` says.
    public static func opened(viewSize: CGSize, imageSize: CGSize, rules: ZoomRules) -> ViewTransform {
        ViewTransform(imageSize: imageSize, viewSize: viewSize, mode: rules.defaultMode, fitUpscale: rules.fitUpscale)
    }
}
