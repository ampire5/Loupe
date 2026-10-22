import CoreGraphics
import Foundation
import HomeScreenModel
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

    /// Review Focus 4: a folder whose four samples the catalog has is not listed again, and no file is read (folder
    /// cards: while its summary is fresh, i.e. made at the date its parent's listing gives).
    @Test func catalogFirst() async {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader(), listing = FakeListing()
        let names = (1...6).map { "\($0).jpg" }
        photos(reader, in: "/photos/f", names)
        listing.set("/photos/f", files: names)
        let first = store(reader, dir: dir)
        await first.setCoverListing(listing.lister)
        let modified = Date(timeIntervalSinceReferenceDate: 1000)
        #expect(await first.folderCover(URL(fileURLWithPath: "/photos/f"), archive: false, in: loc("/photos/f"), maxPixel: 64,
                                        modified: modified)?.count == 4)
        await first.commit()
        let reads = reader.reads.count
        let again = store(reader, dir: dir)   // next session
        await again.setCoverListing(listing.lister)
        #expect(await again.folderCover(URL(fileURLWithPath: "/photos/f"), archive: false, in: loc("/photos/f"), maxPixel: 64,
                                        modified: modified)?.count == 4)
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
        // Three seconds: under a loaded test run (every suite in parallel on an 8-core Intel Mac) the listing's utility
        // thread started more than a second late and gave no name in time.
        await store.setCoverListing(slow, networkTimeout: .seconds(3))
        let start = ContinuousClock.now
        let images = await store.folderCover(URL(fileURLWithPath: "/photos/f"), archive: false,
                                             in: loc("/photos/f", network: true), maxPixel: 64)
        #expect(ContinuousClock.now - start < .seconds(8))   // the listing goes on for 10
        #expect(images?.count == 2)
        #expect(await eventually { stopped.isSet })
    }

    /// Review fix: the catalog's four are a spread too, the photo last viewed first, sorted as Finder does; the folder is
    /// not listed (its summary fresh).
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
        let folder = URL(fileURLWithPath: "/photos/f"), modified = Date(timeIntervalSinceReferenceDate: 1000)
        await store.putFolderSummaries([(loc("/photos/f"), FolderSummary(photos: 10, folders: 0, folderModified: modified))])
        let plain = await store.folderCover(folder, archive: false, in: loc("/photos/f"), maxPixel: 64,
                                            modified: modified) ?? []
        #expect(plain.map { byHeight[$0.height] } == ["01.jpg", "04.jpg", "07.jpg", "10.jpg"])
        let last = await store.folderCover(folder, archive: false, in: loc("/photos/f"), maxPixel: 64,
                                           lastViewed: "05.jpg", modified: modified) ?? []
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

    /// Review fix: a running cover makes no thumbnail while the viewer is busy, and goes on once it is idle; the
    /// store's queue starts no card meanwhile. `.current` is also what a two-page pair reports while its other page
    /// reads (`ImageCache.isCurrent`).
    @Test(arguments: [CacheActivity.neighbours, .current])
    func waitsWhileViewerBusy(_ busy: CacheActivity) async {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader(), listing = FakeListing()
        photos(reader, in: "/photos/f", ["1.jpg", "2.jpg"])
        listing.set("/photos/f", files: ["1.jpg", "2.jpg"])
        let store = store(reader, dir: dir)
        await store.setCoverListing(listing.lister)
        await store.setViewerActivity(busy)
        let queued = LockedFlag()
        await store.coverQueue.want(["/photos/g"], visible: 1, isNetwork: { _ in false }) { _ in
            queued.set()
            return true
        }
        let task = Task { await store.folderCover(URL(fileURLWithPath: "/photos/f"), archive: false, in: loc("/photos/f"), maxPixel: 64) }
        try? await Task.sleep(for: .milliseconds(200))
        #expect(reader.reads.isEmpty)
        #expect(!queued.isSet)
        await store.setViewerActivity(.idle)
        #expect(await task.value?.count == 2)
        #expect(await eventually { queued.isSet })
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

    /// Task 4: a share is asked again for as long as its folder is shown, and its place found once it answers. The
    /// first two asks hang until the end (a gate, not a sleep: a stalled CI machine cannot let one answer before its
    /// time limit), so the place can only come from a later ask; then the hung threads give their places back.
    @Test func shownShareKeepsAsking() async {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let gate = DispatchSemaphore(value: 0), calls = TryCounter(), hung = 2
        let store = store(ThumbReader(), dir: dir, locate: { url in
            calls.add()
            if calls.count <= hung { gate.wait() }
            return ThumbnailLocation(volume: "net:share", folder: url.deletingLastPathComponent().path, name: "_")
        })
        await store.setCoverListing(ThumbnailStore.listCoverNames, networkTimeout: .milliseconds(20))
        await store.setCoverVolumes { _ in true }
        let place = await store.shownFolderPlace(URL(fileURLWithPath: "/net/f"), retry: .milliseconds(10))
        #expect(place == .located(loc("/net/f", network: true)))
        #expect(calls.count > hung)   // only an ask past the hung ones can answer (a loaded machine may time out more)
        for _ in 0..<hung { gate.signal() }
        let lane = CoverLane(network: true, resolving: true)
        #expect(await eventually { store.coverThreads.count(lane) == 0 })
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
        let started = LockedFlag(), stopped = LockedFlag()
        let hung: ThumbnailStore.CoverLister = { _, _, part in
            started.set()
            while part(CoverNames(files: [], folders: [])) { usleep(10_000) }
            stopped.set()
            throw CancellationError()
        }
        let store = store(reader, dir: dir)
        await store.setCoverListing(hung)
        let task = Task { await store.folderCover(URL(fileURLWithPath: "/photos/f"), archive: false, in: loc("/photos/f"), maxPixel: 64) }
        // Cancelled once its listing runs (a loaded machine may open the catalog first for longer than any sleep).
        #expect(await eventually { started.isSet })
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
    func reset() { lock.withLock { value = false } }
    var isSet: Bool { lock.withLock { value } }
}

/// A dated listing by folder path (folder cards spec, "Сводка папки"): names with dates and sizes on a local volume
/// (`dated`), names only on a share, and which folders it was asked for and how.
private final class FakeDatedListing: @unchecked Sendable {
    struct File { let name: String; let date: Date; let size: Int }
    private let lock = NSLock()
    private var files: [String: [File]] = [:]
    private var folders: [String: [String]] = [:]
    private var asked: [(path: String, dated: Bool)] = []

    func set(_ folder: String, files: [File] = [], folders: [String] = []) {
        lock.withLock {
            self.files[folder] = files
            self.folders[folder] = folders
        }
    }

    var calls: [String] { lock.withLock { asked.map(\.path) } }
    var datedFlags: [Bool] { lock.withLock { asked.map(\.dated) } }

    var lister: ThumbnailStore.DatedCoverLister {
        { folder, _, dated, _ in
            self.lock.withLock {
                self.asked.append((folder.path, dated))
                let files = self.files[folder.path] ?? [], folders = self.folders[folder.path] ?? []
                guard dated else {
                    return CoverListing(names: CoverNames(files: files.map(\.name), folders: folders))
                }
                let entries = files.map {
                    BrowserEntry(url: folder.appendingPathComponent($0.name), name: $0.name, kind: .file, date: $0.date,
                                 size: Int64($0.size))
                } + folders.map {
                    BrowserEntry(url: folder.appendingPathComponent($0, isDirectory: true), name: $0, kind: .folder)
                }
                return CoverListing(listing: entries, dated: true)
            }
        }
    }
}

/// Task 6 of the folder cards: the cover queue's task brings the folder's summary too, from a listing with dates on a
/// local volume and names only on a share, kept in the catalog; a stored summary still fresh and the four thumbnails
/// in the catalog make the card without a listing; a broken zip and a share that does not answer are told.
@Suite struct FolderCardTests {
    private let fm = FileManager.default

    private func tempDir() -> URL { fm.temporaryDirectory.appendingPathComponent("loupe-folder-card-\(UUID().uuidString)") }

    private func store(_ reader: ThumbReader, dir: URL) -> ThumbnailStore {
        ThumbnailStore(directory: dir, reader: reader, thumbSize: 32, limitBytes: 1 << 30,
                       locate: { url in
                           ThumbnailLocation(volume: url.path.hasPrefix("/net/") ? "net:share" : "test",
                                             folder: url.deletingLastPathComponent().path, name: url.lastPathComponent)
                       }, idleDelay: .zero, commitDelay: .seconds(3600))
    }

    private func loc(_ folder: String, network: Bool = false) -> ThumbnailLocation {
        ThumbnailLocation(volume: network ? "net:share" : "test", folder: folder, name: "_")
    }

    private func photos(_ reader: ThumbReader, in folder: String, _ names: [String]) {
        for name in names {
            reader.add(URL(fileURLWithPath: folder).appendingPathComponent(name), TestJPEGs.gradient(width: 40, height: 30))
        }
    }

    private static func day(_ n: Double) -> Date { Date(timeIntervalSinceReferenceDate: 700_000_000 + n * 86_400) }

    /// On a local volume the real listing has each photo's date and size: the summary has the span, the bytes and the
    /// histogram, the card the photos' dates, and the catalog keeps the summary.
    @Test func localListingCarriesDates() async throws {
        let dir = tempDir(), folder = tempDir()
        defer {
            try? fm.removeItem(at: dir)
            try? fm.removeItem(at: folder)
        }
        try fm.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let reader = ThumbReader()
        let files = [("a.jpg", 1.0, 10), ("b.jpg", 5.0, 20), ("c.jpg", 9.0, 30)]
        for (name, day, size) in files {
            let url = folder.appendingPathComponent(name)
            try Data(repeating: 1, count: size).write(to: url)
            try fm.setAttributes([.modificationDate: Self.day(day)], ofItemAtPath: url.path)
            reader.add(url, TestJPEGs.gradient(width: 40, height: 30))
        }
        try Data([1]).write(to: folder.appendingPathComponent("notes.txt"))
        let store = store(reader, dir: dir)
        let modified = Self.day(10)
        let card = try #require(await store.folderCard(folder, archive: false, in: loc(folder.path), maxPixel: 64,
                                                       modified: modified))
        #expect(card.images.count == 3)
        #expect(card.problem == nil)
        let summary = try #require(card.summary)
        #expect(summary.photos == 3)
        #expect(summary.folders == 1)
        #expect(summary.bytes == 60)
        #expect(summary.first == Self.day(1))
        #expect(summary.last == Self.day(9))
        #expect(summary.histogram.count == FolderSummary.histogramBins)
        #expect(summary.datesKnown)
        #expect(summary.folderModified == modified)
        #expect(card.photoDates?.sorted() == [Self.day(1), Self.day(5), Self.day(9)])
        #expect(await store.folderSummary(at: loc(folder.path)) == summary)
        // In one batch with the store's next commit: a new session reads it from the catalog.
        await store.commit()
        let next = try ThumbnailDatabase(directory: dir, thumbSize: 32)
        #expect(try next.summary(at: loc(folder.path)) == summary)
    }

    /// On a share the listing stays names only: counts, no dates or size; the cover as before. A summary kept from an
    /// earlier visit with dates keeps its dates and size.
    @Test func shareListsNamesOnly() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader(), listing = FakeDatedListing()
        let names = (1...10).map { String(format: "%02d.jpg", $0) }
        photos(reader, in: "/net/f", names)
        listing.set("/net/f", files: names.map { .init(name: $0, date: Self.day(1), size: 100) }, folders: ["sub"])
        let store = store(reader, dir: dir)
        await store.setCoverListing(dated: listing.lister)
        await store.setCoverVolumes { _ in true }
        let card = try #require(await store.folderCard(URL(fileURLWithPath: "/net/f"), archive: false,
                                                       in: loc("/net/f", network: true), maxPixel: 64,
                                                       modified: Self.day(2)))
        #expect(listing.datedFlags == [false])
        #expect(card.images.count == 4)
        #expect(Set(reader.reads.map(\.lastPathComponent)) == ["01.jpg", "04.jpg", "07.jpg", "10.jpg"])
        let summary = try #require(card.summary)
        #expect(summary.photos == 10 && summary.folders == 1)
        #expect(!summary.datesKnown)
        #expect(summary.bytes == nil && summary.first == nil && summary.histogram.isEmpty)
        #expect(card.photoDates == nil)

        // The folder was opened once (its full listing has dates): a later names-only count keeps them.
        let visited = FolderSummary(photos: 9, folders: 1, bytes: 900, first: Self.day(0), last: Self.day(1),
                                    histogram: [255] + Array(repeating: 0, count: 11), folderModified: Self.day(1),
                                    datesKnown: true)
        listing.set("/net/g", files: names.map { .init(name: $0, date: Self.day(1), size: 100) })
        photos(reader, in: "/net/g", names)
        await store.putFolderSummaries([(loc("/net/g", network: true), visited)])
        let again = try #require(await store.folderCard(URL(fileURLWithPath: "/net/g"), archive: false,
                                                        in: loc("/net/g", network: true), maxPixel: 64,
                                                        modified: Self.day(3)))
        #expect(listing.datedFlags == [false, false])
        let kept = try #require(again.summary)
        #expect(kept.photos == 10)
        #expect(kept.datesKnown && kept.bytes == 900 && kept.first == Self.day(0) && kept.last == Self.day(1))
        #expect(kept.folderModified == Self.day(3))
    }

    /// A summary whose folder date is still the listing's and the four thumbnails in the catalog: the next session's
    /// card is made without a listing.
    @Test func freshSummarySkipsListing() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader(), listing = FakeDatedListing()
        let names = (1...6).map { "\($0).jpg" }
        photos(reader, in: "/photos/f", names)
        listing.set("/photos/f", files: names.map { .init(name: $0, date: Self.day(1), size: 10) })
        let first = store(reader, dir: dir)
        await first.setCoverListing(dated: listing.lister)
        let folder = URL(fileURLWithPath: "/photos/f"), modified = Self.day(2)
        let made = try #require(await first.folderCard(folder, archive: false, in: loc("/photos/f"), maxPixel: 64,
                                                       modified: modified))
        #expect(made.images.count == 4 && made.summary?.photos == 6)
        await first.commit()
        #expect(listing.calls == ["/photos/f"])
        let reads = reader.reads.count
        let next = store(reader, dir: dir)   // next session
        await next.setCoverListing(dated: listing.lister)
        let card = try #require(await next.folderCard(folder, archive: false, in: loc("/photos/f"), maxPixel: 64,
                                                      modified: modified))
        #expect(listing.calls == ["/photos/f"])
        #expect(reader.reads.count == reads)
        #expect(card.images.count == 4)
        #expect(card.summary == made.summary)
        #expect(card.photoDates == nil)   // from the catalog: no listing's dates
    }

    /// A folder whose date moved past its summary's is listed again, even with four thumbnails in the catalog, and
    /// its new summary goes to the catalog.
    @Test func changedFolderIsRecounted() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader(), listing = FakeDatedListing()
        let names = (1...6).map { "\($0).jpg" }
        photos(reader, in: "/photos/f", names + ["7.jpg"])
        listing.set("/photos/f", files: names.map { .init(name: $0, date: Self.day(1), size: 10) })
        let store = store(reader, dir: dir)
        await store.setCoverListing(dated: listing.lister)
        let folder = URL(fileURLWithPath: "/photos/f")
        _ = await store.folderCard(folder, archive: false, in: loc("/photos/f"), maxPixel: 64, modified: Self.day(2))
        // Another session: the catalog has the four thumbnails and a summary of the older folder.
        await store.commit()
        let next = self.store(reader, dir: dir)
        await next.setCoverListing(dated: listing.lister)
        listing.set("/photos/f", files: (names + ["7.jpg"]).map { .init(name: $0, date: Self.day(3), size: 10) })
        // The pictures from the catalog at once, with the older summary; the count follows on the next call.
        let first = try #require(await next.folderCard(folder, archive: false, in: loc("/photos/f"), maxPixel: 64,
                                                       modified: Self.day(4)))
        #expect(first.summaryPending && first.images.count == 4 && first.summary?.photos == 6)
        #expect(listing.calls == ["/photos/f"])
        let card = try #require(await next.folderCard(folder, archive: false, in: loc("/photos/f"), maxPixel: 64,
                                                      modified: Self.day(4)))
        #expect(!card.summaryPending)
        #expect(listing.calls == ["/photos/f", "/photos/f"])
        #expect(card.images.count == 4)
        #expect(card.summary?.photos == 7)
        #expect(card.summary?.folderModified == Self.day(4))
        #expect(card.photoDates?.count == 7)
        #expect(await next.folderSummary(at: loc("/photos/f"))?.photos == 7)
    }

    /// A zip whose directory cannot be read: the card says it is broken (and is not dimmed for it), once a session.
    @Test func brokenZip() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let calls = TryCounter()
        let store = store(ThumbReader(), dir: dir)
        await store.setCoverListing(dated: { _, _, _, _ in
            calls.add()
            throw ArchiveError.damaged
        })
        let zip = URL(fileURLWithPath: "/photos/bad.zip")
        let card = try #require(await store.folderCard(zip, archive: true, in: loc("/photos/bad.zip"), maxPixel: 64,
                                                       modified: Self.day(1)))
        #expect(card.problem == .broken)
        #expect(card.images.isEmpty)
        let again = try #require(await store.folderCard(zip, archive: true, in: loc("/photos/bad.zip"), maxPixel: 64,
                                                        modified: Self.day(1)))
        #expect(again.problem == .broken)
        #expect(calls.count == 1)
    }

    /// A zip read whole: its photo count, the archive's size and date, no histogram.
    @Test func zipSummaryFromItsDirectory() async throws {
        let folder = tempDir(), dir = tempDir()
        defer {
            try? fm.removeItem(at: folder)
            try? fm.removeItem(at: dir)
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let zip = try ZipFixture.write(ZipFixture.make([.init(name: "caps/1.jpg", data: Data([1])),
                                                        .init(name: "caps/2.jpg", data: Data([1])),
                                                        .init(name: "readme.txt", data: Data([1]))]), in: folder)
        let listing = try ThumbnailStore.listCover(zip, archive: true, dated: false, part: { _ in true })
        let size = try #require(try zip.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(Set(listing.names.files) == ["caps\u{2215}1.jpg", "caps\u{2215}2.jpg"])
        #expect(listing.summary?.photos == 2)
        #expect(listing.summary?.bytes == Int64(size))
        #expect(listing.summary?.histogram.isEmpty == true)
        #expect(listing.summary?.datesKnown == true)
    }

    /// A share whose cover listing gave no name in time twice in a row is offline; a listing that answers clears it.
    @Test func offlineAfterTwoTimeouts() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader(), calls = TryCounter()
        photos(reader, in: "/net/slow", ["1.jpg", "2.jpg"])
        // The first two listings wait at the gate, opened only once their covers gave up on them.
        let gate = DispatchSemaphore(value: 0)
        let store = store(reader, dir: dir)
        let lister: ThumbnailStore.DatedCoverLister = { _, _, _, part in
            calls.add()
            if calls.count <= 2 {
                gate.wait()
                _ = part(CoverListing(names: CoverNames(files: ["late.jpg"], folders: [])))
                throw CancellationError()
            }
            return CoverListing(names: CoverNames(files: ["1.jpg", "2.jpg"], folders: []))
        }
        await store.setCoverListing(dated: lister, networkTimeout: .milliseconds(50))
        await store.setCoverVolumes { _ in true }
        let folder = URL(fileURLWithPath: "/net/slow"), share = loc("/net/slow", network: true)
        #expect(await store.folderCard(folder, archive: false, in: share, maxPixel: 64) == nil)   // not now
        let offline = try #require(await store.folderCard(folder, archive: false, in: share, maxPixel: 64))
        #expect(offline.problem == .offline)
        #expect(offline.images.isEmpty)
        // The share answers: a time limit no loaded machine's late thread runs out of, once both hung listings are in.
        #expect(await eventually { calls.count == 2 })
        await store.setCoverListing(dated: lister, networkTimeout: .seconds(30))
        let back = try #require(await store.folderCard(folder, archive: false, in: share, maxPixel: 64))
        #expect(back.problem == nil)
        #expect(back.images.count == 2)
        gate.signal()
        gate.signal()
        #expect(await eventually { store.coverThreads.count(CoverLane(network: true, resolving: false)) == 0 })
    }

    /// A share folder whose volume is gone (the mount table no longer puts it on a share): offline.
    @Test func unmountedShareIsOffline() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let store = store(ThumbReader(), dir: dir)
        // Answers at once; a generous limit, as a loaded machine may start the utility thread late.
        await store.setCoverListing(dated: { _, _, _, _ in throw CocoaError(.fileNoSuchFile) },
                                    networkTimeout: .seconds(30))
        await store.setCoverVolumes { _ in false }
        let card = try #require(await store.folderCard(URL(fileURLWithPath: "/net/gone"), archive: false,
                                                       in: loc("/net/gone", network: true), maxPixel: 64))
        #expect(card.problem == .offline)
        // A local folder that cannot be listed is just empty.
        let local = try #require(await store.folderCard(URL(fileURLWithPath: "/p/locked"), archive: false,
                                                        in: loc("/p/locked"), maxPixel: 64))
        #expect(local.problem == nil)
    }

    /// The open folder's full listing (`BrowserListingSource.full`, with stat) gives its summary, kept in the catalog
    /// with the folder's own date: a share's folder gets its dates once visited.
    @Test func openFolderWritesItsSummary() async throws {
        let dir = tempDir(), folder = tempDir()
        defer {
            try? fm.removeItem(at: dir)
            try? fm.removeItem(at: folder)
        }
        try fm.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        for (name, day, size) in [("a.jpg", 1.0, 10), ("b.jpg", 3.0, 20)] {
            let url = folder.appendingPathComponent(name)
            try Data(repeating: 1, count: size).write(to: url)
            try fm.setAttributes([.modificationDate: Self.day(day)], ofItemAtPath: url.path)
        }
        try Data([1]).write(to: folder.appendingPathComponent("notes.txt"))
        let entries = try BrowserListingSource.full(folder, archives: true)
        let pure = FolderSummary.of(listing: entries, folderModified: Self.day(5))
        #expect(pure.photos == 2 && pure.folders == 1 && pure.bytes == 30 && pure.datesKnown)
        #expect(pure.first == Self.day(1) && pure.last == Self.day(3) && pure.folderModified == Self.day(5))

        let store = store(ThumbReader(), dir: dir)
        await store.putOpenFolderSummary(folder, listing: entries)
        let modified = try folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let summary = try #require(await store.folderSummary(at: loc(folder.path)))
        #expect(summary.photos == 2 && summary.folders == 1 && summary.bytes == 30 && summary.datesKnown)
        #expect(summary.folderModified == modified)
        await store.commit()
        let next = try ThumbnailDatabase(directory: dir, thumbSize: 32)
        #expect(try next.summary(at: loc(folder.path)) == summary)
    }
}

