import Testing
import Foundation
@testable import LoupeCore

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("loupe-positions-\(UUID().uuidString)")
}

private func open(_ dir: URL) throws -> StateDatabase { try StateDatabase(directory: dir) }

private func folder(_ n: Int) -> URL { URL(fileURLWithPath: "/photos/f\(n)") }

@Test func rememberAndRecall() {
    let p = FolderPositions(database: nil)
    p.record(folder: folder(1), file: "b.jpg")
    #expect(p.fileName(in: folder(1)) == "b.jpg")
    #expect(p.fileName(in: folder(2)) == nil)
    p.record(folder: folder(1), file: "c.jpg")
    #expect(p.fileName(in: folder(1)) == "c.jpg")
}

@Test func folderIsKeyedStandardized() {
    let p = FolderPositions(database: nil)
    p.record(folder: URL(fileURLWithPath: "/photos/x/../f1"), file: "a.jpg")
    #expect(p.fileName(in: folder(1)) == "a.jpg")
}

@Test func recallFindsTheFileAmongTheListingOrNil() {
    let p = FolderPositions(database: nil)
    p.record(folder: folder(1), file: "b.jpg")
    let files = ["a.jpg", "b.jpg"].map { folder(1).appendingPathComponent($0) }
    #expect(p.recall(in: folder(1), among: files) == files[1])
    #expect(p.recall(in: folder(1), among: [files[0]]) == nil)     // the remembered file is gone
    #expect(p.recall(in: folder(2), among: files) == nil)
}

@Test func lruCapEvictsTheLeastRecentlyRecorded() {
    let p = FolderPositions(database: nil, capacity: 3)
    for n in 1...3 { p.record(folder: folder(n), file: "a.jpg") }
    p.record(folder: folder(1), file: "b.jpg")      // touch 1: now 2 is the oldest
    p.record(folder: folder(4), file: "a.jpg")
    #expect(p.fileName(in: folder(2)) == nil)
    #expect(p.fileName(in: folder(1)) == "b.jpg")
    #expect(p.fileName(in: folder(3)) == "a.jpg")
    #expect(p.fileName(in: folder(4)) == "a.jpg")
    #expect(p.count == 3)
}

@Test func roundTripKeepsPositionsAndOrder() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let p = FolderPositions(database: try open(dir), capacity: 3)
    for n in 1...3 { p.record(folder: folder(n), file: "f\(n).jpg") }
    p.record(folder: folder(1), file: "g.jpg")
    p.flush()
    let q = FolderPositions(database: try open(dir), capacity: 3)
    #expect(q.fileName(in: folder(1)) == "g.jpg")
    #expect(q.fileName(in: folder(3)) == "f3.jpg")
    q.record(folder: folder(4), file: "x.jpg")      // order survived: 2 was the oldest
    #expect(q.fileName(in: folder(2)) == nil)
    #expect(q.fileName(in: folder(1)) == "g.jpg")
    q.flush()
    let r = FolderPositions(database: try open(dir), capacity: 3)      // and the cap reached the database
    #expect(r.count == 3)
    #expect(r.fileName(in: folder(2)) == nil)
}

@Test func positionsCapIsEnforcedInTheDatabaseToo() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let db = try open(dir)
    let p = FolderPositions(database: db, capacity: 3)
    for n in 1...5 { p.record(folder: folder(n), file: "a.jpg") }
    p.flush()
    var paths: [String] = []
    try db.perform { try $0.query("SELECT path FROM folder_positions ORDER BY touched", []) { paths.append($0.text(0)) } }
    #expect(paths == ["/photos/f3", "/photos/f4", "/photos/f5"])
    // A smaller cap than the database holds (the setting changed): only the newest load, the rest go at the next write.
    let q = FolderPositions(database: db, capacity: 2)
    #expect(q.count == 2)
    #expect(q.fileName(in: folder(3)) == nil)
    q.record(folder: folder(5), file: "b.jpg")
    q.flush()
    var left = 0
    try db.perform { try $0.query("SELECT count(*) FROM folder_positions", []) { left = Int($0.int(0)) } }
    #expect(left == 2)
}

