import CoreGraphics
import Testing
@testable import LoupeCore

// M4b spec §4.2: the view a newly shown photo gets.

private func rules(keep: Bool = true, mode: ZoomMode = .fit, fitUpscale: Bool = true,
                   carry: ZoomCarry = .share, pan: StepPan = .keep,
                   chain: [SubjectKind] = SubjectKind.vision) -> ZoomRules {
    var c = Config()
    c.subjectTarget = chain
    c.keepZoomAs = carry
    c.stepPan = pan
    c.keepZoomPosition = keep
    c.defaultZoomMode = mode
    c.fitUpscale = fitUpscale
    var r = ZoomRules(config: c); r.composition.maxZoom = 4
    return r
}

private let view = CGSize(width: 2000, height: 1000)
private let newSize = CGSize(width: 600, height: 400)

/// A view zoomed in somewhere off-centre, with transient state (a rubber-band offset and a zoom stretch) on it.
private func zoomedIn(mode: ZoomMode = .actual(2)) -> ViewTransform {
    var t = ViewTransform(imageSize: CGSize(width: 4000, height: 3000), viewSize: view, mode: mode,
                          center: CGPoint(x: 0.2, y: 0.7))
    t.offset = CGVector(dx: 12, dy: -5)
    t.stretch = ZoomStretch(factor: 1.1, anchor: CGPoint(x: 100, y: 100))
    return t
}

@Test func photoSwitchViewKeepKeepsModeAndCentre() {
    let next = PhotoSwitchView.next(current: zoomedIn(), imageSize: newSize, rules: rules(keep: true))
    #expect(next.mode == .actual(2))
    #expect(next.center == CGPoint(x: 0.2, y: 0.7))
    #expect(next.imageSize == newSize)
    #expect(next.viewSize == view)
    #expect(next.offset == .zero)
    #expect(next.stretch == nil)
}

@Test func photoSwitchViewNoKeepOpensInTheDefaultModeCentred() {
    for mode in [ZoomMode.actual(1), .fitWidth, .fit, .fitHeight, .fill, .actual(2.5)] {
        let next = PhotoSwitchView.next(current: zoomedIn(), imageSize: newSize, rules: rules(keep: false, mode: mode, pan: .center))
        #expect(next.mode == mode, "\(mode)")
        #expect(next.center == CGPoint(x: 0.5, y: 0.5), "\(mode)")
        #expect(next.imageSize == newSize && next.viewSize == view, "\(mode)")
        #expect(next.offset == .zero && next.stretch == nil, "\(mode)")
    }
}

@Test func photoSwitchViewCopiesFitUpscale() {
    for keep in [true, false] {
        for on in [true, false] {
            var current = zoomedIn(mode: .fit)
            current.fitUpscale = !on
            let next = PhotoSwitchView.next(current: current, imageSize: newSize, rules: rules(keep: keep, fitUpscale: on))
            #expect(next.fitUpscale == on, "keep \(keep), fit-upscale \(on)")
            let opened = PhotoSwitchView.opened(viewSize: view, imageSize: newSize, rules: rules(keep: keep, fitUpscale: on))
            #expect(opened.fitUpscale == on, "keep \(keep), fit-upscale \(on)")
        }
    }
    // A small photo in Fit without fit-upscale stands at 100 %.
    let small = PhotoSwitchView.next(current: zoomedIn(mode: .fit), imageSize: newSize, rules: rules(fitUpscale: false))
    #expect(small.scale == 1)
}

/// The session passes `zoomTarget ?? transform`: a photo switched to while a zoom key's animation runs gets the mode the
/// key asked for, which `next` keeps (a named mode, not the `.free` frame on the way).
@Test func photoSwitchViewSwitchUsesTargetMidAnimation() {
    let target = zoomedIn(mode: .actual(1))
    let next = PhotoSwitchView.next(current: target, imageSize: newSize, rules: rules(keep: true))
    #expect(next.mode == .actual(1))
    #expect(next.scale == 1)
    // The frame on the way would have carried its `.free` scale over instead.
    let frame = PhotoSwitchView.next(current: zoomedIn(mode: .free(1.4)), imageSize: newSize, rules: rules(keep: true))
    #expect(frame.mode != .actual(1))
}