/// Fix round 1 of the folder cards' task 6: the catalog's pictures never wait on a summary listing (beyond its time
/// limit) nor depend on it; a share goes offline as a whole; only a malformed zip is broken.
@Suite struct FolderCardFixTests {
    private let fm = FileManager.default

    private func tempDir() -> URL { fm.temporaryDirectory.appendingPathComponent("loupe-folder-card-\(UUID().uuidString)") }

    private func store(_ reader: ThumbReader, dir: URL) -> ThumbnailStore {
        ThumbnailStore(directory: dir, reader: reader, thumbSize: 32, limitBytes: 1 << 30,
                       locate: { url in
                           ThumbnailLocation(volume: url.path.hasPrefix("/net/") ? "net:share" : "test",
                                             folder: url.deletingLastPathComponent().path, name: url.lastPathComponent)
                       }, idleDelay: .zero, commitDelay: .seconds(3600))
    }

    private func loc(_ folder: String) -> ThumbnailLocation {
        ThumbnailLocation(volume: folder.hasPrefix("/net/") ? "net:share" : "test", folder: folder, name: "_")
    }

    /// Four thumbnails of `folder` in the catalog, as an earlier session left them.
    private func catalogued(_ store: ThumbnailStore, _ reader: ThumbReader, in folder: String) async {
        let names = (1...4).map { "\($0).jpg" }
        for name in names {
            let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
            reader.add(url, TestJPEGs.gradient(width: 40, height: 30))
            _ = await store.cover(url, maxPixel: 64)
        }
    }

