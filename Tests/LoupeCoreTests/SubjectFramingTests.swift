import CoreGraphics
import Foundation
import Testing
@testable import LoupeCore

// Smart zoom spec §4: the frame of the first kind of the chain that was found.

@Test func frameTakesTheFirstKindFoundInTheChain() {
    let b = SubjectBoxes(faces: [], people: [CGRect(x: 0.2, y: 0.1, width: 0.2, height: 0.8)], objects: [],
                         saliency: [CGRect(x: 0.6, y: 0.6, width: 0.1, height: 0.1)])
    let f = SubjectFraming.frame(b, chain: [.face, .person, .object, .saliency])!
    // The person plus 8 % of its size each side: x 0.184…0.416, y 0.036…0.964.
    #expect(abs(f.minX - 0.184) < 1e-9 && abs(f.maxX - 0.416) < 1e-9)
    #expect(abs(f.minY - 0.036) < 1e-9 && abs(f.maxY - 0.964) < 1e-9)
    #expect(SubjectFraming.frame(b, chain: [.saliency])!.midX > 0.6)
    #expect(SubjectFraming.frame(b, chain: [.face]) == nil)
}

@Test func facesGrowToTheHeadAndAreFramedTogether() {
    let b = SubjectBoxes(faces: [CGRect(x: 0.2, y: 0.4, width: 0.1, height: 0.1),
                                 CGRect(x: 0.6, y: 0.4, width: 0.1, height: 0.1)], people: [], objects: [], saliency: [])
    let f = SubjectFraming.frame(b, chain: [.face])!
    // Each face ×1.8 about its centre (y 0.36…0.54), lifted by 0.15 × 0.1: y 0.345…0.525; the union x 0.16…0.74.
    #expect(abs(f.midX - 0.45) < 1e-9)
    #expect(f.minX < 0.16 && f.maxX > 0.74)
    #expect(abs(SubjectFraming.centre(b, chain: [.face])!.y - 0.435) < 1e-9)
}

@Test func frameStaysInsideThePhoto() {
    let b = SubjectBoxes(faces: [CGRect(x: 0, y: 0, width: 0.2, height: 0.2)], people: [], objects: [], saliency: [])
    let f = SubjectFraming.frame(b, chain: [.face])!
    #expect(f.minX >= 0 && f.minY >= 0 && f.maxX <= 1 && f.maxY <= 1)
}

@Test func boxesRoundTripAndKnowTheirVersion() throws {
    let b = SubjectBoxes(faces: [CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)], people: [], objects: [], saliency: [])
    let back = try JSONDecoder().decode(SubjectBoxes.self, from: JSONEncoder().encode(b))
    #expect(back == b && back.version == SubjectBoxes.version)
    #expect(SubjectBoxes(faces: [], people: [], objects: [], saliency: []).isEmpty)
}

// Smart zoom spec §4.3: the frame takes `subject-size` of the view, never below Fit, never past the upper limit.
@Test func subjectScaleTakesTheSizeOfTheView() {
    let image = CGSize(width: 1000, height: 1000), view = CGSize(width: 2000, height: 1000)
    let limits = 0.25...64.0
    // The frame's 200 px height becomes 600 px: scale 3.
    #expect(abs(SubjectFraming.scale(frame: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), size: 0.6, imageSize: image,
                                     viewSize: view, limits: limits, fit: 1) - 3) < 1e-9)
    #expect(SubjectFraming.scale(frame: CGRect(x: 0, y: 0, width: 1, height: 1), size: 0.6, imageSize: image,
                                 viewSize: view, limits: limits, fit: 1) == 1)
    #expect(SubjectFraming.scale(frame: CGRect(x: 0.5, y: 0.5, width: 0.0001, height: 0.0001), size: 1, imageSize: image,
                                 viewSize: view, limits: limits, fit: 1) == 64)
}

// The pan of framing while browsing: the subject's frame whole in the view, as many of the other boxes as fit, then
// `pull` of the way to the frame's centre.
@Test func panShowsTheSubjectAndAsMuchOfTheRestAsFits() {
    let main = CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1), other = CGRect(x: 0.7, y: 0.4, width: 0.1, height: 0.1)
    let window = CGSize(width: 0.5, height: 0.5)
    func pan(_ pull: Double) -> CGPoint { SubjectFraming.pan(main: main, others: [other], window: window, pull: pull) }
    func near(_ p: CGPoint, _ x: Double, _ y: Double) -> Bool { abs(p.x - x) < 1e-9 && abs(p.y - y) < 1e-9 }
    #expect(near(pan(0), 0.55, 0.45))     // the other box just in, the nearest such place to the subject
    #expect(near(pan(1), 0.45, 0.45))     // the subject in the middle
    #expect(near(pan(0.5), 0.5, 0.45))
    // A box too far to show with the subject whole: as much of it as can be, the subject still whole.
    let far = SubjectFraming.pan(main: main, others: [CGRect(x: 0.85, y: 0.4, width: 0.1, height: 0.1)], window: window, pull: 0)
    #expect(near(far, 0.65, 0.45))
    // A subject wider than the view: its centre.
    let wide = SubjectFraming.pan(main: CGRect(x: 0.1, y: 0.4, width: 0.7, height: 0.1), others: [other], window: window, pull: 0)
    #expect(near(wide, 0.45, 0.45))
}

