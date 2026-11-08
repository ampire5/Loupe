import Foundation
import LoupeCore
import SettingsKit

/// Settings over the live Config. Quality filter controls read/edit the current folder when the app
/// supplies a folder editor; without a photo, and for other controls, writes update loupe.conf.
/// File writes keep comments/order and reload; folder writes use the app's bounded persistence path.
@MainActor
public final class ConfigSettingsStore: SettingsStore {
    private let fileURL: URL
    private let current: () -> Config
    private let reload: () -> Void
    private let folder: () -> (url: URL, values: [String: String])?
    private let clearFolder: (String, URL) -> Void
    private let mergedFolderValues: ((URL) -> [String: String])?
    private let editFolder: ((String, String, URL) -> Void)?
    /// Quality controls edit the shown folder; their defaults are saved explicitly by the viewer commands.
    public static let folderFilterKeys = Config.scalingFolderKeys + EffectFolderKeys.keys(.grain)
    private let profile: MachineProfile
    private let defaults: UserDefaults
    public static let thumbnailKeys: Set<String> = ["thumbnail-format", "thumbnail-quality"]

    /// `current` is the app's live config; `reload` re-reads the file into it (and calls `configDidReload(from:)`).
    /// `folder` is the main viewer window's folder and the values it records for itself (nil without a window or a
    /// photo); `clearFolder` drops one key from a folder's values (spec §4.3). `profile` is the Mac the notes judge
    /// the written values against. `folderValues` includes inherited values for filter editors;
    /// `folder` stays own-only for the removable override note. `editFolder` enables folder editing.
    public init(fileURL: URL, current: @escaping () -> Config, reload: @escaping () -> Void,
                folder: @escaping () -> (url: URL, values: [String: String])? = { nil },
                clearFolder: @escaping (String, URL) -> Void = { _, _ in },
                folderValues: ((URL) -> [String: String])? = nil,
                editFolder: ((String, String, URL) -> Void)? = nil,
                profile: MachineProfile = .current, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.fileURL = fileURL
        self.current = current
        self.reload = reload
        self.folder = folder
        self.clearFolder = clearFolder
        self.mergedFolderValues = folderValues
        self.editFolder = editFolder
        self.profile = profile
    }

    /// The `Config.keys` whose file text differs between the two configs.
    public static func changedKeys(from old: Config, to new: Config) -> [String] {
        Config.keys.filter { old.text(forKey: $0) != new.text(forKey: $0) }
    }

    /// Posts `.settingsStoreDidChange` for the keys that differ from `old`; nothing when none do.
    public func configDidReload(from old: Config) {
        let keys = Self.changedKeys(from: old, to: current())
        guard !keys.isEmpty else { return }
        NotificationCenter.default.post(name: .settingsStoreDidChange, object: self, userInfo: ["keys": keys])
    }

    public func value(forKey key: String) -> String? {
        if key == "thumbnail-format" { return defaults.string(forKey: key).flatMap(ThumbnailEncoding.Format.init(rawValue:))?.rawValue ?? "jpeg" }
        if key == "thumbnail-quality" { return String(Int((ThumbnailEncoding.configured(defaults).quality * 100).rounded())) }
        var config = current()
        if editFolder != nil, Self.folderFilterKeys.contains(key), let folder = folder(),
           let value = (mergedFolderValues?(folder.url) ?? folder.values)[key] {
            _ = config.set(key, value)
        }
        return config.text(forKey: key)
    }

    /// Refresh actual editor values as well as override notes after a viewer/folder switch or hotkey.
    public func folderContextDidChange() {
        guard editFolder != nil else { return }
        NotificationCenter.default.post(name: .settingsStoreDidChange, object: self,
                                        userInfo: ["keys": Self.folderFilterKeys])
    }

    public func defaultValue(forKey key: String) -> String {
        if key == "thumbnail-format" { return "jpeg" }
        if key == "thumbnail-quality" { return "80" }
        return Config().text(forKey: key) ?? ""
    }

