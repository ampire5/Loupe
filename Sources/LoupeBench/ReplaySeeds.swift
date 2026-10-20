import Darwin
import Foundation
import LoupeCore
import LoupeRender

// `replay --seed`: the stored thumbnails a strip jump seeds its landing from (M2.5 spec §5.1), as in the app once a
// folder's thumbnails are made. Before the run, untimed, a ThumbnailStore makes every thumbnail of the playlist into
// databases in a fresh temporary directory (never under /Volumes; deleted after the run), reading with F_NOCACHE so
// the client's page cache keeps none of the photos the run reads. Each script then gets a new store over those
// databases, sharing the replay's reader and decode pool as the app's store shares the viewer's: seeds come from
// Thumbs.db, as after a restart.

/// The prefilled thumbnail databases of a `--seed` replay.
struct ReplaySeeds {
    let directory: URL
    let files: [URL]
    let stamps: [URL: FileStamp]
    let thumbSize: Int
    /// Files whose thumbnail the prefill made (the others have none to seed).
    let ready: Int
    let prefillSeconds: Double

    /// Makes the thumbnails of `files` the way the app does with the viewer idle, and waits until each is made or
    /// failed (at most 60 s plus 5 s per file).
    static func prefill(files: [URL], thumbSize: Int) async -> ReplaySeeds {
        var stamps: [URL: FileStamp] = [:]
        for url in files {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize, let modified = values.contentModificationDate else { fail("cannot stat \(url.path)") }
            stamps[url] = FileStamp(modified: modified, size: size)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-replay-seeds-\(UUID().uuidString)")
        if directory.standardizedFileURL.path.hasPrefix("/Volumes/") { fail("refusing to write under /Volumes: \(directory.path)") }
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) } catch {
            fail("cannot create \(directory.path): \(error)")
        }
        let reader = FileReader(threads: 4, chunkReader: { fd, buffer, count, offset in
            if offset == 0 { _ = fcntl(fd, F_NOCACHE, 1) }
            return FileReader.pread(fd, buffer, count, offset)
        })
        let store = ThumbnailStore(directory: directory, reader: reader, pool: DecodePool(), thumbSize: thumbSize,
                                   limitBytes: 2 << 30, idleDelay: .zero)
        let resolved = LockedLines()
        await store.setOnThumbnail { resolved.add($0.path) }
        let start = ContinuousClock.now
        await store.setRequest(window: 1, ThumbnailRequest(files: files, current: 0, visible: [], isKey: true), stamps: stamps)
        let deadline = start + .seconds(60 + 5 * files.count)
        while Set(resolved.all).count < files.count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let seconds = msSince(start) / 1000
        var ready = 0
        for url in files {
            if await store.status(url) == .ready { ready += 1 }
        }
        await store.setRequest(window: 1, nil, stamps: [:])   // the last batch goes to the database
        return ReplaySeeds(directory: directory, files: files, stamps: stamps, thumbSize: thumbSize, ready: ready,
                           prefillSeconds: seconds)
    }

    /// A store over the prefilled databases, told the playlist (window 1) and the cache's activity as the app's is
    /// (AppDelegate.connect, ViewerSession.sendThumbnailRequest): with every thumbnail made it reads nothing.
    /// `close` ends it.
    func store(cache: ImageCache<MetalPyramidLoader>, reader: any FileReading, pool: DecodePool) async -> ReplaySeedStore {
        let store = ThumbnailStore(directory: directory, reader: reader, pool: pool, thumbSize: thumbSize,
                                   limitBytes: 2 << 30, cachedBytes: { await cache.cachedBytes($0, stamp: $1) })
        let (activities, sink) = AsyncStream.makeStream(of: CacheActivity.self)
        await cache.setOnActivity { sink.yield($0) }
        Task { for await activity in activities { await store.setViewerActivity(activity) } }
        await store.setRequest(window: 1, ThumbnailRequest(files: files, current: 0, visible: [], isKey: true), stamps: stamps)
        return ReplaySeedStore(store: store, activity: sink)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// One script's thumbnail store and its activity feed.
struct ReplaySeedStore {
    let store: ThumbnailStore
    let activity: AsyncStream<CacheActivity>.Continuation

    func close(_ cache: ImageCache<MetalPyramidLoader>) async {
        await cache.setOnActivity { _ in }
        activity.finish()
        await store.setRequest(window: 1, nil, stamps: [:])
    }
}
