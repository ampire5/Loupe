import Testing
@testable import LoupeCore

// MARK: S / A (folder settings spec §4)

@Test func cycleFromConfig() {
    var config = Config()
    _ = config.set("upscale-high", "mitchell")
    #expect(ScalingKeys.cycle(config, key: .upscaleHigh) == ("upscale-high", "catmull-rom"))
    _ = config.set("upscale", "ewa-lanczos")
    #expect(ScalingKeys.cycle(config, key: .upscale) == ("upscale", "lanczos3"))        // wraps
    _ = config.set("downscale", "bilinear")
    #expect(ScalingKeys.cycle(config, key: .downscale) == ("downscale", "lanczos3"))    // no metalfx on downscale
    #expect(ScalingKeys.cycle(Config(), key: .downscale) == ("downscale", "lanczos2"))
}

@Test func antiringToggle() {
    var config = Config()
    #expect(ScalingKeys.toggledAntiring(config) == "yes")
    _ = config.set("lanczos-antiring", "yes")
    #expect(ScalingKeys.toggledAntiring(config) == "no")
}

// MARK: Toast (spec §5)

@Test func toastTexts() {
    #expect(ScalingKeys.toast(key: "upscale-high", setForFolder: "ewa-lanczos") == "upscale-high: ewa-lanczos · this folder")
    #expect(ScalingKeys.toast(key: "lanczos-antiring", setForFolder: "yes") == "lanczos-antiring: yes · this folder")
    #expect(ScalingKeys.toast(savedAsDefault: ["downscale", "upscale-high"]) == "Saved as default: downscale, upscale-high")
    #expect(ScalingKeys.toast(savedAsDefault: ["lanczos-antiring"]) == "Saved as default: lanczos-antiring")
    #expect(ScalingKeys.toast(pixelArtPercent: 800) == "nearest · pixel-art 800 %")
    #expect(ScalingKeys.nothingToSave == "Nothing to save: no folder filters")
    #expect(ScalingKeys.couldNotSave == "Could not save loupe.conf")
}

// MARK: ⇧S

@Test func keysToSave() {
    let folder = ["upscale": "metalfx", "lanczos-antiring": "yes"]
    #expect(ScalingKeys.keysToSave(folderValues: folder, among: ScalingKeys.filterKeys) == ["upscale"])
    let all = ["upscale-high": "ewa-lanczos", "downscale": "mitchell", "upscale": "bilinear"]
    #expect(ScalingKeys.keysToSave(folderValues: all, among: ScalingKeys.filterKeys) == ["downscale", "upscale", "upscale-high"])
    #expect(ScalingKeys.keysToSave(folderValues: [:], among: ScalingKeys.filterKeys).isEmpty)
}

// MARK: ⇧S / ⇧A never change what the window draws

@Test func keysToClearWithoutAncestor() {
    // Without the folder's own entry the window gets the new loupe.conf value, the saved one: clear.
    #expect(ScalingKeys.keysToClear(saved: ["upscale": "metalfx"], own: ["upscale": "metalfx"], inheritedWithoutOwn: [:])
            == ["upscale"])
}

@Test func keysToClearAncestorWithSameValue() {
    #expect(ScalingKeys.keysToClear(saved: ["downscale": "mitchell"], own: ["downscale": "mitchell"],
                                    inheritedWithoutOwn: ["downscale": "mitchell"]) == ["downscale"])
    // Spelled differently, the same filter.
    #expect(ScalingKeys.keysToClear(saved: ["downscale": "lanczos3"], own: ["downscale": "lanczos3"],
                                    inheritedWithoutOwn: ["downscale": "Lanczos3"]) == ["downscale"])
}

@Test func keysToClearAncestorWithDifferentValueKeeps() {
    #expect(ScalingKeys.keysToClear(saved: ["upscale-high": "ewa-lanczos"], own: ["upscale-high": "ewa-lanczos"],
                                    inheritedWithoutOwn: ["upscale-high": "mitchell"]).isEmpty)
}

