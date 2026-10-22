import Foundation

// Reads and decode jobs. Each runs as a Task on the actor; every await (read, decode slot, upload) hands the
// actor back, and on resumption the job re-checks that its entry was not reset. A stage (probe, decode) only
// starts while the goal is still planned; a result already decoded when its goal left the plan is uploaded if it
// fits `cache-memory` and dropped otherwise (spec §11.1).

extension ImageCache {
    /// The read of `url` in flight, started if needed: one per entry, shared by every job that needs the bytes.
    /// The read is queued at `readPriority` and moved as the plan changes (`reconcile`) through a priority box the
    /// reader shares, so a move made before the read reaches the reader's queue still counts.
    func readTask(_ url: URL, _ e: CacheEntry<Pyramid>) -> Task<Data, Error> {
        if let read = e.read { return read }
        e.readID += 1
        let priority = ReadPriority(readPriority(url))
        e.readPriority = priority
        let id = e.readID
        let task = Task<Data, Error> {
            let start = ContinuousClock.now
            do {
                emit(url, .readRequested, priority: priority.value)
                let bytes = try await reader.read(url, priority: priority)
                if entries[url] === e && e.readID == id {
                    emit(url, .readDelivered)
                    e.read = nil
                    e.data = bytes.data
                    e.stamp = bytes.stamp
                    e.timings.readMs = start.millisecondsElapsed
                    notify(url)
                    reconcile()
                }
                return bytes.data
            } catch {
                if entries[url] === e && e.readID == id {
                    e.read = nil
                    if !(error is CancellationError) && !Task.isCancelled {
                        e.failure = LoadErrorText.message(name: url.lastPathComponent, error: error, size: nil)
                        notify(url)
                        reconcile()
                    } else {
                        updateActivity()
                    }
                }
                throw error
            }
        }
        e.read = task
        return task
    }

    /// Where `url`'s read queues: the current photo and its pair's other page first (0, `isCurrent`), a neighbour at
    /// its first position in the plan (the current photo's items come first, so that is never 0), anything unplanned
    /// last.
    func readPriority(_ url: URL) -> Int {
        isCurrent(url) ? 0 : planned[url]?.values.min() ?? Int.max
    }

    /// Moves a read in flight to its rank in the latest plan (the current photo's to the front), when that changed.
    /// A read already on a reader thread is not affected; one still queued, or on its way to the queue, is.
    func reprioritizeRead(_ url: URL, _ e: CacheEntry<Pyramid>) {
        guard e.read != nil, let box = e.readPriority else { return }
        let priority = readPriority(url)
        guard priority != box.value else { return }
        box.value = priority
        emit(url, .readReprioritized, priority: priority)
    }

    func launch(_ url: URL, _ e: CacheEntry<Pyramid>, _ goal: CacheGoal) {
        nextJobID += 1
        runningJobs += 1
        let id = nextJobID
        let phase = JobPhase(forCurrent: isCurrent(url))
        let task = Task {
            await runJob(url, e, goal, phase: phase)
            if e.jobs[goal]?.id == id { e.jobs[goal] = nil }
            runningJobs -= 1
            reconcile()
        }
        e.jobs[goal] = CacheJob(id: id, task: task, phase: phase)
        emit(url, .jobLaunched, goal)
    }

    /// Not cancelled (restarted, or reset) and the entry not reset: a result in hand may still be uploaded.
    private func isAlive(_ url: URL, _ e: CacheEntry<Pyramid>) -> Bool {
        !Task.isCancelled && entries[url] === e
    }

    /// Alive and the goal still planned: worth starting the next stage. A busy job is not cancelled when its goal
    /// leaves the plan (it may come back), so the plan is checked here.
    private func isWanted(_ url: URL, _ e: CacheEntry<Pyramid>, _ goal: CacheGoal) -> Bool {
        isAlive(url, e) && planned[url]?[goal] != nil
    }

    /// The priority to queue with, read live right before each `pool.run`: whether the photo is current now,
    /// and the goal's position in the latest plan. Marks the job as waiting (restartable) in that class.
    private func priority(_ url: URL, _ goal: CacheGoal, _ phase: JobPhase) -> (forCurrent: Bool, rank: Int) {
        let forCurrent = isCurrent(url)
        phase.markWaiting(forCurrent: forCurrent)
        return (forCurrent, planned[url]?[goal] ?? Int.max)
    }

