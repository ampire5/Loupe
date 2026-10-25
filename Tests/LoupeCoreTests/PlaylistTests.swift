import Testing
import Foundation
@testable import LoupeCore

@Test func naturalSortAndFilter() {
    let d = URL(fileURLWithPath: "/x")
    let p = Playlist(files: ["b10.jpg", "b2.JPG", "notes.txt", "a.heic"].map { d.appendingPathComponent($0) }, current: d.appendingPathComponent("b2.JPG"))
    #expect(p.files.map(\.lastPathComponent) == ["a.heic", "b2.JPG", "b10.jpg"])
    #expect(p.index == 1)
}
@Test func currentAddedWhenMissing() {
    let d = URL(fileURLWithPath: "/x"); let cur = d.appendingPathComponent("z.png")
    #expect(Playlist(files: [], current: cur).files == [cur])
}
@Test func currentKeptEvenWithUnlistedExtension() {
    let d = URL(fileURLWithPath: "/x"); let cur = d.appendingPathComponent("odd.xyz")
    let p = Playlist(files: [d.appendingPathComponent("a.jpg")], current: cur)
    #expect(p.files.map(\.lastPathComponent) == ["a.jpg", "odd.xyz"])
    #expect(p.current == cur)
}
@Test func currentMatchesUnstandardizedListing() {      // "/x/../x/b.jpg" and "/x/b.jpg" are the same file
    let d = URL(fileURLWithPath: "/x")
    let listed = ["a.jpg", "b.jpg"].map { d.appendingPathComponent($0) }
    let p = Playlist(files: listed, current: URL(fileURLWithPath: "/x/../x/b.jpg"))
    #expect(p.files.count == 2 && p.index == 1)
}
@Test func moveStopsAtEnds() {
    let d = URL(fileURLWithPath: "/x")
    var p = Playlist(files: ["1.jpg", "2.jpg"].map { d.appendingPathComponent($0) }, current: d.appendingPathComponent("2.jpg"))
    #expect(p.move(by: 1) == false && p.index == 1)
    #expect(p.move(by: -1) == true && p.index == 0)
    #expect(p.move(by: -1) == false && p.index == 0)
}
@Test func moveByLargeStepStaysPut() {
    let d = URL(fileURLWithPath: "/x")
    var p = Playlist(files: ["1.jpg", "2.jpg", "3.jpg"].map { d.appendingPathComponent($0) }, current: d.appendingPathComponent("2.jpg"))
    #expect(p.move(by: 5) == false && p.index == 1)
    #expect(p.move(by: -2) == false && p.index == 1)
    #expect(p.move(by: 0) == true && p.index == 1)
    #expect(p.move(by: 1) == true && p.current.lastPathComponent == "3.jpg")
}
@Test func moveToFirstAndLast() {
    let d = URL(fileURLWithPath: "/x")
    var p = Playlist(files: ["1.jpg", "2.jpg", "3.jpg"].map { d.appendingPathComponent($0) }, current: d.appendingPathComponent("2.jpg"))
    p.moveToLast()
    #expect(p.index == 2 && p.current.lastPathComponent == "3.jpg")
    p.moveToFirst()
    #expect(p.index == 0 && p.current.lastPathComponent == "1.jpg")
}
@Test func relistListsRealFolder() async throws {      // temp dir with 3 empty files incl. a hidden one
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    for name in [".h.jpg", "1.jpg", "2.png"] {
        #expect(FileManager.default.createFile(atPath: tmp.appendingPathComponent(name).path, contents: Data()))
    }
    let p = try #require(await Playlist.relist(current: tmp.appendingPathComponent("1.jpg")))
    #expect(p.files.map(\.lastPathComponent) == ["1.jpg", "2.png"])
    #expect(p.index == 0)
}
@Test func relistFillsStampsFromListing() async throws {
    let fm = FileManager.default
    let d = fm.temporaryDirectory.appendingPathComponent("loupe-stamps-\(UUID().uuidString)")
    try fm.createDirectory(at: d, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: d) }
    let a = d.appendingPathComponent("a.jpg"), b = d.appendingPathComponent("b.png"), c = d.appendingPathComponent("c.txt")
    try Data([1, 2, 3]).write(to: a)
    try Data([1, 2, 3, 4, 5]).write(to: b)
    try Data([1]).write(to: c)
    let list = try #require(await Playlist.relist(current: a))
    #expect(list.stamps[a.standardizedFileURL]?.size == 3)
    #expect(list.stamps[b.standardizedFileURL]?.size == 5)
    #expect(list.stamps[c.standardizedFileURL] == nil)
    let mtime = try a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    #expect(list.stamps[a.standardizedFileURL]?.modified == mtime)
}
@Test func stampsFollowTheFilesTheListKeeps() {
    let d = URL(fileURLWithPath: "/x")
    let a = d.appendingPathComponent("a.jpg"), t = d.appendingPathComponent("t.txt")
    let stamp = FileStamp(modified: Date(timeIntervalSince1970: 1), size: 9)
    let p = Playlist(files: [a, t], current: a, stamps: [a: stamp, t: stamp])
    #expect(p.stamps == [a: stamp])
    #expect(Playlist(files: [a], current: a).stamps.isEmpty)
}
@Test func listingStampEqualsStatStampExactly() throws {   // the mtime double must round the same way on both paths
    let fm = FileManager.default
    let d = fm.temporaryDirectory.appendingPathComponent("loupe-exact-\(UUID().uuidString)")
    try fm.createDirectory(at: d, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: d) }
    for i in 0..<200 {
        let url = d.appendingPathComponent("\(i).jpg")
        try Data([1, 2, 3]).write(to: url)
        var st = stat()
        #expect(stat(url.path, &st) == 0)
        let listed = FileStamp(try url.resourceValues(forKeys: Set(FileStamp.listingKeys)))
        #expect(listed == FileStamp(st))
    }
}

