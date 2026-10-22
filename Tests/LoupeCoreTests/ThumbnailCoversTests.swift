import CoreGraphics
import Foundation
import Testing
@testable import LoupeCore

/// Home's card covers (Home spec §2.5): a thumbnail for a file of a folder no window lists.
@Suite struct ThumbnailCoversTests {
    private let fm = FileManager.default

    private func tempDir() -> URL { fm.temporaryDirectory.appendingPathComponent("loupe-covers-\(UUID().uuidString)") }

    private static let locate: @Sendable (URL) -> ThumbnailLocation? = { url in
        ThumbnailLocation(volume: "test", folder: url.deletingLastPathComponent().path, name: url.lastPathComponent)
    }

    private func store(_ reader: ThumbReader, dir: URL) -> ThumbnailStore {
        ThumbnailStore(directory: dir, reader: reader, thumbSize: 32, limitBytes: 1 << 30,
                       locate: Self.locate, idleDelay: .zero, commitDelay: .seconds(3600))
    }

    private func photo(_ reader: ThumbReader, _ path: String = "/photos/a/1.jpg", width: Int = 40) -> URL {
        let url = URL(fileURLWithPath: path)
        reader.add(url, TestJPEGs.gradient(width: width, height: 30))
        return url
    }

    /// Review Focus 5: an empty Thumbs.db makes the cover from the file and keeps it; a later store reads nothing.
    @Test func peekAfterWipe() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader()
        let url = photo(reader)
        let first = await store(reader, dir: dir).cover(url, maxPixel: 64)
        #expect(first != nil)
        let reads = reader.readCount(url)
        #expect(reads > 0)
        let again = await store(reader, dir: dir).cover(url, maxPixel: 64)
        #expect(again != nil)
        #expect(reader.readCount(url) == reads)
    }

    /// Review Focus 5: a row whose stamp no longer matches the file is not used; the cover is made again.
    @Test func peekIgnoresStaleStamp() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader()
        let url = photo(reader, width: 40)
        let old = try #require(await store(reader, dir: dir).cover(url, maxPixel: 64))
        _ = photo(reader, width: 60)
        let reads = reader.readCount(url)
        let new = try #require(await store(reader, dir: dir).cover(url, maxPixel: 64))
        #expect(reader.readCount(url) > reads)
        #expect(Double(new.width) / Double(new.height) > Double(old.width) / Double(old.height))
    }

    @Test func coverUnreadable() async {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader()
        let url = photo(reader)
        reader.fail(url)
        #expect(await store(reader, dir: dir).cover(url, maxPixel: 64) == nil)
    }

    /// `addFile` adds one file to a folder without dropping its other files, as `sync` would.
    @Test func addFileKeepsSiblings() throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let db = try ThumbnailDatabase(directory: dir, thumbSize: 32)
        let folder = ThumbnailLocation(volume: "v", folder: "/f", name: "")
        let stamp = FileStamp(modified: Date(timeIntervalSinceReferenceDate: 1), size: 10)
        let ids = try db.sync(folder: folder, files: [("a.jpg", stamp), ("b.jpg", stamp), ("c.jpg", stamp)])
        let info = ImageInfo(pixelSize: PixelSize(width: 4, height: 3), typeIdentifier: "public.jpeg",
                             isProgressive: false, fileSize: 10, colorSpaceName: nil, orientation: .up)
        try db.put(ids.values.map { ($0, stamp, Data([1, 2, 3]), info) })
        let d = try db.addFile(ThumbnailLocation(volume: "v", folder: "/f", name: "d.jpg"), stamp: stamp)
        #expect(try db.hasThumbnail(Array(ids.values)) == Set(ids.values))
        #expect(try db.file(at: ThumbnailLocation(volume: "v", folder: "/f", name: "d.jpg"))?.id == d)
        #expect(try db.file(at: ThumbnailLocation(volume: "v", folder: "/f", name: "a.jpg"))?.stamp == stamp)
        #expect(try db.file(at: ThumbnailLocation(volume: "v", folder: "/f", name: "zz.jpg")) == nil)
        #expect(try db.addFile(ThumbnailLocation(volume: "v", folder: "/f", name: "a.jpg"), stamp: stamp) == ids["a.jpg"])
    }
}

