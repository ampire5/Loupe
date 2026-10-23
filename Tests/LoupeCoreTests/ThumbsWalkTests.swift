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
    private var down = false
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
    /// While true, every listing fails as a share's lost connection does.
    var offline: Bool {
        get { lock.withLock { down } }
        set { lock.withLock { down = newValue } }
    }
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
            if self.offline { throw POSIXError(.ENOTCONN) }
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
    private var failing: Set<URL> = []

    /// How long each stamp waits in the reader's queue before a thread picks it up.
    private let queued: Duration

    init(_ inner: ThumbReader, holdFrom: Int = .max, queued: Duration = .zero) {
        self.inner = inner
        self.holdFrom = holdFrom
        self.queued = queued
    }

    var stamps: Int { lock.withLock { count } }
    var peakConcurrent: Int { lock.withLock { peak } }
    var allBackground: Bool { lock.withLock { background } }
    var cancelled: Int { lock.withLock { cancelledCount } }
    /// The stamps parked from now on go on (and none parks again).
    func release() { gate.open() }
    /// Stamps of `url` fail as for a file gone.
    func fail(_ url: URL) { lock.withLock { _ = failing.insert(url) } }

    func read(_ url: URL, priority: ReadPriority) async throws -> FileBytes { try await inner.read(url, priority: priority) }

    func readPrefix(_ url: URL, priority: ReadPriority,
                    isEnough: @escaping @Sendable (Data) -> Bool) async throws -> FileBytes {
        try await inner.readPrefix(url, priority: priority, isEnough: isEnough)
    }

    func stamp(_ url: URL, priority: Int) async throws -> FileStamp {
        try await stamp(url, priority: ReadPriority(priority))
    }

    func stamp(_ url: URL, priority: ReadPriority, started: @escaping @Sendable () -> Void) async throws -> FileStamp {
        if queued > .zero { try await Task.sleep(for: queued) }
        started()
        return try await stamp(url, priority: priority)
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
        if lock.withLock({ failing.contains(url) }) { throw CocoaError(.fileReadNoSuchFile) }
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
        let changes = Locked(0)
        await store.coverQueue.setOnProgress { client in if client == 7 { changes.update { $0 += 1 } } }
        let walk = ThumbsWalk(store: store, queue: store.coverQueue, client: 7)
        await walk.start(URL(fileURLWithPath: "/t"), location: loc("/t"), depth: 2)
        await walk.finished()
        let progress = await walk.progress
        #expect(progress.folders == WorkCount(done: 3, total: 3))
        #expect(progress.files == WorkCount(done: 6, total: 6))
        #expect(progress.stopped == nil)
        #expect(!progress.running)
        // Made and kept in the catalog (the window is gone with the walk).
        for folder in ["/t", "/t/a", "/t/a/b"] {
            #expect(await store.folderSamples(URL(fileURLWithPath: folder), limit: 10).count == 2)
        }
        // Each folder's summary from the walk's own listing: one listing a folder, no cover listing it again.
        for folder in ["/t", "/t/a", "/t/a/b"] {
            #expect(await store.folderSummary(at: loc(folder))?.photos == 2)
        }
        #expect(await store.folderSummary(at: loc("/t/a/b/c")) == nil)
        #expect(tree.calls == ["/t", "/t/a", "/t/a/b"])
        // One `want` a folder (its listing) and its listing done, and the last `want` that leaves the queue.
        #expect(changes.get == 2 * 3 + 1)
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
        // A generous time limit: these count listings, which a time out under load would repeat.
        await store.setCoverListing(dated: tree.lister, networkTimeout: .seconds(30))
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
        #expect(await eventually { await queue.progress(client: 1).inView.done == 3 })
        // Each of the walk's folders listed once.
        for path in ["/s", "/s/a", "/s/b", "/s/c", "/s/d"] { #expect(tree.calls.filter { $0 == path }.count == 1) }
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
        #expect(await walk.progress.running)
        await walk.cancel()
        await walk.finished()
        #expect(await !walk.progress.running)
        // Those already on their threads end; nothing starts after.
        #expect(await eventually { await store.coverQueue.runningCount == 0 })
        let calls = tree.calls
        try? await Task.sleep(for: .milliseconds(300))
        #expect(tree.calls == calls)
        #expect(!tree.calls.contains { $0.hasSuffix("/x") })
        #expect(await store.walkWindow == nil)
        #expect(await store.coverQueue.progress(client: 7) == CoverProgress())
        // A walk that was cancelled counts nothing as still to do: the pill of the window that started it goes out.
        let progress = await walk.progress
        #expect(progress.folders.done == progress.folders.total)
        #expect(progress.files.done == progress.files.total)
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

    /// The user's pause during a share's stamps: the walk waits on the queue's resume (no poll), and goes on to the
    /// end once the pause is lifted.
    @Test func walkWaitsForTheResume() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let inner = ThumbReader(), tree = FakeTree(reader: inner)
        tree.set("/p", photos: 40)
        let reader = StampReader(inner, queued: .milliseconds(10))
        let store = store(reader, dir: dir)
        await store.setCoverListing(dated: tree.lister)
        await store.setCoverVolumes { _ in true }
        await store.setCoverStat { _ in nil }
        let queue = store.coverQueue
        let walk = ThumbsWalk(store: store, queue: queue, client: 7)
        await walk.start(URL(fileURLWithPath: "/p"), location: nil, depth: 0)
        #expect(await eventually { reader.stamps > 0 })
        await queue.pauseAhead(true)
        #expect(await eventually { await queue.aheadWaiterCount >= 1 })
        let stamps = reader.stamps
        try? await Task.sleep(for: .milliseconds(150))
        #expect(reader.stamps <= stamps + ThumbnailStore.maxReads)   // those in flight end; none starts
        await queue.pauseAhead(false)
        await walk.finished()
        #expect(await walk.progress.files == WorkCount(done: 40, total: 40))
        #expect(await queue.aheadWaiterCount == 0)
    }

    /// Home's cards in view on the share go before the walk: the walk's first listing waits for them.
    @Test func homeCardsGoBeforeTheWalk() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader(), tree = FakeTree(reader: reader, latency: 0.05)
        tree.set("/s", photos: 0, folders: ["a"])
        tree.set("/s/a", photos: 0)
        for name in ["h1", "h2", "h3"] { tree.set("/home/" + name, photos: 1) }
        let store = store(reader, dir: dir)
        // A generous time limit: these count listings, which a time out under load would repeat.
        await store.setCoverListing(dated: tree.lister, networkTimeout: .seconds(30))
        await store.setCoverVolumes { _ in true }
        await store.setCoverStat { _ in nil }
        let queue = store.coverQueue
        // The walk first; Home's cards come while its first listing runs, and go before its next one.
        let walk = ThumbsWalk(store: store, queue: queue, client: 7)
        await walk.start(URL(fileURLWithPath: "/s"), location: nil, depth: 1)
        #expect(await eventually { tree.calls.contains("/s") })
        await queue.want(["/home/h1", "/home/h2", "/home/h3"], visible: 3, client: 1, isNetwork: { _ in true }) { id in
            await store.folderCard(URL(fileURLWithPath: id), archive: false, in: nil, network: true, maxPixel: 16) != nil
        }
        await walk.finished()
        #expect(tree.calls == ["/s", "/home/h1", "/home/h2", "/home/h3", "/s/a"])
    }

    /// A share's stamp that waits in the reader's queue (behind the open folders' reads) past the time limit is not a
    /// time out: the share is not noted, and the stamp comes.
    @Test func aQueuedStampIsNoTimeOut() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let inner = ThumbReader()
        inner.add(URL(fileURLWithPath: "/q/0.jpg"), TestJPEGs.gradient(width: 40, height: 30))
        let reader = StampReader(inner, queued: .milliseconds(300))
        let store = store(reader, dir: dir)
        await store.setCoverListing(dated: FakeTree(reader: inner).lister, networkTimeout: .milliseconds(100))
        await store.setCoverVolumes { _ in true }
        await store.setCoverNetworkVolumes { _ in "net:share" }
        for _ in 0..<2 {
            guard case .stamp = await store.walkStamp(URL(fileURLWithPath: "/q/0.jpg"), in: nil) else {
                Issue.record("a queued stamp gave no stamp")
                return
            }
        }
        #expect(await store.coverVolumeTimeouts["net:share"] == nil)
        #expect(!(await store.isOffline("net:share")))
    }

    /// A stamp a thread picked up that then takes longer than the time limit is a time out of the share.
    @Test func aStartedStampTimesOut() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let inner = ThumbReader()
        inner.add(URL(fileURLWithPath: "/q/0.jpg"), TestJPEGs.gradient(width: 40, height: 30))
        let reader = StampReader(inner, holdFrom: 0)
        let store = store(reader, dir: dir)
        await store.setCoverListing(dated: FakeTree(reader: inner).lister, networkTimeout: .milliseconds(100))
        await store.setCoverVolumes { _ in true }
        await store.setCoverNetworkVolumes { _ in "net:share" }
        guard case .notNow(offline: false) = await store.walkStamp(URL(fileURLWithPath: "/q/0.jpg"), in: nil) else {
            Issue.record("a stamp that hangs gave an answer")
            return
        }
        #expect(await store.coverVolumeTimeouts["net:share"] == 1)
        _ = await store.walkStamp(URL(fileURLWithPath: "/q/0.jpg"), in: nil)
        #expect(await store.isOffline("net:share"))
    }

    /// A share's stamps keep to its gate: each has the share's time limit, two time outs make it offline, then only
    /// its probe turn stamps; the walk says it waits, keeps its place, and goes on when the share answers.
    @Test func walkStampsKeepToTheSharesGate() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let inner = ThumbReader(), tree = FakeTree(reader: inner)
        tree.set("/g", photos: 6)
        let reader = StampReader(inner, holdFrom: 0)
        let store = store(reader, dir: dir)
        await store.setCoverListing(dated: tree.lister, networkTimeout: .milliseconds(100))
        await store.setCoverVolumes { _ in true }
        await store.setCoverNetworkVolumes { _ in "net:share" }
        await store.setCoverStat { _ in nil }
        await store.setCoverProbeInterval(.milliseconds(400))
        let walk = ThumbsWalk(store: store, queue: store.coverQueue, client: 7, retryDelay: .milliseconds(20),
                              maxRetryDelay: .milliseconds(50))
        await walk.start(URL(fileURLWithPath: "/g"), location: nil, depth: 0)
        #expect(await eventually { await walk.progress.waiting == ThumbsWalk.waitingForShare })
        #expect(await store.isOffline("net:share"))
        // Offline: stamps only on the probe turn, a few in all, however often the walk asks.
        let stamps = reader.stamps
        try? await Task.sleep(for: .milliseconds(300))
        #expect(reader.stamps <= stamps + 2)
        reader.release()
        await walk.finished()
        let progress = await walk.progress
        #expect(progress.waiting == nil)
        #expect(progress.files == WorkCount(done: 6, total: 6))
        #expect(!(await store.isOffline("net:share")))
    }

    /// A share that does not answer the walk's listing: the walk waits with a note, keeps its place, and goes on when
    /// the share is back.
    @Test func walkWaitsForAnOfflineShare() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let reader = ThumbReader(), tree = FakeTree(reader: reader)
        tree.set("/w", photos: 2)
        tree.offline = true
        let store = store(reader, dir: dir)
        await store.setCoverListing(dated: tree.lister)
        await store.setCoverVolumes { _ in true }
        await store.setCoverNetworkVolumes { _ in "net:share" }
        await store.setCoverStat { _ in
            if tree.offline { throw POSIXError(.ENOTCONN) }
            return nil
        }
        await store.setCoverProbeInterval(.milliseconds(50))
        let queue = CoverQueue(retryDelay: .milliseconds(20), maxRetryDelay: .milliseconds(50))
        let walk = ThumbsWalk(store: store, queue: queue, client: 7)
        await walk.start(URL(fileURLWithPath: "/w"), location: nil, depth: 0)
        #expect(await eventually { await walk.progress.waiting == ThumbsWalk.waitingForShare })
        #expect(await walk.progress.folders.done == 0)
        tree.offline = false
        await walk.finished()
        let progress = await walk.progress
        #expect(progress.waiting == nil)
        #expect(progress.folders == WorkCount(done: 1, total: 1))
        #expect(progress.files == WorkCount(done: 2, total: 2))
    }

    /// A share photo whose stamp failed keeps its catalog row and thumbnail: only names the listing lacks may go.
    @Test func walkKeepsTheRowsOfUnstampedPhotos() async throws {
        let dir = tempDir()
        defer { try? fm.removeItem(at: dir) }
        let inner = ThumbReader(), tree = FakeTree(reader: inner)
        tree.set("/k", photos: 3)
        let all = files("/k", 3)
        let first = ThumbnailStore(directory: dir, reader: inner, thumbSize: 32, limitBytes: 1 << 30,
                                   locate: Self.locate, idleDelay: .zero, commitDelay: .milliseconds(5), decodes: 1)
        await first.setRequest(window: 1, ThumbnailRequest(files: all, current: 0, visible: [], isKey: true),
                               stamps: inner.stamps)
        #expect(await eventually {
            let ready = await Self.allReady(first, all), writes = await first.pendingWrites
            return ready && writes == 0
        })
        await first.setRequest(window: 1, nil, stamps: [:])

        let reader = StampReader(inner)
        reader.fail(all[1])
        let store = store(reader, dir: dir)
        await store.setCoverListing(dated: tree.lister)
        await store.setCoverVolumes { _ in true }
        await store.setCoverStat { _ in nil }
        let walk = ThumbsWalk(store: store, queue: store.coverQueue, client: 7)
        await walk.start(URL(fileURLWithPath: "/k"), location: nil, depth: 0)
        await walk.finished()
        #expect(await store.folderSamples(URL(fileURLWithPath: "/k"), limit: 10).count == 3)
    }
}
