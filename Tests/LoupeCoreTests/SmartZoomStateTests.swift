import Foundation
import Testing
import SlotModel
@testable import LoupeCore

@Test func smartZoomPowerAndModeAreIndependent() {
    var state = SmartZoomState()
    #expect(state.mode == .off)
    state.togglePower(); #expect(state.mode == .frame)
    state.select(.pan)
    state.togglePower(); #expect(state.mode == .off)
    state.togglePower(); #expect(state.mode == .pan)
    state.activateAuto(); #expect(state.mode == .frame)
}

@Test func smartZoomSlotRoundtripAndSingletons() throws {
    let old = try #require(FolderSlotSettings.parse("folders, overlay, glass, mouse-leaves, 400, hidden, at-once", edge: .right))
    #expect(old.tabs == [FolderSlotSettings.folders])
    var state = old
    state.tabs = [FolderSlotSettings.smartzoom, FolderSlotSettings.folders]
    #expect(FolderSlotSettings.parse(FolderSlotSettings.text(state), edge: .right) == state)
    let normalized = FolderSlotSettings.normalized([.left: state, .right: state])
    #expect(normalized[.left]?.tabs == state.tabs)
    #expect(normalized[.right]?.tabs.isEmpty == true)
    #expect(FolderSlotSettings.parse("unknown, overlay, glass, mouse-leaves, 400, hidden, at-once", edge: .right) == nil)
}

@Test func smartZoomConfigAndPendingInputGuard() {
    var c = Config()
    #expect(c.set("smart-zoom", "off") == .ok)
    #expect(c.smartZoomMode == .off)
    #expect(c.set("smart-zoom-gesture", "no") == .ok && !c.smartZoomGesture)
    let encoded = "{\"portrait\":{\"max-zoom\":\"75%\",\"size\":\"80%\"}}"
    #expect(c.set("smart-zoom-options", encoded) == .ok)
    #expect(c.smartZoomOptions["portrait"]?["size"] == "80%")
    #expect(c.set("smart-zoom-options", "{\"portrait\":{\"weights\":\"face:NaN\"}}") == .badValue)
    let url = URL(fileURLWithPath: "/photo.jpg")
    let request = SmartZoomRequest(photo: url, revision: 4)
    #expect(request.matches(photo: url, revision: 4, enabled: true))
    #expect(!request.matches(photo: url, revision: 5, enabled: true))
    #expect(!request.matches(photo: url, revision: 4, enabled: false))
}

@Test func profileSavingPreservesOtherSectionsAndComments() throws {
    let source = "# user\n[portrait]\nchain = face\nsize = 60% # keep\n\n[other]\nchain = person\n"
    let changed = try #require(DetectorSetup.settingValues(["size": "85%", "max-zoom": "100%"], of: "portrait", in: source))
    #expect(changed.contains("size = 85% # keep"))
    #expect(changed.contains("[other]\nchain = person"))
    #expect(changed.hasPrefix("# user\n"))
    #expect(changed.contains("max-zoom = 100%"))
    #expect(DetectorSetup.settingValues(["size": "80%"], of: "absent", in: source) == nil)
}

@Test func cancelledArrivalCannotRearmOnSamePhoto() {
    let a = URL(fileURLWithPath: "/a.jpg"), b = URL(fileURLWithPath: "/b.jpg")
    var arrival = SmartZoomArrival()
    let first = arrival.observe(a); #expect(first)
    // A manual pan clears its pending request; a transform notification is not another photo arrival.
    let same = arrival.observe(a); #expect(!same)
    let next = arrival.observe(b); #expect(next)
    let back = arrival.observe(a); #expect(back)
}

@Test func canonicalDuplicateGroupsAreDiagnosedOnce() {
    let (setup, warnings) = DetectorSetup.parse("[classes]\nA=apple\nB=cup\n[x]\nchain=apple+cup,cup+apple,apple")
    #expect(setup.modes[0].chain.map(\.rawValue) == ["apple+cup", "apple"])
    #expect(warnings.contains { $0.contains("duplicate") })
}

