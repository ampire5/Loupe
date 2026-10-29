import Foundation
import Testing
@testable import LoupeCore

@Suite(.serialized) struct SmartCompositionTests {
    let a = SubjectKind(rawValue: "apple")!, b = SubjectKind(rawValue: "cup")!
    func photo() -> SubjectBoxes {
        SubjectBoxes(faces: [], people: [], objects: [], saliency: [], detections: [
            .init(kind: a, rect: CGRect(x: 0.05, y: 0.1, width: 0.1, height: 0.1), score: 1),
            .init(kind: a, rect: CGRect(x: 0.25, y: 0.1, width: 0.1, height: 0.1), score: 1),
            .init(kind: b, rect: CGRect(x: 0.8, y: 0.7, width: 0.1, height: 0.1), score: 1)])
    }
    @Test func allInstancesAcrossWholePhoto() {
        let pair = SubjectKind(rawValue: "apple+cup")!
        #expect(SubjectFraming.pick(photo(), pair)?.count == 3)
        #expect(SubjectFraming.pick(photo(), a)?.count == 2)
        var bad = photo()
        bad.detections[2].rect = CGRect(x: 2, y: 2, width: 0.1, height: 0.1)
        #expect(SubjectFraming.pick(bad, pair) == nil)
    }
    @Test func strictOrderAndIdenticalFramesRemainSelectable() {
        var c = Config()
        c.detector = true
        c.detectorSetup.installed = true
        c.detectorSetup.classes = [("APPLE", a), ("CUP", b)]
        c.detectorSetup.modes = [.init(name: "test", chain: [a, SubjectKind(rawValue: "apple+cup")!, b], size: 0.8)]
        let t = ViewTransform(imageSize: .init(width: 1000, height: 1000), viewSize: .init(width: 100, height: 100))
        #expect(PhotoSwitchView.subjectSteps(t, boxes: photo(), rules: ZoomRules(config: c)).map(\.kind) == c.detectorSetup.modes[0].chain)
    }
}

@Suite(.serialized) struct WeightedCompositionTests {
    @Test func normalizationAndConstrainedPan() throws {
        let a = SubjectKind(rawValue: "apple")!, b = SubjectKind(rawValue: "cup")!
        let boxes = SubjectBoxes(faces: [], people: [], objects: [], saliency: [], detections: [
            .init(kind: a, rect: CGRect(x: 0.1, y: 0.3, width: 0.1, height: 0.1), score: 1),
            .init(kind: a, rect: CGRect(x: 0.3, y: 0.3, width: 0.1, height: 0.1), score: 1),
            .init(kind: b, rect: CGRect(x: 0.7, y: 0.5, width: 0.1, height: 0.1), score: 1)])
        let kind = SubjectKind(rawValue: "apple+cup")!
        var options = CompositionOptions()
        options.margin = 0
        let c = try #require(SubjectFraming.composition(boxes, kind: kind, options: options))
        #expect(abs(c.desiredCenter.x - 0.5) < 1e-9)
        options.normalization = .object
        options.panOverflow = .keep
        let d = try #require(SubjectFraming.composition(boxes, kind: kind, options: options))
        #expect(abs(d.desiredCenter.x - 1.25 / 3) < 1e-9)
        let t = ViewTransform(imageSize: .init(width: 1000, height: 1000), viewSize: .init(width: 600, height: 600), mode: .actual(1))
        let pan = d.transform(t, autoZoom: false, size: 1)
        #expect(pan.scale == t.scale)
        // Oversized union aims at the weighted center, clamped only to the photo.
        #expect(abs(pan.clamped.center.x - d.desiredCenter.x) < 1e-9)
        let framed = d.transform(t, autoZoom: true, size: 1)
        #expect(framed.scale <= 1)
        #expect(framed.visibleRect.contains(CGRect(x: 100.0001, y: 300.0001, width: 699.9998, height: 299.9998)))
    }
    @Test func fitFloorTakesPrecedenceOverNativeCapAndProfileOptionsInherit() throws {
        let (setup, warnings) = DetectorSetup.parse("""
        max-zoom = 75%
        margin = 8%
        weights = face:1.25
        [portrait]
        chain = face
        margin = 4%
        weight-normalization = object
        """)
        #expect(warnings.isEmpty)
        let options = try #require(setup.mode("portrait")?.composition)
        #expect(options.maxZoom == 0.75 && options.margin == 0.04 && options.weights[.face] == 1.25)
        let c = try #require(SubjectFraming.composition(.init(faces: [.init(x: 0.4, y: 0.4, width: 0.2, height: 0.2)], people: [], objects: [], saliency: []), kind: .face, options: options))
        let t = ViewTransform(imageSize: .init(width: 100, height: 100), viewSize: .init(width: 1000, height: 1000))
        #expect(c.transform(t, autoZoom: true, size: 0.8).scale == t.fitScale)
    }
}

