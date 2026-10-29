import CoreGraphics
import Foundation
import Testing
@testable import LoupeCore

// Framing while browsing from photo to photo (owner, 2026-10-28): the size follows the kind, a burst keeps its view.

private func rules(chain: [SubjectKind] = [.face, .person, .object, .saliency]) -> ZoomRules {
    var c = Config()
    c.subjectTarget = chain
    c.subjectPull = 50
    var r = ZoomRules(config: c); r.composition.maxZoom = 4
    return r
}

private let a = URL(fileURLWithPath: "/photos/a.jpg")
private let square = ViewTransform(imageSize: CGSize(width: 1000, height: 1000), viewSize: CGSize(width: 1000, height: 1000))
private let face = CGRect(x: 0.45, y: 0.2, width: 0.1, height: 0.1)
private func boxes(faces: [CGRect] = [], people: [CGRect] = []) -> SubjectBoxes {
    SubjectBoxes(faces: faces, people: people, objects: [], saliency: [])
}

/// The photo left showed its face at `size` of the view.
private func leftAFace(at size: Double) -> BrowseFraming {
    var f = BrowseFraming()
    let frame = SubjectFraming.frame(boxes(faces: [face]), chain: [.face])!
    let view = PhotoSwitchView.subjectFraming(square, frame: frame, others: [], size: size, pull: 1)
    f.leave(a, view: view, boxes: boxes(faces: [face]), chain: rules().chain)
    return f
}

@Test func aPersonWithoutAFaceIsFramedOnItsGuessedHeadAtTheFacesSize() {
    let f = leftAFace(at: 0.3)
    #expect(abs(f.sizes[.face]! - 0.3) < 1e-9)
    // The next photo: someone turned away, only the person is found.
    let person = CGRect(x: 0.6, y: 0.1, width: 0.2, height: 0.8)
    let next = boxes(people: [person])
    let target = f.target(next, chain: rules().chain, imageSize: square.imageSize)!
    #expect(target.kind == .face && target.guessed)
    #expect(abs(target.frame.height - 0.2) < 1e-9 && target.frame.minY == 0.1 && abs(target.frame.midX - 0.7) < 1e-9)
    let framed = f.frame(square, boxes: next, rules: rules())!
    #expect(abs(BrowseFraming.size(framed, frame: target.frame) - 0.3) < 1e-9)   // the head as big as the face was
    // Not following a face: the whole person, at subject-size.
    #expect(BrowseFraming().target(next, chain: rules().chain, imageSize: square.imageSize)?.kind == .person)
    // A chain that puts the person first frames it.
    #expect(f.target(next, chain: [.person, .face], imageSize: square.imageSize)?.kind == .person)
}

@Test func sizesNeverConvertBetweenDifferentGroups() {
    var f = BrowseFraming()
    let person = CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.4)   // its frame 0.464 high: 0.8 needs no clamp
    let frame = SubjectFraming.frame(boxes(people: [person]), chain: [.person])!
    let view = PhotoSwitchView.subjectFraming(square, frame: frame, others: [], size: 0.8, pull: 1)
    f.leave(a, view: view, boxes: boxes(people: [person]), chain: [.person])
    #expect(f.size(of: .face, rules: rules()) == rules().subjectSize)
    let g = leftAFace(at: 0.3)
    #expect(g.size(of: .person, rules: rules()) == rules().subjectSize)
    #expect(BrowseFraming().size(of: .person, rules: rules()) == rules().subjectSize)
}

@Test func aBurstKeepsTheViewOfThePhotoLeft() {
    var f = BrowseFraming()
    var mine = square.withMode(.free(3))
    mine.center = CGPoint(x: 0.47, y: 0.22)   // the user's own view, on the eyes
    f.leave(a, view: mine, boxes: boxes(faces: [face]), chain: rules().chain)
    let nudged = boxes(faces: [face.offsetBy(dx: 0.003, dy: -0.002)])
    let kept = f.frame(square, boxes: nudged, rules: rules())!
    #expect(kept != mine)  // New boxes are recomposed; a stale burst view cannot bypass visibility constraints.
    // Moved by a fifth of the face: framed anew.
    let moved = boxes(faces: [face.offsetBy(dx: 0.02, dy: 0)])
    #expect(f.frame(square, boxes: moved, rules: rules())!.center != mine.center)
    // Another photo size: framed anew.
    let wide = ViewTransform(imageSize: CGSize(width: 2000, height: 1000), viewSize: square.viewSize)
    #expect(f.frame(wide, boxes: nudged, rules: rules())!.center != mine.center)
}

