import Foundation
import Testing
@testable import LoupeCore

@Suite(.serialized) struct CircleBrowsingTests {
    let image = CGSize(width: 1000, height: 1000)
    func boxes(x: Double, faces: [CGRect] = []) -> SubjectBoxes {
        .init(faces: faces, people: [], objects: [.init(x: x, y: 0.4, width: 0.2, height: 0.2)], saliency: [])
    }
    func rules(steady: Bool = true) -> ZoomRules {
        var rules = ZoomRules(config: Config()); rules.chain = [.object]; rules.subjectSize = 0.7
        rules.composition.margin = 0; rules.composition.steadyFraming = steady
        return rules
    }
    func memory() -> BrowseFraming {
        var memory = BrowseFraming()
        let view = ViewTransform(imageSize: image, viewSize: .init(width: 400, height: 200), mode: .actual(0.7), center: .init(x: 0.52, y: 0.5))
        memory.leave(URL(fileURLWithPath: "/photo-a.jpg"), view: view, boxes: boxes(x: 0.4), chain: [.object], options: rules().composition, manualZoom: false)
        return memory
    }

    @Test func nearIdenticalTargetsKeepThePreviousCentre() throws {
        let view = ViewTransform(imageSize: image, viewSize: .init(width: 400, height: 200))
        let result = try #require(memory().frame(view, boxes: boxes(x: 0.401), rules: rules()))
        #expect(abs(result.clamped.center.x - 0.52) < 1e-9)
    }

    @Test func stabilityCanBeDisabledAndDoesNotCrossProfiles() throws {
        let view = ViewTransform(imageSize: image, viewSize: .init(width: 400, height: 200))
        var memory = memory()
        let result = try #require(memory.frame(view, boxes: boxes(x: 0.401), rules: rules(steady: false)))
        #expect(abs(result.clamped.center.x - 0.501) < 1e-9)
        memory.useProfile("other")
        let changed = try #require(memory.frame(view, boxes: boxes(x: 0.401), rules: rules()))
        #expect(abs(changed.clamped.center.x - 0.501) < 1e-9)
    }

    @Test func currentPhotoProtectionOverridesTheRememberedCentre() throws {
        let face = CGRect(x: 0.05, y: 0.46, width: 0.08, height: 0.08)
        let view = ViewTransform(imageSize: image, viewSize: .init(width: 400, height: 200))
        let result = try #require(memory().frame(view, boxes: boxes(x: 0.401, faces: [face]), rules: rules()))
        #expect(abs(result.scale - 0.7) < 1e-9)
        #expect(result.visibleRect.minX <= 50 + 1e-8)
        #expect(result.visibleRect.maxX >= 130 - 1e-8)
    }

    @Test func overlayDrawsRoundSupportOnANonSquareSource() throws {
        let boxes = SubjectBoxes(faces: [], people: [], objects: [.init(x: 0.4, y: 0.2, width: 0.2, height: 0.4)], saliency: [])
        let t = ViewTransform(imageSize: .init(width: 1000, height: 2000), viewSize: .init(width: 600, height: 400))
        var options = CompositionOptions(); options.margin = 0
        let c = try #require(SubjectFraming.composition(boxes, kind: .object, options: options, imageSize: t.imageSize))
        let overlay = SubjectOverlay(boxes, chain: [.object], transform: t, composition: c)
        // One circle and its enclosing group frame, both 40×40 screen pixels.
        let round = overlay.marks.filter { abs($0.rect.width - 40) < 1e-8 && abs($0.rect.height - 40) < 1e-8 }
        #expect(round.count == 2)
    }
}
