import CoreGraphics
import Foundation
import HomeScreenModel

/// Home's card covers (Home spec §2.5): the thumbnail of a file whose folder no window lists, from the catalog without
/// opening the folder, else made from the file and kept in the database like any thumbnail.
extension ThumbnailStore {
    /// The cover of `url` at most `maxPixel` on its long side; nil when the file cannot be read. A folder some window
    /// lists answers from the strip's thumbnails; else a stored thumbnail whose stamp is still the file's; else one
    /// made now, one at a time, behind every viewer read.
    public func cover(_ url: URL, maxPixel: Int) async -> CGImage? {
        if ids[url] != nil, let cell = await cell(url, maxPixel: maxPixel) { return cell }
        let locate = self.locate
        // `resolve` may block on a slow share: never on the actor.
        let location = await Self.offActor { locate(url) }
        guard let stamp = try? await reader.stamp(url, priority: ReadPriority.background) else { return nil }
        if let location, let row = perform("cover", { try $0.file(at: location) }) ?? nil, row.stamp == stamp,
           let stored = perform("cover", { try $0.thumbnail(row.id) }) ?? nil {
            return await Self.offActor { ThumbnailMaker.decodeCell(stored.jpeg, maxPixel: maxPixel) }
        }
        try? await coverLimit.acquireSlot(forCurrent: false, rank: Self.readPriority)
        defer { coverLimit.releaseSlot(forCurrent: false) }
        let recipe = Recipe(url: url, listedStamp: stamp, maxSide: thumbSize, reader: reader,
                            decodeLimit: decodeLimit, decoder: decoder, cachedBytes: cachedBytes,
                            readEnded: {}, readAgain: {})
        var timing = Timing()
        guard case .made(let jpeg, let info, let madeStamp) = await Self.generate(recipe, &timing) else { return nil }
        if let location {
            _ = perform("cover") { db in
                let id = try db.addFile(location, stamp: madeStamp)
                try db.put([(id, madeStamp, jpeg, info)])
            }
        }
        return await Self.offActor { ThumbnailMaker.decodeCell(jpeg, maxPixel: maxPixel) }
    }

    /// The file browser's folder cards (file browser spec §4.2): how many photos the catalog knows in each folder, from
    /// rows earlier listings left; a folder never listed has no count (it is not listed for one).
    public func knownCounts(_ folders: [URL]) async -> [URL: Int] {
        let locate = self.locate
        var counts: [URL: Int] = [:]
        for folder in folders {
            // `resolve` may block on a slow share: never on the actor.
            guard let location = await Self.offActor({ locate(folder.appendingPathComponent("_")) }),
                  let count = perform("counts", { try $0.fileCount(in: location) }) ?? nil else { continue }
            counts[folder] = count
        }
        return counts
    }

    /// A folder card's mosaic (file browser, second round): up to `limit` photos of the folder that already have a
    /// thumbnail, by name, from the catalog alone — no listing and no read of the folder, which on a slow share would
    /// queue in front of what the user clicked.
    public func folderSamples(_ folder: URL, limit: Int) async -> [URL] {
        let locate = self.locate
        guard let location = await Self.offActor({ locate(folder.appendingPathComponent("_")) }),
              let names = perform("samples", { try $0.namesWithThumbnails(in: location, limit: limit) }) else { return [] }
        return names.map { folder.appendingPathComponent($0) }
    }

    /// The stored thumbnail of `url` at most `maxPixel` on its long side, from the catalog alone: no stat and no read
    /// of the file (a folder card's mosaic on a slow share). Nil when the catalog has none; it may be older than the
    /// file, which only a folder card can afford.
    public func catalogThumbnail(_ url: URL, maxPixel: Int) async -> CGImage? {
        let locate = self.locate
        guard let location = await Self.offActor({ locate(url) }),
              let row = perform("catalog", { try $0.file(at: location) }) ?? nil,
              let stored = perform("catalog", { try $0.thumbnail(row.id) }) ?? nil else { return nil }
        return await Self.offActor { ThumbnailMaker.decodeCell(stored.jpeg, maxPixel: maxPixel) }
    }
}

