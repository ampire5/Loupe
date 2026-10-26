import Foundation
import HomeScreenModel
import Testing
@testable import LoupeCore

@Suite struct BrowserListingSourceTests {
    private let fm = FileManager.default

    private func tree(_ files: [String], dirs: [String] = []) throws -> URL {
        let root = fm.temporaryDirectory.appendingPathComponent("loupe-browse-\(UUID().uuidString)")
        for d in dirs { try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for f in files { try Data("x".utf8).write(to: root.appendingPathComponent(f)) }
        return root
    }

    private func zip(at url: URL, entries: [String]) throws {
        try ZipFixture.make(entries.map { .init(name: $0, data: Data([1, 2, 3])) }).write(to: url)
    }

    @Test func filtersToImagesFoldersAndZips() throws {
        let root = try tree(["a.jpg", "b.JXL", "notes.txt", ".hidden.jpg"], dirs: ["sub", "Foo.app/Contents"])
        defer { try? fm.removeItem(at: root) }
        try zip(at: root.appendingPathComponent("a.zip"), entries: ["1.jpg"])
        let full = try BrowserListingSource.full(root, archives: true)
        #expect(Set(full.map(\.name)) == ["a.zip", "sub", "a.jpg", "b.JXL"])
        #expect(full.first { $0.name == "a.zip" }?.kind == .archive)
        #expect(full.first { $0.name == "sub" }?.kind == .folder)
        let jpg = try #require(full.first { $0.name == "a.jpg" })
        #expect(jpg.kind == .file && jpg.size == 1 && jpg.date != nil && jpg.canRename && jpg.canTrash)
        let names = try BrowserListingSource.names(root, archives: true)
        #expect(Set(names.map(\.name)).isSuperset(of: ["a.zip", "sub", "a.jpg", "b.JXL"]))
        #expect(!names.contains { $0.name.hasPrefix(".") || $0.name == "notes.txt" })
        #expect(names.allSatisfy { $0.date == nil })
    }

    /// A package (an app, a bundle) is not a folder in the names-only pass either: the full listing must not take
    /// cards away (an `.icon` folder of hundreds of them made the grid jump).
    @Test func namesSkipPackages() throws {
        let root = try tree(["a.jpg"], dirs: ["Foo.app/Contents", "Bar.bundle", "Trip.2024"])
        defer { try? fm.removeItem(at: root) }
        let names = try BrowserListingSource.names(root, archives: true).map(\.name)
        #expect(Set(names) == ["a.jpg", "Trip.2024"])
        #expect(Set(try BrowserListingSource.full(root, archives: true).map(\.name)) == Set(names))
    }

    /// Sort by date orders folders too: the full listing gives each folder its own modification date (as Finder's Date
    /// Modified), so the newest folder leads a newest-first sort and the oldest leads an oldest-first one.
    @Test func foldersCarryTheirModificationDate() throws {
        let root = try tree(["a.jpg"], dirs: ["Old", "New", "Middle"])
        defer { try? fm.removeItem(at: root) }
        let old = Date(timeIntervalSinceReferenceDate: 600_000_000)
        let dates = ["Old": old, "Middle": old.addingTimeInterval(86_400), "New": old.addingTimeInterval(2 * 86_400)]
        for (name, date) in dates {
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: root.appendingPathComponent(name).path)
        }
        let full = try BrowserListingSource.full(root, archives: true)
        for (name, date) in dates {
            #expect(full.first { $0.name == name }?.date == date, "\(name)")
        }
        let folders = { (sort: BrowserSort) in sort.order(full).filter { $0.kind == .folder }.map(\.name) }
        #expect(folders(BrowserSort(key: .date, ascending: false)) == ["New", "Middle", "Old"])
        #expect(folders(BrowserSort(key: .date, ascending: true)) == ["Old", "Middle", "New"])
    }

    @Test func zipHiddenWithoutArchiveFolders() throws {
        let root = try tree(["a.jpg"])
        defer { try? fm.removeItem(at: root) }
        try zip(at: root.appendingPathComponent("a.zip"), entries: ["1.jpg"])
        #expect(try BrowserListingSource.full(root, archives: false).map(\.name) == ["a.jpg"])
        #expect(try BrowserListingSource.names(root, archives: false).map(\.name) == ["a.jpg"])
    }

    @Test func namesThenFull() async throws {
        let root = try tree(["a.jpg", "b.jpg"])
        defer { try? fm.removeItem(at: root) }
        var got: [BrowserListing] = []
        for try await listing in BrowserListingSource.listings(root, archives: true) { got.append(listing) }
        #expect(got.count == 2)
        #expect(got.first?.complete == false && got.first?.entries.allSatisfy { $0.date == nil } == true)
        #expect(got.last?.complete == true && got.last?.entries.allSatisfy { $0.date != nil } == true)
    }

    @Test func insideZipListsEntriesReadOnly() async throws {
        let root = try tree([])
        defer { try? fm.removeItem(at: root) }
        let archive = root.appendingPathComponent("g.zip")
        try zip(at: archive, entries: ["caps/0001.jpg", "0002.jpg", "readme.txt"])
        var got: [BrowserListing] = []
        for try await listing in BrowserListingSource.listings(archive, archives: true) { got.append(listing) }
        #expect(got.count == 1)
        let entries = try #require(got.first?.entries)
        #expect(Set(entries.map(\.name)) == ["caps/0001.jpg", "0002.jpg"])
        #expect(entries.allSatisfy { $0.kind == .file && !$0.canRename && !$0.canTrash })
        #expect(entries.allSatisfy { ArchivePath.split($0.url)?.archive.standardizedFileURL == archive.standardizedFileURL })
    }

