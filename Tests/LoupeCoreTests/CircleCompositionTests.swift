import Foundation
import Testing
@testable import LoupeCore

@Suite(.serialized) struct CircleCompositionTests {
    // A normalised box is not physically square on a portrait image.
    @Test func circleUsesTheShortPixelSideOnAPortrait() throws {
        let boxes = SubjectBoxes(faces: [], people: [], objects: [.init(x: 0.4, y: 0.2, width: 0.2, height: 0.4)], saliency: [])
        var rules = ZoomRules(config: Config())
        rules.chain = [.object]; rules.subjectSize = 1
        rules.composition.margin = 0; rules.composition.maxZoom = 4
        let t = ViewTransform(imageSize: .init(width: 1000, height: 2000), viewSize: .init(width: 600, height: 400))
        let result = try #require(PhotoSwitchView.subjectTransform(t, boxes: boxes, rules: rules))
        // The 200×800 px box contributes a 200 px diameter circle, so 400/200 = 2.
        #expect(abs(result.scale - 2) < 1e-9)
        #expect(abs(result.clamped.center.y - 0.4) < 1e-9)
    }

    @Test func classRadiusOverridesTheProfileRadius() throws {
        let boxes = SubjectBoxes(faces: [], people: [], objects: [.init(x: 0.4, y: 0.2, width: 0.2, height: 0.4)], saliency: [])
        var rules = ZoomRules(config: Config())
        rules.chain = [.object]; rules.subjectSize = 1
        rules.composition.margin = 0; rules.composition.maxZoom = 4
        #expect(rules.composition.set("circle-radius", "50%") == true)
        #expect(rules.composition.set("circle-radii", "object:200%") == true)
        let t = ViewTransform(imageSize: .init(width: 1000, height: 2000), viewSize: .init(width: 600, height: 400))
        let result = try #require(PhotoSwitchView.subjectTransform(t, boxes: boxes, rules: rules))
        #expect(abs(result.scale - 1) < 1e-9)
    }

    @Test func framingOptionsInheritAndRoundTripThroughProfiles() throws {
        let text = """
        circle-radius = 75%
        circle-radii = cat:125%
        max-crop = face:0%,cat:5%,ball:off
        protection-margin = 4%
        protection-margins = cat:8%
        protection-scope = all
        steady-framing = yes
        [classes]
        CAT = cat
        BALL = ball
        [test]
        chain = face
        protection-scope = selected
        """
        let (setup, warnings) = DetectorSetup.parse(text)
        #expect(warnings.isEmpty)
        let mode = try #require(setup.mode("test"))
        #expect(mode.composition.values["circle-radius"] == "75.0%")
        #expect(mode.composition.values["protection-scope"] == "selected")
        #expect(mode.composition.values["max-crop"] == "ball:off,cat:5.0%,face:0.0%")
        var draft = DetectorProfileDraft(name: "test", chain: [.face])
        draft.composition = mode.composition
        let saved = try draft.writing(in: text, creating: false)
        #expect(DetectorSetup.parse(saved).0.mode("test")?.composition == mode.composition)
    }

    @Test func invalidCircleAndProtectionValuesLeaveOptionsIntact() {
        var options = CompositionOptions()
        let before = options
        for (key,value) in [("circle-radius", "0%"), ("circle-radius", "nan"),
                            ("circle-radii", "face:0%"), ("max-crop", "face:50%"),
                            ("max-crop", "face:5%,face:10%"), ("protection-margin", "-1%"),
                            ("protection-scope", "everything"), ("steady-framing", "maybe")] {
            #expect(options.set(key, value) == false)
            #expect(options == before)
        }
    }
}