/// The file browser's folder cards (file browser spec §4.2): how many photos the catalog knows in a folder.
@Suite struct ThumbnailKnownCountsTests {
    private let fm = FileManager.default

    @Test func knownCountsForListedFolder() async {
        let dir = fm.temporaryDirectory.appendingPathComponent("loupe-counts-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader()
        let locate: @Sendable (URL) -> ThumbnailLocation? = { url in
            ThumbnailLocation(volume: "test", folder: url.deletingLastPathComponent().path, name: url.lastPathComponent)
        }
        let store = ThumbnailStore(directory: dir, reader: reader, thumbSize: 32, limitBytes: 1 << 30,
                                   locate: locate, idleDelay: .zero, commitDelay: .seconds(3600))
        for name in ["1.jpg", "2.jpg"] {
            let url = URL(fileURLWithPath: "/photos/a/\(name)")
            reader.add(url, TestJPEGs.gradient(width: 40, height: 30))
            _ = await store.cover(url, maxPixel: 64)
        }
        let a = URL(fileURLWithPath: "/photos/a"), b = URL(fileURLWithPath: "/photos/b")
        let counts = await store.knownCounts([a, b])
        #expect(counts[a] == 2)
        #expect(counts[b] == nil)
    }
}

/// A folder card's mosaic comes from the catalog only: the photos of the folder that have a thumbnail.
@Suite struct ThumbnailFolderSamplesTests {
    private let fm = FileManager.default

    @Test func samplesFromTheCatalog() async {
        let dir = fm.temporaryDirectory.appendingPathComponent("loupe-samples-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader()
        let locate: @Sendable (URL) -> ThumbnailLocation? = { url in
            ThumbnailLocation(volume: "test", folder: url.deletingLastPathComponent().path, name: url.lastPathComponent)
        }
        let store = ThumbnailStore(directory: dir, reader: reader, thumbSize: 32, limitBytes: 1 << 30,
                                   locate: locate, idleDelay: .zero, commitDelay: .seconds(3600))
        for name in ["b.jpg", "a.jpg", "c.jpg", "d.jpg", "e.jpg"] {
            let url = URL(fileURLWithPath: "/photos/a/\(name)")
            reader.add(url, TestJPEGs.gradient(width: 40, height: 30))
            _ = await store.cover(url, maxPixel: 64)
        }
        let folder = URL(fileURLWithPath: "/photos/a")
        let samples = await store.folderSamples(folder, limit: 4)
        #expect(samples.map(\.lastPathComponent) == ["a.jpg", "b.jpg", "c.jpg", "d.jpg"])
        #expect(await store.folderSamples(URL(fileURLWithPath: "/photos/none"), limit: 4).isEmpty)
        // A fresh store (no window lists the folder) still decodes them, from the catalog, reading no file.
        let fresh = ThumbnailStore(directory: dir, reader: reader, thumbSize: 32, limitBytes: 1 << 30,
                                   locate: locate, idleDelay: .zero, commitDelay: .seconds(3600))
        let reads = reader.readCount(samples[0])
        #expect(await fresh.catalogThumbnail(samples[0], maxPixel: 64) != nil)
        #expect(reader.readCount(samples[0]) == reads)
        #expect(await fresh.catalogThumbnail(URL(fileURLWithPath: "/photos/a/zz.jpg"), maxPixel: 64) == nil)
    }
}

/// Names the fake listing hands out by folder path, and which folders it was asked for.
private final class FakeListing: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String: CoverNames] = [:]
    private var asked: [String] = []

    func set(_ folder: String, files: [String] = [], folders: [String] = []) {
        lock.withLock { names[folder] = CoverNames(files: files, folders: folders) }
    }

    var calls: [String] { lock.withLock { asked } }

    var lister: ThumbnailStore.CoverLister {
        { folder, _, _ in
            self.lock.withLock {
                self.asked.append(folder.path)
                return self.names[folder.path] ?? CoverNames(files: [], folders: [])
            }
        }
    }
}