/// What a folder's (or a zip's) listing gives a cover: its photos' names (a zip's entries as one path component each,
/// "caps∕0001.jpg") and its subfolders' names, in listing order.
public struct CoverNames: Equatable, Sendable {
    public var files: [String]
    public var folders: [String]

    public init(files: [String], folders: [String]) {
        self.files = files
        self.folders = folders
    }
}

/// Home's folder and archive covers made in the background (folder covers spec): `coverQueue` runs `folderCover` for a
/// few cards at a time.
extension ThumbnailStore {
    /// Lists `folder` (a zip's directory when `archive`), blocking. Now and then `part` gets the names so far; false
    /// from it stops the listing (thrown or returned, either will do).
    typealias CoverLister = @Sendable (_ folder: URL, _ archive: Bool,
                                       _ part: @escaping @Sendable (CoverNames) -> Bool) throws -> CoverNames

    /// How long a cover's listing on a share may take: what came by then is what the photos are picked from, so a
    /// folder of thousands of files on a slow share holds its place in the queue no longer than this.
    public static let coverListingTimeout: Duration = .seconds(2)
    /// Covers' reads and decodes go behind the open folders' thumbnails (`readPriority`) in the reader's queue and
    /// the decode slots.
    public static let coverReadPriority = readPriority + 1
    /// Thumbnails a cover makes at most: the four of a folder's mosaic.
    static let coverPhotos = 4
    /// Subfolders looked into below a folder without photos: its own, and theirs.
    static let coverDepth = 2
    /// Listing threads at most, those given up on (hung on a dead share) included: past that no cover lists until
    /// one returns (its card stays empty), so a share that hangs costs a few threads, not one per card. One more than
    /// `CoverQueue`'s limits together, so one hung listing leaves the others their threads.
    static let coverListingThreads = 4
    /// The listing's thread: background work, below the viewer's and the open folders' thumbnails.
    static let coverQoS = DispatchQoS.QoSClass.utility

    /// Tests: a fake listing, and the share's time limit.
    func setCoverListing(_ lister: @escaping CoverLister, networkTimeout: Duration = coverListingTimeout) {
        coverLister = lister
        coverNetworkTimeout = networkTimeout
    }

    /// The pictures of a folder's or zip's card, at most `maxPixel` on their long side: up to four photos spread across
    /// it (the one last viewed there first), from the catalog when it has four of the folder, else from a listing of
    /// names (limited to `coverListingTimeout` on a share) whose picks are made into thumbnails and kept in the
    /// catalog, like `cover`'s. A folder without photos shows one of each of its first four subfolders' (two levels
    /// down at most). Empty when there is nothing to show; a folder found empty is not listed again this session.
    /// Cancelling the task stops the listing and the reads.
    public func folderCover(_ folder: URL, archive: Bool, maxPixel: Int, lastViewed: String? = nil) async -> [CGImage] {
        await folderCover(folder, archive: archive, maxPixel: maxPixel, lastViewed: lastViewed,
                          count: Self.coverPhotos, depth: 0)
    }