    /// read → probe → (first look) → decode → upload, for one (url, goal) with goal `coarse`, `preview` or `full`.
    private func runJob(_ url: URL, _ e: CacheEntry<Pyramid>, _ goal: CacheGoal, phase: JobPhase) async {
        do {
            let data: Data
            if let cached = e.data {
                data = cached
            } else {
                data = try await readTask(url, e).value
            }
            guard isWanted(url, e, goal) else { return }

            let (decoder, info) = try await probe(url, e, goal, data, phase: phase)
            guard isWanted(url, e, goal) else { return }
            // A level beyond Metal's texture-array limit is refused from the header, before any pixel is decoded.
            guard TileGrid.fitsTextureArrays(info.pixelSize) else { throw DecodeError.tooLarge }
            let l = levels(info, url)

            // The current photo's first look (progressive JPEG): a coarse picture within tens of ms.
            if goal == .preview && isCurrent(url) && !isSatisfied(url, e, .preview) {
                let start = ContinuousClock.now
                let p = priority(url, goal, phase)
                let trace = self.trace
                let lookDecoder = decoder.forRole(p.forCurrent ? .current : .other)
                emit(url, .lookWait, goal)
                let look = try? await pool.run(forCurrent: p.forCurrent, rank: p.rank) {
                    phase.markBusy()
                    trace?(CacheTraceEvent(url: url, kind: .lookStart, goal: goal))
                    return try lookDecoder.firstLook(data, info: info)
                }
                emit(url, .lookDone, goal, level: (look ?? nil)?.level)
                guard isAlive(url, e) else { return }
                // Over the thumbnail only if at least as sharp: the preview decode follows anyway.
                let seededLevel = e.seeded ? e.pyramid.flatMap { loader.finestResidentLevel(of: $0) } : nil
                if let look = look ?? nil, look.level <= seededLevel ?? Int.max {
                    e.timings.firstLookMs = start.millisecondsElapsed
                    notify(url)
                    try await upload(look, url, e, goal, grid: l.grid, phase: phase)
                }
                guard isWanted(url, e, goal) else { return }
            }
            guard !isSatisfied(url, e, goal) else { return }

            let wanted = goal == .coarse ? l.coarse : goal == .preview ? l.lfit : 0
            let start = ContinuousClock.now
            let p = priority(url, goal, phase)
            let trace = self.trace
            // Neighbours decode with fewer libjxl threads, leaving the current photo room (`jxl-threads-other`).
            let roleDecoder = decoder.forRole(p.forCurrent ? .current : .other)
            emit(url, .decodeWait, goal)
            // At most two progressive full decodes, one reserved for the current photo (spec §11.1.6); the gate is
            // taken before the decode slot, so a job waiting for it holds no slot, and is released as soon as the
            // decode (and its buffers) is done. Previews made from a full decode (JXL without a DC image: ~590 MB of
            // buffer at 147 MP) go through the same gate.
            let serial = goal == .full ? info.isProgressive
                                       : roleDecoder.previewNeedsFullDecode(data, info: info, level: wanted)
            if serial { try await progressiveFull.acquireSlot(forCurrent: p.forCurrent, rank: p.rank) }
            let image: LevelImage
            do {
                image = try await pool.run(forCurrent: p.forCurrent, rank: p.rank) { () throws -> LevelImage in
                    phase.markBusy()
                    trace?(CacheTraceEvent(url: url, kind: .decodeStart, goal: goal))
                    if goal == .full { return LevelImage(image: try roleDecoder.decodeFull(data, info: info), level: 0) }
                    return try roleDecoder.preview(data, info: info, level: wanted)
                }
            } catch {
                if serial { progressiveFull.releaseSlot(forCurrent: p.forCurrent) }
                throw error
            }
            if serial { progressiveFull.releaseSlot(forCurrent: p.forCurrent) }
            emit(url, .decodeDone, goal, level: image.level)
            guard isAlive(url, e) else { return }
            // Coarser than asked would leave the goal unmet and the job restarting forever.
            guard image.level <= wanted, image.level < l.grid.levelCount else { throw DecodeError.unreadable }
            if goal == .full { e.timings.fullMs = start.millisecondsElapsed } else { e.timings.previewMs = start.millisecondsElapsed }
            notify(url)
            try await upload(image, url, e, goal, grid: l.grid, phase: phase)
        } catch {
            guard !(error is CancellationError), isWanted(url, e, goal), e.failure == nil else { return }
            e.failure = LoadErrorText.message(name: url.lastPathComponent, error: error, size: e.info?.pixelSize)
            notify(url)
        }
    }