// MARK: Re-reading the folder (M2.5 spec §4.5)

@Test func replacingKeepsCurrentByURL() {
    let d = URL(fileURLWithPath: "/x")
    let names = ["a.jpg", "b.jpg", "c.jpg"].map { d.appendingPathComponent($0) }
    let old = Playlist(files: names, current: names[1])
    let stamp = FileStamp(modified: Date(timeIntervalSince1970: 1), size: 9)
    let added = d.appendingPathComponent("a2.jpg"), last = d.appendingPathComponent("d.jpg")
    // The listing's own position (here its first file) is not where the viewer is.
    let listed = Playlist(files: names + [added, last], current: names[0], stamps: [added: stamp])
    let new = old.replacing(with: listed)
    #expect(new.current == names[1] && new.index == 2)
    #expect(new.files.map(\.lastPathComponent) == ["a.jpg", "a2.jpg", "b.jpg", "c.jpg", "d.jpg"])
    #expect(new.stamps == [added: stamp])
    // Nothing changed: the same playlist.
    #expect(old.replacing(with: Playlist(files: names, current: names[2])) == old)
}
@Test func replacingWhenCurrentGoneClampsIndex() {
    let d = URL(fileURLWithPath: "/x")
    let names = ["a.jpg", "b.jpg", "c.jpg"].map { d.appendingPathComponent($0) }
    // The middle one went: the file now at its index (the next one) becomes current.
    let middle = Playlist(files: names, current: names[1])
    let withoutB = Playlist(files: [names[0], names[2]], current: names[0])
    #expect(middle.replacing(with: withoutB).current == names[2])
    // The last one went: the index is clamped to the new end.
    let end = Playlist(files: names, current: names[2])
    let withoutC = Playlist(files: [names[0], names[1]], current: names[0])
    let new = end.replacing(with: withoutC)
    #expect(new.current == names[1] && new.index == 1 && new.files == withoutC.files)
}
@Test func relistDropsAGoneCurrentAndSeesNewFiles() async throws {
    let fm = FileManager.default
    let d = fm.temporaryDirectory.appendingPathComponent("loupe-relist-\(UUID().uuidString)")
    try fm.createDirectory(at: d, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: d) }
    for name in ["1.jpg", "2.jpg", "3.jpg"] { try Data([1]).write(to: d.appendingPathComponent(name)) }
    let two = d.appendingPathComponent("2.jpg")
    let kept = try #require(await Playlist.relist(current: two))
    #expect(kept.files.map(\.lastPathComponent) == ["1.jpg", "2.jpg", "3.jpg"] && kept.current == two.standardizedFileURL)
    #expect(kept.stamps.count == 3)
    try fm.removeItem(at: two)
    try Data([1, 2]).write(to: d.appendingPathComponent("4.jpg"))
    let listed = try #require(await Playlist.relist(current: two))
    #expect(listed.files.map(\.lastPathComponent) == ["1.jpg", "3.jpg", "4.jpg"])
    let old = Playlist(files: kept.files, current: two)
    #expect(old.replacing(with: listed).current.lastPathComponent == "3.jpg")
}
@Test func relistKeepsACurrentTheListingLeavesOut() async throws {   // opened directly: odd extension, hidden
    let fm = FileManager.default
    let d = fm.temporaryDirectory.appendingPathComponent("loupe-relist-odd-\(UUID().uuidString)")
    try fm.createDirectory(at: d, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: d) }
    for name in ["a.jpg", "odd.xyz", ".hidden.jpg"] { try Data([1]).write(to: d.appendingPathComponent(name)) }
    for name in ["odd.xyz", ".hidden.jpg"] {
        let current = d.appendingPathComponent(name)
        let listed = try #require(await Playlist.relist(current: current))
        #expect(listed.files.count == 2 && listed.files.contains(current.standardizedFileURL), "\(name)")
        #expect(Playlist(files: [current], current: current).replacing(with: listed).current == current.standardizedFileURL)
    }
}
@Test func relistKeepsFilesTheFilterDropsWhileTheyExist() async throws {   // stepped off an odd file opened directly
    let fm = FileManager.default
    let d = fm.temporaryDirectory.appendingPathComponent("loupe-relist-keep-\(UUID().uuidString)")
    try fm.createDirectory(at: d, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: d) }
    let a = d.appendingPathComponent("a.jpg"), odd = d.appendingPathComponent("odd.xyz"), hidden = d.appendingPathComponent(".h.jpg")
    for url in [a, odd, hidden] { try Data([1]).write(to: url) }
    // Opened odd.xyz, kept .h.jpg from an earlier relist, then stepped to a.jpg.
    var old = Playlist(files: [a, odd], current: odd, stamps: [:], keeping: [hidden])
    #expect(old.move(by: try #require(old.files.firstIndex(of: a.standardizedFileURL)) - old.index))
    #expect(old.current == a.standardizedFileURL && old.files.count == 3)
    let listed = try #require(await Playlist.relist(current: a, keeping: old.files))
    #expect(Set(listed.files.map(\.lastPathComponent)) == ["a.jpg", "odd.xyz", ".h.jpg"])
    let kept = old.replacing(with: listed)
    #expect(kept.files == old.files && kept.current == old.current)
    try fm.removeItem(at: odd)
    try fm.removeItem(at: hidden)
    let gone = try #require(await Playlist.relist(current: a, keeping: old.files))
    #expect(gone.files.map(\.lastPathComponent) == ["a.jpg"])
}
@Test func relistLeavesOutFlagHiddenFilesUnlessKept() async throws {   // chflags hidden: a visible name, the hidden flag
    let fm = FileManager.default
    let d = fm.temporaryDirectory.appendingPathComponent("loupe-relist-flag-\(UUID().uuidString)")
    try fm.createDirectory(at: d, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: d) }
    let a = d.appendingPathComponent("a.jpg")
    var flagged = d.appendingPathComponent("flagged.jpg")
    for url in [a, flagged] { try Data([1]).write(to: url) }
    var values = URLResourceValues()
    values.isHidden = true
    try flagged.setResourceValues(values)
    flagged.removeAllCachedResourceValues()
    #expect(try flagged.resourceValues(forKeys: [.isHiddenKey]).isHidden == true)
    let plain = try #require(await Playlist.relist(current: a))
    #expect(plain.files.map(\.lastPathComponent) == ["a.jpg"])
    let kept = try #require(await Playlist.relist(current: a, keeping: [a, flagged]))
    #expect(kept.files.map(\.lastPathComponent) == ["a.jpg", "flagged.jpg"])
    #expect(kept.stamps[flagged.standardizedFileURL]?.size == 1)
    let opened = try #require(await Playlist.relist(current: flagged))
    #expect(opened.files.map(\.lastPathComponent) == ["a.jpg", "flagged.jpg"] && opened.current == flagged.standardizedFileURL)
}
@Test func relistOfAnEmptiedFolderKeepsJustTheCurrent() async throws {
    let fm = FileManager.default
    let d = fm.temporaryDirectory.appendingPathComponent("loupe-relist-empty-\(UUID().uuidString)")
    try fm.createDirectory(at: d, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: d) }
    let gone = d.appendingPathComponent("gone.jpg")
    let listed = try #require(await Playlist.relist(current: gone))
    #expect(listed.files == [gone.standardizedFileURL])
}
@Test func relistOfAnUnreadableFolderIsNil() async {   // a dropped share keeps the playlist it had
    let cur = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/a.jpg")
    #expect(await Playlist.relist(current: cur) == nil)
}