    /// Checks the exact line a write puts in the file, read back as `Config.parse` reads it: so a value with a ` #`
    /// (read as a comment), unknown `zoom-stops` tokens and a list parse would fall back on are refused too (spec §11).
    /// A line break would write a second line, so it is refused before parsing.
    public func validate(_ value: String, forKey key: String) -> String? {
        if key == "thumbnail-format" { return ThumbnailEncoding.Format(rawValue: value) == nil ? "Choose JPEG, HEIC or AVIF" : nil }
        if key == "thumbnail-quality" { return Int(value).map { (10...100).contains($0) } == true ? nil : "Enter a whole number from 10 to 100" }
        guard value.rangeOfCharacter(from: .newlines) == nil,
              Config.parse("\(key)=\(value)").1.isEmpty else { return "Not a valid value" }
        return nil
    }

    /// The folder's own value of a `Config.folderKeys` key; nil for the other keys and without a folder.
    public func folderOverride(forKey key: String) -> String? {
        guard Config.folderKeys.contains(key) else { return nil }
        return folder()?.values[key]
    }

    /// «Use Default»: the folder drops its value of `key` (loupe.conf is not written), then the key is announced.
    public func clearFolderOverride(forKey key: String) {
        guard Config.folderKeys.contains(key), let url = folder()?.url else { return }
        clearFolder(key, url)
        NotificationCenter.default.post(name: .settingsStoreDidChange, object: self, userInfo: ["keys": [key]])
    }

    /// The note on this Mac for the key's value in the live config (as written: clamping happens where it takes
    /// effect); nil when the value is inside the rule, which a key left out of the file always is.
    public func machineNote(forKey key: String) -> SettingsNote? {
        guard let written = value(forKey: key),
              let note = HardwareAdvice.note(forKey: key, value: written, on: profile) else { return nil }
        return SettingsNote(severity: note.severity == .harmful ? .harmful : .suboptimal, text: note.text,
                            recommended: note.recommended)
    }

    public func setValue(_ value: String, forKey key: String) throws {
        if Self.thumbnailKeys.contains(key) {
            guard validate(value, forKey: key) == nil else { throw NSError(domain: "LoupeSettings", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not a valid thumbnail setting"]) }
            if key == "thumbnail-quality" { defaults.set(Int(value), forKey: key) }
            else { defaults.set(value, forKey: key) }
            NotificationCenter.default.post(name: .settingsStoreDidChange, object: self, userInfo: ["keys": [key]])
            return
        }
        if let editFolder, Self.folderFilterKeys.contains(key), let folder = folder() {
            guard validate(value, forKey: key) == nil else {
                throw NSError(domain: "LoupeSettings", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Not a valid filter setting"])
            }
            let parsed = Config.parse("\(key)=\(value)").0
            guard let canonical = parsed.text(forKey: key) else { return }
            editFolder(key, canonical, folder.url)
            NotificationCenter.default.post(name: .settingsStoreDidChange, object: self, userInfo: ["keys": [key]])
            return
        }
        // Only a missing file starts empty; any other read failure must not clobber the file.
        let existing = FileManager.default.fileExists(atPath: fileURL.path)
            ? try String(contentsOf: fileURL, encoding: .utf8) : ""
        let updated = ConfigText.setting([(key: key, value: value)], in: existing)
        try requireWritable(fileURL)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try updated.write(to: fileURL, atomically: true, encoding: .utf8)
        reload()
    }

    /// Reset to Default: the keys' lines leave the file (comments stay), so a default that depends on this Mac
    /// (`cache-memory`, `jxl-threads-current`) follows it again. One write and one reload for a whole page; no file,
    /// or none of the keys in it: nothing is written.
    public func removeValues(forKeys keys: [String]) throws {
        let preferences = keys.filter(Self.thumbnailKeys.contains)
        for key in preferences { defaults.removeObject(forKey: key) }
        if !preferences.isEmpty {
            NotificationCenter.default.post(name: .settingsStoreDidChange, object: self, userInfo: ["keys": preferences])
        }
        let keys = keys.filter { !Self.thumbnailKeys.contains($0) }
        guard !keys.isEmpty else { return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let existing = try String(contentsOf: fileURL, encoding: .utf8)
        let updated = ConfigText.removing(keys, in: existing)
        guard updated != existing else { return }
        try requireWritable(fileURL)
        try updated.write(to: fileURL, atomically: true, encoding: .utf8)
        reload()
    }
}

/// An existing file the user made read-only is not replaced: an atomic write would swap it out anyway (the folder
/// is writable), so the write fails as the system's own permission error does.
func requireWritable(_ url: URL) throws {
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path), !fm.isWritableFile(atPath: url.path) else { return }
    throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path, NSURLErrorKey: url])
}