    /// The entry's decoder and header, probing on a decode slot the first time.
    private func probe(_ url: URL, _ e: CacheEntry<Pyramid>, _ goal: CacheGoal, _ data: Data,
                       phase: JobPhase) async throws -> (any ImageDecoder, ImageInfo) {
        if let decoder = e.decoder, let info = e.info { return (decoder, info) }
        let makeDecoder = self.makeDecoder
        let p = priority(url, goal, phase)
        let trace = self.trace
        emit(url, .probeWait, goal)
        let probed = try await pool.run(forCurrent: p.forCurrent, rank: p.rank) { () throws -> Probed in
            phase.markBusy()
            trace?(CacheTraceEvent(url: url, kind: .probeStart, goal: goal))
            let decoder = makeDecoder(data)
            return Probed(decoder: decoder, info: try decoder.probe(data))
        }
        emit(url, .probeDone, goal)
        // Another job of the entry may have probed meanwhile; either result is the same header.
        guard entries[url] === e else { throw CancellationError() }
        if e.decoder == nil {
            // A seeded entry's header came from the thumbnail's catalog row: another size or type means the file was
            // replaced since, so the entry starts over (like a changed stamp) from the bytes just read, which are
            // the new file's.
            if let seeded = e.info, !Self.sameFile(seeded, probed.info) {
                reset(url)
                if let fresh = entries[url] {
                    fresh.data = e.data ?? data
                    fresh.stamp = e.stamp
                    fresh.timings.readMs = e.timings.readMs
                }
                reconcile()
                throw CancellationError()
            }
            let known = e.info != nil
            e.decoder = probed.decoder
            e.info = probed.info
            notify(url)
            // The real size changes the plan (costs, Lfit); this may cancel or unplan the job itself.
            if !known { reconcile() }
        }
        return (e.decoder ?? probed.decoder, e.info ?? probed.info)
    }

    /// Uploads `image` unless something at least as sharp is already resident. The levels it builds are reserved
    /// in `usedBytes` (with a graphics tier, in `usedGraphicsBytes`) while it runs. A planned goal first makes room
    /// (evicting unplanned state farthest first: with a graphics tier other pyramids' levels, never files); an
    /// unplanned one (it left the plan while decoding) is uploaded only if it fits as things stand, else dropped.
    /// Afterwards whatever no longer fits is evicted (a preview finer than planned, say, when memory is short).
    private func upload(_ image: LevelImage, _ url: URL, _ e: CacheEntry<Pyramid>, _ goal: CacheGoal,
                        grid: TileGrid, phase: JobPhase) async throws {
        guard isAlive(url, e) else { return }
        // While the entry shows the thumbnail, decoded levels build a pyramid of their own (`pending`): the seeded
        // levels are no reason to skip one.
        if let p = e.seeded ? e.pending : e.pyramid, let finest = loader.finestResidentLevel(of: p), finest <= image.level {
            emit(url, .uploadSkipped, goal, level: image.level)
            return
        }
        let reserve = grid.byteCount(levels: image.level..<grid.levelCount)
        if planned[url]?[goal] != nil {
            e.uploadReserve += reserve   // first, so making room never touches this entry
            evictToFit()
        } else {
            guard levelsFit(reserve) else {
                emit(url, .uploadSkipped, goal, level: image.level)
                return
            }
            e.uploadReserve += reserve
        }
        emit(url, .uploadStart, goal, level: image.level)
        let pyramid: Pyramid
        if e.seeded {
            pyramid = e.pending ?? loader.makePyramid(grid: grid, colorSpace: image.image.colorSpace)
            e.pending = pyramid
        } else if let p = e.pyramid {
            pyramid = p
        } else {
            pyramid = loader.makePyramid(grid: grid, colorSpace: image.image.colorSpace)
            e.pyramid = pyramid
        }
        phase.markBusy()
        let start = ContinuousClock.now
        do {
            try await loader.upload(image, into: pyramid)
        } catch {
            e.uploadReserve -= reserve
            throw error
        }
        e.uploadReserve -= reserve
        emit(url, .uploadDone, goal, level: image.level)
        guard entries[url] === e else { return }
        if e.pending === pyramid {
            // The first decoded level lands: it replaces the thumbnail's pyramid, colour space and all.
            e.pyramid = pyramid
            e.pending = nil
            e.seeded = false
        }
        guard e.pyramid === pyramid else { return }
        e.timings.uploadMs = start.millisecondsElapsed
        evictToFit()
        notify(url)
    }
}

extension ImageCache {
    /// Whether `bytes` more of pyramid levels fit as things stand: against the graphics tier when there is one, else
    /// with everything held against the effective `cache-memory`.
    func levelsFit(_ bytes: Int) -> Bool {
        if let graphics = limits.graphicsMemory { return usedGraphicsBytes() + bytes <= graphics }
        return usedBytes() + bytes <= effectiveMemory
    }
}

private struct Probed: Sendable {
    let decoder: any ImageDecoder
    let info: ImageInfo
}
