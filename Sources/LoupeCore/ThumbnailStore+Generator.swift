import Foundation

// The generator: up to `readLimit` reads in flight, new ones started only while the viewer cache has been idle
// for `idleDelay` (spec §3.6). A job reads, tells the store its read is over and decodes in `DecodePool` while the
// next job's read runs: on a share the reads are the limit, so the decode is hidden behind them. A job reports
// back through `finish`; its slot stays taken until its task really ends, cancelled or not.

extension ThumbnailStore {
    /// One job beyond the reads or the decodes, whichever are more: on a share a finished read decodes while the next
    /// two run, on a local disk one file waits read for a free decode; no more bytes than that wait.
    var jobLimit: Int { max(readLimit, decodeLimit.slotCount) + 1 }

    var readsInFlight: Int { jobs.values.reduce(0) { $0 + ($1.reading ? 1 : 0) } }

    /// The queue is rebuilt lazily, when the generator next wants a file.
    func replan() {
        queueIsStale = true
        for job in jobs.values where listed[job.url] == nil { cancel(job.token) }   // its folder was replaced or closed
        pump()
    }

    /// Lets a job waiting to read again go first, then starts new ones while reads and jobs are free and the viewer
    /// has been idle long enough.
    func pump() {
        resumeWaitingReads()
        while readsInFlight < readLimit, jobs.count < jobLimit {
            guard activity == .idle, let since = idleSince else { return }
            let waited = ContinuousClock.now - since
            guard waited >= idleDelay else {
                if idleWake == nil {
                    let rest = idleDelay - waited
                    idleWake = Task { [weak self] in
                        guard (try? await Task.sleep(for: rest)) != nil else { return }
                        await self?.idleWoke()
                    }
                }
                return
            }
            guard let url = nextFile(), let stamp = listed[url] else { return }
            start(url, listedStamp: stamp)
        }
    }

    func idleWoke() {
        idleWake = nil
        pump()
    }

    func nextFile() -> URL? {
        if queueIsStale {
            // Files in flight are left out: they come back through `finish` if they stay pending.
            let skip = stored.union(made.keys).union(unavailable).union(evicted).union(jobs.values.map(\.url))
            let requests = windows.sorted { $0.key < $1.key }.map(\.value.request)
            queue = ThumbnailQueue.order(requests, skip: skip)
            queuePosition = 0
            queueIsStale = false
        }
        while queuePosition < queue.count {
            let url = queue[queuePosition]
            queuePosition += 1
            if listed[url] != nil, status(url) == .pending, !evicted.contains(url) { return url }
        }
        return nil
    }

    func start(_ url: URL, listedStamp: FileStamp) {
        nextToken += 1
        let token = nextToken
        let recipe = Recipe(url: url, listedStamp: listedStamp, maxSide: thumbSize, reader: reader,
                            decodeLimit: decodeLimit, decoder: decoder, cachedBytes: cachedBytes,
                            readEnded: { await self.readEnded(token) }, readAgain: { await self.readAgain(token) })
        // Isolated to the store (it uses `self`): `generate` runs off it, `finish` back on it.
        let task = Task(priority: .utility) {
            var timing = Timing()
            let outcome = await Self.generate(recipe, &timing)
            self.finish(token, recipe, outcome, timing)
        }
        jobs[token] = Job(token: token, url: url, task: task)
    }

    /// The job's read returned: its bytes go to the decoder and the read is free for the next file.
    func readEnded(_ token: UInt64) {
        jobs[token]?.reading = false
        pump()
    }

    /// The whole file after a coarse prefix is a read like any other: it waits for a free one (ahead of new jobs),
    /// and not at all while the current photo needs I/O. A cancelled job returns at once and finds its task cancelled.
    func readAgain(_ token: UInt64) async {
        guard let job = jobs[token], !job.cancelled else { return }
        guard activity != .current else { return cancel(token) }
        if readsInFlight < readLimit {
            jobs[token]?.reading = true
            return
        }
        await withCheckedContinuation { readWaiters[token] = $0 }
    }