@Test func automaticFramingNeverLearnsSecondarySize() {
    let p = SubjectBoxes(faces: [CGRect(x: 0.2, y: 0.1, width: 0.1, height: 0.1)], people: [], objects: [],
                         saliency: [CGRect(x: 0.6, y: 0.6, width: 0.1, height: 0.1)])
    let t = ViewTransform(imageSize: .init(width: 1000, height: 1000), viewSize: .init(width: 600, height: 600))
    let url = URL(fileURLWithPath: "/test.jpg")
    var memory = BrowseFraming()
    memory.framed = (url, t)
    memory.leave(url, view: t, boxes: p, chain: [.face, .saliency])
    #expect(memory.sizes.isEmpty)
    memory.leave(url, view: t.withMode(.actual(1)), boxes: p, chain: [.face, .saliency])
    #expect(memory.sizes[.face] != nil && memory.sizes[.saliency] == nil)
}

@Test func malformedBoxesDoNotCountAndOverlayUsesComposition() throws {
    #expect(SubjectFraming.validRect(CGRect(x: 0.2, y: 0.2, width: -0.1, height: 0.1)) == nil)
    let b = SubjectBoxes(faces: [], people: [], objects: [.init(x: 0.1, y: 0.1, width: 0.1, height: 0.1)], saliency: [])
    let t = ViewTransform(imageSize: .init(width: 1000, height: 1000), viewSize: .init(width: 1000, height: 1000))
    let c = SubjectComposition(frame: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.4), desiredCenter: CGPoint(x: 0.18, y: 0.22), maxZoom: 1)
    let overlay = SubjectOverlay(b, chain: [.object], transform: t, composition: c)
    #expect(overlay.centre == CGPoint(x: 180, y: 220))
    #expect(overlay.marks.last?.rect == CGRect(x: 100, y: 100, width: 300, height: 400))
}

@Test func rememberedSizesAreScopedToProfileAndCanonicalGroup() {
    var memory = BrowseFraming()
    memory.useProfile("one")
    let a = SubjectKind(rawValue: "apple")!, b = SubjectKind(rawValue: "cup")!
    let pair = SubjectKind(rawValue: "apple+cup")!
    let boxes = SubjectBoxes(faces: [], people: [], objects: [], saliency: [], detections: [
        .init(kind: a, rect: .init(x: 0.3, y: 0.3, width: 0.1, height: 0.1), score: 1),
        .init(kind: b, rect: .init(x: 0.4, y: 0.3, width: 0.1, height: 0.1), score: 1)])
    let t = ViewTransform(imageSize: .init(width: 1000, height: 1000), viewSize: .init(width: 1000, height: 1000), mode: .actual(2))
    memory.leave(URL(fileURLWithPath: "/a.jpg"), view: t, boxes: boxes, chain: [pair])
    let rules = ZoomRules(config: Config())
    let size = memory.size(of: pair, rules: rules)
    #expect(size < 0.6)
    memory.useProfile("two")
    #expect(memory.size(of: pair, rules: rules) == rules.subjectSize)
    memory.useProfile("one")
    #expect(memory.size(of: SubjectKind(rawValue: "cup+apple")!, rules: rules) == size)
}