    @Test func parentOfVolumeRootIsPlaces() {
        #expect(BrowserListingSource.parent(of: URL(fileURLWithPath: "/Volumes/T")) == .places)
        #expect(BrowserListingSource.parent(of: URL(fileURLWithPath: "/")) == .places)
        #expect(BrowserListingSource.parent(of: URL(fileURLWithPath: "/Volumes/T/x")) == .folder(URL(fileURLWithPath: "/Volumes/T")))
        #expect(BrowserListingSource.parent(of: URL(fileURLWithPath: "/Users")) == .folder(URL(fileURLWithPath: "/")))
    }

    @Test func parentOfShareMountedOutsideVolumesIsPlaces() {
        let roots: Set<String> = ["/", "/Users/u/Volumes/D$"]
        #expect(BrowserListingSource.parent(of: URL(fileURLWithPath: "/Users/u/Volumes/D$"), volumeRoots: roots) == .places)
        #expect(BrowserListingSource.parent(of: URL(fileURLWithPath: "/Users/u/Volumes/D$/x"), volumeRoots: roots)
            == .folder(URL(fileURLWithPath: "/Users/u/Volumes/D$")))
        #expect(BrowserListingSource.parent(of: URL(fileURLWithPath: "/Users/u/Volumes"), volumeRoots: roots)
            == .folder(URL(fileURLWithPath: "/Users/u")))
    }

    @Test func parentOfArchive() {
        #expect(BrowserListingSource.parent(of: URL(fileURLWithPath: "/Volumes/T/x/g.zip"))
            == .folder(URL(fileURLWithPath: "/Volumes/T/x")))
    }

    @Test func placesOrderHomeVolumesPins() async throws {
        let root = try tree([], dirs: ["home", "vol", "pin"])
        defer { try? fm.removeItem(at: root) }
        let places = await BrowserListingSource.places(pins: [root.appendingPathComponent("pin")],
                                                       home: root.appendingPathComponent("home"),
                                                       volumes: [root.appendingPathComponent("vol")])
        #expect(places.map(\.name) == ["home", "vol", "pin"])
        #expect(places.allSatisfy { $0.kind == .place && !$0.isDimmed && !$0.canRename && !$0.canTrash })
    }

    @Test func placesDimsMissingPin() async throws {
        let root = try tree([], dirs: ["home"])
        defer { try? fm.removeItem(at: root) }
        let places = await BrowserListingSource.places(pins: [root.appendingPathComponent("gone")],
                                                       home: root.appendingPathComponent("home"), volumes: [])
        #expect(places.map(\.isDimmed) == [false, true])
    }

    @Test func unreadableFolderThrows() async {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(throws: (any Error).self) { try BrowserListingSource.names(missing, archives: true) }
        var failed = false
        do { for try await _ in BrowserListingSource.listings(missing, archives: true) {} } catch { failed = true }
        #expect(failed)
    }
}

/// A slow share: names come in parts, and a folder left stops its listing at the next part.
@Suite struct BrowserListingPartsTests {
    private let fm = FileManager.default

    private func folder(_ n: Int) throws -> URL {
        let root = fm.temporaryDirectory.appendingPathComponent("loupe-parts-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for i in 0..<n { try Data("x".utf8).write(to: root.appendingPathComponent("\(i).jpg")) }
        return root
    }

    @Test func namesInParts() throws {
        let root = try folder(5)
        defer { try? fm.removeItem(at: root) }
        var parts: [Int] = []
        let all = try BrowserListingSource.names(root, archives: true, partEvery: 2, partAfter: .zero) { parts.append($0.count); return true }
        #expect(parts == [2, 4])
        #expect(all.count == 5)
    }

    @Test func stoppedPartsEndTheListing() throws {
        let root = try folder(5)
        defer { try? fm.removeItem(at: root) }
        #expect(throws: CancellationError.self) {
            try BrowserListingSource.names(root, archives: true, partEvery: 2, partAfter: .zero) { _ in false }
        }
    }

    @Test func listingsSendParts() async throws {
        let root = try folder(5)
        defer { try? fm.removeItem(at: root) }
        var got: [(Int, Bool, Bool)] = []
        for try await l in BrowserListingSource.listings(root, archives: true, partEvery: 2, partAfter: .zero) {
            got.append((l.entries.count, l.complete, l.more))
        }
        #expect(got.map(\.0) == [2, 4, 5, 5])
        #expect(got.map(\.2) == [true, true, false, false])
        #expect(got.last?.1 == true)
    }
}

@Test func aFastDiskListsInOneGo() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("loupe-fast-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    for i in 0..<20 { try Data("x".utf8).write(to: root.appendingPathComponent("\(i).jpg")) }
    var parts = 0
    _ = try BrowserListingSource.names(root, archives: true, partEvery: 2, partAfter: .seconds(5)) { _ in parts += 1; return true }
    #expect(parts == 0)
}