/// Home's folder and archive covers made in the background (folder covers spec): the folder's names listed (with a time
/// limit on a share), four photos spread across it picked, their thumbnails made and kept in the catalog.
@Suite struct ThumbnailFolderCoverTests {
    private let fm = FileManager.default

    private func tempDir() -> URL { fm.temporaryDirectory.appendingPathComponent("loupe-folder-cover-\(UUID().uuidString)") }

    private func store(_ reader: ThumbReader, dir: URL, network: Bool = false) -> ThumbnailStore {
        let volume = network ? "net:share" : "test"
        let locate: @Sendable (URL) -> ThumbnailLocation? = { url in
            ThumbnailLocation(volume: volume, folder: url.deletingLastPathComponent().path, name: url.lastPathComponent)
        }
        return ThumbnailStore(directory: dir, reader: reader, thumbSize: 32, limitBytes: 1 << 30,
                              locate: locate, idleDelay: .zero, commitDelay: .seconds(3600))
    }

    private func photos(_ reader: ThumbReader, in folder: String, _ names: [String]) {
        for name in names { reader.add(URL(fileURLWithPath: folder).appendingPathComponent(name), TestJPEGs.gradient(width: 40, height: 30)) }
    }

    @Test func spreadsFourAcrossTheFolder() async {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader(), listing = FakeListing()
        let names = (1...10).map { String(format: "%02d.jpg", $0) }
        photos(reader, in: "/photos/f", names)
        listing.set("/photos/f", files: names.reversed() + ["notes.txt"], folders: ["sub"])
        let store = store(reader, dir: dir)
        await store.setCoverListing(listing.lister)
        let images = await store.folderCover(URL(fileURLWithPath: "/photos/f"), archive: false, maxPixel: 64)
        #expect(images.count == 4)
        #expect(Set(reader.reads.map(\.lastPathComponent)) == ["01.jpg", "04.jpg", "07.jpg", "10.jpg"])
        // Behind the open folders' own thumbnails, in the reader's queue.
        #expect(reader.priorities == [ThumbnailStore.coverReadPriority])
        let samples = await store.folderSamples(URL(fileURLWithPath: "/photos/f"), limit: 4)
        #expect(samples.map(\.lastPathComponent) == ["01.jpg", "04.jpg", "07.jpg", "10.jpg"])
    }

    /// The photo last viewed in the folder goes first.
    @Test func lastViewedFirst() async {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader(), listing = FakeListing()
        let names = (1...10).map { String(format: "%02d.jpg", $0) }
        photos(reader, in: "/photos/f", names)
        listing.set("/photos/f", files: names)
        let store = store(reader, dir: dir)
        await store.setCoverListing(listing.lister)
        let images = await store.folderCover(URL(fileURLWithPath: "/photos/f"), archive: false, maxPixel: 64,
                                             lastViewed: "05.jpg")
        #expect(images.count == 4)
        #expect(reader.reads.first?.lastPathComponent == "05.jpg")
    }

    /// Review Focus 4: a folder whose four samples the catalog has is not listed again, and no file is read.
    @Test func catalogFirst() async {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader(), listing = FakeListing()
        let names = (1...6).map { "\($0).jpg" }
        photos(reader, in: "/photos/f", names)
        listing.set("/photos/f", files: names)
        let first = store(reader, dir: dir)
        await first.setCoverListing(listing.lister)
        #expect(await first.folderCover(URL(fileURLWithPath: "/photos/f"), archive: false, maxPixel: 64).count == 4)
        let reads = reader.reads.count
        let again = store(reader, dir: dir)   // next session
        await again.setCoverListing(listing.lister)
        #expect(await again.folderCover(URL(fileURLWithPath: "/photos/f"), archive: false, maxPixel: 64).count == 4)
        #expect(listing.calls == ["/photos/f"])
        #expect(reader.reads.count == reads)
    }