@Test func manualSizeUsesTheActiveProfilesMargin() {
    var options = CompositionOptions(); options.margin = 0
    let boxes = SubjectBoxes(faces: [], people: [.init(x: 0.3, y: 0.3, width: 0.2, height: 0.2)], objects: [], saliency: [])
    let t = ViewTransform(imageSize: .init(width: 1000, height: 1000), viewSize: .init(width: 1000, height: 1000), mode: .actual(2))
    var memory = BrowseFraming()
    memory.leave(URL(fileURLWithPath: "/a.jpg"), view: t, boxes: boxes, chain: [.person], options: options)
    #expect(abs(memory.size(of: .person, rules: ZoomRules(config: Config())) - 0.4) < 1e-9)
    #expect(memory.size(of: .face, rules: ZoomRules(config: Config())) == 0.6)
}

@Test func panAndResizeDoNotTeachANewSize() {
    let boxes = SubjectBoxes(faces: [], people: [.init(x: 0.3, y: 0.3, width: 0.1, height: 0.1)], objects: [], saliency: [])
    let url = URL(fileURLWithPath: "/a.jpg")
    let t = ViewTransform(imageSize: .init(width: 1000, height: 1000), viewSize: .init(width: 1000, height: 1000), mode: .actual(1))
    var memory = BrowseFraming(); memory.framed = (url, t)
    var panned = t; panned.center = .init(x: 0.6, y: 0.6)
    memory.leave(url, view: panned, boxes: boxes, chain: [.person])
    #expect(memory.sizes.isEmpty)
    var resized = t; resized.viewSize = .init(width: 500, height: 500)
    memory.leave(url, view: resized, boxes: boxes, chain: [.person])
    #expect(memory.sizes.isEmpty)
}

@Test func automaticViewChangesNeverTeachWithoutManualZoom() {
    let boxes = SubjectBoxes(faces: [], people: [.init(x: 0.3, y: 0.3, width: 0.1, height: 0.1)], objects: [], saliency: [])
    var memory = BrowseFraming()
    let t = ViewTransform(imageSize: .init(width: 1000, height: 1000), viewSize: .init(width: 600, height: 600), mode: .actual(1))
    memory.leave(URL(fileURLWithPath: "/a.jpg"), view: t, boxes: boxes, chain: [.person], manualZoom: false)
    #expect(memory.sizes.isEmpty)
}

@Test func broadGroupNeverShrinksBelowFit() {
    let t = ViewTransform(imageSize: .init(width: 2000, height: 3000), viewSize: .init(width: 1000, height: 1000))
    let c = SubjectComposition(frame: .init(x: 0, y: 0, width: 1, height: 1), desiredCenter: .init(x: 0.4, y: 0.7), maxZoom: 1)
    #expect(c.transform(t, autoZoom: true, size: 0.6).scale == t.fitScale)
    #expect(c.transform(t.withMode(.actual(0.1)), autoZoom: false, size: 0.6).scale == 0.1)
}

@Test func panOverflowFitsByDefaultAndKeepZoomFindsAnObject() throws {
    let objects = [CGRect(x: 0.05, y: 0.4, width: 0.1, height: 0.1), CGRect(x: 0.85, y: 0.4, width: 0.1, height: 0.1)]
    let boxes = SubjectBoxes(faces: [], people: [], objects: objects, saliency: [])
    let t = ViewTransform(imageSize: .init(width: 2000, height: 1000), viewSize: .init(width: 500, height: 500), mode: .actual(1))
    var options = CompositionOptions(); options.margin = 0
    let fitting = try #require(SubjectFraming.composition(boxes, kind: .object, options: options))
    let fit = fitting.transform(t, autoZoom: false, size: 0.6)
    #expect(abs(fit.scale - 500.0 / 1800) < 1e-9)
    #expect(fit.scale >= t.fitScale)
    #expect(options.set("pan-overflow", "keep") == true)
    let keeping = try #require(SubjectFraming.composition(boxes, kind: .object, options: options))
    let kept = keeping.transform(t, autoZoom: false, size: 0.6)
    #expect(kept.scale == t.scale)
    #expect(objects.contains { kept.visibleRect.intersects(CGRect(x: $0.minX * 2000, y: $0.minY * 1000, width: $0.width * 2000, height: $0.height * 1000)) })
    #expect(options.values["pan-overflow"] == "keep")
}
