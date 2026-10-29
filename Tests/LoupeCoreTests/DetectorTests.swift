import CoreGraphics
import Foundation
import Testing
@testable import LoupeCore

// The custom detector (owner, 2026-10-28): a model of the user's own, detector.conf's classes and modes.

private let file = """
detector = on
model = models/pets.mlmodelc
look = whole, people
mode = play
score = 0.5
reach = 50%
min-frame = 20%
margin = 8%
heads = cat

[classes]
CAT_FACE = cat
DOG = dog
BALL = ball

[play]
chain = dog+ball, ball, cat, face
size = 65%

[pets]
chain = cat+dog, cat   # a comment
size = 0.7
"""

private func found(_ kind: SubjectKind, _ x: Double, _ y: Double, _ side: Double, score: Double = 0.9) -> SubjectBoxes.Detection {
    .init(kind: kind, rect: CGRect(x: x, y: y, width: side, height: side), score: score)
}

private func boxes(_ detections: [SubjectBoxes.Detection], faces: [CGRect] = []) -> SubjectBoxes {
    SubjectBoxes(faces: faces, people: [], objects: [], saliency: [], detections: detections)
}

private let cat = SubjectKind(rawValue: "cat")!, dog = SubjectKind(rawValue: "dog")!, ball = SubjectKind(rawValue: "ball")!

@Test func detectorConfReadsItsClassesAndModes() {
    let (setup, warnings) = DetectorSetup.parse(file)
    #expect(warnings.count == 2 && warnings.allSatisfy { $0.contains("deprecated") })
    #expect(setup.on && setup.model == "models/pets.mlmodelc" && setup.lookWhole && setup.lookPeople && setup.mode == "play")
    #expect(setup.score == 0.5 && setup.reach == 0.5 && setup.minFrame == 0.2 && abs(setup.margin - 0.08) < 1e-12)
    #expect(setup.heads == [cat] && setup.classes.map(\.label) == ["CAT_FACE", "DOG", "BALL"] && setup.kinds == [cat, dog, ball])
    #expect(setup.modes.map(\.name) == ["play", "pets"])
    #expect(setup.modes[0].chain.map(\.rawValue) == ["dog+ball", "ball", "cat", "face"])
    #expect(setup.modes[0].size == 0.65 && setup.modes[1].size == 0.7)
    #expect(setup.mode("pets")?.name == "pets" && setup.mode("nothing")?.name == "play")
    #expect(setup.next(after: "play")?.name == "pets" && setup.next(after: "pets")?.name == "play")
    #expect(setup.modelURL(relativeTo: URL(fileURLWithPath: "/conf"))?.path == "/conf/models/pets.mlmodelc")
    // No model file: nothing is detected.
    #expect(!setup.detects)
    // A target naming no class, a size out of range, a bad place to look: reported, skipped.
    let (bad, w) = DetectorSetup.parse("look = sky\n[classes]\nA = a\n[x]\nchain = a+b\nsize = 150%\n[y]\nchain = a, face")
    #expect(w.count == 4 && bad.modes.map(\.name) == ["y"] && bad.lookWhole && bad.lookPeople)
}

@Test func aKindIsVisionsOrAClassNameAndCombinationsJoinClasses() {
    #expect(SubjectKind(rawValue: "Dog + Ball")?.rawValue == "dog+ball")
    #expect(SubjectKind(rawValue: "dog+ball")?.parts == [dog, ball])
    #expect(SubjectKind(rawValue: "face+ball") == nil)       // Vision's kinds stand alone
    #expect(SubjectKind(rawValue: "ball+ball") == nil)
    #expect(SubjectKind(rawValue: "dog+") == nil && SubjectKind(rawValue: "2dogs") == nil && SubjectKind(rawValue: "") == nil)
    #expect(cat.isCustom && !SubjectKind.face.isCustom && SubjectKind(rawValue: "dog+ball")!.title == "Dog+Ball")
}

@Test func aCombinationFramesEveryInstanceRegardlessOfReach() {
    SubjectFraming.detector = DetectorFraming(DetectorSetup.parse(file).0)
    let pair = SubjectKind(rawValue: "dog+ball")!
    // Two balls: the one next to the dog is framed with it.
    let near = boxes([found(dog, 0.40, 0.50, 0.05), found(ball, 0.46, 0.52, 0.05), found(ball, 0.05, 0.05, 0.05)])
    let picked = SubjectFraming.pick(near, pair)!
    #expect(picked.count == 3 && picked.contains(CGRect(x: 0.46, y: 0.52, width: 0.05, height: 0.05)))
    // Apart by more than the reach: not found, the chain goes on to the ball alone.
    let apart = boxes([found(dog, 0.10, 0.40, 0.05), found(ball, 0.85, 0.40, 0.05)])
    #expect(apart.boxes(pair).count == 2)
    let frame = SubjectFraming.frame(apart, chain: DetectorSetup.parse(file).0.modes[0].chain)!
    // A small box's frame grows to the smallest frame, about its centre.
    #expect(frame.minX < 0.1 && frame.maxX > 0.9)
    // Below the score: not there.
    #expect(boxes([found(ball, 0.4, 0.4, 0.1, score: 0.4)]).boxes(ball).isEmpty)
    // A class framed as a face: its head.
    let catFrame = SubjectFraming.frame(boxes([found(cat, 0.4, 0.4, 0.2)]), chain: [cat])!
    #expect(catFrame.width > 0.2 * SubjectFraming.faceGrowth)
}

