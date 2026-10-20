import Testing
@testable import LoupeCore

// MARK: c / v (M3c spec §2.1)

@Test func colourToggles() {
    var config = Config()
    #expect(ColourKeys.toggled(config, key: "auto-color") == "yes")
    #expect(ColourKeys.toggled(config, key: "vibrance") == "yes")
    _ = config.set("auto-color", "yes")
    _ = config.set("vibrance", "yes")
    #expect(ColourKeys.toggled(config, key: "auto-color") == "no")
    #expect(ColourKeys.toggled(config, key: "vibrance") == "no")
    // The two are independent.
    _ = config.set("vibrance", "no")
    #expect(ColourKeys.toggled(config, key: "auto-color") == "no")
    #expect(ColourKeys.toggled(config, key: "vibrance") == "yes")
}

@Test func colourKeyLists() {
    #expect(ColourKeys.autoKeys == ["auto-color", "auto-color-method", "auto-color-strength"])
    #expect(ColourKeys.vibranceKeys == ["vibrance", "vibrance-amount"])
    // Both lists are folder keys, and together they are the five Reset Folder Colour clears.
    #expect(Set(ColourKeys.autoKeys + ColourKeys.vibranceKeys) == Set(Config.colorFolderKeys))
}

@Test func colourToasts() {
    #expect(ColourKeys.toast(autoColor: true) == "Auto colour: on · folder")
    #expect(ColourKeys.toast(autoColor: false) == "Auto colour: off")
    #expect(ColourKeys.toast(vibrance: true) == "Vibrance: on · folder")
    #expect(ColourKeys.toast(vibrance: false) == "Vibrance: off")
    #expect(ColourKeys.autoColorSaved == "Auto colour saved as default")
    #expect(ColourKeys.vibranceSaved == "Vibrance saved as default")
    #expect(ColourKeys.toast(method: .appleLuma) == "Method: apple-luma · folder")
    #expect(ColourKeys.toast(method: .apple) == "Method: apple · folder")
    #expect(ColourKeys.folderReset == "Folder colour reset")
}

@Test func colourMethodMenu() {
    #expect(ColourKeys.menuMethods.map(\.method) == [.apple, .appleLuma])
    #expect(ColourKeys.menuMethods.map(\.title) == ["Apple", "Apple, Luminance Only"])
}
