import Foundation
import Testing
@testable import LoupeCore

@Test func effectFolderSettingsKeepOverridesWhenDefaultsChange() {
    let folders = FolderSettings(database: nil)
    let a = URL(fileURLWithPath: "/photos/a")
    let b = URL(fileURLWithPath: "/photos/b")
    let fresh = URL(fileURLWithPath: "/photos/new")
    folders.set("deband", "adaptive", for: a)
    folders.set("deband-radius", "41", for: a)
    folders.set("grain", "particles", for: b)
    folders.set("grain-amount", "1.8", for: b)
    var defaults = Config()
    defaults.deband = .reference
    defaults.grain = .soft
    let (aConfig, aRejected) = defaults.applying(folders.values(for: a))
    let (bConfig, bRejected) = defaults.applying(folders.values(for: b))
    #expect(aRejected.isEmpty && bRejected.isEmpty)
    #expect(aConfig.deband == .adaptive && aConfig.debandRadius == 41)
    #expect(aConfig.grain == .soft)
    #expect(bConfig.deband == .reference)
    #expect(bConfig.grain == .particles && bConfig.grainAmount == 1.8)
    #expect(defaults.applying(folders.values(for: fresh)).config == defaults)
}

@Test func effectFolderSaveIncludesParametersAndLeavesOtherFoldersAlone() {
    #expect(EffectFolderKeys.keys(.deband) == ["deband", "deband-strength", "deband-threshold", "deband-radius", "deband-iterations", "deband-texture-protection"])
    #expect(EffectFolderKeys.keys(.grain) == ["grain", "grain-stage", "grain-amount", "grain-size"])
    let saved = ["grain": "fine", "grain-size": "2"]
    #expect(ScalingKeys.keysToClear(saved: saved, own: saved, inheritedWithoutOwn: [:]) == ["grain", "grain-size"])
    #expect(ScalingKeys.keysToClear(saved: saved, own: saved, inheritedWithoutOwn: ["grain": "particles"]) == ["grain-size"])
}

@Test func effectFolderToggleRestoresOwnModeAndHidesMemoryFromConfig() {
    let folders = FolderSettings(database: nil)
    let a = URL(fileURLWithPath: "/photos/a")
    let b = URL(fileURLWithPath: "/photos/b")
    folders.setEffectMode("grain", "off", remembering: "particles", for: a)
    folders.setEffectMode("grain", "off", remembering: "soft", for: b)
    #expect(folders.values(for: a) == ["grain": "off"])
    #expect(folders.ownValues(for: a) == ["grain": "off"])
    #expect(folders.inheritedValues(for: a.appendingPathComponent("child")) == ["grain": "off"])
    var config = Config()
    #expect(EffectFolderKeys.toggled(.grain, config: config, remembered: folders.rememberedEffectMode("grain", for: a)) == "particles")
    #expect(EffectFolderKeys.toggled(.grain, config: config, remembered: folders.rememberedEffectMode("grain", for: b)) == "soft")
    config.grain = .av1
    #expect(EffectFolderKeys.toggled(.grain, config: config, remembered: nil) == "off")
    #expect(EffectFolderKeys.toggled(.deband, config: Config(), remembered: nil) == "window")
}

@Test func folderEffectHotkeysUseNAndLeaveSmartZoomOnOptionN() {
    let map = KeyMap.standard
    #expect(map.action(keyCode: 45, character: "n", modifiers: [], isRepeat: false)?.rawValue == "toggleDeband")
    #expect(map.action(keyCode: 45, character: "n", modifiers: .shift, isRepeat: false)?.rawValue == "saveDeband")
    #expect(map.action(keyCode: 45, character: "n", modifiers: .option, isRepeat: false) == .nextTarget)
    #expect(map.action(keyCode: 45, character: "n", modifiers: [.option, .shift], isRepeat: false) == .previousTarget)
}

@Test func effectFolderMemoryPersistsWithSettingsAcrossReopen() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("LoupeEffectFolders-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let folder = URL(fileURLWithPath: "/photos/gradients")
    let db = try StateDatabase(directory: home)
    let folders = FolderSettings(database: db)
    folders.setEffectMode("deband", "off", remembering: "reference", for: folder)
    folders.set("deband-radius", "33", for: folder)
    folders.flush()
    let reopened = FolderSettings(database: db)
    #expect(reopened.values(for: folder) == ["deband": "off", "deband-radius": "33"])
    #expect(reopened.rememberedEffectMode("deband", for: folder) == "reference")
    #expect(EffectFolderKeys.toggled(.deband, config: Config(), remembered: reopened.rememberedEffectMode("deband", for: folder)) == "reference")
}
