import Foundation
import HomeScreenModel
import Testing
@testable import LoupeCore

/// A folder tree for the walk's listings: each folder's photos (served by a `ThumbReader`) and subfolders. Records the
/// listings asked for and how many ran at once.
private final class FakeTree: @unchecked Sendable {
    private let lock = NSLock()
    private let reader: ThumbReader
    private var files: [String: [String]] = [:]
    private var folders: [String: [String]] = [:]
    private var asked: [(path: String, dated: Bool)] = []
    private var running = 0
    private var peak = 0
    private let latency: TimeInterval

    init(reader: ThumbReader, latency: TimeInterval = 0) {
        self.reader = reader
        self.latency = latency
    }

    /// `photos` small JPEGs in `path` (in the reader too) and the subfolders `folders` (by name).
    func set(_ path: String, photos: Int, folders: [String] = []) {
        let names = (0..<photos).map { "\($0).jpg" }
        for (index, name) in names.enumerated() {
            reader.add(URL(fileURLWithPath: path + "/" + name), TestJPEGs.gradient(width: 40 + index % 8, height: 30))
        }
        lock.withLock {
            files[path] = names
            self.folders[path] = folders
        }
    }

    var calls: [String] { lock.withLock { asked.map(\.path) } }
    var datedCalls: [Bool] { lock.withLock { asked.map(\.dated) } }
    var peakConcurrent: Int { lock.withLock { peak } }

    var lister: ThumbnailStore.DatedCoverLister {
        { folder, _, dated, _ in
            let (names, subfolders) = self.lock.withLock { () -> ([String], [String]) in
                self.asked.append((folder.path, dated))
                self.running += 1
                self.peak = max(self.peak, self.running)
                return (self.files[folder.path] ?? [], self.folders[folder.path] ?? [])
            }
            defer { self.lock.withLock { self.running -= 1 } }
            if self.latency > 0 { Thread.sleep(forTimeInterval: self.latency) }
            guard dated else { return CoverListing(names: CoverNames(files: names, folders: subfolders)) }
            let entries = names.map { name -> BrowserEntry in
                let url = folder.appendingPathComponent(name)
                let stamp = self.reader.stamp(of: url)
                return BrowserEntry(url: url, name: name, kind: .file, date: stamp.modified, size: Int64(stamp.size))
            } + subfolders.map {
                BrowserEntry(url: folder.appendingPathComponent($0, isDirectory: true), name: $0, kind: .folder)
            }
            return CoverListing(listing: entries, dated: true)
        }
    }
}

/// `ThumbReader` whose stamps are recorded (count, how many at once, at what priority), and those from the
/// `holdFrom`-th on park until cancelled.
private final class StampReader: FileReading, @unchecked Sendable {
    let inner: ThumbReader
    private let lock = NSLock()
    private var count = 0
    private var running = 0
    private var peak = 0
    private var background = true
    private var cancelledCount = 0
    private let holdFrom: Int
    private let gate = HoldGate()

    init(_ inner: ThumbReader, holdFrom: Int = .max) {
        self.inner = inner
        self.holdFrom = holdFrom
    }

    var stamps: Int { lock.withLock { count } }
    var peakConcurrent: Int { lock.withLock { peak } }
    var allBackground: Bool { lock.withLock { background } }
    var cancelled: Int { lock.withLock { cancelledCount } }

    func read(_ url: URL, priority: ReadPriority) async throws -> FileBytes { try await inner.read(url, priority: priority) }

    func readPrefix(_ url: URL, priority: ReadPriority,
                    isEnough: @escaping @Sendable (Data) -> Bool) async throws -> FileBytes {
        try await inner.readPrefix(url, priority: priority, isEnough: isEnough)
    }

    func stamp(_ url: URL, priority: Int) async throws -> FileStamp {
        try await stamp(url, priority: ReadPriority(priority))
    }

    func stamp(_ url: URL, priority: ReadPriority) async throws -> FileStamp {
        let index = lock.withLock { () -> Int in
            count += 1
            running += 1
            peak = max(peak, running)
            if !priority.isBackground { background = false }
            return count
        }
        defer { lock.withLock { running -= 1 } }
        if index > holdFrom {
            do {
                try await gate.wait()
            } catch {
                lock.withLock { cancelledCount += 1 }
                throw error
            }
        }
        return inner.stamp(of: url)
    }
}

@Suite struct ThumbsWalkTests {
    private let fm = FileManager.default