@Test func anUntouchedFramingKeepsTheSizesItWasFramedWith() {
    var f = leftAFace(at: 0.3)
    let person = CGRect(x: 0.3, y: 0.1, width: 0.4, height: 0.8)
    let next = boxes(faces: [CGRect(x: 0.1, y: 0.1, width: 0.05, height: 0.05)], people: [person])
    let b = URL(fileURLWithPath: "/photos/b.jpg")
    let framed = f.frame(square, boxes: next, rules: rules())!
    f.framed = (b, framed)
    f.leave(b, view: framed, boxes: next, chain: rules().chain)
    #expect(abs(f.sizes[.face]! - 0.3) < 1e-9)          // kept, not measured again
    #expect(f.sizes[.person] == nil)                     // secondary kinds never teach a size
    // The user zoomed: measured anew.
    f.framed = (b, framed)
    f.leave(b, view: framed.withMode(.free(framed.scale * 2 / framed.fitScale)), boxes: next, chain: rules().chain)
    #expect(abs(f.sizes[.face]! - 0.6) < 1e-6)
}

@Test func theIndicatorNamesWhatTheFramingLooksAt() {
    let f = leftAFace(at: 0.3)
    let view = PhotoSwitchView.subjectFraming(square, frame: SubjectFraming.frame(boxes(faces: [face]), chain: [.face])!,
                                              others: [], size: 0.6, pull: 1)
    let shown = f.indicator(view, boxes: boxes(faces: [face]), rules: rules())!
    #expect(shown.name == "Face" && abs(shown.size - 0.6) < 1e-9)
    #expect(f.indicator(view, boxes: boxes(people: [CGRect(x: 0.4, y: 0.1, width: 0.2, height: 0.8)]), rules: rules())?.name == "Head")
    #expect(StatsLine.modeText(view, framing: ("Face", 0.6)) == "Face 60 %")
    #expect(StatsLine.modeText(view.withMode(.fit), framing: ("Face", 0.6)) == "Fit 100 %")
}

// ⇧Z under framing while browsing chooses the kind followed (owner, 2026-10-28): the next of the kinds found, round.
@Test func shiftZFollowsTheNextKindRound() {
    var f = BrowseFraming()
    let person = CGRect(x: 0.35, y: 0.15, width: 0.3, height: 0.5)
    let both = boxes(faces: [face], people: [person])
    let r = rules()
    #expect(f.target(both, chain: r.chain, imageSize: square.imageSize)?.kind == .face)
    let first = f.followNext(square, boxes: both, rules: r)!
    #expect(first.kind == .person && first.index == 1 && first.count == 2)
    #expect(f.target(both, chain: r.chain, imageSize: square.imageSize)?.kind == .person)
    #expect(f.chain(r.chain).first == .person)
    #expect(f.followNext(square, boxes: both, rules: r)!.kind == .face)   // round
    // A photo without the kind followed: the chain's next.
    f.followed = .person
    #expect(f.target(boxes(faces: [face]), chain: r.chain, imageSize: square.imageSize)?.kind == .face)
    #expect(f.followNext(square, boxes: boxes(), rules: r) == nil)
}

// A window as wide as the frame (crash, owner, 2026-10-28): hi - w/2 rounded past lo + w/2 trapped the range.
@Test func aWindowAsWideAsTheFrameIsNoCrash() {
    let lo = 0.04304830828525992, hi = 0.7334952711816164
    let main = CGRect(x: lo, y: lo, width: hi - lo, height: hi - lo)
    let c = SubjectFraming.pan(main: main, others: [], window: CGSize(width: hi - lo, height: hi - lo), pull: 0)
    #expect(abs(c.x - (lo + hi) / 2) < 1e-9 && abs(c.y - (lo + hi) / 2) < 1e-9)
    let none = SubjectFraming.pan(main: main, others: [], window: CGSize(width: Double.nan, height: 1), pull: 0)
    #expect(none == CGPoint(x: main.midX, y: main.midY))
}

// N follows the next kind at subject-size, not at the size it had while another kind was framed (owner, 2026-10-28).
@Test func theNextKindFollowedIsFramedAtSubjectSize() {
    let person = CGRect(x: 0.35, y: 0.15, width: 0.3, height: 0.5)
    let both = boxes(faces: [face], people: [person])
    var f = BrowseFraming()
    let frame = SubjectFraming.frame(both, chain: [.face])!
    let view = PhotoSwitchView.subjectFraming(square, frame: frame, others: [], size: 0.3, pull: 1)
    f.leave(a, view: view, boxes: both, chain: rules().chain)
    #expect(f.sizes[.person] == nil)
    #expect(f.followNext(square, boxes: both, rules: rules())?.kind == .person)
    let target = f.target(both, chain: rules().chain, imageSize: square.imageSize)!
    let framed = f.frame(square, boxes: both, rules: rules())!
    #expect(abs(BrowseFraming.size(framed, frame: target.frame) - rules().subjectSize) < 1e-9)
}