// MARK: Folder polling

@Test func folderPollOffAtZero() {
    #expect(FolderPollSchedule.interval(pollMilliseconds: 0, watched: false, lastListing: nil) == nil)
    #expect(FolderPollSchedule.interval(pollMilliseconds: 0, watched: false, lastListing: .milliseconds(50)) == nil)
}
@Test func folderPollEveryFolderPollMilliseconds() {
    #expect(FolderPollSchedule.interval(pollMilliseconds: 3000, watched: false, lastListing: nil) == .milliseconds(3000))
    #expect(FolderPollSchedule.interval(pollMilliseconds: 3000, watched: false, lastListing: .milliseconds(5)) == .milliseconds(3000))
    #expect(FolderPollSchedule.interval(pollMilliseconds: 3000, watched: false, lastListing: .milliseconds(300)) == .milliseconds(3000))
}
@Test func folderPollStretchedToTenListings() {   // a slow share is never listed back to back
    #expect(FolderPollSchedule.interval(pollMilliseconds: 3000, watched: false, lastListing: .milliseconds(301)) == .milliseconds(3010))
    #expect(FolderPollSchedule.interval(pollMilliseconds: 500, watched: false, lastListing: .seconds(2)) == .seconds(20))
}
@Test func folderPollWithKqueueIsASafetyNet() {   // events report changes; the poll comes ten times less often
    #expect(FolderPollSchedule.interval(pollMilliseconds: 0, watched: true, lastListing: nil) == nil)
    #expect(FolderPollSchedule.interval(pollMilliseconds: 3000, watched: true, lastListing: nil) == .seconds(30))
    #expect(FolderPollSchedule.interval(pollMilliseconds: 3000, watched: true, lastListing: .milliseconds(11)) == .seconds(30))
    #expect(FolderPollSchedule.interval(pollMilliseconds: 3000, watched: true, lastListing: .seconds(4)) == .seconds(40))
    #expect(FolderPollSchedule.interval(pollMilliseconds: 500, watched: true, lastListing: .milliseconds(1300)) == .seconds(13))
}
@Test func returnRereadsWhatMayHaveBeenMissed() {   // no events, an event dropped while hidden, a failed or no listing
    func reread(watched: Bool = true, missed: Bool = false, last: Duration? = .milliseconds(20),
                since: Duration? = .seconds(1)) -> Bool {
        FolderPollSchedule.rereadOnReturn(pollMilliseconds: 3000, watched: watched, missed: missed,
                                          lastListing: last, sinceListing: since)
    }
    #expect(reread(watched: false))
    #expect(reread(missed: true))
    #expect(reread(last: nil, since: nil))
    #expect(!reread())
}
@Test func returnRereadsOnceThePollWouldHave() {   // a file rewritten in place raises no event: the safety net's interval
    #expect(!FolderPollSchedule.rereadOnReturn(pollMilliseconds: 3000, watched: true, missed: false,
                                               lastListing: .milliseconds(20), sinceListing: .seconds(29)))
    #expect(FolderPollSchedule.rereadOnReturn(pollMilliseconds: 3000, watched: true, missed: false,
                                              lastListing: .milliseconds(20), sinceListing: .seconds(30)))
    // A slow share's interval is stretched as the poll's is: ten 4 s listings.
    #expect(!FolderPollSchedule.rereadOnReturn(pollMilliseconds: 3000, watched: true, missed: false,
                                               lastListing: .seconds(4), sinceListing: .seconds(39)))
    #expect(FolderPollSchedule.rereadOnReturn(pollMilliseconds: 3000, watched: true, missed: false,
                                              lastListing: .seconds(4), sinceListing: .seconds(40)))
}
@Test func returnWithPollingOffTrustsTheEvents() {   // folder-poll=0: no safety net while active, none on return either
    #expect(!FolderPollSchedule.rereadOnReturn(pollMilliseconds: 0, watched: true, missed: false,
                                               lastListing: .milliseconds(20), sinceListing: .seconds(3600)))
    #expect(FolderPollSchedule.rereadOnReturn(pollMilliseconds: 0, watched: false, missed: false,
                                              lastListing: .milliseconds(20), sinceListing: .seconds(1)))
}
@Test func quickListGivesTheFolderNamesWithoutStamps() async throws {   // the fast first pass after an open
    let fm = FileManager.default
    let d = fm.temporaryDirectory.appendingPathComponent("loupe-quick-\(UUID().uuidString)")
    try fm.createDirectory(at: d.appendingPathComponent("sub.jpg"), withIntermediateDirectories: true)   // a folder is not a photo
    defer { try? fm.removeItem(at: d) }
    for name in ["img10.jpg", "img2.png", ".h.jpg", "notes.txt", "é.jpg"] { try Data([1]).write(to: d.appendingPathComponent(name)) }
    let current = d.appendingPathComponent("img2.png")
    let quick = try #require(await Playlist.quickList(current: current))
    #expect(quick.files.map(\.lastPathComponent) == ["é.jpg", "img2.png", "img10.jpg"])
    #expect(quick.current == current.standardizedFileURL && quick.stamps.isEmpty)
    // The full listing spells every file the same way (é included), so it replaces the quick one without moving the photo.
    let full = try #require(await Playlist.relist(current: current))
    // (`relist` keeps a folder named like a photo; the quick pass knows folders by `d_type` and leaves them out.)
    #expect(full.files.filter { !$0.hasDirectoryPath } == quick.files)
}
@Test func quickListKeepsACurrentItLeavesOutAndFailsOnAMissingFolder() async throws {
    let fm = FileManager.default
    let d = fm.temporaryDirectory.appendingPathComponent("loupe-quick-odd-\(UUID().uuidString)")
    try fm.createDirectory(at: d, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: d) }
    for name in ["a.jpg", ".h.jpg"] { try Data([1]).write(to: d.appendingPathComponent(name)) }
    let hidden = d.appendingPathComponent(".h.jpg")
    let quick = try #require(await Playlist.quickList(current: hidden))
    #expect(quick.files.map(\.lastPathComponent) == [".h.jpg", "a.jpg"] && quick.current == hidden.standardizedFileURL)
    #expect(await Playlist.quickList(current: d.appendingPathComponent("gone/a.jpg")) == nil)
}