private let view2 = SavedView(mode: .actual(2), center: CGPoint(x: 0.31, y: 0.62), imageSize: CGSize(width: 6000, height: 4000))
private let viewFit = SavedView(mode: .fitWidth, center: CGPoint(x: 0.5, y: 0.5), imageSize: CGSize(width: 6000, height: 4000))

@Test func theViewBelongsToTheRecordedFile() {
    let p = FolderPositions(database: nil)
    p.record(folder: folder(1), file: "a.jpg", view: view2)
    #expect(p.fileName(in: folder(1)) == "a.jpg")
    #expect(p.view(in: folder(1), file: "a.jpg") == view2)
    #expect(p.view(in: folder(1), file: "b.jpg") == nil)          // asked for another file of the folder
    #expect(p.view(in: folder(2), file: "a.jpg") == nil)
    p.record(folder: folder(1), file: "a.jpg", view: viewFit)     // a later view replaces it
    #expect(p.view(in: folder(1), file: "a.jpg") == viewFit)
    p.record(folder: folder(1), file: "a.jpg", view: nil)         // and none clears it
    #expect(p.view(in: folder(1), file: "a.jpg") == nil)
}

@Test func recordingTheSameFileKeepsItsViewAnotherFileDropsIt() {
    let p = FolderPositions(database: nil)
    p.record(folder: folder(1), file: "a.jpg", view: view2)
    p.record(folder: folder(2), file: "x.jpg")
    p.record(folder: folder(1), file: "a.jpg")                    // back to the same photo: the view stays
    #expect(p.view(in: folder(1), file: "a.jpg") == view2)
    p.record(folder: folder(1), file: "b.jpg")                    // another photo: the old view is meaningless
    #expect(p.view(in: folder(1), file: "b.jpg") == nil)
    p.record(folder: folder(1), file: "a.jpg")                    // and does not come back with its file
    #expect(p.view(in: folder(1), file: "a.jpg") == nil)
}

@Test func theViewRoundTripsThroughTheDatabase() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let db = try open(dir)
    let p = FolderPositions(database: db)
    p.record(folder: folder(1), file: "a.jpg", view: view2)
    p.record(folder: folder(2), file: "b.jpg")
    p.flush()
    var stored: [String: String?] = [:]
    try db.perform { try $0.query("SELECT path, view FROM folder_positions", []) { stored.updateValue($0.isNull(1) ? nil : $0.text(1), forKey: $0.text(0)) } }
    let expected: [String: String?] = ["/photos/f1": "actual:2.0 0.31 0.62 6000x4000", "/photos/f2": String?.none]
    #expect(stored == expected)
    let q = FolderPositions(database: db)
    #expect(q.view(in: folder(1), file: "a.jpg") == view2)
    #expect(q.view(in: folder(2), file: "b.jpg") == nil)
    q.record(folder: folder(1), file: "c.jpg")                    // another file: the stored view goes too
    q.flush()
    #expect(FolderPositions(database: db).view(in: folder(1), file: "c.jpg") == nil)
    try db.perform { try $0.query("SELECT view IS NULL FROM folder_positions WHERE path = '/photos/f1'", []) { #expect($0.int(0) == 1) } }
}

@Test func anUnreadableStoredViewLoadsAsNone() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let db = try open(dir)
    try db.perform { try $0.run("INSERT INTO folder_positions(path, file, view, touched) VALUES('/photos/f1', 'a.jpg', 'zoom', 1)", []) }
    let p = FolderPositions(database: db)
    #expect(p.fileName(in: folder(1)) == "a.jpg")
    #expect(p.view(in: folder(1), file: "a.jpg") == nil)
}

@Test func recordingAnUnchangedViewWritesNothing() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let p = FolderPositions(database: try open(dir))
    p.record(folder: folder(1), file: "a.jpg", view: view2)
    p.flush()
    p.record(folder: folder(1), file: "a.jpg", view: view2)       // leaving the photo again, nothing moved
    p.record(folder: folder(1), file: "a.jpg")
    p.flush()
    #expect(p.writes == 1)
}

