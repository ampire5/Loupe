import Testing
import Foundation
import SettingsKit
import LoupeCore
@testable import LoupeSettings

/// A store over a temp `loupe.conf`, wired like the app: `reload` re-reads the file and then calls
/// `configDidReload(from:)` with the config from before the re-read (what `Settings.reload` does).
@MainActor
private final class Fixture {
    let dir: URL
    let file: URL
    var config = Config()
    var store: ConfigSettingsStore!

    init(_ text: String? = nil) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("loupe.conf")
        if let text { try text.write(to: file, atomically: true, encoding: .utf8) }
        config = Config.load(from: file).0
        store = ConfigSettingsStore(fileURL: file, current: { [unowned self] in self.config }, reload: { [unowned self] in
            self.reload()
        })
    }

    /// What `Settings.reload` does: keep the old config, re-read the file, tell the store.
    func reload() {
        let previous = config
        config = Config.load(from: file).0
        store.configDidReload(from: previous)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    var text: String { (try? String(contentsOf: file, encoding: .utf8)) ?? "" }
}

@MainActor
struct ConfigSettingsStoreTests {
    @Test func firstWriteCreatesFile() throws {
        let f = try Fixture()
        #expect(!FileManager.default.fileExists(atPath: f.file.path))
        try f.store.setValue("no", forKey: "zoom-animation")
        #expect(f.text.hasPrefix(ConfigText.header))
        #expect(f.text.contains("zoom-animation=no"))
        #expect(f.store.value(forKey: "zoom-animation") == "0")
    }

    @Test func writeKeepsComments() throws {
        let original = "# my notes\ntoast-duration=2000 # long enough\n\n# keep me\nzoom-animation=yes\n"
        let f = try Fixture(original)
        try f.store.setValue("1500", forKey: "toast-duration")
        #expect(f.text == original.replacingOccurrences(of: "toast-duration=2000", with: "toast-duration=1500"))
        #expect(f.store.value(forKey: "toast-duration") == "1500")
    }

    @Test func validateMatchesConfig() throws {
        let f = try Fixture()
        #expect(f.store.validate("abc", forKey: "toast-duration") == "Not a valid value")
        #expect(f.store.validate("1500", forKey: "toast-duration") == nil)
        #expect(f.store.validate("1500", forKey: "no-such-key") == "Not a valid value")
    }

    @Test func validateReadsTheLineAsParseDoes() throws {
        let f = try Fixture()
        #expect(f.store.validate("fit-widht", forKey: "zoom-stops") == "Not a valid value")
        #expect(f.store.validate("fit-widht,100%", forKey: "zoom-stops") == "Not a valid value")
        #expect(f.store.validate("fit-width,100%", forKey: "zoom-stops") == nil)
        #expect(f.store.validate("none", forKey: "zoom-stops") == nil)
        #expect(f.store.validate("#fff, #ccc", forKey: "checker-colors") == "Not a valid value")
        #expect(f.store.validate("#fff,#ccc", forKey: "checker-colors") == nil)
        #expect(f.store.validate("#333", forKey: "background") == nil)
        #expect(f.store.validate("1500\nzoom-animation=no", forKey: "toast-duration") == "Not a valid value")
    }