    func resumeWaitingReads() {
        for token in readWaiters.keys.sorted() where readsInFlight < readLimit {
            jobs[token]?.reading = true
            readWaiters.removeValue(forKey: token)?.resume()
        }
    }

    /// A cancelled job keeps its slot (and its read, if it was reading) until its task ends, so the next read starts
    /// only after the cancelled one has returned (on a share, `FileReader` stops it at the next chunk; a pool thread
    /// already inside a chunk may finish that chunk after the task has gone).
    func cancel(_ token: UInt64) {
        guard let job = jobs[token], !job.cancelled else { return }
        jobs[token]?.cancelled = true
        job.task.cancel()
        readWaiters.removeValue(forKey: token)?.resume()
    }

    func cancelJobs() {
        for token in jobs.keys { cancel(token) }
    }

    /// The jobs reading or waiting to read again; those decoding go on.
    func cancelReads() {
        for job in jobs.values where job.reading || readWaiters[job.token] != nil { cancel(job.token) }
    }

    func finish(_ token: UInt64, _ recipe: Recipe, _ outcome: Outcome, _ timing: Timing) {
        guard let job = jobs.removeValue(forKey: token) else { return }
        let url = recipe.url
        switch outcome {
        case let .made(jpeg, info, stamp):
            // Kept even if cancelled late: the work is done. Not if it is the old size, or the file was
            // listed anew with another stamp meanwhile (it changed: the queue makes it again).
            let relisted = listed[url].map { $0 != recipe.listedStamp } ?? false
            if recipe.maxSide == thumbSize, !relisted { add(url, Made(jpeg: jpeg, info: info, stamp: stamp)) }
            log?("thumb \(url.lastPathComponent): read \(Self.ms(timing.read)) ms (\(timing.source)), "
                 + "decode \(Self.ms(timing.decode)) ms")
        case .failed:
            if !job.cancelled {
                unavailable.insert(url)
                onThumbnail?(url)
            }
            log?("thumb \(url.lastPathComponent): failed after read \(Self.ms(timing.read)) ms")
        case .cancelled:
            break
        }
        // Not made after all (cancelled, or a result dropped above): back in the queue, which left it out while
        // the job ran.
        if status(url) == .pending { queueIsStale = true }
        pump()
    }

    func add(_ url: URL, _ thumbnail: Made) {
        setMade(url, thumbnail)
        cells.remove(url)
        unavailable.remove(url)
        missed.remove(url)
        // A file that changed after its listing (the read saw another stamp) stays in memory only: the
        // catalog row still has the listing's stamp, and `put` would skip it.
        if case .open = disk, ids[url] != nil, listed[url] == thumbnail.stamp {
            uncommitted.insert(url)
            if uncommitted.count >= Self.batchSize { commit() } else { scheduleCommit() }
        }
        enforceMemoryCap()   // after `uncommitted`, which the cap leaves alone
        onThumbnail?(url)
    }

    /// Everything a job needs, so it runs without touching the actor (but for telling it where its reads stand).
    struct Recipe: Sendable {
        let url: URL
        let listedStamp: FileStamp
        let maxSide: Int
        let reader: any FileReading
        let decodeLimit: DecodePool
        let decoder: @Sendable (Data) -> any ImageDecoder
        let cachedBytes: @Sendable (URL, FileStamp) async -> Data?
        let readEnded: @Sendable () async -> Void
        let readAgain: @Sendable () async -> Void
    }

    /// Where a job's time went, for the `log` line. Each includes its wait (for a `FileReader` thread, a decode slot).
    struct Timing: Sendable {
        var read = Duration.zero
        var decode = Duration.zero
        /// "cached" (the viewer's bytes), "prefix", "full" or "prefix+full".
        var source = "cached"
    }