@Test func keysToClearInheritedOnlyHasNothingToClear() {
    // The value came from an ancestor: the folder has no entry of its own to drop.
    #expect(ScalingKeys.keysToClear(saved: ["upscale": "bilinear"], own: [:],
                                    inheritedWithoutOwn: ["upscale": "bilinear"]).isEmpty)
    #expect(ScalingKeys.keysToClear(saved: ["upscale": "bilinear", "downscale": "mitchell"],
                                    own: ["downscale": "mitchell", "lanczos-antiring": "yes"],
                                    inheritedWithoutOwn: ["upscale": "bilinear"]) == ["downscale"])
}

@Test func keysToClearRefusedAncestorValueCountsAsAbsent() {
    // A hand-edited ancestor value that `Config.applying` refuses does not draw: loupe.conf's (the saved one) does.
    #expect(ScalingKeys.keysToClear(saved: ["downscale": "mitchell"], own: ["downscale": "mitchell"],
                                    inheritedWithoutOwn: ["downscale": "nonsense"]) == ["downscale"])
}

// MARK: Scaling menu (spec §6)

@Test func menuChoicesLists() {
    let downscale = ["lanczos3", "lanczos2", "mitchell", "catmull-rom", "bilinear"]
    let upscale = downscale + ["metalfx", "ewa-lanczos"]
    #expect(ScalingKeys.menuChoices(for: "downscale", current: "lanczos3") == downscale)
    #expect(ScalingKeys.menuChoices(for: "upscale", current: "metalfx") == upscale)
    #expect(ScalingKeys.menuChoices(for: "upscale-high", current: "ewa-lanczos") == upscale)
    #expect(ScalingKeys.menuChoices(for: "upscale-high-from", current: "300") == ["0", "200", "300", "400", "600"])
    #expect(ScalingKeys.menuChoices(for: "pixel-art", current: "400") == ["0", "400", "800", "1600"])
    #expect(ScalingKeys.menuChoices(for: "pyramid-filter", current: "box") == ["lanczos3", "box"])
    #expect(ScalingKeys.menuChoices(for: "background", current: "black").isEmpty)
}

@Test func menuChoicesPrependAValueOutsideTheList() {
    #expect(ScalingKeys.menuChoices(for: "upscale-high-from", current: "250") == ["250", "0", "200", "300", "400", "600"])
    #expect(ScalingKeys.menuChoices(for: "pixel-art", current: "1000") == ["1000", "0", "400", "800", "1600"])
}

@Test func menuTitles() {
    #expect(ScalingKeys.menuTitle(key: "upscale-high-from", value: "0") == "Off")
    #expect(ScalingKeys.menuTitle(key: "upscale-high-from", value: "250") == "250 %")
    #expect(ScalingKeys.menuTitle(key: "pixel-art", value: "0") == "Off")
    #expect(ScalingKeys.menuTitle(key: "pixel-art", value: "800") == "800 %")
    #expect(ScalingKeys.menuTitle(key: "upscale", value: "ewa-lanczos") == "ewa-lanczos")
    #expect(ScalingKeys.menuTitle(key: "pyramid-filter", value: "box") == "box")
}

// MARK: Reset Folder Scaling / Colour enabling

@Test func resetEnabledOnlyByItsOwnKeys() {
    let colourOnly = ["auto-color": "yes", "vibrance-amount": "0.3"]
    let scalingOnly = ["upscale": "metalfx"]
    #expect(!ScalingKeys.canReset(own: [:], keys: Config.scalingFolderKeys))
    #expect(!ScalingKeys.canReset(own: colourOnly, keys: Config.scalingFolderKeys))
    #expect(ScalingKeys.canReset(own: colourOnly, keys: Config.colorFolderKeys))
    #expect(ScalingKeys.canReset(own: scalingOnly, keys: Config.scalingFolderKeys))
    #expect(!ScalingKeys.canReset(own: scalingOnly, keys: Config.colorFolderKeys))
    #expect(ScalingKeys.canReset(own: colourOnly.merging(scalingOnly) { a, _ in a }, keys: Config.scalingFolderKeys))
}