// MARK: Browser order (file browser spec §4.4)

import HomeScreenModel

private func stamped(_ names: [(String, Double, Int)]) -> (files: [URL], stamps: [URL: FileStamp]) {
    let d = URL(fileURLWithPath: "/x")
    var stamps: [URL: FileStamp] = [:]
    let files = names.map { name, date, size -> URL in
        let url = d.appendingPathComponent(name)
        stamps[url] = FileStamp(modified: Date(timeIntervalSinceReferenceDate: date), size: size)
        return url
    }
    return (files, stamps)
}

@Test func sortedByDateDescKeepsCurrent() {
    let (files, stamps) = stamped([("a.jpg", 1, 10), ("b.jpg", 3, 5), ("c.jpg", 2, 7)])
    let p = Playlist(files: files, current: files[2], stamps: stamps).sorted(BrowserSort(text: "date-desc")!)
    #expect(p.files.map(\.lastPathComponent) == ["b.jpg", "c.jpg", "a.jpg"])
    #expect(p.current.lastPathComponent == "c.jpg")
    #expect(p.stamps.count == 3)
}

@Test func sortedBySizeUsesStamps() {
    let (files, stamps) = stamped([("a.jpg", 1, 10), ("b.jpg", 3, 5), ("c.jpg", 2, 7)])
    let p = Playlist(files: files, current: files[0], stamps: stamps).sorted(BrowserSort(text: "size")!)
    #expect(p.files.map(\.lastPathComponent) == ["b.jpg", "c.jpg", "a.jpg"])
    #expect(p.index == 2)
}