    private static let day = Date(timeIntervalSinceReferenceDate: 700_000_000)

    /// A share that hangs: the catalog's four pictures come all the same, and the listing tried for the summary is not
    /// tried again on the next request.
    @Test func hungShareKeepsTheCatalogPictures() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader(), calls = TryCounter(), gate = DispatchSemaphore(value: 0)
        let store = store(reader, dir: dir)
        await catalogued(store, reader, in: "/net/f")
        await store.setCoverListing(dated: { _, _, _, _ in
            calls.add()
            gate.wait()
            throw CancellationError()
        }, networkTimeout: .milliseconds(50))
        await store.setCoverVolumes { _ in true }
        let folder = URL(fileURLWithPath: "/net/f"), lane = CoverLane(network: true, resolving: false)
        let card = try #require(await store.folderCard(folder, archive: false, in: loc("/net/f"), maxPixel: 64,
                                                       modified: Self.day))
        #expect(card.images.count == 4 && card.summaryPending && card.summary == nil)
        #expect(store.coverThreads.count(lane) == 0)   // not listed: the pictures went out at once
        let again = try #require(await store.folderCard(folder, archive: false, in: loc("/net/f"), maxPixel: 64,
                                                        modified: Self.day))
        #expect(again.images.count == 4 && !again.summaryPending && again.summary == nil)
        #expect(store.coverThreads.count(lane) == 1)   // the summary's listing, hung
        let third = try #require(await store.folderCard(folder, archive: false, in: loc("/net/f"), maxPixel: 64,
                                                        modified: Self.day))
        #expect(third.images.count == 4 && !third.summaryPending)
        #expect(store.coverThreads.count(lane) == 1)   // tried once this session: no second listing
        gate.signal()
        #expect(await eventually { store.coverThreads.count(lane) == 0 })
        #expect(calls.count == 1)
    }

    /// A share listing only part of a big folder in time: the pictures from the catalog, no summary from a part, and
    /// no second try this session.
    @Test func partialListingIsNotRepeated() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader(), calls = TryCounter(), gate = DispatchSemaphore(value: 0)
        let store = store(reader, dir: dir)
        await catalogued(store, reader, in: "/net/big")
        await store.setCoverListing(dated: { _, _, _, part in
            calls.add()
            _ = part(CoverListing(names: CoverNames(files: ["1.jpg"], folders: [])))
            gate.wait()
            throw CancellationError()
        }, networkTimeout: .milliseconds(50))
        await store.setCoverVolumes { _ in true }
        let folder = URL(fileURLWithPath: "/net/big"), lane = CoverLane(network: true, resolving: false)
        for pending in [true, false, false] {
            let card = try #require(await store.folderCard(folder, archive: false, in: loc("/net/big"), maxPixel: 64,
                                                           modified: Self.day))
            #expect(card.images.count == 4)
            #expect(card.summary == nil)
            #expect(card.summaryPending == pending)
        }
        // One listing in all, still held by its thread: the third call listed nothing.
        #expect(store.coverThreads.count(lane) == 1)
        gate.signal()
        #expect(await eventually { store.coverThreads.count(lane) == 0 })
        #expect(calls.count == 1)
    }

    /// A listing that fails keeps the stored summary (however old) and the catalog's pictures.
    @Test func failedListingKeepsTheStoredSummary() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader()
        let store = store(reader, dir: dir)
        await catalogued(store, reader, in: "/p/f")
        let old = FolderSummary(photos: 4, folders: 0, bytes: 40, first: Self.day, last: Self.day,
                                histogram: [255] + Array(repeating: 0, count: 11), folderModified: Self.day,
                                datesKnown: true)
        await store.putFolderSummaries([(loc("/p/f"), old)])
        await store.setCoverListing(dated: { _, _, _, _ in throw POSIXError(.EACCES) })
        let first = try #require(await store.folderCard(URL(fileURLWithPath: "/p/f"), archive: false, in: loc("/p/f"),
                                                        maxPixel: 64, modified: Self.day.addingTimeInterval(60)))
        #expect(first.summaryPending && first.summary == old)
        let card = try #require(await store.folderCard(URL(fileURLWithPath: "/p/f"), archive: false, in: loc("/p/f"),
                                                       maxPixel: 64, modified: Self.day.addingTimeInterval(60)))
        #expect(card.images.count == 4)
        #expect(card.summary == old)
        #expect(card.problem == nil)
        #expect(await store.folderSummary(at: loc("/p/f")) == old)
    }

    /// Three folders on one share that hangs: after two time outs the share is offline, and every card on it says so,
    /// those whose listing only found the lane full too; a listing that answers brings the share back.
    @Test func shareGoesOfflineAsAWhole() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader(), gate = DispatchSemaphore(value: 0), hung = LockedFlag()
        hung.set()
        let store = store(reader, dir: dir)
        let lister: ThumbnailStore.DatedCoverLister = { _, _, _, _ in
            if hung.isSet {
                gate.wait()
                throw CancellationError()
            }
            return CoverListing(names: CoverNames(files: [], folders: []))
        }
        await store.setCoverListing(dated: lister, networkTimeout: .milliseconds(50))
        await store.setCoverVolumes { _ in true }
        func card(_ name: String) async -> FolderCard? {
            await store.folderCard(URL(fileURLWithPath: "/net/\(name)"), archive: false, in: loc("/net/\(name)"),
                                   maxPixel: 64)
        }
        #expect(await card("a") == nil)                     // one time out: not now
        #expect(await card("b")?.problem == .offline)       // two in a row: the share
        #expect(await card("c")?.problem == .offline)       // a third hangs too
        let lane = CoverLane(network: true, resolving: false)
        #expect(store.coverThreads.count(lane) == ThumbnailStore.coverThreadsPerLane)
        #expect(await card("d")?.problem == .offline)       // the lane full: busy, offline all the same
        #expect(await card("a")?.problem == .offline)
        hung.reset()
        for _ in 0..<ThumbnailStore.coverThreadsPerLane { gate.signal() }
        #expect(await eventually { store.coverThreads.count(lane) == 0 })
        // The share answers: a time limit no loaded machine's late thread runs out of.
        await store.setCoverListing(dated: lister, networkTimeout: .seconds(30))
        let back = try #require(await card("e"))
        #expect(back.problem == nil)
        #expect(await card("d")?.problem == nil)
    }

    /// Only a malformed zip is broken; a zip that cannot be opened has no badge; an I/O error on a share counts as a
    /// time out towards offline.
    @Test func brokenOnlyForArchiveErrors() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let errors = LockedErrors()
        let store = store(ThumbReader(), dir: dir)
        await store.setCoverListing(dated: { folder, _, _, _ in throw errors.error(for: folder.lastPathComponent) },
                                    networkTimeout: .seconds(30))
        await store.setCoverVolumes { _ in true }
        errors.set("bad.zip", ArchiveError.damaged)
        errors.set("locked.zip", POSIXError(.EACCES))
        errors.set("x", POSIXError(.EIO))
        errors.set("y", POSIXError(.ENOTCONN))
        #expect(await store.folderCard(URL(fileURLWithPath: "/p/bad.zip"), archive: true, in: loc("/p/bad.zip"),
                                       maxPixel: 64)?.problem == .broken)
        let locked = await store.folderCard(URL(fileURLWithPath: "/p/locked.zip"), archive: true,
                                            in: loc("/p/locked.zip"), maxPixel: 64)
        #expect(locked != nil && locked?.problem == nil)
        #expect(await store.folderCard(URL(fileURLWithPath: "/net/x"), archive: false, in: loc("/net/x"),
                                       maxPixel: 64) == nil)
        #expect(await store.folderCard(URL(fileURLWithPath: "/net/y"), archive: false, in: loc("/net/y"),
                                       maxPixel: 64)?.problem == .offline)
    }

    /// A dated summary written while a names-only listing ran (the folder opened meanwhile) keeps its dates.
    @Test func summaryWrittenDuringTheListingKeepsItsDates() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let started = LockedFlag(), gate = DispatchSemaphore(value: 0)
        let store = store(ThumbReader(), dir: dir)
        await store.setCoverListing(dated: { _, _, _, _ in
            started.set()
            gate.wait()
            return CoverListing(names: CoverNames(files: ["a.jpg", "b.jpg"], folders: []))
        }, networkTimeout: .seconds(30))
        await store.setCoverVolumes { _ in true }
        let task = Task {
            await store.folderCard(URL(fileURLWithPath: "/net/f"), archive: false, in: loc("/net/f"), maxPixel: 64,
                                   modified: Self.day)
        }
        #expect(await eventually { started.isSet })
        let visited = FolderSummary(photos: 2, folders: 0, bytes: 20, first: Self.day, last: Self.day,
                                    histogram: [255] + Array(repeating: 0, count: 11), folderModified: Self.day,
                                    datesKnown: true)
        await store.putFolderSummaries([(loc("/net/f"), visited)])
        gate.signal()
        let card = await task.value
        #expect(card?.summary?.datesKnown == true)
        #expect(card?.summary?.bytes == 20)
        #expect(await store.folderSummary(at: loc("/net/f"))?.datesKnown == true)
    }

    /// A listing's summary knows its dates only when its photos have them, and its size only when they have one.
    @Test func listingSummaryKnowsWhatItHas() {
        let folder = URL(fileURLWithPath: "/p")
        let undated = [BrowserEntry(url: folder.appendingPathComponent("a.jpg"), name: "a.jpg", kind: .file)]
        let summary = FolderSummary.of(listing: undated, folderModified: nil)
        #expect(summary.photos == 1 && !summary.datesKnown && summary.bytes == nil)
        let none = FolderSummary.of(listing: [BrowserEntry(url: folder.appendingPathComponent("s"), name: "s",
                                                           kind: .folder)], folderModified: nil)
        #expect(none.photos == 0 && none.folders == 1 && none.datesKnown)
    }

    /// The dated listing: hidden names, packages and other files left out; a symlinked photo counts but is not
    /// followed for its date (a link into a hung mount must not hold a local listing).
    @Test func datedListingLeavesOutHiddenPackagesAndLinks() throws {
        let folder = tempDir()
        defer { try? fm.removeItem(at: folder) }
        try fm.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: folder.appendingPathComponent("Tool.app"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10).write(to: folder.appendingPathComponent("a.jpg"))
        try fm.setAttributes([.modificationDate: Self.day], ofItemAtPath: folder.appendingPathComponent("a.jpg").path)
        try Data([1]).write(to: folder.appendingPathComponent(".hidden.jpg"))
        try Data([1]).write(to: folder.appendingPathComponent("notes.txt"))
        try fm.createSymbolicLink(atPath: folder.appendingPathComponent("link.jpg").path,
                                  withDestinationPath: "/nowhere/at/all.jpg")
        let listing = try ThumbnailStore.listCover(folder, archive: false, dated: true, part: { _ in true })
        #expect(Set(listing.names.files) == ["a.jpg", "link.jpg"])
        #expect(listing.names.folders == ["sub"])
        let summary = try #require(listing.summary)
        #expect(summary.photos == 2 && summary.folders == 1)
        #expect(summary.bytes == 10)
        #expect(summary.first == Self.day && summary.last == Self.day && summary.datesKnown)
        #expect(listing.photoDates == [Self.day])
    }

    /// The open folder's summary: none for a zip (its card has its own from its directory), and nothing written
    /// again when it has not changed.
    @Test func openFolderSummarySkipsZipsAndRepeats() async throws {
        let dir = tempDir(), folder = tempDir()
        defer {
            try? fm.removeItem(at: dir)
            try? fm.removeItem(at: folder)
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1]).write(to: folder.appendingPathComponent("a.jpg"))
        let store = store(ThumbReader(), dir: dir)
        let zip = folder.appendingPathComponent("set.zip")
        await store.putOpenFolderSummary(zip, listing: [BrowserEntry(url: zip.appendingPathComponent("1.jpg"),
                                                                     name: "1.jpg", kind: .file)])
        #expect(await store.folderSummary(at: loc(zip.path)) == nil)
        let entries = try BrowserListingSource.full(folder, archives: true)
        await store.putOpenFolderSummary(folder, listing: entries)
        #expect(await store.folderSummary(at: loc(folder.path))?.photos == 1)
        await store.commit()
        await store.putOpenFolderSummary(folder, listing: entries)
        #expect(await store.pendingSummaries.isEmpty)
    }
}