    private func folderCover(_ folder: URL, archive: Bool, maxPixel: Int, lastViewed: String?, count: Int,
                             depth: Int) async -> [CGImage] {
        guard !emptyCovers.contains(folder.standardizedFileURL.path), !Task.isCancelled else { return [] }
        let locate = self.locate
        // `resolve` may block on a slow share: never on the actor.
        let location = await Self.offActor(qos: Self.coverQoS) { locate(folder.appendingPathComponent("_")) }
        if let location, let names = perform("cover", { try $0.namesWithThumbnails(in: location, limit: count) }),
           names.count >= count {
            var images: [CGImage] = []
            for name in names where !Task.isCancelled {
                let file = ThumbnailLocation(volume: location.volume, folder: location.folder, name: name)
                if let image = await storedCell(at: file, maxPixel: maxPixel) { images.append(image) }
            }
            return images
        }
        // An unknown volume may be a share that does not answer: limited like one.
        let isNetwork = location.map { $0.volume.hasPrefix("net:") } ?? true
        let timeout = isNetwork ? coverNetworkTimeout : nil
        guard let (names, complete) = await coverNames(folder, archive: archive, timeout: timeout) else { return [] }
        let photos = names.files.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let folders = names.folders.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        switch CoverSampling.plan(names: photos, directories: folders, lastViewed: lastViewed) {
        case .photos(let picked):
            var images: [CGImage] = []
            for name in picked.prefix(count) {
                guard !Task.isCancelled else { break }
                let file = location.map { ThumbnailLocation(volume: $0.volume, folder: $0.folder, name: name) }
                if let image = await coverCell(folder.appendingPathComponent(name), at: file, maxPixel: maxPixel) {
                    images.append(image)
                }
            }
            return images
        case .subfolders(let subfolders):
            guard depth < Self.coverDepth else { return [] }
            var images: [CGImage] = []
            for name in subfolders where images.count < count && !Task.isCancelled {
                let sub = folder.appendingPathComponent(name, isDirectory: true)
                // One picture of each: the subfolder's own card makes the rest when it is shown.
                images += await folderCover(sub, archive: false, maxPixel: maxPixel, lastViewed: nil, count: 1,
                                            depth: depth + 1).prefix(1)
            }
            let paths = subfolders.map { folder.appendingPathComponent($0).standardizedFileURL.path }
            if complete, paths.allSatisfy(emptyCovers.contains) { emptyCovers.insert(folder.standardizedFileURL.path) }
            return images
        case .empty:
            if complete { emptyCovers.insert(folder.standardizedFileURL.path) }
            return []
        }
    }

    /// The catalog's thumbnail of the file at `location` as a cell, however old (a card can afford it); nil when it
    /// has none.
    private func storedCell(at location: ThumbnailLocation, maxPixel: Int) async -> CGImage? {
        guard let row = perform("cover", { try $0.file(at: location) }) ?? nil,
              let stored = perform("cover", { try $0.thumbnail(row.id) }) ?? nil else { return nil }
        return await Self.offActor(qos: Self.coverQoS) { ThumbnailMaker.decodeCell(stored.jpeg, maxPixel: maxPixel) }
    }

    /// One photo of a cover: the strip's thumbnail when a window lists its folder, else the catalog's, else one made
    /// now, behind the open folders' thumbnails, and kept in the catalog.
    private func coverCell(_ url: URL, at location: ThumbnailLocation?, maxPixel: Int) async -> CGImage? {
        if ids[url] != nil || made[url] != nil, let cell = await cell(url, maxPixel: maxPixel) { return cell }
        if let location, let stored = await storedCell(at: location, maxPixel: maxPixel) { return stored }
        // No stamp is asked for (a stat queues like a read): the read brings the file's, and no viewer bytes are
        // looked up, so the listed stamp is never used.
        let recipe = Recipe(url: url, listedStamp: FileStamp(modified: .distantPast, size: 0), maxSide: thumbSize,
                            reader: reader, decodeLimit: decodeLimit, decoder: decoder, cachedBytes: { _, _ in nil },
                            readEnded: {}, readAgain: {}, rank: Self.coverReadPriority)
        var timing = Timing()
        guard case .made(let jpeg, let info, let stamp) = await Self.generate(recipe, &timing) else { return nil }
        log?("cover \(url.lastPathComponent): read \(Self.ms(timing.read)) ms (\(timing.source)), "
             + "decode \(Self.ms(timing.decode)) ms")
        if let location, perform("cover", { db -> Bool in
            let id = try db.addFile(location, stamp: stamp)
            try db.put([(id, stamp, jpeg, info)])
            return true
        }) == true {
            storedBytes += jpeg.count
            if storedBytes > limitBytes { enforceLimit() }
        }
        return await Self.offActor(qos: Self.coverQoS) { ThumbnailMaker.decodeCell(jpeg, maxPixel: maxPixel) }
    }

