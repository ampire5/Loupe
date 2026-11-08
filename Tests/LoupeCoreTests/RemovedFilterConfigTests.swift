import Testing
@testable import LoupeCore

@Test func removedMetalLimiterHasNoControlsOrEffectAndOldSettingsAreHarmless() {
    for key in ["metalfx-antiring", "metalfx-antiring-strength"] {
        #expect(!Config.keys.contains(key))
        #expect(!Config.folderKeys.contains(key))
        #expect(Config().text(forKey: key) == nil)
    }
    #expect(ScalingKeys.antiringKey == "lanczos-antiring")
    let (loaded, warnings) = Config.parse("metalfx-antiring=yes\nmetalfx-antiring-strength=2")
    #expect(warnings.isEmpty)
    #expect(loaded == Config())
    let (folder, rejected) = Config().applying(["metalfx-antiring":"yes", "metalfx-antiring-strength":"2"])
    #expect(rejected.isEmpty)
    #expect(folder == Config())
}
