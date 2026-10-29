import CoreGraphics
import Testing
@testable import LoupeCore

// Show Subjects: every box Vision found on screen, the chain's chosen kind marked, the frame and its centre.

private func near(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) < 1e-6 && abs(a.minY - b.minY) < 1e-6 && abs(a.width - b.width) < 1e-6 && abs(a.height - b.height) < 1e-6
}

private let square = ViewTransform(imageSize: CGSize(width: 1000, height: 1000), viewSize: CGSize(width: 1000, height: 1000))

@Test func overlayMarksEveryBoxTheChosenKindAndTheFrame() {
    let boxes = SubjectBoxes(faces: [CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1)],
                             people: [CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.6)], objects: [],
                             saliency: [CGRect(x: 0.6, y: 0.1, width: 0.2, height: 0.2)])
    let o = SubjectOverlay(boxes, chain: [.face, .person, .object, .saliency], transform: square)
    #expect(o.marks.contains { $0.kind == .face && $0.role == .chosen && near($0.rect, CGRect(x: 400, y: 400, width: 100, height: 100)) })
    #expect(o.marks.contains { $0.kind == .face && $0.role == .head })
    #expect(o.marks.contains { $0.kind == .person && $0.role == .found && near($0.rect, CGRect(x: 300, y: 300, width: 400, height: 600)) })
    #expect(o.marks.contains { $0.kind == .saliency && $0.role == .found })
    let frame = SubjectFraming.frame(boxes, chain: [.face])!
    let drawn = o.marks.first { $0.role == .frame }!.rect
    #expect(abs(drawn.minX - frame.minX * 1000) < 1e-6 && abs(drawn.width - frame.width * 1000) < 1e-6)
    #expect(abs(o.centre!.x - frame.midX * 1000) < 1e-6 && abs(o.centre!.y - frame.midY * 1000) < 1e-6)
}

@Test func overlayFollowsTheZoom() {
    let boxes = SubjectBoxes(faces: [CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1)], people: [], objects: [], saliency: [])
    var t = square
    t.mode = .free(2)   // twice Fit, still centred: (0.5, 0.5) stays at the view's centre
    let o = SubjectOverlay(boxes, chain: [.face], transform: t)
    #expect(o.marks.contains { $0.kind == .face && $0.role == .chosen && near($0.rect, CGRect(x: 500, y: 500, width: 200, height: 200)) })
}

@Test func overlayCaptionTellsWhatWasFoundAndChosen() {
    let boxes = SubjectBoxes(faces: [], people: [.zero, .zero], objects: [], saliency: [.zero],
                             searched: [.face, .person, .saliency], proxySide: 1536)
    #expect(SubjectOverlay.caption(boxes, chain: [.face, .person, .saliency])
            == "Face 0 · Person 2 ✓ · Object — · Eye 1 · 1536 px")
    let none = SubjectBoxes(faces: [], people: [], objects: [], saliency: [], searched: [.face], proxySide: 1024)
    #expect(SubjectOverlay.caption(none, chain: [.face]) == "Face 0 · Person — · Object — · Eye — · 1024 px · no subject")
}

// Framing while browsing guessed a head on a person: drawn as a face's head and framed instead of the person.
@Test func aGuessedHeadIsDrawnAndFramed() {
    let t = ViewTransform(imageSize: CGSize(width: 1000, height: 1000), viewSize: CGSize(width: 1000, height: 1000))
    let person = CGRect(x: 0.4, y: 0.1, width: 0.2, height: 0.8)
    let boxes = SubjectBoxes(faces: [], people: [person], objects: [], saliency: [])
    let head = BrowseFraming.guessedHead([person], imageSize: t.imageSize)!
    let overlay = SubjectOverlay(boxes, chain: [.face, .person], transform: t, guessedHead: head)
    let s = t.scale * 1000
    #expect(overlay.marks.contains { $0.role == .head && $0.kind == .face })
    let frame = overlay.marks.first { $0.role == .frame }!.rect
    #expect(abs(frame.height - head.height * s) < 1e-6)
    #expect(SubjectOverlay.caption(boxes, chain: [.face, .person], guessedHead: true).contains("head guessed"))
}