@Test func detectorRulesTakeTheModesChainAndSize() {
    var c = Config()
    c.detectorSetup = DetectorSetup.parse(file).0
    c.detectorSetup.installed = true
    c.detector = true
    c.detectorMode = "pets"
    var rules = ZoomRules(config: c)
    #expect(rules.detector?.name == "pets" && rules.subjectSize == 0.7)
    #expect(rules.chain.map(\.rawValue) == ["cat+dog", "cat"] && rules.stepKinds == rules.chain)
    #expect(ZoomKeys.nextDetectorMode(c) == "play" && ZoomKeys.toggledDetector(c) == false)
    // Off, or no model: loupe.conf's chain.
    c.detector = false
    rules = ZoomRules(config: c)
    #expect(rules.detector == nil && rules.chain == SubjectKind.vision)
    c.detector = true
    c.detectorSetup.installed = false
    #expect(ZoomRules(config: c).detector == nil && ZoomKeys.toggledDetector(c) == nil)
    // The tab's keys.
    var t = Config()
    #expect(t.set("detector", "yes") == .ok && t.detector && t.text(forKey: "detector") == "yes")
    #expect(t.set("detector-mode", "Pets") == .ok && t.detectorMode == "pets")
}

@Test func detectorStepsFollowTheChain() {
    SubjectFraming.detector = DetectorFraming(DetectorSetup.parse(file).0)
    var c = Config()
    c.detectorSetup = DetectorSetup.parse(file).0
    c.detectorSetup.installed = true
    c.detector = true
    let rules = ZoomRules(config: c)
    let t = ViewTransform(imageSize: CGSize(width: 1000, height: 1000), viewSize: CGSize(width: 1000, height: 1000))
    let photo = boxes([found(dog, 0.40, 0.50, 0.05), found(ball, 0.46, 0.52, 0.05)],
                      faces: [CGRect(x: 0.4, y: 0.1, width: 0.1, height: 0.1)])
    let steps = PhotoSwitchView.subjectSteps(t, boxes: photo, rules: rules).map(\.kind.rawValue)
    #expect(steps.first == "dog+ball" && steps.contains("face"))
    let caption = SubjectOverlay.caption(photo, chain: rules.chain)
    #expect(caption.contains("Dog 1") && caption.contains("Dog+Ball ✓"))
    #expect(photo.kinds == SubjectKind.vision + [dog, ball])
}

@Test func theSameBoxFoundTwiceIsKeptOnce() {
    let a = found(dog, 0.40, 0.50, 0.10, score: 0.8), b = found(dog, 0.41, 0.51, 0.10, score: 0.95)
    let c = found(ball, 0.41, 0.51, 0.10, score: 0.7)
    let kept = ModelDetector.merged([a, b, c])
    #expect(kept.count == 2 && kept.contains(b) && kept.contains(c))
}

@Test func storedBoxesKeepTheirDetections() throws {
    let photo = boxes([found(ball, 0.3, 0.3, 0.1)])
    let back = try JSONDecoder().decode(SubjectBoxes.self, from: JSONEncoder().encode(photo))
    #expect(back == photo)
}

// The detector in the interface (owner, 2026-10-28: "где их название, почему не видно"): the Zoom menu's section says
// why it cannot be used, each mode reads its chain and size; the zoom fact and Show Subjects' caption name the mode.
@Test func theMenuNamesTheDetectorsStateAndModes() {
    var setup = DetectorSetup.parse(file).0
    #expect(DetectorMenu.header(setup) == "Custom Detector — no model (detector.conf)")
    setup.installed = true
    #expect(DetectorMenu.header(setup) == "Custom Detector")
    #expect(DetectorMenu.tip(setup.modes[0]) == "dog+ball, ball, cat, face · 65 % of the window")
    setup.modes = []
    #expect(DetectorMenu.header(setup) == "Custom Detector — no modes (detector.conf)")
}