/// Errors handed out by folder name, from other threads.
final class LockedErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [String: Error] = [:]
    func set(_ name: String, _ error: Error) { lock.withLock { errors[name] = error } }
    func error(for name: String) -> Error { lock.withLock { errors[name] ?? CocoaError(.fileReadUnknown) } }
}

/// Fix round 2 of the folder cards' task 6: the catalog's pictures go out at once and the facts follow on the next
/// call; a share comes back as soon as it answers anything.
@Suite struct FolderCardFollowUpTests {
    private let fm = FileManager.default

    private func tempDir() -> URL { fm.temporaryDirectory.appendingPathComponent("loupe-folder-card-\(UUID().uuidString)") }

    private func store(_ reader: ThumbReader, dir: URL) -> ThumbnailStore {
        ThumbnailStore(directory: dir, reader: reader, thumbSize: 32, limitBytes: 1 << 30,
                       locate: { url in
                           ThumbnailLocation(volume: url.path.hasPrefix("/net/") ? "net:share" : "test",
                                             folder: url.deletingLastPathComponent().path, name: url.lastPathComponent)
                       }, idleDelay: .zero, commitDelay: .seconds(3600))
    }

    private func loc(_ folder: String) -> ThumbnailLocation {
        ThumbnailLocation(volume: folder.hasPrefix("/net/") ? "net:share" : "test", folder: folder, name: "_")
    }

