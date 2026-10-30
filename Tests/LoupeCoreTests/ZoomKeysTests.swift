import Testing
@testable import LoupeCore

// MARK: L / ⇧L (M4b spec §4.4)

@Test func zoomKeysToggle() {
    var config = Config()
    #expect(config.keepZoomPosition)
    #expect(ZoomKeys.toggled(config) == "no")
    _ = config.set("keep-zoom-position", "no")
    #expect(ZoomKeys.toggled(config) == "yes")
    #expect(ZoomKeys.keepKey == "keep-zoom-position")
    #expect(Config.zoomFolderKeys.contains(ZoomKeys.keepKey))
}

@Test func zoomCarryKeyToggles() {
    var config = Config()
    #expect(config.keepZoomAs == .share)
    #expect(ZoomKeys.toggledCarry(config) == .scale)
    _ = config.set("keep-zoom-as", "scale")
    #expect(ZoomKeys.toggledCarry(config) == .screen)
    #expect(Config.zoomFolderKeys.contains(ZoomKeys.carryKey))
    #expect(ZoomKeys.toast(carry: .scale) == "Manual zoom keeps: scale · tab")
}

@Test func zoomKeysToasts() {
    #expect(ZoomKeys.toast(keep: true) == "Manual zoom: keep on · tab")
    #expect(ZoomKeys.toast(keep: false) == "Manual zoom: keep off · tab")
    #expect(ZoomKeys.keepSaved == "Keep zoom saved as default")
}

@Test func zoomCarryCyclesThroughScreen() {
    var c = Config()
    c.keepZoomAs = .share
    #expect(ZoomKeys.toggledCarry(c) == .scale)
    c.keepZoomAs = .scale
    #expect(ZoomKeys.toggledCarry(c) == .screen)
    c.keepZoomAs = .screen
    #expect(ZoomKeys.toggledCarry(c) == .share)
    #expect(ZoomKeys.toast(carry: .screen) == "Manual zoom keeps: share of screen · tab")
}

@Test func stepPanAndAnchorKeysCycle() {
    var c = Config()
    c.stepPan = .subject; #expect(ZoomKeys.toggledPan(c) == .keep)
    c.stepPan = .keep; #expect(ZoomKeys.toggledPan(c) == .center)
    c.stepPan = .center; #expect(ZoomKeys.toggledPan(c) == .subject)
    c.zoomAnchor = .pointer; #expect(ZoomKeys.toggledAnchor(c) == .center)
    c.zoomAnchor = .center; #expect(ZoomKeys.toggledAnchor(c) == .subject)
    c.zoomAnchor = .subject; #expect(ZoomKeys.toggledAnchor(c) == .pointer)
    #expect(ZoomKeys.toast(pan: .keep) == "Manual pan: the same place · tab")
    #expect(ZoomKeys.toast(anchor: .subject) == "Zoom towards: the subject · tab")
    #expect(ZoomKeys.panKey == "step-pan" && ZoomKeys.anchorKey == "zoom-anchor")
}

@Test func keyMapBindsSmartZoomKeys() {
    func action(_ code: UInt16, _ c: String, _ m: KeyModifiers) -> KeyAction? {
        KeyMap.standard.action(keyCode: code, character: c, modifiers: m, isRepeat: false)
    }
    #expect(action(6, "Z", .shift) == .zoomSubject)
    #expect(action(40, "k", .option) == .cycleStepPan)
    #expect(action(40, "K", [.option, .shift]) == .saveStepPan)
    #expect(action(6, "z", .option) == .cycleZoomAnchor)
    #expect(action(6, "Z", [.option, .shift]) == .saveZoomAnchor)
}

// Smart zoom spec §3.3: g switches the zoom block's set; in the smart set 1 and 2 are Subject and Screen.
@Test func zoomSetRemapsTheNumberKeys() {
    #expect(ZoomSet.remap(.actual100, in: .smart) == .actual100)
    #expect(ZoomSet.remap(.actual200, in: .smart) == .actual200)
    #expect(ZoomSet.remap(.fit, in: .smart) == .fit)
    #expect(ZoomSet.remap(.actual100, in: .classic) == .actual100)
    #expect(ZoomSet.classic.toggled == .smart && ZoomSet.smart.toggled == .classic)
    func action(_ code: UInt16, _ c: String) -> KeyAction? {
        KeyMap.standard.action(keyCode: code, character: c, modifiers: [], isRepeat: false)
    }
    #expect(action(5, "g") == .toggleZoomSet)
    #expect(action(20, "3") == .fill)
}