    /// `folder`'s names from `coverLister` on a thread of its own: all of them (`complete`), or those it had when
    /// `timeout` ran out or the task was cancelled. Nil when it cannot be listed, or too many listings still hang.
    func coverNames(_ folder: URL, archive: Bool, timeout: Duration?) async -> CoverListing.Answer? {
        guard coverListings.enter() else { return nil }
        let listing = CoverListing(), lister = coverLister, threads = coverListings
        DispatchQueue.global(qos: Self.coverQoS).async {
            let result = Result { try lister(folder, archive) { listing.part($0) } }
            threads.leave()
            listing.finish(result)
        }
        enum Race: Sendable {
            case listed(CoverListing.Answer?)
            case timedOut
        }
        return await withTaskGroup(of: Race.self, returning: CoverListing.Answer?.self) { group in
            group.addTask { .listed(await listing.value()) }
            if let timeout {
                group.addTask {
                    try? await Task.sleep(for: timeout)
                    return .timedOut
                }
            }
            // Whichever comes first: the timer stops the listing, whose answer is then what it had so far.
            while let first = await group.next() {
                listing.stop()
                group.cancelAll()
                if case .listed(let answer) = first { return answer }
            }
            return nil
        }
    }

    /// The real listing: a folder's names without a stat (`BrowserListingSource.names`), a zip's photo entries from
    /// one read of its directory. Photos (by extension) and folders; hidden names left out.
    @Sendable static func listCoverNames(_ folder: URL, archive: Bool,
                               part: @escaping @Sendable (CoverNames) -> Bool) throws -> CoverNames {
        if archive || ArchivePath.isArchive(folder) {
            let entries = try ArchiveReader.shared.entries(of: folder)
            return CoverNames(files: entries.map(\.url.lastPathComponent), folders: [])
        }
        func names(_ entries: [BrowserEntry]) -> CoverNames {
            CoverNames(files: entries.filter { $0.kind == .file }.map(\.name),
                       folders: entries.filter { $0.kind == .folder }.map(\.name))
        }
        // Parts every 100 ms at most: what a time limit finds is never older than that.
        return names(try BrowserListingSource.names(folder, archives: false, partEvery: 64,
                                                    partAfter: .milliseconds(100)) { part(names($0)) })
    }
}

/// One cover's listing, between its thread and the task waiting for it: the names so far, how it ended, and whether
/// the waiter gave up on it (the thread then stops at its next part).
final class CoverListing: @unchecked Sendable {
    /// The names, and whether the listing ran to its end.
    typealias Answer = (CoverNames, complete: Bool)

    private let lock = NSLock()
    private var latest: CoverNames?
    private var outcome: Result<CoverNames, Error>?
    private var stopped = false
    private var waiter: CheckedContinuation<Answer?, Never>?

    /// From the listing's thread: false once the waiter gave up.
    func part(_ names: CoverNames) -> Bool {
        lock.withLock {
            guard !stopped else { return false }
            latest = names
            return true
        }
    }

    func finish(_ result: Result<CoverNames, Error>) {
        let (waiter, answer) = lock.withLock { () -> (CheckedContinuation<Answer?, Never>?, Answer?) in
            outcome = result
            defer { self.waiter = nil }
            return (self.waiter, answerLocked())
        }
        waiter?.resume(returning: answer)
    }

    /// The waiter gives up: it gets the names so far now.
    func stop() {
        let (waiter, answer) = lock.withLock { () -> (CheckedContinuation<Answer?, Never>?, Answer?) in
            stopped = true
            defer { self.waiter = nil }
            return (self.waiter, answerLocked())
        }
        waiter?.resume(returning: answer)
    }

    /// All the names once the listing ended, else those so far once `stop` was called or the task cancelled; nil when
    /// the listing failed with nothing so far.
    func value() async -> Answer? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Answer?, Never>) in
                let answer = lock.withLock { () -> Answer?? in
                    guard outcome != nil || stopped else {
                        waiter = continuation
                        return nil
                    }
                    return .some(answerLocked())
                }
                if let answer { continuation.resume(returning: answer) }
            }
        } onCancel: {
            stop()
        }
    }

    private func answerLocked() -> Answer? {
        if case .success(let names) = outcome { return (names, true) }
        return latest.map { ($0, false) }
    }
}

/// Counts the threads in a cover's listing, up to `limit`.
final class CoverListingThreads: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var count = 0

    init(limit: Int) { self.limit = limit }

    func enter() -> Bool {
        lock.withLock {
            guard count < limit else { return false }
            count += 1
            return true
        }
    }

    func leave() { lock.withLock { count -= 1 } }
}