@Test func settingsAndKeysShareTransitionEffects() {
    var state = SmartZoomState()
    let auto = state.select(.frame); #expect(auto == .reframe)
    let pan = state.select(.pan); #expect(pan == .hold)
    let off = state.select(.off); #expect(off == .hold)
    let resume = state.select(.pan); #expect(resume == .reframe)
}

@Test func enabledSmartZoomOwnsItsAnalysis() {
    var state = SmartZoomState()
    state.select(.pan)
    #expect(state.analysis(.off) == .onDemand)
    #expect(state.analysis(.ahead) == .ahead)
    state.select(.frame)
    #expect(state.analysis(.off) == .onDemand)
    state.select(.off)
    #expect(state.analysis(.off) == .off)
    #expect(state.analysis(.ahead) == .off)
}

@Test func directAutoReappliesAndFirstPowerEntersAuto() {
    var state = SmartZoomState()
    state.select(.off)
    state.togglePower()
    #expect(state.mode == .frame)
    state.select(.pan)
    state.activateAuto()
    #expect(state.mode == .frame)
    state.activateAuto()
    #expect(state.mode == .frame)
    state.togglePower()
    #expect(state.mode == .off)
    state.togglePower()
    #expect(state.mode == .frame)
}

@Test func savedSmartProfileOverridesDetectorFileDefault() {
    var defaults = Config(); defaults.detector = true; defaults.detectorMode = "first"
    let chosen = Config.parse("detector=yes\ndetector-mode=chosen", defaults: defaults).0
    #expect(chosen.detector && chosen.detectorMode == "chosen")
    let vision = Config.parse("detector=no", defaults: defaults).0
    #expect(!vision.detector)
    let inherited = Config.parse("keep-zoom-position=no", defaults: defaults).0
    #expect(inherited.detector && inherited.detectorMode == "first")
}

@Test func profileSelectionRemembersOnlyProfileKeys() {
    #expect(ZoomKeys.profileSelection("portrait") == ["detector": "yes", "detector-mode": "portrait"])
    #expect(ZoomKeys.profileSelection(nil) == ["detector": "no"])
    #expect(Set(ZoomKeys.profileSelection("portrait").keys).isDisjoint(with: Set(ZoomKeys.manualSaveKeys + ["smart-zoom", "smart-zoom-options"])))
}

@Test func recalledProfileRejectsRemovedProfilesAndKeepsVision() {
    var setup = DetectorSetup(); setup.modes = [.init(name: "portrait", chain: [.face], size: 0.8)]
    #expect(ZoomKeys.recalledProfile(ZoomKeys.profileSelection("portrait"), setup: setup) == ZoomKeys.profileSelection("portrait"))
    #expect(ZoomKeys.recalledProfile(ZoomKeys.profileSelection("removed"), setup: setup).isEmpty)
    #expect(ZoomKeys.recalledProfile(ZoomKeys.profileSelection(nil), setup: setup) == ["detector": "no"])
}

@Test func modelsWithTheSameClassesCannotShareDetections() throws {
    var a = DetectorSetup(); a.model = "/models/320.mlmodelc"; a.installed = true
    a.classes = [("THING", .object)]
    var b = a; b.model = "/models/640.mlmodelc"
    #expect(a.analysisID != b.analysisID)
    var boxes = SubjectBoxes(faces: [], people: [], objects: [], saliency: [])
    boxes.analysisID = a.analysisID
    let data = try JSONEncoder().encode(boxes)
    let restored = try JSONDecoder().decode(SubjectBoxes.self, from: data)
    #expect(restored.analysisID == a.analysisID)
    #expect(restored.analysisID != b.analysisID)
}

@Test func smartZoomRestoresModeAndResumeBehavior() {
    var state = SmartZoomState(); state.select(.pan); state.select(.off)
    var reopened = SmartZoomState(restoring: state.rememberedValues)
    #expect(reopened.mode == .off)
    reopened.togglePower()
    #expect(reopened.mode == .pan)
    reopened.activateAuto()
    #expect(SmartZoomState(restoring: reopened.rememberedValues).mode == .frame)
    #expect(SmartZoomState(restoring: ["mode": "broken", "last-enabled": "off"]).lastEnabled == .frame)
}
