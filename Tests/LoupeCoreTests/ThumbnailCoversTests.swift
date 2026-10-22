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

    private func store(_ reader: ThumbReader, dir: URL,
                       locate: @escaping @Sendable (URL) -> ThumbnailLocation? = { url in
                           ThumbnailLocation(volume: "test", folder: url.deletingLastPathComponent().path,
                                             name: url.lastPathComponent)
                       }) -> ThumbnailStore {
        return ThumbnailStore(directory: dir, reader: reader, thumbSize: 32, limitBytes: 1 << 30,
                              locate: locate, idleDelay: .zero, commitDelay: .seconds(3600))
    }

    /// Where the catalog keeps `folder`'s files, as `folderLocation` would say.
    private func loc(_ folder: String, network: Bool = false) -> ThumbnailLocation {
        ThumbnailLocation(volume: network ? "net:share" : "test", folder: folder, name: "_")
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
        let images = await store.folderCover(URL(fileURLWithPath: "/photos/f"), archive: false, in: loc("/photos/f"), maxPixel: 64)
        #expect(images?.count == 4)
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
        let images = await store.folderCover(URL(fileURLWithPath: "/photos/f"), archive: false, in: loc("/photos/f"), maxPixel: 64,
                                             lastViewed: "05.jpg")
        #expect(images?.count == 4)
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
        #expect(await first.folderCover(URL(fileURLWithPath: "/photos/f"), archive: false, in: loc("/photos/f"), maxPixel: 64)?.count == 4)
        let reads = reader.reads.count
        let again = store(reader, dir: dir)   // next session
        await again.setCoverListing(listing.lister)
        #expect(await again.folderCover(URL(fileURLWithPath: "/photos/f"), archive: false, in: loc("/photos/f"), maxPixel: 64)?.count == 4)
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
        #expect(await store.folderCover(URL(fileURLWithPath: "/photos/f"), archive: false, in: loc("/photos/f"), maxPixel: 64)?.count == 4)
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
        let store = store(reader, dir: dir)
        // A second: under a loaded test run the listing's thread may start late, and give no name before 200 ms.
        await store.setCoverListing(slow, networkTimeout: .seconds(1))
        let start = ContinuousClock.now
        let images = await store.folderCover(URL(fileURLWithPath: "/photos/f"), archive: false,
                                             in: loc("/photos/f", network: true), maxPixel: 64)
        #expect(ContinuousClock.now - start < .seconds(5))   // the listing goes on for 10
        #expect(images?.count == 2)
        #expect(await eventually { stopped.isSet })
    }

    /// Review fix: the catalog's four are a spread too, the photo last viewed first, sorted as Finder does; the folder is
    /// not listed.
    @Test func catalogCoverIsASpread() async {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader(), listing = FakeListing()
        // Told apart by their shape: thumbnails 32 wide, 24 ... 7 high.
        let names = (1...10).map { String(format: "%02d.jpg", $0) }
        var byHeight: [Int: String] = [:]
        let store = store(reader, dir: dir)
        for (i, name) in names.enumerated() {
            let url = URL(fileURLWithPath: "/photos/f").appendingPathComponent(name)
            reader.add(url, TestJPEGs.gradient(width: 40 + 10 * i, height: 30))
            guard let image = await store.cover(url, maxPixel: 64) else { Issue.record("no cover for \(name)"); return }
            byHeight[image.height] = name
        }
        #expect(byHeight.count == 10)
        await store.setCoverListing(listing.lister)
        let folder = URL(fileURLWithPath: "/photos/f")
        let plain = await store.folderCover(folder, archive: false, in: loc("/photos/f"), maxPixel: 64) ?? []
        #expect(plain.map { byHeight[$0.height] } == ["01.jpg", "04.jpg", "07.jpg", "10.jpg"])
        let last = await store.folderCover(folder, archive: false, in: loc("/photos/f"), maxPixel: 64,
                                           lastViewed: "05.jpg") ?? []
        #expect(last.map { byHeight[$0.height] } == ["05.jpg", "01.jpg", "07.jpg", "10.jpg"])
        #expect(listing.calls.isEmpty)
    }

    /// Review fix: a share whose listings hang fills its own lane, never the local one: the local cards' covers are all
    /// made, and the share's cards are "not now" (tried again later), not done with nothing.
    @Test func hungShareDoesNotStarveLocalCovers() async {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader()
        let hang = DispatchSemaphore(value: 0)
        let locals = (1...4).map { "/loc/\($0)" }, shares = (1...5).map { "/net/\($0)" }
        for folder in locals { photos(reader, in: folder, ["a.jpg", "b.jpg", "c.jpg", "d.jpg"]) }
        let lister: ThumbnailStore.CoverLister = { folder, _, _ in
            if folder.path.hasPrefix("/net/") { hang.wait() }   // in the kernel: deaf to `part`
            return CoverNames(files: ["a.jpg", "b.jpg", "c.jpg", "d.jpg"], folders: [])
        }
        let store = store(reader, dir: dir)
        await store.setCoverListing(lister, networkTimeout: .milliseconds(100))
        let queue = CoverQueue(listingLimit: 2, networkListingLimit: 1, retryDelay: .milliseconds(50))
        let made = FolderResults()
        let work: @Sendable (String) async -> Bool = { id in
            let network = id.hasPrefix("/net/")
            let location = ThumbnailLocation(volume: network ? "net:share" : "test", folder: id, name: "_")
            guard let images = await store.folderCover(URL(fileURLWithPath: id), archive: false, in: location,
                                                       maxPixel: 64) else { return false }
            made.add(id, images.count)
            return true
        }
        // The share's cards first, until its hung listings fill its lane.
        await queue.want(shares, visible: shares.count, isNetwork: { $0.hasPrefix("/net/") }, work: work)
        #expect(await eventually { store.coverThreads.count(CoverLane(network: true, resolving: false)) == ThumbnailStore.coverThreadsPerLane })
        let ids = shares + locals
        await queue.want(ids, visible: ids.count, isNetwork: { $0.hasPrefix("/net/") }, work: work)
        #expect(await eventually { locals.allSatisfy { made.count(of: $0) == 4 } })
        try? await Task.sleep(for: .milliseconds(200))   // a few retries of the share's cards
        #expect(shares.allSatisfy { made.count(of: $0) == nil })
        #expect(await queue.pendingCount >= shares.count - 1)   // one may be running its quick "not now"
        #expect(store.coverThreads.count(CoverLane(network: true, resolving: false)) == ThumbnailStore.coverThreadsPerLane)
        await queue.want([], visible: 0, isNetwork: { _ in false }) { _ in true }
        for _ in 0..<ThumbnailStore.coverThreadsPerLane { hang.signal() }
        #expect(await eventually { store.coverThreads.count(CoverLane(network: true, resolving: false)) == 0 })
    }

    /// Review fix: resolving the folder Home shows is limited like a share's listing: a resolve that hangs gives nil
    /// after the time limit, and its thread stays in the share lane until it returns.
    @Test func hungResolveTimesOut() async {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let hang = DispatchSemaphore(value: 0)
        let store = store(ThumbReader(), dir: dir, locate: { _ in
            hang.wait()
            return nil
        })
        await store.setCoverListing(ThumbnailStore.listCoverNames, networkTimeout: .milliseconds(100))
        await store.setCoverVolumes { $0.path.hasPrefix("/net/") }
        let start = ContinuousClock.now
        #expect(await store.folderLocation(URL(fileURLWithPath: "/net/share")) == .notNow)
        #expect(ContinuousClock.now - start < .seconds(3))   // the limit is 100 ms; the resolve hangs for good
        let lane = CoverLane(network: true, resolving: true)
        #expect(store.coverThreads.count(lane) == 1)
        hang.signal()
        #expect(await eventually { store.coverThreads.count(lane) == 0 })
    }

    /// Review fix: a cover asks the system nothing but its listing: the subfolders' locations come from the folder's.
    @Test func folderCoverNeverResolves() async {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader(), listing = FakeListing()
        listing.set("/p/top", folders: ["s1", "s2"])
        listing.set("/p/top/s1", files: ["a.jpg"])
        listing.set("/p/top/s2", files: ["b.jpg"])
        photos(reader, in: "/p/top/s1", ["a.jpg"])
        photos(reader, in: "/p/top/s2", ["b.jpg"])
        let resolved = LockedFlag()
        let store = store(reader, dir: dir, locate: { _ in
            resolved.set()
            return nil
        })
        await store.setCoverListing(listing.lister)
        #expect(await store.folderCover(URL(fileURLWithPath: "/p/top"), archive: false, in: loc("/p/top"), maxPixel: 64)?.count == 2)
        #expect(!resolved.isSet)
    }

    /// Review fix: a running cover makes no thumbnail while the viewer is busy, and goes on once it is idle.
    @Test func waitsWhileViewerBusy() async {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader(), listing = FakeListing()
        photos(reader, in: "/photos/f", ["1.jpg", "2.jpg"])
        listing.set("/photos/f", files: ["1.jpg", "2.jpg"])
        let store = store(reader, dir: dir)
        await store.setCoverListing(listing.lister)
        await store.setViewerActivity(.neighbours)
        let task = Task { await store.folderCover(URL(fileURLWithPath: "/photos/f"), archive: false, in: loc("/photos/f"), maxPixel: 64) }
        try? await Task.sleep(for: .milliseconds(200))
        #expect(reader.reads.isEmpty)
        await store.setViewerActivity(.idle)
        #expect(await task.value?.count == 2)
    }

    /// Fix round 2: a share's resolves and listings that hang fill their own lanes; a local folder still resolves
    /// (as local) and its covers are made.
    @Test func hungShareLeavesLocalResolvesAlone() async {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader()
        let hang = DispatchSemaphore(value: 0)
        photos(reader, in: "/loc/shown/a", ["1.jpg", "2.jpg"])
        let store = store(reader, dir: dir, locate: { url in
            if url.path.hasPrefix("/net/") { hang.wait() }
            return ThumbnailLocation(volume: "test", folder: url.deletingLastPathComponent().path, name: url.lastPathComponent)
        })
        let lister: ThumbnailStore.CoverLister = { folder, _, _ in
            if folder.path.hasPrefix("/net/") { hang.wait() }
            return CoverNames(files: ["1.jpg", "2.jpg"], folders: [])
        }
        await store.setCoverListing(lister, networkTimeout: .milliseconds(50))
        await store.setCoverVolumes { $0.path.hasPrefix("/net/") }
        let lanes = [true, false].map { CoverLane(network: true, resolving: $0) }
        for i in 0..<ThumbnailStore.coverThreadsPerLane {
            #expect(await store.folderLocation(URL(fileURLWithPath: "/net/s\(i)")) == .notNow)
            let share = ThumbnailLocation(volume: "net:share", folder: "/net/f\(i)", name: "_")
            #expect(await store.folderCover(URL(fileURLWithPath: "/net/f\(i)"), archive: false, in: share, maxPixel: 64) == nil)
        }
        #expect(lanes.allSatisfy { store.coverThreads.count($0) == ThumbnailStore.coverThreadsPerLane })
        guard case .located(let shown) = await store.folderLocation(URL(fileURLWithPath: "/loc/shown")) else {
            Issue.record("the local folder did not resolve")
            return
        }
        #expect(!shown.isNetwork)
        let images = await store.folderCover(URL(fileURLWithPath: "/loc/shown/a"), archive: false,
                                             in: shown.subfolder("a"), maxPixel: 64)
        #expect(images?.count == 2)
        for _ in 0..<(2 * ThumbnailStore.coverThreadsPerLane) { hang.signal() }
        #expect(await eventually { lanes.allSatisfy { store.coverThreads.count($0) == 0 } })
    }

    /// Fix round 2: a share alive but too slow to give a name in time is given up after three tries (empty for the
    /// session), not listed again and again.
    @Test func slowShareGivenUpAfterThreeTimeouts() async {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let calls = TryCounter()
        // Alive, but nothing before the limit: each listing waits at the gate, opened only once its cover has given
        // up on it, so what it then hands to `part` comes after the stop however late its thread runs.
        let gate = DispatchSemaphore(value: 0)
        let silent: ThumbnailStore.CoverLister = { _, _, part in
            calls.add()
            gate.wait()
            #expect(!part(CoverNames(files: ["late.jpg"], folders: [])))
            throw CancellationError()
        }
        let store = store(ThumbReader(), dir: dir)
        await store.setCoverListing(silent, networkTimeout: .milliseconds(50))
        let folder = URL(fileURLWithPath: "/net/slow"), share = loc("/net/slow", network: true)
        #expect(await store.folderCover(folder, archive: false, in: share, maxPixel: 64) == nil)
        gate.signal()
        #expect(await store.folderCover(folder, archive: false, in: share, maxPixel: 64) == nil)
        gate.signal()
        #expect(await store.folderCover(folder, archive: false, in: share, maxPixel: 64) == [])
        gate.signal()
        #expect(await store.folderCover(folder, archive: false, in: share, maxPixel: 64) == [])
        // The listings' threads may start late on a loaded machine (that, too, is a time out): three in all, no more.
        #expect(await eventually { calls.count == 3 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(calls.count == 3)
    }

    /// Task 4: the folder Home shows resolves once, as it is.
    @Test func shownFolderResolves() async {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let store = store(ThumbReader(), dir: dir)
        await store.setCoverVolumes { _ in false }
        #expect(await store.shownFolderPlace(URL(fileURLWithPath: "/loc/shown")) == .located(loc("/loc/shown")))
    }

    /// Task 4: a local folder whose resolve hangs (a symlink into a hung share) is asked three times, then goes on as
    /// a share without the catalog: it does not keep the local resolving lane's threads for good.
    @Test func shownLocalFolderGivesUpAfterThreeTries() async {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let hang = DispatchSemaphore(value: 0), calls = TryCounter()
        let store = store(ThumbReader(), dir: dir, locate: { _ in
            calls.add()
            hang.wait()
            return nil
        })
        await store.setCoverListing(ThumbnailStore.listCoverNames, localTimeout: .milliseconds(50))
        await store.setCoverVolumes { _ in false }
        let place = await store.shownFolderPlace(URL(fileURLWithPath: "/loc/link"), retry: .milliseconds(10))
        #expect(place == .unknown(network: true))
        // The threads may start late on a loaded machine: three in all, no more.
        #expect(await eventually { calls.count == ThumbnailStore.coverLocalResolveTries })
        for _ in 0..<ThumbnailStore.coverLocalResolveTries { hang.signal() }
        let lane = CoverLane(network: false, resolving: true)
        #expect(await eventually { store.coverThreads.count(lane) == 0 })
        #expect(calls.count == ThumbnailStore.coverLocalResolveTries)
    }

    /// Task 4: a share is asked again for as long as its folder is shown, and its place found once it answers.
    @Test func shownShareKeepsAsking() async {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let calls = TryCounter(), slow = ThumbnailStore.coverLocalResolveTries + 1
        let store = store(ThumbReader(), dir: dir, locate: { url in
            calls.add()
            if calls.count <= slow { usleep(100_000) }   // past the limit, then back: its thread frees its place
            return ThumbnailLocation(volume: "net:share", folder: url.deletingLastPathComponent().path, name: "_")
        })
        await store.setCoverListing(ThumbnailStore.listCoverNames, networkTimeout: .milliseconds(20))
        await store.setCoverVolumes { _ in true }
        let place = await store.shownFolderPlace(URL(fileURLWithPath: "/net/f"), retry: .milliseconds(50))
        #expect(place == .located(loc("/net/f", network: true)))
        #expect(calls.count > slow)
    }

    /// Task 4: a cancelled resolve (Home left the folder) ends at once, "not now".
    @Test func shownFolderResolveCancelled() async {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let hang = DispatchSemaphore(value: 0)
        let store = store(ThumbReader(), dir: dir, locate: { _ in
            hang.wait()
            return nil
        })
        await store.setCoverVolumes { _ in true }
        let task = Task { await store.shownFolderPlace(URL(fileURLWithPath: "/net/f"), retry: .milliseconds(10)) }
        try? await Task.sleep(for: .milliseconds(50))
        let start = ContinuousClock.now
        task.cancel()
        #expect(await task.value == .notNow)
        #expect(ContinuousClock.now - start < .seconds(1))
        hang.signal()
    }

    /// Review fix: a local folder whose resolving lane is full of another folder's hung resolves is not timed out
    /// three times for it: it goes on as a local folder without the catalog, on its own volume's terms.
    @Test func shownLocalFolderBusyLaneGoesOnLocally() async {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let hang = DispatchSemaphore(value: 0), calls = TryCounter()
        let store = store(ThumbReader(), dir: dir, locate: { url in
            if url.path.hasPrefix("/loc/hung") { hang.wait() } else { calls.add() }
            return ThumbnailLocation(volume: "test", folder: url.deletingLastPathComponent().path, name: "_")
        })
        await store.setCoverListing(ThumbnailStore.listCoverNames, localTimeout: .milliseconds(30))
        await store.setCoverVolumes { _ in false }
        let lane = CoverLane(network: false, resolving: true)
        for i in 0..<ThumbnailStore.coverThreadsPerLane {
            #expect(await store.folderLocation(URL(fileURLWithPath: "/loc/hung\(i)")) == .notNow)
        }
        #expect(store.coverThreads.count(lane) == ThumbnailStore.coverThreadsPerLane)
        let place = await store.shownFolderPlace(URL(fileURLWithPath: "/loc/ok"), retry: .milliseconds(10))
        #expect(place == .unknown(network: false))
        #expect(calls.count == 0)   // never got a thread: busy each time, not timed out
        for _ in 0..<ThumbnailStore.coverThreadsPerLane { hang.signal() }
        #expect(await eventually { store.coverThreads.count(lane) == 0 })
        // The lane free again: it resolves.
        #expect(await store.shownFolderPlace(URL(fileURLWithPath: "/loc/ok")) == .located(loc("/loc/ok")))
    }

    /// Review fix (spec: a return is instant): a folder with fewer photos than a cover takes is listed once a
    /// session; its next cover comes from the pick remembered and the catalog's thumbnails.
    @Test func smallFolderListedOnce() async {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader(), listing = FakeListing()
        photos(reader, in: "/p/two", ["1.jpg", "2.jpg"])
        listing.set("/p/two", files: ["1.jpg", "2.jpg"])
        let store = store(reader, dir: dir)
        await store.setCoverListing(listing.lister)
        let folder = URL(fileURLWithPath: "/p/two")
        #expect(await store.folderCover(folder, archive: false, in: loc("/p/two"), maxPixel: 64)?.count == 2)
        #expect(listing.calls == ["/p/two"])
        let reads = reader.reads.count
        #expect(await store.folderCover(folder, archive: false, in: loc("/p/two"), maxPixel: 64)?.count == 2)
        #expect(listing.calls == ["/p/two"])
        #expect(reader.reads.count == reads)
    }

    /// Review fix: a folder of folders is listed once a session too; its subfolders' pictures come from the catalog.
    @Test func containerFolderListedOnce() async {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader(), listing = FakeListing()
        listing.set("/p/box", folders: ["s1", "s2"])
        listing.set("/p/box/s1", files: ["a.jpg"])
        listing.set("/p/box/s2", files: ["b.jpg"])
        photos(reader, in: "/p/box/s1", ["a.jpg"])
        photos(reader, in: "/p/box/s2", ["b.jpg"])
        let store = store(reader, dir: dir)
        await store.setCoverListing(listing.lister)
        let folder = URL(fileURLWithPath: "/p/box")
        #expect(await store.folderCover(folder, archive: false, in: loc("/p/box"), maxPixel: 64)?.count == 2)
        let listed = listing.calls.count
        #expect(await store.folderCover(folder, archive: false, in: loc("/p/box"), maxPixel: 64)?.count == 2)
        #expect(listing.calls.count == listed)
    }

    /// Review fix: a pick remembered for another last-viewed photo is not used: the folder is listed again, so the
    /// photo last viewed leads.
    @Test func rememberedPickForAnotherLastViewedListsAgain() async {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader(), listing = FakeListing()
        photos(reader, in: "/p/two", ["1.jpg", "2.jpg"])
        listing.set("/p/two", files: ["1.jpg", "2.jpg"])
        let store = store(reader, dir: dir)
        await store.setCoverListing(listing.lister)
        let folder = URL(fileURLWithPath: "/p/two")
        #expect(await store.folderCover(folder, archive: false, in: loc("/p/two"), maxPixel: 64)?.count == 2)
        // Another photo last viewed: the remembered pick was made without it.
        #expect(await store.folderCover(folder, archive: false, in: loc("/p/two"), maxPixel: 64, lastViewed: "2.jpg")?.count == 2)
        #expect(listing.calls == ["/p/two", "/p/two"])
    }

    /// Fix round 2: a local disk that hangs is limited too (generously): its cover is "not now" after the local time
    /// limit, so it gives the local lane's queue place back.
    @Test func hungLocalDiskTimesOut() async {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let hang = DispatchSemaphore(value: 0)
        let store = store(ThumbReader(), dir: dir)
        await store.setCoverListing({ _, _, _ in
            hang.wait()
            return CoverNames(files: [], folders: [])
        }, localTimeout: .milliseconds(100))
        let start = ContinuousClock.now
        #expect(await store.folderCover(URL(fileURLWithPath: "/usb/f"), archive: false, in: loc("/usb/f"), maxPixel: 64) == nil)
        #expect(ContinuousClock.now - start < .seconds(2))
        let lane = CoverLane(network: false, resolving: false)
        #expect(store.coverThreads.count(lane) == 1)
        hang.signal()
        #expect(await eventually { store.coverThreads.count(lane) == 0 })
    }

    /// A folder that cannot be listed is empty for the session: not listed again.
    @Test func unlistableSettled() async {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let calls = TryCounter()
        let store = store(ThumbReader(), dir: dir)
        await store.setCoverListing { _, _, _ in
            calls.add()
            throw CocoaError(.fileReadNoPermission)
        }
        #expect(await store.folderCover(URL(fileURLWithPath: "/p/locked"), archive: false, in: loc("/p/locked"), maxPixel: 64) == [])
        #expect(await store.folderCover(URL(fileURLWithPath: "/p/locked"), archive: false, in: loc("/p/locked"), maxPixel: 64) == [])
        #expect(calls.count == 1)
    }

    /// A folder found empty is looked at again when its modification date changed (filled in the Finder).
    @Test func emptyMemoFollowsTheFolderDate() async {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader(), listing = FakeListing()
        let store = store(reader, dir: dir)
        await store.setCoverListing(listing.lister)
        let folder = URL(fileURLWithPath: "/p/fill")
        let before = Date(timeIntervalSinceReferenceDate: 1000), after = Date(timeIntervalSinceReferenceDate: 2000)
        listing.set("/p/fill", files: [])
        #expect(await store.folderCover(folder, archive: false, in: loc("/p/fill"), maxPixel: 64, modified: before) == [])
        #expect(await store.folderCover(folder, archive: false, in: loc("/p/fill"), maxPixel: 64, modified: before) == [])
        #expect(listing.calls.count == 1)               // same date: not listed again
        photos(reader, in: "/p/fill", ["1.jpg", "2.jpg"])
        listing.set("/p/fill", files: ["1.jpg", "2.jpg"])
        #expect(await store.folderCover(folder, archive: false, in: loc("/p/fill"), maxPixel: 64, modified: after)?.count == 2)
    }

    /// A pick remembered is dropped when the folder's date changed (emptied or changed in the Finder).
    @Test func pickMemoFollowsTheFolderDate() async {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader(), listing = FakeListing()
        photos(reader, in: "/p/two", ["1.jpg", "2.jpg"])
        listing.set("/p/two", files: ["1.jpg", "2.jpg"])
        let store = store(reader, dir: dir)
        await store.setCoverListing(listing.lister)
        let folder = URL(fileURLWithPath: "/p/two")
        let before = Date(timeIntervalSinceReferenceDate: 1000), after = Date(timeIntervalSinceReferenceDate: 2000)
        #expect(await store.folderCover(folder, archive: false, in: loc("/p/two"), maxPixel: 64, modified: before)?.count == 2)
        #expect(await store.folderCover(folder, archive: false, in: loc("/p/two"), maxPixel: 64, modified: before)?.count == 2)
        #expect(listing.calls == ["/p/two"])            // same date: from the pick
        #expect(await store.folderCover(folder, archive: false, in: loc("/p/two"), maxPixel: 64, modified: after)?.count == 2)
        #expect(listing.calls == ["/p/two", "/p/two"])  // another date: listed again
    }

    /// The mount table says where a path is without asking its file system: the boot volume is local.
    @Test func mountTableKnowsLocal() {
        #expect(!ThumbnailStore.mountIsNetwork(URL(fileURLWithPath: "/")))
        #expect(!ThumbnailStore.mountIsNetwork(fm.temporaryDirectory))
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
        #expect(await store.folderCover(URL(fileURLWithPath: "/photos/f"), archive: false, in: loc("/photos/f"), maxPixel: 64)?.count == 3)
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
        let task = Task { await store.folderCover(URL(fileURLWithPath: "/photos/f"), archive: false, in: loc("/photos/f"), maxPixel: 64) }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        #expect(await task.value?.isEmpty != false)
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
        let images = await store.folderCover(URL(fileURLWithPath: "/photos/top"), archive: false, in: loc("/photos/top"), maxPixel: 64)
        #expect(images?.count == 4)
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
        #expect(await store.folderCover(URL(fileURLWithPath: "/p/two"), archive: false, in: loc("/p/two"), maxPixel: 64)?.count == 1)
        #expect(await store.folderCover(URL(fileURLWithPath: "/p/three"), archive: false, in: loc("/p/three"), maxPixel: 64) == [])
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
        #expect(await store.folderCover(URL(fileURLWithPath: "/photos/videos"), archive: false, in: loc("/photos/videos"), maxPixel: 64) == [])
        #expect(await store.folderCover(URL(fileURLWithPath: "/photos/videos"), archive: false, in: loc("/photos/videos"), maxPixel: 64) == [])
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
        #expect(await store.folderCover(URL(fileURLWithPath: "/photos/g.zip"), archive: true, in: loc("/photos/g.zip"), maxPixel: 64)?.count == 2)
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

/// Calls counted from other threads.
final class TryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func add() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

/// Pictures per folder, from other tasks.
final class FolderResults: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func add(_ folder: String, _ count: Int) { lock.withLock { counts[folder] = count } }
    func count(of folder: String) -> Int? { lock.withLock { counts[folder] } }
}

/// A flag set from another thread.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