/// `keep-zoom-as`: a free zoom on a landscape photo carried to the same photo turned portrait keeps its scale either
/// way (its ratio to Fit would have jumped by the aspect ratio); to a photo of four times the pixels, `share` doubles
/// the scale (the same share in view) and `scale` keeps it. Named modes are left alone.
@Test func photoSwitchViewCarriesAFreeZoomByShareOrScale() {
    let landscape = ViewTransform(imageSize: CGSize(width: 6000, height: 4000), viewSize: view, mode: .free(2))
    let s = landscape.scale
    for carry in [ZoomCarry.share, .scale] {
        let portrait = PhotoSwitchView.next(current: landscape, imageSize: CGSize(width: 4000, height: 6000),
                                            rules: rules(carry: carry))
        #expect(abs(portrait.scale - s) < 1e-9, "\(carry)")
    }
    let big = CGSize(width: 12000, height: 8000)
    #expect(abs(PhotoSwitchView.next(current: landscape, imageSize: big, rules: rules(carry: .share)).scale - s / 2) < 1e-9)
    #expect(abs(PhotoSwitchView.next(current: landscape, imageSize: big, rules: rules(carry: .scale)).scale - s) < 1e-9)
    let fitWidth = ViewTransform(imageSize: CGSize(width: 6000, height: 4000), viewSize: view, mode: .fitWidth)
    #expect(PhotoSwitchView.next(current: fitWidth, imageSize: big, rules: rules(carry: .scale)).mode == .fitWidth)
}

/// A resize keeps a free zoom's framing (its ratio to Fit), or with `keepingScale` its scale.
@Test func resizeKeepsFramingOrScale() {
    let t = ViewTransform(imageSize: CGSize(width: 6000, height: 4000), viewSize: view, mode: .free(2))
    let smaller = CGSize(width: 1000, height: 500)
    #expect(t.withViewSize(smaller).mode == .free(2))
    #expect(abs(t.withViewSize(smaller, carry: .scale).scale - t.scale) < 1e-9)
    let unlaid = ViewTransform(imageSize: t.imageSize, viewSize: .zero, mode: .free(2))
    #expect(unlaid.withViewSize(view, carry: .scale).mode == .free(2))
}

@Test func photoSwitchViewOpenedUsesTheDefaultModeCentred() {
    for keep in [true, false] {
        for mode in [ZoomMode.fit, .actual(1), .fitWidth, .fill] {
            let t = PhotoSwitchView.opened(viewSize: view, imageSize: newSize, rules: rules(keep: keep, mode: mode))
            #expect(t.mode == mode && t.center == CGPoint(x: 0.5, y: 0.5), "keep \(keep) \(mode)")
            #expect(t.imageSize == newSize && t.viewSize == view)
            #expect(t.offset == .zero && t.stretch == nil)
        }
    }
}

/// `shown`, the whole choice for a photo without a saved view: the photo already laid out keeps its view whatever the
/// rules (a level arriving must not reset a zoom made on it), a switch follows `next`, an opened photo `opened`.
@Test func photoSwitchViewShownByArrival() {
    let current = zoomedIn()
    let noKeep = rules(keep: false, mode: .fitWidth)
    let same = PhotoSwitchView.shown(.laidOut, current: current, imageSize: current.imageSize, rules: noKeep)
    #expect(same == current.withImageSize(current.imageSize))
    #expect(same.mode == .actual(2) && same.center == CGPoint(x: 0.2, y: 0.7))
    #expect(PhotoSwitchView.shown(.switched, current: current, imageSize: newSize, rules: noKeep)
            == PhotoSwitchView.next(current: current, imageSize: newSize, rules: noKeep))
    let keep = rules(keep: true, mode: .fitWidth)
    #expect(PhotoSwitchView.shown(.switched, current: current, imageSize: newSize, rules: keep).mode == .actual(2))
    // Launch and Finder's Open: the default mode even with keep.
    let opened = PhotoSwitchView.shown(.opened, current: current, imageSize: newSize, rules: keep)
    #expect(opened == PhotoSwitchView.opened(viewSize: view, imageSize: newSize, rules: keep))
    #expect(opened.mode == .fitWidth)
}

// Smart zoom spec §2: `step-pan` on every step, the zoom kept or not.