@Test func theZoomFactAndTheCaptionNameTheMode() {
    let info = ImageInfo(pixelSize: PixelSize(width: 1000, height: 1000), typeIdentifier: "public.jpeg", isProgressive: false,
                         fileSize: 1, colorSpaceName: nil)
    let t = ViewTransform(imageSize: CGSize(width: 1000, height: 1000), viewSize: CGSize(width: 1000, height: 1000))
    let facts = ImageStatus.facts(index: 0, count: 1, info: info, transform: t, detectorMode: "play")
    #expect(facts.first { $0.kind == .zoom }?.value == "play · Fit 100 %")
    #expect(ImageStatus.facts(index: 0, count: 1, info: info, transform: t).first { $0.kind == .zoom }?.value == "Fit 100 %")
    let photo = boxes([found(ball, 0.3, 0.3, 0.1)])
    #expect(SubjectOverlay.caption(photo, chain: [ball], mode: "play").hasPrefix("Mode play · "))
    #expect(!SubjectOverlay.caption(photo, chain: [ball]).contains("Mode"))
}

// Show Subjects labels each box (owner, 2026-10-28): its kind, and the detector's score for its own classes.
@Test func eachBoxIsLabelled() {
    SubjectFraming.detector = DetectorFraming(DetectorSetup.parse(file).0)
    let t = ViewTransform(imageSize: CGSize(width: 1000, height: 1000), viewSize: CGSize(width: 1000, height: 1000))
    let photo = SubjectBoxes(faces: [CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1)], people: [], objects: [], saliency: [],
                             detections: [found(ball, 0.6, 0.6, 0.1, score: 0.87), found(dog, 0.3, 0.6, 0.1)])
    let o = SubjectOverlay(photo, chain: [ball, .face], transform: t)
    #expect(o.marks.first { $0.kind == ball && $0.role == .chosen }?.label == "Ball 87 %")
    #expect(o.marks.first { $0.kind == dog }?.label == "Dog 90 %")
    #expect(o.marks.first { $0.kind == .face }?.label == "Face")
    #expect(o.marks.allSatisfy { $0.role == .frame || $0.role == .head ? $0.label == nil : $0.label != nil })
}

// One key for the model (owner, 2026-10-28: "упростить хоткеи … чтобы все было на автомате"): under the detector every
// step frames its target, whatever `step-zoom` says.
@Test func theDetectorDoesNotForceAutomaticZoom() {
    var c = Config()
    c.detectorSetup = DetectorSetup.parse(file).0
    c.detectorSetup.installed = true
    c.detector = true
    _ = c.set("step-zoom", "keep")
    #expect(ZoomRules(config: c).stepZoom == .keep)
    c.detector = false
    #expect(ZoomRules(config: c).stepZoom == .keep)
}

// ⇧M writes the size framed on screen into the mode's section, keeping the rest of the file.
@Test func aModesSizeIsWrittenIntoItsSection() {
    let set = DetectorSetup.settingSize(0.734, of: "Play", in: file)!
    #expect(set.contains("[play]\nchain = dog+ball, ball, cat, face\nsize = 73%\n"))
    #expect(DetectorSetup.parse(set).0.modes[0].size == 0.73 && DetectorSetup.parse(set).0.modes[1].size == 0.7)
    // A section without a size gets one under its header; a comment on the line stays; bounds hold.
    let bare = DetectorSetup.settingSize(0.1, of: "solo", in: "[solo]\nchain = cat\n")!
    #expect(bare == "[solo]\nsize = 20%\nchain = cat\n")
    let commented = DetectorSetup.settingSize(1.5, of: "a", in: "[a]\nsize = 50%   # big\n")!
    #expect(commented == "[a]\nsize = 100%   # big\n")
    #expect(DetectorSetup.settingSize(0.5, of: "nothing", in: file) == nil)
}

@Test func forgettingTheSizesFramesAtTheModesSize() {
    var browse = BrowseFraming()
    let t = ViewTransform(imageSize: CGSize(width: 1000, height: 1000), viewSize: CGSize(width: 1000, height: 1000))
    browse.leave(URL(fileURLWithPath: "/a.jpg"), view: t.withMode(.free(3)),
                 boxes: SubjectBoxes(faces: [CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1)], people: [], objects: [], saliency: []),
                 chain: [.face])
    var c = Config()
    c.detectorSetup = DetectorSetup.parse(file).0
    let rules = ZoomRules(config: c)
    #expect(!browse.sizes.isEmpty)
    browse.forgetSizes()
    #expect(browse.sizes.isEmpty && browse.size(of: .face, rules: rules) == rules.subjectSize)
}

@Test func mTurnsTheDetectorOnInTheFoldersModeThenGoesRound() {
    var c = Config()
    c.detectorSetup = DetectorSetup.parse(file).0
    #expect(ZoomKeys.modeAfterM(c) == nil)   // no model
    c.detectorSetup.installed = true
    c.detector = false
    c.detectorMode = "pets"
    #expect(ZoomKeys.modeAfterM(c) == "pets")
    c.detector = true
    #expect(ZoomKeys.modeAfterM(c) == "play")
}
