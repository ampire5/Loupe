import Testing
import Foundation
@testable import LoupeCore

private func tempHome() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("loupe-settings-\(UUID().uuidString)")
}

private func open(_ home: URL) throws -> StateDatabase { try StateDatabase(directory: home) }

private func dir(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }

@Test func inheritsFromParentAndGrandparent() {
    let s = FolderSettings(database: nil)
    s.set("downscale", "mitchell", for: dir("/photos"))
    #expect(s.values(for: dir("/photos")) == ["downscale": "mitchell"])
    #expect(s.values(for: dir("/photos/2024")) == ["downscale": "mitchell"])
    #expect(s.values(for: dir("/photos/2024/trip")) == ["downscale": "mitchell"])
    #expect(s.values(for: dir("/other")).isEmpty)
}

@Test func perKeyInheritance() {
    let s = FolderSettings(database: nil)
    s.set("upscale-high", "ewa-lanczos", for: dir("/Photos"))
    s.set("downscale", "mitchell", for: dir("/Photos/2024"))
    #expect(s.values(for: dir("/Photos/2024/trip")) == ["upscale-high": "ewa-lanczos", "downscale": "mitchell"])
    #expect(s.values(for: dir("/Photos")) == ["upscale-high": "ewa-lanczos"])
}

@Test func ownOverridesParent() {
    let s = FolderSettings(database: nil)
    s.set("downscale", "lanczos3", for: dir("/Photos"))
    s.set("downscale", "mitchell", for: dir("/Photos/2024"))
    #expect(s.values(for: dir("/Photos/2024")) == ["downscale": "mitchell"])
    #expect(s.values(for: dir("/Photos/2024/trip")) == ["downscale": "mitchell"])
    #expect(s.values(for: dir("/Photos")) == ["downscale": "lanczos3"])
}

@Test func ownValuesExcludeInherited() {
    let s = FolderSettings(database: nil)
    s.set("upscale", "bicubic", for: dir("/Photos"))
    s.set("downscale", "mitchell", for: dir("/Photos/2024"))
    #expect(s.ownValues(for: dir("/Photos/2024")) == ["downscale": "mitchell"])
    #expect(s.ownValues(for: dir("/Photos/2024/trip")).isEmpty)
}

@Test func settingsFolderIsKeyedStandardized() {
    let s = FolderSettings(database: nil)
    s.set("downscale", "mitchell", for: dir("/photos/x/../f1"))
    #expect(s.ownValues(for: dir("/photos/f1")) == ["downscale": "mitchell"])
}

@Test func setNilRemovesAndEmptyEntryDrops() {
    let s = FolderSettings(database: nil)
    s.set("downscale", "mitchell", for: dir("/photos"))
    s.set("upscale", "bicubic", for: dir("/photos"))
    #expect(s.count == 1)
    s.set("downscale", nil, for: dir("/photos"))
    #expect(s.ownValues(for: dir("/photos")) == ["upscale": "bicubic"])
    s.set("upscale", nil, for: dir("/photos"))
    #expect(s.count == 0)
    s.set("upscale", nil, for: dir("/photos"))      // removing what is not there is harmless
    #expect(s.count == 0)
}

@Test func clearKeys() {
    let s = FolderSettings(database: nil)
    s.set("downscale", "mitchell", for: dir("/photos"))
    s.set("upscale", "bicubic", for: dir("/photos"))
    s.set("lanczos-antiring", "on", for: dir("/photos"))
    s.clear(["downscale", "lanczos-antiring", "nope"], for: dir("/photos"))
    #expect(s.ownValues(for: dir("/photos")) == ["upscale": "bicubic"])
    s.clear(["upscale"], for: dir("/photos"))
    #expect(s.count == 0)
}

@Test func prefixIsNotAncestor() {
    let s = FolderSettings(database: nil)
    s.set("downscale", "mitchell", for: dir("/a/b"))
    #expect(s.values(for: dir("/a/bc")).isEmpty)
    #expect(s.values(for: dir("/a/bc/d")).isEmpty)
    #expect(s.values(for: dir("/a/b/c")) == ["downscale": "mitchell"])
}