@Test func stepPanKeepCentreAndSubjectFallback() {
    let tall = CGSize(width: 1000, height: 3000)   // taller than the 2:1 view's shape
    for keep in [true, false] {
        let kept = PhotoSwitchView.next(current: zoomedIn(), imageSize: newSize, rules: rules(keep: keep, pan: .keep))
        #expect(kept.center == CGPoint(x: 0.2, y: 0.7), "keep \(keep)")   // keep-zoom-position decides the zoom only
        let centred = PhotoSwitchView.next(current: zoomedIn(), imageSize: newSize, rules: rules(keep: keep, pan: .center))
        #expect(centred.center == CGPoint(x: 0.5, y: 0.5), "keep \(keep)")
        let subject = PhotoSwitchView.next(current: zoomedIn(), imageSize: tall, rules: rules(keep: keep, pan: .subject))
        #expect(subject.center == CGPoint(x: 0.5, y: 0), "keep \(keep)")
        let wide = PhotoSwitchView.next(current: zoomedIn(), imageSize: CGSize(width: 3000, height: 1000),
                                        rules: rules(keep: keep, pan: .subject))
        #expect(wide.center == CGPoint(x: 0.5, y: 0.5), "keep \(keep)")
    }
}

@Test func stepPanSubjectLandsOnTheBoxes() {
    let tall = CGSize(width: 1000, height: 3000)
    let boxes = SubjectBoxes(faces: [], people: [CGRect(x: 0.6, y: 0.5, width: 0.2, height: 0.4)], objects: [],
                             saliency: [])
    let on = PhotoSwitchView.next(current: zoomedIn(), imageSize: tall, rules: rules(pan: .subject), subject: boxes)
    #expect(abs(on.center.x - 0.7) < 1e-9 && abs(on.center.y - 0.7) < 1e-9)
    let noFace = PhotoSwitchView.next(current: zoomedIn(), imageSize: tall, rules: rules(pan: .subject, chain: [.face]),
                                      subject: boxes)
    #expect(noFace.center == CGPoint(x: 0.5, y: 0))
    let unknown = PhotoSwitchView.next(current: zoomedIn(), imageSize: tall, rules: rules(pan: .subject), subject: nil)
    #expect(unknown.center == CGPoint(x: 0.5, y: 0))
}

// Smart zoom spec §3, §4: Zoom to Subject's transform.
@Test func subjectTransformFramesTheSubject() {
    let t = ViewTransform(imageSize: CGSize(width: 1000, height: 1000), viewSize: CGSize(width: 2000, height: 1000))
    // A frame (with its margin) of 0.2 × 0.2 at the middle: a person box of 0.2 / 1.16.
    let side = 0.2 / 1.16
    let boxes = SubjectBoxes(faces: [], people: [CGRect(x: 0.5 - side / 2, y: 0.5 - side / 2, width: side, height: side)],
                             objects: [], saliency: [])
    let framed = PhotoSwitchView.subjectTransform(t, boxes: boxes, rules: rules(chain: [.person]))!
    #expect(abs(framed.scale - 3) < 1e-9)                       // 200 px of frame → 60 % of 1000
    #expect(abs(framed.center.x - 0.5) < 1e-9 && abs(framed.center.y - 0.5) < 1e-9)
    #expect(PhotoSwitchView.subjectTransform(t, boxes: boxes, rules: rules(chain: [.face])) == nil)
}

// Owner's report: after Zoom to Subject, a right-button press and a few points of drag up or down made the picture
// jump. The press changes nothing, and each half point of drag moves the subject no more than a few pixels: it stays
// under the anchor, or slides where the photo's edge holds the view (`clamped`, owner 2026-10-28), never jumps.
@Test func rightButtonZoomFromSubjectZoomDoesNotJump() {
    let t = ViewTransform(imageSize: CGSize(width: 4416, height: 2944), viewSize: CGSize(width: 4300, height: 2266))
    for (x, y) in [(0.85, 0.15), (0.5, 0.5), (0.1, 0.9), (0.95, 0.5)] {
        let boxes = SubjectBoxes(faces: [CGRect(x: x - 0.03, y: y - 0.04, width: 0.06, height: 0.08)], people: [],
                                 objects: [], saliency: [])
        let framed = PhotoSwitchView.subjectTransform(t, boxes: boxes, rules: rules(chain: [.face]))!
        let frame = SubjectFraming.frame(boxes, chain: [.face])!
        let subject = CGPoint(x: frame.midX * 4416, y: frame.midY * 2944)
        let onScreen = framed.viewPoint(forImage: subject)
        for anchor in [onScreen, CGPoint(x: 600, y: 400)] {
            let zoom = RMBZoom(anchor: anchor, transform: framed, pointsPerDoubling: 200)
            let pressed = zoom.transform(dyPoints: 0).viewPoint(forImage: subject)
            #expect(hypot(pressed.x - onScreen.x, pressed.y - onScreen.y) < 1e-6, "subject (\(x), \(y)) on the press")
            for sign in [-1.0, 1.0] {
                var last = onScreen
                for i in 1...20 {
                    let p = zoom.transform(dyPoints: sign * 0.5 * Double(i)).viewPoint(forImage: subject)
                    #expect(hypot(p.x - last.x, p.y - last.y) < 8,
                            "subject (\(x), \(y)) anchor \(anchor) dy \(sign * 0.5 * Double(i)): \(last) → \(p)")
                    last = p
                }
            }
        }
    }
}