@Test func sortedWithoutStampsIsNatural() {
    let d = URL(fileURLWithPath: "/x")
    let files = ["img10.jpg", "img2.jpg"].map { d.appendingPathComponent($0) }
    let p = Playlist(files: files, current: files[0]).sorted(BrowserSort(text: "date-desc")!)
    #expect(p.files.map(\.lastPathComponent) == ["img2.jpg", "img10.jpg"])
    #expect(p.current.lastPathComponent == "img10.jpg")
}

@Test func sortedStandardIsIdentity() {
    let (files, stamps) = stamped([("b.jpg", 1, 1), ("a.jpg", 2, 2)])
    let p = Playlist(files: files, current: files[0], stamps: stamps)
    #expect(p.sorted(.standard) == p)
    #expect(p.sorted(BrowserSort(text: "name-desc")!).files.map(\.lastPathComponent) == ["b.jpg", "a.jpg"])
}

@Test func sortSettingInherits() {
    let s = FolderSettings(database: nil)
    s.set(BrowserSort.settingKey, "date-desc", for: URL(fileURLWithPath: "/a", isDirectory: true))
    #expect(BrowserSort.forFolder(URL(fileURLWithPath: "/a/b", isDirectory: true), settings: s) == BrowserSort(text: "date-desc"))
    #expect(BrowserSort.forFolder(URL(fileURLWithPath: "/c", isDirectory: true), settings: s) == .standard)
    #expect(BrowserSort.forFolder(URL(fileURLWithPath: "/a", isDirectory: true), settings: nil) == .standard)
}

@Test func badSortTextIsStandard() {
    let s = FolderSettings(database: nil)
    s.set(BrowserSort.settingKey, "sideways", for: URL(fileURLWithPath: "/a", isDirectory: true))
    #expect(BrowserSort.forFolder(URL(fileURLWithPath: "/a", isDirectory: true), settings: s) == .standard)
}