@Test func emptyDatabaseGivesAnEmptyMapAndStillWorks() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let p = FolderPositions(database: try open(dir))
    #expect(p.count == 0)
    p.record(folder: folder(1), file: "a.jpg")
    p.flush()
    #expect(FolderPositions(database: try open(dir)).fileName(in: folder(1)) == "a.jpg")
}

@Test func writesAreDebouncedOffTheCallerAndLandWithoutFlush() async throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let db = try open(dir)
    let p = FolderPositions(database: db, debounce: .milliseconds(100))
    p.record(folder: folder(1), file: "a.jpg")
    #expect(FolderPositions(database: db).fileName(in: folder(1)) == nil)   // not written synchronously
    try await Task.sleep(for: .milliseconds(800))
    #expect(FolderPositions(database: db).fileName(in: folder(1)) == "a.jpg")
}

@Test func nothingIsWrittenWithoutChanges() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let p = FolderPositions(database: try open(dir))
    p.flush()
    #expect(p.writes == 0)
}

private func waitForWrites(_ p: FolderPositions, atLeast n: Int) async throws {
    for _ in 0..<100 where p.writes < n { try await Task.sleep(for: .milliseconds(50)) }
}

@Test func debounceCoalescesBurstsIntoOneWrite() async throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let db = try open(dir)
    let p = FolderPositions(database: db, debounce: .milliseconds(300))
    for n in 1...20 { p.record(folder: folder(1), file: "f\(n).jpg") }   // one burst, well inside the window
    try await waitForWrites(p, atLeast: 1)
    try await Task.sleep(for: .milliseconds(600))                          // no second write follows
    #expect(p.writes == 1)
    #expect(FolderPositions(database: db).fileName(in: folder(1)) == "f20.jpg")
    p.record(folder: folder(2), file: "x.jpg")                              // a later change schedules a new write
    try await waitForWrites(p, atLeast: 2)
    #expect(p.writes == 2)
}

@Test func folderViewIsTheSavedViewOfAnyFile() {
    let p = FolderPositions(database: nil)
    let v = SavedView(mode: .fitWidth, center: CGPoint(x: 0.5, y: 0.3), imageSize: CGSize(width: 600, height: 400))
    #expect(p.view(in: folder(1)) == nil)
    p.record(folder: folder(1), file: "a.jpg")
    #expect(p.view(in: folder(1)) == nil)                          // remembered file, no view
    p.record(folder: folder(1), file: "a.jpg", view: v)
    #expect(p.view(in: folder(1)) == v)
    #expect(p.view(in: folder(1), file: "b.jpg") == nil)           // the file's own question is unchanged
    #expect(p.view(in: folder(2)) == nil)
}

@Test func keepingViewCarriesTheFoldersViewToTheNewFile() {
    let p = FolderPositions(database: nil)
    let v = SavedView(mode: .fitWidth, center: CGPoint(x: 0.5, y: 0.3), imageSize: CGSize(width: 600, height: 400))
    p.record(folder: folder(1), file: "a.jpg", view: v)
    p.record(folder: folder(1), file: "b.jpg", keepingView: true)      // b never shown
    p.record(folder: folder(1), file: "c.jpg", keepingView: true)
    #expect(p.fileName(in: folder(1)) == "c.jpg" && p.view(in: folder(1)) == v)
    let w = SavedView(mode: .fit, center: CGPoint(x: 0.5, y: 0.5), imageSize: CGSize(width: 600, height: 400))
    p.record(folder: folder(1), file: "c.jpg", view: w)                 // the real view overwrites it
    #expect(p.view(in: folder(1), file: "c.jpg") == w)
}

@Test func withoutKeepingViewTheViewIsDropped() {
    let p = FolderPositions(database: nil)
    let v = SavedView(mode: .fitWidth, center: CGPoint(x: 0.5, y: 0.3), imageSize: CGSize(width: 600, height: 400))
    p.record(folder: folder(1), file: "a.jpg", view: v)
    p.record(folder: folder(1), file: "b.jpg")
    #expect(p.view(in: folder(1)) == nil)
    p.record(folder: folder(1), file: "a.jpg", view: v)
    p.record(folder: folder(1), file: "b.jpg", keepingView: false)
    #expect(p.view(in: folder(1)) == nil)
}