@Test func volumesRootStopsInheritance() {
    let s = FolderSettings(database: nil)
    s.set("downscale", "mitchell", for: dir("/Volumes"))
    s.set("upscale", "bicubic", for: dir("/"))
    #expect(s.values(for: dir("/Volumes/share/x")).isEmpty)
    #expect(s.values(for: dir("/Volumes/share")).isEmpty)
    s.set("upscale-high", "ewa-lanczos", for: dir("/Volumes/share"))
    #expect(s.values(for: dir("/Volumes/share/x")) == ["upscale-high": "ewa-lanczos"])
    #expect(s.values(for: dir("/Volumes/other/x")).isEmpty)
    #expect(s.values(for: dir("/Users/x")) == ["upscale": "bicubic"])    // local folders go up to /
}

@Test func capacityDropsLeastRecentlyTouched() {
    let s = FolderSettings(database: nil, capacity: 3)
    for n in 1...4 { s.set("downscale", "mitchell", for: dir("/p/f\(n)")) }
    #expect(s.ownValues(for: dir("/p/f1")).isEmpty)
    #expect(s.count == 3)

    let t = FolderSettings(database: nil, capacity: 3)
    for n in 1...3 { t.set("downscale", "mitchell", for: dir("/p/f\(n)")) }
    t.set("downscale", "lanczos3", for: dir("/p/f1"))     // touch 1: now 2 is the oldest
    t.set("downscale", "mitchell", for: dir("/p/f4"))
    #expect(t.ownValues(for: dir("/p/f2")).isEmpty)
    #expect(t.ownValues(for: dir("/p/f1")) == ["downscale": "lanczos3"])
    #expect(t.count == 3)
}

@Test func persistsAcrossInstances() throws {
    let home = tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let s = FolderSettings(database: try open(home), capacity: 3)
    for n in 1...3 { s.set("downscale", "v\(n)", for: dir("/p/f\(n)")) }
    s.set("upscale", "bicubic", for: dir("/p/f1"))
    s.flush()
    let t = FolderSettings(database: try open(home), capacity: 3)
    #expect(t.ownValues(for: dir("/p/f1")) == ["downscale": "v1", "upscale": "bicubic"])
    #expect(t.ownValues(for: dir("/p/f3")) == ["downscale": "v3"])
    t.set("downscale", "v4", for: dir("/p/f4"))          // order survived: 2 was the oldest
    #expect(t.ownValues(for: dir("/p/f2")).isEmpty)
    #expect(t.ownValues(for: dir("/p/f1")).count == 2)
    t.flush()
    let u = FolderSettings(database: try open(home), capacity: 3)      // and the cap reached the database
    #expect(u.count == 3)
    #expect(u.ownValues(for: dir("/p/f2")).isEmpty)
}

@Test func removedKeysAndForgottenFoldersLeaveTheDatabase() throws {
    let home = tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let db = try open(home)
    let s = FolderSettings(database: db)
    s.set("downscale", "mitchell", for: dir("/p"))
    s.set("upscale", "bicubic", for: dir("/p"))
    s.set("downscale", "lanczos3", for: dir("/q"))
    s.flush()
    s.set("downscale", nil, for: dir("/p"))
    s.clear(["downscale"], for: dir("/q"))
    s.flush()
    var rows: [String] = []
    try db.perform { try $0.query("SELECT path, key, value FROM folder_settings", []) { rows.append("\($0.text(0)) \($0.text(1)) \($0.text(2))") } }
    #expect(rows == ["/p upscale bicubic"])
}

@Test func settingsCapIsEnforcedInTheDatabaseToo() throws {
    let home = tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let db = try open(home)
    let s = FolderSettings(database: db, capacity: 2)
    for n in 1...4 { s.set("downscale", "v\(n)", for: dir("/p/f\(n)")) }
    s.set("upscale", "bicubic", for: dir("/p/f3"))       // a folder with two keys counts once
    s.flush()
    var paths: [String] = []
    try db.perform { try $0.query("SELECT DISTINCT path FROM folder_settings ORDER BY path", []) { paths.append($0.text(0)) } }
    #expect(paths == ["/p/f3", "/p/f4"])
    // A smaller cap than the database holds: only the newest folder loads.
    let t = FolderSettings(database: db, capacity: 1)
    #expect(t.count == 1)
    #expect(t.ownValues(for: dir("/p/f3")).count == 2)
}