    /// Makes one thumbnail from the cheapest source (spec §3.4; the database was checked by the queue):
    /// the viewer's bytes, else one read that a progressive JPEG ends at its DC scans; when that prefix
    /// cannot give a sharp thumbnail, the whole file after all.
    static func generate(_ r: Recipe, _ t: inout Timing) async -> Outcome {
        do {
            if let data = await r.cachedBytes(r.url, r.listedStamp) {
                await r.readEnded()
                let (jpeg, info) = try await decode(r, &t) { try ThumbnailMaker.make(from: data, decoder: r.decoder(data).forRole(.other), maxSide: r.maxSide) }
                return .made(jpeg: jpeg, info: info, stamp: r.listedStamp)
            }
            if let outcome = try await fromFirstRead(r, &t) { return outcome }
            await r.readAgain()
            try Task.checkCancellation()
            let start = ContinuousClock.now
            let bytes = try await r.reader.read(r.url, priority: ReadPriority(readPriority, isBackground: true))
            t.read += ContinuousClock.now - start
            t.source = "prefix+full"
            await r.readEnded()
            let data = bytes.data
            let (jpeg, info) = try await decode(r, &t) { try ThumbnailMaker.make(from: data, decoder: r.decoder(data).forRole(.other), maxSide: r.maxSide) }
            return .made(jpeg: jpeg, info: info, stamp: bytes.stamp)
        } catch {
            return Task.isCancelled || error is CancellationError ? .cancelled : .failed
        }
    }

    /// The thumbnail from `readPrefix`, or nil when it stopped at a prefix too coarse for one. Its own
    /// function so the prefix is released before the whole file is read.
    static func fromFirstRead(_ r: Recipe, _ t: inout Timing) async throws -> Outcome? {
        let start = ContinuousClock.now
        let bytes = try await r.reader.readPrefix(r.url, priority: ReadPriority(readPriority, isBackground: true),
                                                  isEnough: { ThumbnailMaker.isPrefixEnough($0) })
        t.read += ContinuousClock.now - start
        await r.readEnded()
        let data = bytes.data, stamp = bytes.stamp
        if data.count >= stamp.size {
            t.source = "full"
            let (jpeg, info) = try await decode(r, &t) { try ThumbnailMaker.make(from: data, decoder: r.decoder(data).forRole(.other), maxSide: r.maxSide) }
            return .made(jpeg: jpeg, info: info, stamp: stamp)
        }
        t.source = "prefix"
        let made = try await decode(r, &t) { () -> (Data, ImageInfo)? in
            guard let header = try? r.decoder(data).probe(data) else { return nil }
            let info = ImageInfo(pixelSize: header.pixelSize, typeIdentifier: header.typeIdentifier,
                                 isProgressive: header.isProgressive, fileSize: stamp.size,
                                 colorSpaceName: header.colorSpaceName, orientation: header.orientation)
            guard ThumbnailMaker.prefixIsSharpEnough(info, maxSide: r.maxSide) else { return nil }
            let jpeg = ImageFormat.detect(data) == .jxl
                ? try? ThumbnailMaker.makeFromJXLPrefix(data, fullSize: info, maxSide: r.maxSide)
                : try? ThumbnailMaker.makeFromPrefix(data, fullSize: info, maxSide: r.maxSide)
            guard let jpeg else { return nil }
            return (jpeg, info)
        }
        return made.map { .made(jpeg: $0.0, info: $0.1, stamp: stamp) }
    }

    /// In the store's own decode pool, apart from the viewer's.
    static func decode<T: Sendable>(_ r: Recipe, _ t: inout Timing, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        let start = ContinuousClock.now
        defer { t.decode += ContinuousClock.now - start }
        return try await r.decodeLimit.run(forCurrent: false, rank: readPriority, work)
    }

    static func ms(_ d: Duration) -> Int {
        Int((Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15).rounded())
    }
}
