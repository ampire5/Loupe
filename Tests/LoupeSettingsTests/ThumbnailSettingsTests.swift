import Foundation
import Testing
import SettingsKit
import LoupeCore
@testable import LoupeSettings

@MainActor @Suite struct ThumbnailSettingsTests {
    @Test func thumbnailPreferencesValidatePersistResetWithoutEditingConfig() throws {
        let suite = "test.thumbnail-settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ConfigSettingsStore(fileURL: file, current: { Config() }, reload: {}, defaults: defaults)
        #expect(store.value(forKey: "thumbnail-format") == "jpeg")
        #expect(store.defaultValue(forKey: "thumbnail-quality") == "80")
        #expect(store.validate("bad", forKey: "thumbnail-format") != nil)
        #expect(store.validate("101", forKey: "thumbnail-quality") != nil)
        #expect(store.validate("9", forKey: "thumbnail-quality") != nil)
        #expect(store.validate("80.5", forKey: "thumbnail-quality") != nil)
        try store.setValue("heic", forKey: "thumbnail-format")
        try store.setValue("65", forKey: "thumbnail-quality")
        #expect(defaults.string(forKey: "thumbnail-format") == "heic")
        #expect(store.value(forKey: "thumbnail-quality") == "65")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        try store.removeValues(forKeys: ["thumbnail-format", "thumbnail-quality"])
        #expect(store.value(forKey: "thumbnail-format") == "jpeg")
        #expect(store.value(forKey: "thumbnail-quality") == "80")
    }
    @Test func nativeThumbnailRowsAppearWithCacheSizeAndLimit() {
        let strip = SettingsPanel.pages().first { $0.id == "strip" }
        #expect(strip?.keys.contains("thumbnail-format") == true)
        #expect(strip?.keys.contains("thumbnail-quality") == true)
    }
}