// ⇧Z's steps (owner, 2026-10-28): every kind found, each framed at `subject-size`, narrow to wide; a step that frames
// about what the one before did (scale within 15 %, centre within a tenth of the view) is left out.
@Test func subjectStepsGoFromNarrowToWide() {
    let t = ViewTransform(imageSize: CGSize(width: 1000, height: 1000), viewSize: CGSize(width: 1000, height: 1000))
    let face = CGRect(x: 0.45, y: 0.2, width: 0.1, height: 0.1)                  // its head: 0.18 square about (0.5, 0.235)
    let boxes = SubjectBoxes(faces: [face], people: [CGRect(x: 0.35, y: 0.15, width: 0.3, height: 0.5)], objects: [],
                             saliency: [CGRect(x: 0.41, y: 0.145, width: 0.18, height: 0.18)])   // the head again
    let steps = PhotoSwitchView.subjectSteps(t, boxes: boxes, rules: rules(chain: [.saliency]))
    #expect(steps.map(\.kind) == [.face, .person, .saliency])
    #expect(steps[0].transform.scale > steps[1].transform.scale)
    #expect(steps[0].transform == PhotoSwitchView.subjectTransform(t, boxes: boxes, rules: rules(chain: [.face])))
    #expect(PhotoSwitchView.subjectSteps(t, boxes: SubjectBoxes(faces: [], people: [], objects: [], saliency: []),
                                         rules: rules()).isEmpty)
}

@Test func subjectFramingPullsTowardsTheSubject() {
    let t = ViewTransform(imageSize: CGSize(width: 1000, height: 1000), viewSize: CGSize(width: 1000, height: 1000))
    let boxes = SubjectBoxes(faces: [CGRect(x: 0.45, y: 0.3, width: 0.1, height: 0.1)], people: [], objects: [],
                             saliency: [CGRect(x: 0.68, y: 0.3, width: 0.05, height: 0.05)])
    var r = rules(chain: [.face])
    r.subjectPull = 1
    #expect(PhotoSwitchView.subjectFraming(t, boxes: boxes, rules: r) == PhotoSwitchView.subjectTransform(t, boxes: boxes, rules: r))
    r.subjectPull = 0
    let framed = PhotoSwitchView.subjectFraming(t, boxes: boxes, rules: r)!
    #expect(framed.scale == PhotoSwitchView.subjectTransform(t, boxes: boxes, rules: r)!.scale)
    #expect(framed.center.x == 0.5)      // unrelated saliency does not pull the selected group
    #expect(PhotoSwitchView.subjectFraming(t, boxes: SubjectBoxes(faces: [], people: [], objects: [], saliency: []), rules: r) == nil)
}

// Framing while browsing keeps how big the subject is on screen (owner, 2026-10-28): the share of the view its frame
// takes, the inverse of `subject-size`'s scale.
@Test func subjectSizeOnScreenIsTheFramingsInverse() {
    let t = ViewTransform(imageSize: CGSize(width: 1000, height: 1000), viewSize: CGSize(width: 2000, height: 1000))
    let side = 0.2 / 1.16
    let boxes = SubjectBoxes(faces: [], people: [CGRect(x: 0.5 - side / 2, y: 0.5 - side / 2, width: side, height: side)],
                             objects: [], saliency: [])
    let r = rules(chain: [.person])
    let framed = PhotoSwitchView.subjectTransform(t, boxes: boxes, rules: r)!       // subject-size 60 %: scale 3
    let frame = SubjectFraming.frame(boxes, chain: [.person])!
    #expect(abs(BrowseFraming.size(framed, frame: frame) - 0.6) < 1e-9)
    var closer = framed
    closer.mode = .free(6 / framed.fitScale)
    #expect(abs(BrowseFraming.size(closer, frame: frame) - 1.2) < 1e-9)   // past the view: above 1
}