    private func tempDir() -> URL { fm.temporaryDirectory.appendingPathComponent("loupe-walk-\(UUID().uuidString)") }

    private static let locate: @Sendable (URL) -> ThumbnailLocation? = { url in
        ThumbnailLocation(volume: "test", folder: url.deletingLastPathComponent().path, name: url.lastPathComponent)
    }

    private func store(_ reader: any FileReading, dir: URL) -> ThumbnailStore {
        ThumbnailStore(directory: dir, reader: reader, thumbSize: 32, limitBytes: 1 << 30, locate: Self.locate,
                       idleDelay: .zero, commitDelay: .seconds(3600), decodes: 1)
    }

    private func loc(_ folder: String) -> ThumbnailLocation { ThumbnailLocation(volume: "test", folder: folder, name: "_") }

    private func eventually(_ timeout: Duration = .seconds(10), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    private func files(_ folder: String, _ count: Int) -> [URL] {
        (0..<count).map { URL(fileURLWithPath: folder + "/\($0).jpg") }
    }

    private static func allReady(_ store: isolated ThumbnailStore, _ files: [URL]) -> Bool {
        files.allSatisfy { store.status($0) == .ready }
    }

    /// Levels 0 to `depth` are listed and their photos made; nothing below is listed or read.
    @Test func walkGoesToTheDepth() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader(), tree = FakeTree(reader: reader)
        tree.set("/t", photos: 2, folders: ["a"])
        tree.set("/t/a", photos: 2, folders: ["b"])
        tree.set("/t/a/b", photos: 2, folders: ["c"])
        tree.set("/t/a/b/c", photos: 2)
        let store = store(reader, dir: dir)
        await store.setCoverListing(dated: tree.lister)
        await store.setCoverVolumes { _ in false }
        await store.setCoverStat { _ in nil }
        let walk = ThumbsWalk(store: store, queue: store.coverQueue, client: 7)
        await walk.start(URL(fileURLWithPath: "/t"), location: loc("/t"), depth: 2)
        await walk.finished()
        let progress = await walk.progress
        #expect(progress.folders == WorkCount(done: 3, total: 3))
        #expect(progress.files == WorkCount(done: 6, total: 6))
        #expect(progress.stopped == nil)
        // Made and kept in the catalog (the window is gone with the walk).
        for folder in ["/t", "/t/a", "/t/a/b"] {
            #expect(await store.folderSamples(URL(fileURLWithPath: folder), limit: 10).count == 2)
        }
        // The subfolders' covers and summaries (made ahead on the walk's client) come too.
        let a = loc("/t/a"), b = loc("/t/a/b"), c = loc("/t/a/b/c")
        #expect(await eventually {
            let first = await store.folderSummary(at: a), second = await store.folderSummary(at: b)
            return first != nil && second != nil
        })
        let deepest = await store.folderSummary(at: c)
        #expect(deepest == nil)
        #expect(Set(tree.calls) == ["/t", "/t/a", "/t/a/b"])
        #expect(!reader.reads.contains { $0.path.hasPrefix("/t/a/b/c/") })
    }

    /// On a share the walk's listings and the subfolders' covers share the one listing at a time with Home's cards.
    @Test func walkOnAShareIsOneAtATime() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader(), tree = FakeTree(reader: reader, latency: 0.01)
        tree.set("/s", photos: 3, folders: ["a", "b", "c", "d"])
        for name in ["a", "b", "c", "d"] { tree.set("/s/" + name, photos: 2) }
        for name in ["h1", "h2", "h3"] { tree.set("/home/" + name, photos: 2) }
        let store = store(reader, dir: dir)
        await store.setCoverListing(dated: tree.lister)
        await store.setCoverVolumes { _ in true }
        await store.setCoverStat { _ in nil }
        let queue = store.coverQueue
        await queue.want(["/home/h1", "/home/h2", "/home/h3"], visible: 3, client: 1, isNetwork: { _ in true }) { id in
            await store.folderCard(URL(fileURLWithPath: id), archive: false, in: nil, network: true, maxPixel: 16) != nil
        }
        let walk = ThumbsWalk(store: store, queue: queue, client: 7)
        await walk.start(URL(fileURLWithPath: "/s"), location: nil, depth: 1)
        await walk.finished()
        #expect(await walk.progress.folders == WorkCount(done: 5, total: 5))
        // Each subfolder listed by the walk and by its cover.
        #expect(await eventually { ["a", "b", "c", "d"].allSatisfy { name in tree.calls.filter { $0 == "/s/" + name }.count == 2 } })
        #expect(await eventually { await queue.progress(client: 1).inView.done == 3 })
        #expect(tree.peakConcurrent == 1)
        // A share's folders are listed by names, never with stat.
        #expect(!tree.datedCalls.contains(true))
    }

    /// More folders than the limit: the walk stops after the folder that found them, and says how far it went.
    @Test func walkStopsAtTheFolderLimit() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader(), tree = FakeTree(reader: reader)
        tree.set("/r", photos: 1, folders: ["a", "b", "c", "d", "e"])
        for name in ["a", "b", "c", "d", "e"] { tree.set("/r/" + name, photos: 1) }
        let store = store(reader, dir: dir)
        await store.setCoverListing(dated: tree.lister)
        await store.setCoverVolumes { _ in false }
        await store.setCoverStat { _ in nil }
        let walk = ThumbsWalk(store: store, queue: store.coverQueue, client: 7, folderLimit: 3)
        await walk.start(URL(fileURLWithPath: "/r"), location: loc("/r"), depth: 1)
        await walk.finished()
        let progress = await walk.progress
        #expect(progress.stopped == "Too many folders — prepared 1")
        #expect(progress.folders.done == 1)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(tree.calls == ["/r"])
        #expect(await store.coverQueue.progress(client: 7) == CoverProgress())
    }

    /// Cancelled, the walk lists nothing more, leaves the queue and drops its window.
    @Test func walkCancelStopsListings() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader(), tree = FakeTree(reader: reader)
        tree.set("/c", photos: 6, folders: ["a", "b", "c", "d", "e"])
        for name in ["a", "b", "c", "d", "e"] { tree.set("/c/" + name, photos: 2, folders: ["x"]) }
        reader.setLatency(.milliseconds(100))
        let store = store(reader, dir: dir)
        await store.setCoverListing(dated: tree.lister)
        await store.setCoverVolumes { _ in false }
        await store.setCoverStat { _ in nil }
        let walk = ThumbsWalk(store: store, queue: store.coverQueue, client: 7)
        await walk.start(URL(fileURLWithPath: "/c"), location: loc("/c"), depth: 2)
        #expect(await eventually { await store.walkWindow != nil })
        await walk.cancel()
        await walk.finished()
        // Those already on their threads end; nothing starts after.
        #expect(await eventually { await store.coverQueue.runningCount == 0 })
        let calls = tree.calls
        try? await Task.sleep(for: .milliseconds(300))
        #expect(tree.calls == calls)
        #expect(!tree.calls.contains { $0.hasSuffix("/x") })
        #expect(await store.walkWindow == nil)
        #expect(await store.coverQueue.progress(client: 7) == CoverProgress())
    }

    /// On a share the folder is listed by names (the cover slot free at once), then each photo's stamp is asked in the
    /// background, never more at once than the generator's reads, and the stamped photos reach the walk window in
    /// chunks while the rest are still being stamped; a cancel stops the stamps.
    @Test func walkOnAShareStampsInChunks() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let inner = ThumbReader(), tree = FakeTree(reader: inner)
        tree.set("/n", photos: ThumbsWalk.stampChunk + 20)
        let reader = StampReader(inner, holdFrom: ThumbsWalk.stampChunk)
        let store = store(reader, dir: dir)
        await store.setCoverListing(dated: tree.lister)
        await store.setCoverVolumes { _ in true }
        await store.setCoverStat { _ in nil }
        let walk = ThumbsWalk(store: store, queue: store.coverQueue, client: 7)
        await walk.start(URL(fileURLWithPath: "/n"), location: nil, depth: 0)
        #expect(await eventually { await store.walkWindow?.request.files.count == ThumbsWalk.stampChunk })
        // The first photos answered (two at a time, so not quite in order), made while the others wait for stamps.
        let chunk = try #require(await store.walkWindow?.request.files)
        #expect(await eventually { await Self.allReady(store, chunk) })
        #expect(tree.calls == ["/n"])
        #expect(tree.datedCalls == [false])
        #expect(await store.coverQueue.runningCount == 0)   // the listing's slot is free while stamps go on
        #expect(reader.peakConcurrent <= ThumbnailStore.maxReads)
        #expect(reader.allBackground)
        await walk.cancel()
        await walk.finished()
        let stamps = reader.stamps
        #expect(reader.cancelled >= 1)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(reader.stamps == stamps)
        #expect(stamps < ThumbsWalk.stampChunk + 20)
    }
}