    /// A picked photo the catalog already has is decoded from there, not read.
    @Test func catalogThumbnailsAreNotReadAgain() async {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader(), listing = FakeListing()
        let names = (1...4).map { "\($0).jpg" }
        photos(reader, in: "/photos/f", names)
        let store = store(reader, dir: dir)
        _ = await store.cover(URL(fileURLWithPath: "/photos/f/1.jpg"), maxPixel: 64)
        let reads = reader.readCount(URL(fileURLWithPath: "/photos/f/1.jpg"))
        listing.set("/photos/f", files: names)
        await store.setCoverListing(listing.lister)
        #expect(await store.folderCover(URL(fileURLWithPath: "/photos/f"), archive: false, maxPixel: 64).count == 4)
        #expect(reader.readCount(URL(fileURLWithPath: "/photos/f/1.jpg")) == reads)
    }

    /// Review Focus 1: a listing on a share that goes on past the time limit is stopped, and the cover is made from the
    /// names it had by then.
    @Test func slowListingTimesOut() async {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader()
        photos(reader, in: "/photos/f", ["1.jpg", "2.jpg"])
        let stopped = LockedFlag()
        let slow: ThumbnailStore.CoverLister = { _, _, part in
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if !part(CoverNames(files: ["1.jpg", "2.jpg"], folders: [])) {
                    stopped.set()
                    throw CancellationError()
                }
                usleep(10_000)
            }
            return CoverNames(files: ["1.jpg", "2.jpg", "3.jpg"], folders: [])
        }
        let store = store(reader, dir: dir, network: true)
        await store.setCoverListing(slow, networkTimeout: .milliseconds(200))
        let start = ContinuousClock.now
        let images = await store.folderCover(URL(fileURLWithPath: "/photos/f"), archive: false, maxPixel: 64)
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(images.count == 2)
        #expect(await eventually { stopped.isSet })
    }

    /// The time limit is the share's: a local listing runs to its end.
    @Test func localListingHasNoTimeLimit() async {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader()
        photos(reader, in: "/photos/f", ["1.jpg", "2.jpg", "3.jpg"])
        let slow: ThumbnailStore.CoverLister = { _, _, part in
            _ = part(CoverNames(files: ["1.jpg"], folders: []))
            usleep(400_000)
            return CoverNames(files: ["1.jpg", "2.jpg", "3.jpg"], folders: [])
        }
        let store = store(reader, dir: dir)
        await store.setCoverListing(slow, networkTimeout: .milliseconds(100))
        #expect(await store.folderCover(URL(fileURLWithPath: "/photos/f"), archive: false, maxPixel: 64).count == 3)
    }

    /// A card that left stops its listing at once, even one hung on a share.
    @Test func cancelledStopsListing() async {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader()
        let stopped = LockedFlag()
        let hung: ThumbnailStore.CoverLister = { _, _, part in
            while part(CoverNames(files: [], folders: [])) { usleep(10_000) }
            stopped.set()
            throw CancellationError()
        }
        let store = store(reader, dir: dir)
        await store.setCoverListing(hung)
        let task = Task { await store.folderCover(URL(fileURLWithPath: "/photos/f"), archive: false, maxPixel: 64) }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        #expect(await task.value.isEmpty)
        #expect(await eventually { stopped.isSet })
    }

    /// A folder without photos of its own shows one photo of each of its first four subfolders, which go to the
    /// catalog too.
    @Test func subfoldersWhenNoPhotos() async {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader(), listing = FakeListing()
        listing.set("/photos/top", files: ["notes.txt"], folders: ["s1", "s2", "s3", "s4", "s5"])
        for s in ["s1", "s2", "s3", "s4", "s5"] {
            photos(reader, in: "/photos/top/\(s)", ["a.jpg", "b.jpg"])
            listing.set("/photos/top/\(s)", files: ["a.jpg", "b.jpg"])
        }
        let store = store(reader, dir: dir)
        await store.setCoverListing(listing.lister)
        let images = await store.folderCover(URL(fileURLWithPath: "/photos/top"), archive: false, maxPixel: 64)
        #expect(images.count == 4)
        #expect(Set(reader.reads.map(\.path)) == Set(["s1", "s2", "s3", "s4"].map { "/photos/top/\($0)/a.jpg" }))
        #expect(await store.folderSamples(URL(fileURLWithPath: "/photos/top/s2"), limit: 4).map(\.lastPathComponent) == ["a.jpg"])
    }

    /// Subfolders are looked into two levels down, no further; a subfolder without photos gives way to the next one.
    @Test func subfoldersTwoLevelsDown() async {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader(), listing = FakeListing()
        listing.set("/p/two", folders: ["empty", "t1"])
        listing.set("/p/two/t1", folders: ["t2"])
        listing.set("/p/two/t1/t2", files: ["x.jpg"])
        photos(reader, in: "/p/two/t1/t2", ["x.jpg"])
        listing.set("/p/three", folders: ["d1"])
        listing.set("/p/three/d1", folders: ["d2"])
        listing.set("/p/three/d1/d2", folders: ["d3"])
        listing.set("/p/three/d1/d2/d3", files: ["y.jpg"])
        photos(reader, in: "/p/three/d1/d2/d3", ["y.jpg"])
        let store = store(reader, dir: dir)
        await store.setCoverListing(listing.lister)
        #expect(await store.folderCover(URL(fileURLWithPath: "/p/two"), archive: false, maxPixel: 64).count == 1)
        #expect(await store.folderCover(URL(fileURLWithPath: "/p/three"), archive: false, maxPixel: 64).isEmpty)
        #expect(!listing.calls.contains("/p/three/d1/d2/d3"))
    }

    /// Nothing to show: remembered for the session, so the folder is not listed again.
    @Test func emptyRemembered() async {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader(), listing = FakeListing()
        listing.set("/photos/videos", files: ["a.mov", "b.txt"])
        let store = store(reader, dir: dir)
        await store.setCoverListing(listing.lister)
        #expect(await store.folderCover(URL(fileURLWithPath: "/photos/videos"), archive: false, maxPixel: 64).isEmpty)
        #expect(await store.folderCover(URL(fileURLWithPath: "/photos/videos"), archive: false, maxPixel: 64).isEmpty)
        #expect(listing.calls == ["/photos/videos"])
    }

    /// A zip's cover comes from its entries, by their inner paths.
    @Test func archiveFromEntries() async {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader(), listing = FakeListing()
        let names = ["caps\u{2215}1.jpg", "caps\u{2215}2.jpg"]
        photos(reader, in: "/photos/g.zip", names)
        listing.set("/photos/g.zip", files: names)
        let store = store(reader, dir: dir)
        await store.setCoverListing(listing.lister)
        #expect(await store.folderCover(URL(fileURLWithPath: "/photos/g.zip"), archive: true, maxPixel: 64).count == 2)
    }

    /// The real listing: a folder's photos and subfolders by name (hidden ones and other files left out), a zip's
    /// photo entries.
    @Test func listsFolderAndZip() throws {
        let folder = tempDir()
        defer { try? fm.removeItem(at: folder) }
        try fm.createDirectory(at: folder.appendingPathComponent("sub 10"), withIntermediateDirectories: true)
        try fm.createDirectory(at: folder.appendingPathComponent("sub 9"), withIntermediateDirectories: true)
        for name in ["img10.jpg", "img9.jpg", ".hidden.jpg", "notes.txt"] {
            try Data([1]).write(to: folder.appendingPathComponent(name))
        }
        let names = try ThumbnailStore.listCoverNames(folder, archive: false, part: { _ in true })
        #expect(Set(names.files) == ["img9.jpg", "img10.jpg"])
        #expect(Set(names.folders) == ["sub 9", "sub 10"])
        let zip = try ZipFixture.write(ZipFixture.make([.init(name: "caps/2.jpg", data: Data([1])),
                                                        .init(name: "caps/1.jpg", data: Data([1])),
                                                        .init(name: "readme.txt", data: Data([1]))]), in: folder)
        let entries = try ThumbnailStore.listCoverNames(zip, archive: true, part: { _ in true })
        #expect(Set(entries.files) == ["caps\u{2215}1.jpg", "caps\u{2215}2.jpg"])
        #expect(entries.folders.isEmpty)
    }
}

/// A flag set from another thread.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