    private func catalogued(_ store: ThumbnailStore, _ reader: ThumbReader, in folder: String) async {
        for name in (1...4).map({ "\($0).jpg" }) {
            let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
            reader.add(url, TestJPEGs.gradient(width: 40, height: 30))
            _ = await store.cover(url, maxPixel: 64)
        }
    }

    /// A share made offline by two listings that hang (their threads wait at `gate`).
    private func offline(_ store: ThumbnailStore, gate: DispatchSemaphore, names: [String] = ["h1", "h2"]) async {
        await store.setCoverListing(dated: { _, _, _, _ in
            gate.wait()
            throw CancellationError()
        }, networkTimeout: .milliseconds(50))
        for name in names {
            _ = await store.folderCard(URL(fileURLWithPath: "/net/\(name)"), archive: false, in: loc("/net/\(name)"),
                                       maxPixel: 64)
        }
    }

    /// Four thumbnails in the catalog and no fresh summary, on a share and on a local volume: the first call gives the
    /// pictures at once without a listing, the summary pending; the next lists and brings it.
    @Test(arguments: ["/net/f", "/p/f"])
    func catalogPicturesGoOutAtOnce(_ path: String) async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader(), calls = TryCounter()
        let store = store(reader, dir: dir)
        await catalogued(store, reader, in: path)
        await store.setCoverListing(dated: { _, _, _, _ in
            calls.add()
            return CoverListing(names: CoverNames(files: (1...4).map { "\($0).jpg" }, folders: []))
        }, networkTimeout: .seconds(30))
        await store.setCoverVolumes { $0.path.hasPrefix("/net/") }
        let folder = URL(fileURLWithPath: path)
        let first = try #require(await store.folderCard(folder, archive: false, in: loc(path), maxPixel: 64))
        #expect(first.images.count == 4 && first.summaryPending && first.summary == nil)
        #expect(calls.count == 0)   // a listing would have ended before the card came back
        let next = try #require(await store.folderCard(folder, archive: false, in: loc(path), maxPixel: 64))
        #expect(next.images.count == 4 && !next.summaryPending)
        #expect(next.summary?.photos == 4)
        #expect(calls.count == 1)
    }

    /// A card whose follow-up is cancelled (it left the screen) keeps its try: the next follow-up lists.
    @Test func cancelledFollowUpKeepsItsTry() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader(), calls = TryCounter(), started = LockedFlag(), gate = DispatchSemaphore(value: 0)
        let store = store(reader, dir: dir)
        await catalogued(store, reader, in: "/p/f")
        await store.setCoverListing(dated: { _, _, _, _ in
            calls.add()
            if calls.count == 1 {
                started.set()
                gate.wait()
            }
            return CoverListing(names: CoverNames(files: ["1.jpg"], folders: []))
        }, localTimeout: .seconds(30))
        let folder = URL(fileURLWithPath: "/p/f")
        #expect(await store.folderCard(folder, archive: false, in: loc("/p/f"), maxPixel: 64)?.summaryPending == true)
        let task = Task { await store.folderCard(folder, archive: false, in: loc("/p/f"), maxPixel: 64) }
        #expect(await eventually { started.isSet })
        task.cancel()
        _ = await task.value
        gate.signal()
        var card = try #require(await store.folderCard(folder, archive: false, in: loc("/p/f"), maxPixel: 64))
        if card.summaryPending {   // the cancelled try was put back as due, or asked for again
            card = try #require(await store.folderCard(folder, archive: false, in: loc("/p/f"), maxPixel: 64))
        }
        #expect(!card.summaryPending && card.summary?.photos == 1)
        #expect(calls.count == 2)
    }

    /// An offline share comes back with the open folder's listing on it, and with the browser telling of one.
    @Test func openFolderListingBringsTheShareBack() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let gate = DispatchSemaphore(value: 0)
        let store = store(ThumbReader(), dir: dir)
        await store.setCoverVolumes { _ in true }
        await offline(store, gate: gate)
        #expect(await store.offlineVolumes["net:share"] != nil)
        // A time limit no loaded machine's late thread runs out of, for the open folder's resolve.
        await store.setCoverListing(dated: { _, _, _, _ in CoverListing(names: CoverNames(files: [], folders: [])) },
                                    networkTimeout: .seconds(30))
        await store.putOpenFolderSummary(URL(fileURLWithPath: "/net/open"), listing: [])
        #expect(await store.offlineVolumes["net:share"] == nil)
        for _ in 0..<2 { gate.signal() }
        let lane = CoverLane(network: true, resolving: false)
        #expect(await eventually { store.coverThreads.count(lane) == 0 })
        await offline(store, gate: gate, names: ["h3", "h4"])
        #expect(await store.offlineVolumes["net:share"] != nil)
        await store.volumeAnswered(URL(fileURLWithPath: "/net/shown"), in: loc("/net/shown"))
        #expect(await store.offlineVolumes["net:share"] == nil)
        for _ in 0..<2 { gate.signal() }
    }

    /// "No such file" or "no permission" from a share is an answer: its time outs in a row start again.
    @Test func answerOfAnErrorClearsTheTimeOuts() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let gate = DispatchSemaphore(value: 0)
        let store = store(ThumbReader(), dir: dir)
        await store.setCoverVolumes { _ in true }
        let lister: ThumbnailStore.DatedCoverLister = { folder, _, _, _ in
            if folder.lastPathComponent == "gone" { throw POSIXError(.ENOENT) }
            gate.wait()
            throw CancellationError()
        }
        // Short limits for the listings that hang, a generous one for the answer (a loaded machine starts threads late).
        func limit(_ timeout: Duration) async { await store.setCoverListing(dated: lister, networkTimeout: timeout) }
        await limit(.milliseconds(50))
        func card(_ name: String) async -> FolderCard? {
            await store.folderCard(URL(fileURLWithPath: "/net/\(name)"), archive: false, in: loc("/net/\(name)"),
                                   maxPixel: 64)
        }
        #expect(await card("t1") == nil)
        #expect(await store.coverVolumeTimeouts["net:share"] == 1)
        await limit(.seconds(30))
        #expect(await card("gone")?.problem == nil)
        #expect(await store.coverVolumeTimeouts["net:share"] == nil)
        await limit(.milliseconds(50))
        #expect(await card("t2") == nil)   // one time out again: not offline
        #expect(await store.offlineVolumes["net:share"] == nil)
        for _ in 0..<2 { gate.signal() }
    }

    /// While a share is offline its cards are not listed for their summary, but one probe a while goes through the
    /// summary's follow-up: when the share answers it, the share is back.
    @Test func probeBringsTheShareBack() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader(), gate = DispatchSemaphore(value: 0), calls = TryCounter()
        let store = store(reader, dir: dir)
        await store.setCoverVolumes { _ in true }
        await catalogued(store, reader, in: "/net/f")
        await offline(store, gate: gate)
        await store.setCoverListing(dated: { _, _, _, _ in
            calls.add()
            return CoverListing(names: CoverNames(files: (1...4).map { "\($0).jpg" }, folders: []))
        }, networkTimeout: .seconds(30))
        let folder = URL(fileURLWithPath: "/net/f")
        // Within the probe interval: the pictures, offline, nothing pending and nothing listed.
        let dim = try #require(await store.folderCard(folder, archive: false, in: loc("/net/f"), maxPixel: 64))
        #expect(dim.images.count == 4 && dim.problem == .offline && !dim.summaryPending)
        #expect(calls.count == 0)
        await store.setCoverProbeInterval(.zero)
        let due = try #require(await store.folderCard(folder, archive: false, in: loc("/net/f"), maxPixel: 64))
        #expect(due.summaryPending && due.problem == .offline)
        let back = try #require(await store.folderCard(folder, archive: false, in: loc("/net/f"), maxPixel: 64))
        #expect(back.problem == nil && back.summary?.photos == 4)
        #expect(calls.count == 1)
        for _ in 0..<2 { gate.signal() }
    }

    /// Without a location a card's volume and share-ness come from the mount table: a local folder that cannot be
    /// listed dims nothing.
    @Test func localFolderWithoutLocationDimsNothing() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let store = store(ThumbReader(), dir: dir)
        await store.setCoverVolumes { _ in false }
        await store.setCoverListing(dated: { folder, _, _, _ in
            if folder.lastPathComponent == "a" { throw POSIXError(.ENOENT) }
            return CoverListing(names: CoverNames(files: [], folders: []))
        })
        #expect(await store.folderCard(URL(fileURLWithPath: "/p/a"), archive: false, in: nil, maxPixel: 64)?.problem == nil)
        #expect(await store.folderCard(URL(fileURLWithPath: "/p/b"), archive: false, in: nil, maxPixel: 64)?.problem == nil)
        #expect(await store.offlineVolumes.isEmpty)
    }

    /// A folder given up earlier this session shows its pictures once the catalog has four of them.
    @Test func givenUpFolderRecoversFromTheCatalog() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader()
        let store = store(reader, dir: dir)
        await store.setCoverListing(dated: { _, _, _, _ in throw POSIXError(.EACCES) })
        let folder = URL(fileURLWithPath: "/p/f")
        #expect(await store.folderCard(folder, archive: false, in: loc("/p/f"), maxPixel: 64)?.images.isEmpty == true)
        await catalogued(store, reader, in: "/p/f")
        #expect(await store.folderCard(folder, archive: false, in: loc("/p/f"), maxPixel: 64)?.images.count == 4)
    }
}