    @Test func readOnlyFileIsNotOverwritten() throws {
        let f = try Fixture("toast-duration=2000\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: f.file.path)
        do {
            try f.store.setValue("1500", forKey: "toast-duration")
            Issue.record("a read-only loupe.conf was written")
        } catch let error as CocoaError {
            #expect(error.code == .fileWriteNoPermission)
            #expect(error.userInfo[NSFilePathErrorKey] as? String == f.file.path)
        }
        #expect(f.text == "toast-duration=2000\n")
        #expect(f.store.value(forKey: "toast-duration") == "2000")
        // The model shows it as a write failure, the alert's text.
        let model = SettingsModel(store: f.store)
        model.register([SettingsPage("p", "P", symbol: "gearshape", sections: [
            SettingsSection("S", rows: [.number("toast-duration", "Toast", unit: "ms")]),
        ])])
        model.set("toast-duration", "1500")
        #expect(model.writeFailure != nil)
        #expect(f.text == "toast-duration=2000\n")
    }

    @Test func everyDefaultIsValid() throws {
        let f = try Fixture()
        for key in Config.keys {
            #expect(f.store.validate(f.store.defaultValue(forKey: key), forKey: key) == nil, "\(key)")
        }
    }

    @Test func validateRejectsNonFinite() throws {
        let f = try Fixture()
        for key in ["toast-duration", "mouse-move-step", "rmb-zoom-speed", "strip-cell-max"] {
            for bad in ["nan", "inf", "-inf", "NaN", "infinity"] {
                #expect(f.store.validate(bad, forKey: key) == "Not a valid value", "\(key)=\(bad)")
            }
        }
    }

    @Test func defaultValueIsTheConfigDefault() throws {
        let f = try Fixture()
        #expect(f.store.defaultValue(forKey: "toast-duration") == Config().text(forKey: "toast-duration"))
        #expect(f.store.value(forKey: "toast-duration") == Config().text(forKey: "toast-duration"))
    }

    @Test func changedKeysListsOnlyChanges() throws {
        var changed = Config()
        #expect(changed.set("zoom-animation", "no") == .ok)
        #expect(ConfigSettingsStore.changedKeys(from: Config(), to: changed) == ["zoom-animation"])
        #expect(ConfigSettingsStore.changedKeys(from: Config(), to: Config()).isEmpty)
    }

    @Test func externalEditUpdatesModel() throws {
        let f = try Fixture("toast-duration=2000\n")
        let model = SettingsModel(store: f.store)
        model.register([SettingsPage("p", "P", symbol: "gearshape", sections: [
            SettingsSection("S", rows: [.number("toast-duration", "Toast", unit: "ms")]),
        ])])
        #expect(model.value("toast-duration") == "2000")
        try "toast-duration=3000\n".write(to: f.file, atomically: true, encoding: .utf8)
        f.reload()
        #expect(model.value("toast-duration") == "3000")
    }

    @Test func modelWriteIsAnnouncedAndSeen() throws {
        let f = try Fixture()
        let model = SettingsModel(store: f.store)
        model.register([SettingsPage("p", "P", symbol: "gearshape", sections: [
            SettingsSection("S", rows: [.number("toast-duration", "Toast", unit: "ms")]),
        ])])
        model.set("toast-duration", "1500")
        #expect(model.value("toast-duration") == "1500")
        #expect(model.errors["toast-duration"] == nil)
        #expect(f.text.contains("toast-duration=1500"))
    }

    @Test func announcementOnlyWhenKeysChanged() throws {
        let f = try Fixture("toast-duration=2000\n")
        var posts: [[String]] = []
        let token = NotificationCenter.default.addObserver(forName: .settingsStoreDidChange, object: f.store, queue: nil) {
            posts.append($0.userInfo?["keys"] as? [String] ?? [])
        }
        defer { NotificationCenter.default.removeObserver(token) }
        f.reload()
        #expect(posts.isEmpty)
        try "toast-duration=3000\n".write(to: f.file, atomically: true, encoding: .utf8)
        f.reload()
        #expect(posts == [["toast-duration"]])
    }

    // MARK: Folder note (spec §4.3)

    @Test func folderOverrideOnlyForFolderKeys() throws {
        let folder = URL(fileURLWithPath: "/Photos/Scans")
        let f = try Fixture()
        let store = ConfigSettingsStore(fileURL: f.file, current: { Config() }, reload: {},
                                        folder: { (url: folder, values: ["upscale": "bilinear", "toast-duration": "1"]) },
                                        clearFolder: { _, _ in })
        #expect(store.folderOverride(forKey: "upscale") == "bilinear")
        #expect(store.folderOverride(forKey: "toast-duration") == nil)
        #expect(store.folderOverride(forKey: "downscale") == nil)
    }

    @Test func noWindowNoFolderNote() throws {
        let f = try Fixture()
        #expect(f.store.folderOverride(forKey: "upscale") == nil)
        f.store.clearFolderOverride(forKey: "upscale")   // nothing to clear, nothing happens
    }

    @Test func useDefaultClearsFolderKey() throws {
        let folder = URL(fileURLWithPath: "/Photos/Scans")
        let f = try Fixture("upscale=metalfx\n")
        var values = ["upscale": "bilinear"]
        var cleared: [(String, URL)] = []
        let store = ConfigSettingsStore(fileURL: f.file, current: { Config() }, reload: {},
                                        folder: { (url: folder, values: values) },
                                        clearFolder: { key, url in
                                            cleared.append((key, url))
                                            values[key] = nil
                                        })
        var posts: [[String]] = []
        let token = NotificationCenter.default.addObserver(forName: .settingsStoreDidChange, object: store, queue: nil) {
            posts.append($0.userInfo?["keys"] as? [String] ?? [])
        }
        defer { NotificationCenter.default.removeObserver(token) }
        store.clearFolderOverride(forKey: "upscale")
        #expect(cleared.map(\.0) == ["upscale"])
        #expect(cleared.map(\.1) == [folder])
        #expect(posts == [["upscale"]])
        #expect(store.folderOverride(forKey: "upscale") == nil)
        // loupe.conf is not touched
        #expect(f.text == "upscale=metalfx\n")
        // a key a folder cannot have is not passed on
        store.clearFolderOverride(forKey: "toast-duration")
        #expect(cleared.count == 1)
    }

    @Test func modelShowsAndClearsTheFolderValue() throws {
        let folder = URL(fileURLWithPath: "/Photos/Scans")
        let f = try Fixture()
        var values = ["upscale": "bilinear"]
        let store = ConfigSettingsStore(fileURL: f.file, current: { Config() }, reload: {},
                                        folder: { (url: folder, values: values) },
                                        clearFolder: { key, _ in values[key] = nil })
        let model = SettingsModel(store: store)
        model.register(SettingsPanel.pages())
        #expect(model.folderOverride("upscale") == "bilinear")
        #expect(model.folderOverride("downscale") == nil)
        values["downscale"] = "mitchell"
        model.refreshFolderOverrides()
        #expect(model.folderOverride("downscale") == "mitchell")
        model.clearFolderOverride("upscale")
        #expect(model.folderOverride("upscale") == nil)
        #expect(values == ["downscale": "mitchell"])
    }
}
