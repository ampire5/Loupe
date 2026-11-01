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

    @Test func inheritedFaceProtectionSurvivesEmptyClassOverrides() {
        var options = CompositionOptions()
        #expect(options.set("max-crop", "") == true)
        #expect(options.cropLimit(for: .face) == 0)
        #expect(options.set("max-crop", "face:off") == true)
        #expect(options.cropLimit(for: .face) == nil)
    }

    @Test func protectionRegionOrderDoesNotInvalidateAnUnchangedOverlay() throws {
        let boxes = SubjectBoxes(faces: [.init(x: 0.1, y: 0.1, width: 0.1, height: 0.1)], people: [],
                                 objects: [.init(x: 0.4, y: 0.4, width: 0.2, height: 0.2)], saliency: [])
        var options = CompositionOptions(); options.maxCrop[.object] = 0
        let reference = try #require(SubjectFraming.composition(boxes, kind: .object, options: options, imageSize: .init(width: 1000, height: 1000)))
        for _ in 0..<30 {
            let next = try #require(SubjectFraming.composition(boxes, kind: .object, options: options, imageSize: .init(width: 1000, height: 1000)))
            #expect(next == reference)
        }
    }

    @Test func folderOverridesCarryAllCirclePoliciesWithoutChangingOtherProfiles() {
        let policies = ["circle-radius": "75%", "circle-radii": "object:125%", "max-crop": "face:off,object:5%",
                        "protection-margin": "4%", "protection-margins": "object:8%", "protection-scope": "selected", "steady-framing": "no"]
        let encoded = Config.smartZoomOptionsText(["vision": policies, "other": ["circle-radius": "150%"]])
        let store = FolderSettings(database: nil)
        let folder = URL(fileURLWithPath: "/photos/portrait")
        store.set("smart-zoom-options", encoded, for: folder)
        var config = Config()
        for (key,value) in store.values(for: folder) { #expect(config.set(key, value) == .ok) }
        let options = ZoomRules(config: config).composition
        #expect(options.circleRadius == 0.75 && options.circleRadii[.object] == 1.25)
        #expect(options.cropLimit(for: .face) == nil && options.cropLimit(for: .object) == 0.05)
        #expect(options.protectionPadding(for: .object) == 0.08)
        #expect(options.protectionScope == .selected && !options.steadyFraming)
        #expect(config.smartZoomOptions["other"]?["circle-radius"] == "150%")
    }
    @Test func visionEditorOverridesPreserveOtherProfilesAndManualMode() throws {
        var config = Config()
        config.smartZoomOptions = ["other": ["circle-radius": "150%"]]
        var draft = DetectorProfileDraft(name: "Vision", chain: [.face, .person])
        draft.composition.maxCrop[.face] = 1
        draft.composition.circleRadii[.face] = 1.25
        let values = try draft.visionOverrides(in: config, mode: .off)
        let (updated, rejected) = config.applying(values)
        #expect(rejected.isEmpty)
        #expect(updated.smartZoomMode == .off && updated.subjectTarget == [.face, .person])
        #expect(updated.smartZoomOptions["other"] == config.smartZoomOptions["other"])
        let rules = ZoomRules(config: updated)
        #expect(rules.composition.cropLimit(for: .face) == nil)
        #expect(rules.composition.circleRadii[.face] == 1.25)
        draft.chain = []
        #expect(throws: DetectorProfileDraft.Invalid.empty) { try draft.visionOverrides(in: config, mode: .off) }
        draft.chain = [SubjectKind(rawValue: "cat")!]
        #expect(throws: DetectorProfileDraft.Invalid.category) { try draft.visionOverrides(in: config, mode: .pan) }
    }

}