// Smart zoom spec §3.2: the zoom menu's smart zoom groups, each a folder key and its values.
@Test func smartZoomMenuGroups() {
    let groups = SmartZoomMenu.groups
    #expect(groups.map(\.key) == ["subject-target", "keep-zoom-as", "smart-zoom", "zoom-anchor", "subject-analysis"])
    #expect(groups[0].choices.map(\.value) == ["face,person,object,saliency", "person,object,saliency", "object,saliency",
                                                "saliency"])
    #expect(groups[1].choices.map(\.value) == ["share", "scale", "screen"])
    #expect(groups[2].choices.map(\.value) == ["off", "pan", "frame"])
    var c = Config()
    for g in groups { for choice in g.choices { #expect(c.set(g.key, choice.value) == .ok, "\(g.key)=\(choice.value)") } }
}

@Test func subjectTargetCyclesThroughThePresets() {
    var c = Config()
    #expect(ZoomKeys.toggledTarget(c) == "person,object,saliency")
    _ = c.set("subject-target", "saliency")
    #expect(ZoomKeys.toggledTarget(c) == "face,person,object,saliency")
    _ = c.set("subject-target", "person,face")                   // not a preset: back to the first
    #expect(ZoomKeys.toggledTarget(c) == "face,person,object,saliency")
    #expect(ZoomKeys.toast(target: "object,saliency") == "Zoom to: an object · tab")
    #expect(Config.zoomFolderKeys.contains("subject-target"))
    #expect(KeyMap.standard.action(keyCode: 5, character: "g", modifiers: .option, isRepeat: false) == .cycleSubjectTarget)
}

// The zoom keys and the zoom menu choose for the tab (owner, 2026-10-28): the tab's values over the folder's, until the
// tab closes; Remember Zoom for This Folder writes them all at once.
@Test func tabZoomValuesGoOverTheFolders() {
    let folder = ["step-pan": "keep", "zoom-anchor": "center", "auto-color": "yes"]
    let tab = ["step-pan": "subject", "subject-target": "saliency"]
    #expect(ZoomKeys.layered(folder: folder, tab: tab)
            == ["step-pan": "subject", "zoom-anchor": "center", "auto-color": "yes", "subject-target": "saliency"])
    #expect(ZoomKeys.remembered == "Zoom remembered for this folder")
}

// ⌥⇧G: framing while browsing on or off for the tab.
@Test func stepZoomKeyToggles() {
    var c = Config()
    #expect(ZoomKeys.toggledStepZoom(c) == .subject)
    c.stepZoom = .subject
    #expect(ZoomKeys.toggledStepZoom(c) == .keep)
    #expect(ZoomKeys.stepZoomKey == "step-zoom")
    #expect(ZoomKeys.toast(stepZoom: .subject) == "After a step: frame the subject · tab")
    #expect(ZoomKeys.toast(stepZoom: .keep) == "After a step: the zoom as kept · tab")
}

@Test func manualAndSmartSavesHaveDisjointScopes() {
    let manual = Set(ZoomKeys.manualSaveKeys), smart = Set(ZoomKeys.smartSaveKeys)
    #expect(manual.isDisjoint(with: smart))
    #expect(manual.contains("keep-zoom-position") && manual.contains("keep-zoom-as"))
    #expect(smart.contains("detector-mode") && smart.contains("smart-zoom-options"))
    #expect(ZoomKeys.saveKeys(for: .off) == ZoomKeys.manualSaveKeys)
    #expect(ZoomKeys.saveKeys(for: .frame) == ZoomKeys.smartSaveKeys)
}

@Test func profileCyclingDoesNotRequireALoadedDetector() {
    var config = Config()
    config.detectorSetup.modes = [.init(name: "Cats", chain: [.object], size: 0.5),
                                  .init(name: "Dogs", chain: [.object], size: 0.5)]
    #expect(!config.detectorSetup.detects)
    #expect(ZoomKeys.profileAfter(config, direction: 1) == "Cats")
    config.detector = true; config.detectorMode = "Cats"
    #expect(ZoomKeys.profileAfter(config, direction: 1) == "Dogs")
    #expect(ZoomKeys.profileAfter(config, direction: -1) == nil)
    config.detectorMode = "Dogs"
    #expect(ZoomKeys.profileAfter(config, direction: 1) == nil)
    #expect(ZoomKeys.profileAfter(config, direction: -1) == "Cats")
}