// Owner: a gesture zoom towards the subject should end with the subject centred. With `zoom-anchor-center` the
// subject's point goes from where it was to the view's centre as the zoom goes in, there at the framing's scale.
@Test func gestureZoomBringsTheSubjectToTheCentre() {
    let start = CGPoint(x: 100, y: 100), centre = CGPoint(x: 500, y: 500)
    func at(_ s: Double) -> CGPoint { SubjectCentring.point(start: start, centre: centre, scale: s, startScale: 1, targetScale: 4) }
    func near(_ p: CGPoint, _ x: Double, _ y: Double) -> Bool { abs(p.x - x) < 1e-9 && abs(p.y - y) < 1e-9 }
    #expect(near(at(1), 100, 100) && near(at(0.5), 100, 100))   // zooming out: where it was
    #expect(near(at(2), 300, 300))                              // half the doublings to the framing's scale
    #expect(near(at(4), 500, 500) && near(at(8), 500, 500))
    // Already past the framing's scale: centred within one doubling.
    #expect(near(SubjectCentring.point(start: start, centre: centre, scale: 10, startScale: 5, targetScale: 4), 500, 500))
}

@Test func zoomPlacingPutsTheImagePointThere() {
    let t = ViewTransform(imageSize: CGSize(width: 1000, height: 1000), viewSize: CGSize(width: 1000, height: 1000))
    let z = t.zoomed(toScale: 2, placing: CGPoint(x: 300, y: 300), at: CGPoint(x: 500, y: 500))
    let p = z.viewPoint(forImage: CGPoint(x: 300, y: 300))
    #expect(abs(p.x - 500) < 1e-9 && abs(p.y - 500) < 1e-9)
    // Near the edge only as far as the normal centring lets it: the view's corner on the photo's (owner, 2026-10-28).
    let edge = t.zoomed(toScale: 2, placing: CGPoint(x: 100, y: 100), at: CGPoint(x: 500, y: 500))
    #expect(edge.viewPoint(forImage: .zero) == .zero)
}

@Test func zoomAnchorCenterParses() {
    #expect(Config().zoomAnchorCenter)
    var c = Config()
    #expect(c.set("zoom-anchor-center", "no") == .ok && c.text(forKey: "zoom-anchor-center") == "no")
    #expect(c.set("zoom-anchor-center", "maybe") == .badValue)
}

/// `SubjectFraming.pan` as it was before its overlaps were measured per axis (owner, 2026-10-28): the reference the
/// faster one must agree with.
private func referencePan(main: CGRect, others: [CGRect], window: CGSize, pull: Double) -> CGPoint {
    func axis(_ lo: Double, _ hi: Double, _ w: Double, _ edges: [Double]) -> [Double] {
        let from = hi - w / 2, to = lo + w / 2
        var range = from <= to ? from...to : ((lo + hi) / 2)...((lo + hi) / 2)
        let inside = (w / 2)...max(w / 2, 1 - w / 2)
        if range.overlaps(inside) { range = max(range.lowerBound, inside.lowerBound)...min(range.upperBound, inside.upperBound) }
        let breaks = edges.flatMap { [$0 - w / 2, $0 + w / 2] } + [range.lowerBound, range.upperBound, (lo + hi) / 2]
        return breaks.map { min(max($0, range.lowerBound), range.upperBound) }
    }
    let w = window.width, h = window.height
    let xs = axis(main.minX, main.maxX, w, others.flatMap { [$0.minX, $0.maxX] })
    let ys = axis(main.minY, main.maxY, h, others.flatMap { [$0.minY, $0.maxY] })
    let mid = CGPoint(x: main.midX, y: main.midY)
    func shown(_ c: CGPoint) -> Double {
        let view = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
        return others.reduce(0) { sum, b in
            let i = view.intersection(b)
            return sum + (i.isNull || b.width * b.height == 0 ? 0 : i.width * i.height / (b.width * b.height))
        }
    }
    var best = CGPoint(x: xs[0], y: ys[0]), bestShown = -1.0, bestDistance = Double.infinity
    for x in xs {
        for y in ys {
            let c = CGPoint(x: x, y: y), s = shown(c), d = hypot(x - mid.x, y - mid.y)
            if s > bestShown + 1e-9 || (abs(s - bestShown) <= 1e-9 && d < bestDistance) {
                best = c; bestShown = s; bestDistance = d
            }
        }
    }
    return CGPoint(x: best.x + (mid.x - best.x) * pull, y: best.y + (mid.y - best.y) * pull)
}

/// A fixed sequence of numbers in 0..<1, so a failure repeats.
private struct Numbers {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
}

@Test func theFasterPanAgreesWithTheReference() {
    var r = Numbers(state: 2026_10_28)
    var differ = 0
    for case_ in 0..<600 {
        let n = case_ % 25
        func box() -> CGRect {
            // Some boxes on a grid, so edges coincide and places tie, some of no size.
            let snap = case_ % 3 == 0
            func v(_ x: Double) -> Double { snap ? (x * 10).rounded() / 10 : x }
            return CGRect(x: v(r.next() * 0.9), y: v(r.next() * 0.9), width: v(r.next() * 0.4), height: v(r.next() * 0.4))
        }
        let main = box(), others = (0..<n).map { _ in box() }
        let window = CGSize(width: 0.05 + r.next() * 1.2, height: 0.05 + r.next() * 1.2)
        let pull = case_ % 2 == 0 ? 0 : 0.5
        if SubjectFraming.pan(main: main, others: others, window: window, pull: pull)
            != referencePan(main: main, others: others, window: window, pull: pull) { differ += 1 }
    }
    #expect(differ == 0)
}
