import Testing
import Foundation
import HomeScreenModel
@testable import LoupeCore

private let origin = URL(fileURLWithPath: "/photos/a/1.jpg")
private let none: (URL, [URL]) -> URL? = { _, _ in nil }

private func target(_ files: [String]) -> FolderTarget {
    let dir = URL(fileURLWithPath: "/photos/b")
    return FolderTarget(folder: dir, images: files.map { dir.appendingPathComponent($0) })
}

@Test func secondRequestIsIgnoredWhilePending() {
    var r = FolderRequest()
    let first = r.begin(from: origin)
    #expect(first != nil && r.isPending)
    #expect(r.begin(from: origin) == nil)
    _ = r.finish(first!, result: .success(nil), current: origin, remembered: none)
    #expect(!r.isPending)
    #expect(r.begin(from: origin) != nil)              // free again once finished
}

@Test func successLandsOnTheFirstPhoto() {
    var r = FolderRequest()
    let t = r.begin(from: origin)!
    let outcome = r.finish(t, result: .success(target(["10.jpg", "2.jpg"])), current: origin, remembered: none)
    guard case .enter(let list) = outcome else { Issue.record("expected enter, got \(outcome)"); return }
    #expect(list.current.lastPathComponent == "2.jpg" && list.index == 0 && list.files.count == 2)
}

@Test func successLandsOnTheRememberedPhoto() {
    var r = FolderRequest()
    let t = r.begin(from: origin)!
    let outcome = r.finish(t, result: .success(target(["1.jpg", "2.jpg", "3.jpg"])), current: origin) { _, files in
        files.first { $0.lastPathComponent == "3.jpg" }
    }
    guard case .enter(let list) = outcome else { Issue.record("expected enter"); return }
    #expect(list.current.lastPathComponent == "3.jpg" && list.index == 2)
}

@Test func noNeighbourStays() {
    var r = FolderRequest()
    let t = r.begin(from: origin)!
    #expect(r.finish(t, result: .success(nil), current: origin, remembered: none) == .stay)
    #expect(!r.isPending)
}

@Test func errorKeepsTheFolderAndNamesTheParent() {
    var r = FolderRequest()
    let t = r.begin(from: origin)!
    let outcome = r.finish(t, result: .failure(FolderNavigationError.timedOut), current: origin, remembered: none)
    guard case .fail(let text) = outcome else { Issue.record("expected fail"); return }
    #expect(text.contains("photos") && text.contains("not responding"))
    var r2 = FolderRequest()
    let t2 = r2.begin(from: origin)!
    guard case .fail(let text2) = r2.finish(t2, result: .failure(FolderNavigationError.unreadable), current: origin, remembered: none)
    else { Issue.record("expected fail"); return }
    #expect(text2.contains("photos") && !text2.contains("not responding"))
}

@Test func resultIsDroppedAfterAnotherNavigation() {
    var r = FolderRequest()
    let t = r.begin(from: origin)!
    r.cancel()                                          // the user flipped to another photo
    #expect(r.finish(t, result: .success(target(["1.jpg"])), current: origin, remembered: none) == .drop)
    #expect(r.begin(from: origin) != nil)
}

@Test func staleTokenCannotFinishANewerRequest() {
    var r = FolderRequest()
    let old = r.begin(from: origin)!
    r.cancel()
    let new = r.begin(from: origin)!
    #expect(r.finish(old, result: .success(nil), current: origin, remembered: none) == .drop)
    #expect(r.isPending)                                // the newer one is untouched
    #expect(r.finish(new, result: .success(nil), current: origin, remembered: none) == .stay)
}

@Test func resultIsDroppedWhenTheCurrentPhotoIsNotTheOrigin() {
    var r = FolderRequest()
    let t = r.begin(from: origin)!
    let other = URL(fileURLWithPath: "/photos/a/2.jpg")
    #expect(r.finish(t, result: .success(target(["1.jpg"])), current: other, remembered: none) == .drop)
    #expect(!r.isPending)
}

@Test func folderJumpPlaylistCarriesTheStampsOfItsImages() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("loupe-jump-\(UUID().uuidString)")
    let from = root.appendingPathComponent("1"), to = root.appendingPathComponent("2")
    for dir in [from, to] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
    defer { try? fm.removeItem(at: root) }
    let a = to.appendingPathComponent("a.jpg"), b = to.appendingPathComponent("b.png"), c = to.appendingPathComponent("c.txt")
    try Data([1, 2, 3]).write(to: a)
    try Data([1, 2, 3, 4, 5]).write(to: b)
    try Data([1]).write(to: c)
    let target = try #require(await FolderNavigator().neighbour(of: from, step: 1))
    let list = FolderRequest.playlist(for: target, remembered: none)
    #expect(list.stamps[a.standardizedFileURL]?.size == 3)
    #expect(list.stamps[b.standardizedFileURL]?.size == 5)
    #expect(list.stamps[c.standardizedFileURL] == nil)
    let mtime = try a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    #expect(list.stamps[a.standardizedFileURL]?.modified == mtime)
}

@Test func playlistForTargetFollowsSort() {
    let d = URL(fileURLWithPath: "/x")
    let a = d.appendingPathComponent("a.jpg"), b = d.appendingPathComponent("b.jpg")
    let stamps = [a: FileStamp(modified: Date(timeIntervalSinceReferenceDate: 1), size: 1),
                  b: FileStamp(modified: Date(timeIntervalSinceReferenceDate: 2), size: 1)]
    let target = FolderTarget(folder: d, images: [a, b], stamps: stamps)
    let first = FolderRequest.playlist(for: target, sort: BrowserSort(text: "date-desc")!) { _, _ in nil }
    #expect(first.files == [b, a])
    #expect(first.current == b)
    let remembered = FolderRequest.playlist(for: target, sort: BrowserSort(text: "date-desc")!) { _, _ in a }
    #expect(remembered.current == a)
    #expect(remembered.files == [b, a])   // the folder's sort kept on the remembered photo
}