@Test func databaseHoldsRowsPerKeyWithATouchCounter() throws {
    let home = tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let db = try open(home)
    let s = FolderSettings(database: db)
    s.set("upscale-high", "ewa-lanczos", for: dir("/Volumes/photo/Trips"))
    s.set("downscale", "mitchell", for: dir("/Volumes/photo/Other"))
    s.flush()
    var rows: [String] = []
    try db.perform {
        try $0.query("SELECT path, key, value, touched FROM folder_settings ORDER BY touched", []) {
            rows.append("\($0.text(0)) \($0.text(1)) \($0.text(2)) \($0.int(3))")
        }
    }
    #expect(rows == ["/Volumes/photo/Trips upscale-high ewa-lanczos 1", "/Volumes/photo/Other downscale mitchell 2"])
}

@Test func settingsNothingIsWrittenWithoutChanges() throws {
    let home = tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let s = FolderSettings(database: try open(home))
    s.flush()
    s.set("downscale", nil, for: dir("/p"))
    s.flush()
    #expect(s.writes == 0)
}

private func waitForSettingsWrites(_ s: FolderSettings, atLeast n: Int) async throws {
    for _ in 0..<100 where s.writes < n { try await Task.sleep(for: .milliseconds(50)) }
}

@Test func settingsDebounceCoalescesBurstsIntoOneWrite() async throws {
    let home = tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let db = try open(home)
    let s = FolderSettings(database: db, debounce: .milliseconds(300))
    for n in 1...20 { s.set("downscale", "v\(n)", for: dir("/p")) }      // one burst, well inside the window
    #expect(FolderSettings(database: db).count == 0)                      // not written synchronously
    try await waitForSettingsWrites(s, atLeast: 1)
    try await Task.sleep(for: .milliseconds(600))                          // no second write follows
    #expect(s.writes == 1)
    #expect(FolderSettings(database: db).ownValues(for: dir("/p")) == ["downscale": "v20"])
    s.set("upscale", "bicubic", for: dir("/q"))                            // a later change schedules a new write
    try await waitForSettingsWrites(s, atLeast: 2)
    #expect(s.writes == 2)
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

@Test func onChangeFiresOncePerEffectiveChange() {
    let s = FolderSettings(database: nil)
    let fired = Counter()
    s.onChange = { fired.bump() }
    s.set("downscale", "mitchell", for: dir("/p"))
    #expect(fired.value == 1)
    s.set("downscale", "mitchell", for: dir("/p"))       // same value: nothing changed
    #expect(fired.value == 1)
    s.set("downscale", "lanczos3", for: dir("/p"))
    #expect(fired.value == 2)
    s.clear(["nope"], for: dir("/p"))                    // nothing to clear
    s.set("upscale", nil, for: dir("/p"))                // nothing to remove
    #expect(fired.value == 2)
    s.clear(["downscale"], for: dir("/p"))
    #expect(fired.value == 3)
    s.set("downscale", nil, for: dir("/p"))
    #expect(fired.value == 3)
}

@Test func inheritedValuesLeaveOutTheFolderItself() {
    let s = FolderSettings(database: nil)
    s.set("downscale", "mitchell", for: dir("/Photos"))
    s.set("downscale", "bilinear", for: dir("/Photos/2024"))
    s.set("upscale", "metalfx", for: dir("/Photos/2024"))
    #expect(s.inheritedValues(for: dir("/Photos/2024")) == ["downscale": "mitchell"])
    #expect(s.inheritedValues(for: dir("/Photos/2024/trip")) == ["downscale": "bilinear", "upscale": "metalfx"])
    #expect(s.inheritedValues(for: dir("/Photos")).isEmpty)
    // A volume's root has no ancestors: /Volumes and / are never inherited from.
    s.set("downscale", "mitchell", for: dir("/Volumes"))
    s.set("upscale-high", "ewa-lanczos", for: dir("/Volumes/share"))
    #expect(s.inheritedValues(for: dir("/Volumes/share")).isEmpty)
    #expect(s.inheritedValues(for: dir("/Volumes/share/x")) == ["upscale-high": "ewa-lanczos"])
}
