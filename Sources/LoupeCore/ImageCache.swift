import Foundation

/// The process-wide photo cache (M2 spec §3–§4, §11): drives every entry — compressed bytes, a GPU pyramid with
/// per-level residency — towards what `CachePlan` asks for. The plan says what must be loaded, not what may be
/// kept: state the plan no longer wants stays while everything fits `cache-memory`, and goes farthest from the
/// current photo first when it does not (lazy eviction).
///
/// It serves several sessions (a window's tab each, spec windows-and-tabs §3) sharing one `cache-memory`: only the
/// active one plans (`setActivity`); the others start nothing and keep what they have, except that a visible one
/// gets its current photo back if it lost it (a short plan). The current photo of the active and of every visible
/// session, and the photo such a session has on screen (`setPinned`), are never evicted; the rest goes by owner
/// (`CacheOwners.evictionOrder`). A session hidden and inactive for `cache-idle-trim` keeps only its current photo
/// (`trimIdle`).
///
/// The actor only does bookkeeping. Reads go through `FileReading` (its own threads), decodes run inside
/// `DecodePool.run`, uploads in the loader, so `setFocus` returns at once however much work is in flight.
/// It replans on `setFocus`, `setActivity`, `setLimits` and whenever a read, probe or job completes. Jobs live in
/// ImageCache+Jobs.swift, sessions in ImageCache+Sessions.swift.
public actor ImageCache<Loader: PyramidLoader> {
    public typealias Pyramid = Loader.Pyramid

    let loader: Loader
    let reader: any FileReading
    let pool: DecodePool
    let makeDecoder: @Sendable (Data) -> any ImageDecoder
    var limits: CacheLimits
    /// The system's memory pressure: `limits.memory` divided by its `divisor` is what the cache holds itself to.
    var pressure = MemoryPressure.normal
    /// Puts the limit back this long after the last pressure event if no `.normal` came (the system's end-of-pressure
    /// event is not reliable).
    let pressureRestoreAfter: Duration
    var pressureRestore: Task<Void, Never>?
    /// Counts pressure events, so a restore timer can tell whether it is still the latest one's.
    var pressureGeneration = 0
    var onActivity: (@Sendable (CacheActivity) -> Void)?
    /// The last value reported to `onActivity` (or computed before there was a handler).
    var activity = CacheActivity.idle
    /// Benchmark trace of job stages (CacheTrace.swift); nil in the app.
    var trace: CacheTrace?

    /// Every registered session's playlist, focus and handler.
    var sessions: [CacheSessionID: CacheSessionState] = [:] { didSet { sessionsChanged() } }
    /// The session whose plan runs; nil when none does (the active one was unregistered).
    var active: CacheSessionID? { didSet { sessionsChanged() } }
    /// The highest `order` of an activation taken (`setActivity`): one sent earlier that arrives later is stale.
    var activationOrder: UInt64 = 0
    /// The sessions as `CacheOwners` sees them, rebuilt whenever one changes.
    private(set) var owners: [CacheOwnerFacts] = []
    /// What the idle trim's timer sleeps on (`updateIdleTimer`).
    let clock: any Clock<Duration>
    /// Wakes once a minute to trim idle sessions (`trimIdle`) while there may be one (`updateIdleTimer`).
    var idleTimer: Task<Void, Never>?
    /// What `evictToFit` took from inactive sessions since launch (`CacheStats.evictedInactive`).
    var evictedInactive = (count: 0, bytes: 0)
    /// At most two progressive JPEG full decodes at a time, one of them reserved for the current photo (spec
    /// §11.1.6): libjpeg-turbo holds its coefficient arrays (≈ 0.4–1.5 GB at 147 MP) for each, and the current
    /// photo never waits for a neighbour's. An async limiter, taken before the decode slot with the same live
    /// priority (current or not, plan rank).
    let progressiveFull = DecodePool(slots: 2, reserved: 1)
    /// Ready decodes (`CacheGoal.ready`, a discrete card only) are made one at a time at `.utility`: background work
    /// that never takes more than one decode's threads (`jxl-threads-other`) and evens the load out over the dwell
    /// (hardware defaults spec, «Два яруса памяти»). The prototype of the spec (i7-10700K, Radeon Pro 5500 XT, 64 GB;
    /// `replay --script backfast`, 15 photos of 147 MP JPEG XL forward at 1.5 s, 14 back at 0.6 s) kept 29 of 29 steps
    /// sharp before the next one against 21 without, a step back 172–255 ms to sharp against 570–583, and the run's CPU
    /// time 126 s against 157. The implementation, same machine and defaults (docs/bench/2026-10-23-memory-tiers.md):
    /// back-fast 29 of 29 sharp against 18–19, a step back 172–198 ms p50 and 244–245 ms max, CPU 137 s against
    /// 162–166. A full job, the photo on screen's included, waits for a ready decode in progress (`awaitReadyDecode`).
    /// A ready decode here takes 2.4–2.8 s against ~0.6 s at the current role, so the first step after opening took
    /// 567–1255 ms to sharp when it waited (base 578–803). Overtaking it, decoding at once at the current role, was
    /// tried and measured: that step took 785–796 ms and once missed the next step 1.5 s later, because the ready
    /// decode cannot be stopped and the second decode runs beside it; no gain, so it was removed. With a queued ready
    /// job given up rather than waited for (d581405, two runs), no step met one in progress: the first step after
    /// opening was already sharp, 100-steps max 1–2 ms, back-fast 29 of 29 with a step back 184–186 ms p50 and
    /// 237–309 ms max. The system tier bounds what is held, not what is being made: up to four full decodes in flight
    /// (three on `pool`, one here), each ~0.6 GB of output at 147 MP plus libjxl's own buffers, can stand ~2.5–3 GB
    /// above it for a moment. That is the one 15.3 GB process peak in those runs, against a cache figure of 11 391 MiB.
    let readyPool = DecodePool(slots: 1, reserved: 0, qos: .utility)
    var entries: [URL: CacheEntry<Pyramid>] = [:]
    /// The latest plan per URL: goal → position in the plan (the decode rank).
    var planned: [URL: [CacheGoal: Int]] = [:]
    /// Each planned URL's first pyramid goal in the plan (`CacheGoal.isPyramid`).
    var firstGoal: [URL: CacheGoal] = [:]
    var nextJobID = 0
    var stampChecks = 0
    /// Job tasks not yet finished, including cancelled ones whose decode or upload is still running.
    var runningJobs = 0

    public init(loader: Loader, reader: any FileReading = FileReader(), pool: DecodePool = DecodePool(),
                decoder: @escaping @Sendable (Data) -> any ImageDecoder = DecoderRegistry.decoder(for:),
                limits: CacheLimits = CacheLimits(config: Config()),
                pressureRestoreAfter: Duration = .seconds(30), clock: any Clock<Duration> = ContinuousClock()) {
        self.pressureRestoreAfter = pressureRestoreAfter
        self.clock = clock
        self.loader = loader
        self.reader = reader
        self.pool = pool
        self.makeDecoder = decoder
        self.limits = limits
    }

    deinit { idleTimer?.cancel() }

    /// Keeps what follows the sessions in step with them: `owners` and the idle trim's timer.
    private func sessionsChanged() {
        owners = ownerFacts()
        updateIdleTimer()
    }

    /// Called on every change of the cache's activity (deduplicated), from inside the actor, so it must not block:
    /// the thumbnail generator hops to its own actor. The handler gets the current value at once.
    public func setOnActivity(_ handler: @escaping @Sendable (CacheActivity) -> Void) {
        onActivity = handler
        activity = currentActivity()
        handler(activity)
    }

    /// The compressed bytes of `url` if resident and read at `stamp`: a thumbnail can be made from them without
    /// another read. Bytes of another stamp are a rewritten file's old content (eviction is lazy, and nothing
    /// checks a stamp until the photo becomes current again), which would otherwise be saved under the new stamp.
    public func cachedBytes(_ url: URL, stamp: FileStamp) -> Data? {
        guard let e = entries[url], e.stamp == stamp else { return nil }
        return e.data
    }

    public func setLimits(_ limits: CacheLimits) {
        self.limits = limits
        updateIdleTimer()
        reconcile()
    }

    /// The system's memory pressure level (spec §11.3). Under `.warning` / `.critical` the effective `cache-memory`
    /// is a half / a quarter, so the next replan evicts down to it (farthest first, never the pinned photo) and
    /// plans against it. `.normal` restores the limit, and so does the end of `pressureRestoreAfter` since the last
    /// non-normal event. Afterwards the freed memory is handed back to the system.
    public func setMemoryPressure(_ level: MemoryPressure) {
        pressureGeneration += 1
        pressureRestore?.cancel()
        pressureRestore = nil
        if level == .normal && pressure == .normal { return }
        let before = usedBytes()
        pressure = level
        reconcile()
        guard level != .normal else { return }
        let generation = pressureGeneration
        pressureRestore = Task { [weak self, pressureRestoreAfter] in
            try? await Task.sleep(for: pressureRestoreAfter)
            guard !Task.isCancelled else { return }
            await self?.pressureTimerFired(generation: generation)
        }
        if usedBytes() < before {
            // Evicted buffers go back to the system rather than sit in malloc's free lists.
            Task.detached(priority: .utility) { _ = malloc_zone_pressure_relief(nil, 0) }
        }
    }

    /// The restore timer of the event numbered `generation` woke up. A later event may have cancelled it after it
    /// woke (its call then waits for the actor behind that event), so it restores only if no event came since.
    func pressureTimerFired(generation: Int) {
        guard generation == pressureGeneration else { return }
        setMemoryPressure(.normal)
    }

    /// `cache-memory` as it applies now (with a graphics tier, the system tier's limit; that tier is not divided).
    var effectiveMemory: Int { limits.memory / pressure.divisor }

    public func entry(_ url: URL) -> CacheEntryView<Pyramid>? {
        guard let e = entries[url] else { return nil }
        let seededOnly = e.seeded && e.pyramid.flatMap { loader.finestResidentLevel(of: $0) } != nil
        return CacheEntryView(url: url, info: e.info, pyramid: e.pyramid, failure: e.failure,
                              decoderName: e.decoder?.name, timings: e.timings, state: state(of: url, e),
                              isSeededOnly: seededOnly, pyramidIsSeeded: e.seeded && e.pyramid != nil)
    }

    /// `usedBytes`: every entry's resident bytes (the pinned photo's included) plus the levels uploads are building;
    /// with a graphics tier, the system tier's (`usedSystemBytes`) and the graphics tier's (`usedGraphicsBytes`) apart.
    public func stats() -> CacheStats {
        var bytes = 0, previews = 0, full = 0, ready = 0
        for (url, e) in entries {
            if e.data != nil { bytes += 1 }
            if e.ready != nil { ready += 1 }
            switch state(of: url, e) {
            case .full: full += 1
            case .preview, .coarse: previews += 1
            default: break
            }
        }
        let tiered = limits.graphicsMemory != nil
        return CacheStats(bytesCount: bytes, previewCount: previews, fullCount: full,
                          usedBytes: tiered ? usedSystemBytes() : usedBytes(),
                          limitBytes: limits.memory, effectiveLimitBytes: effectiveMemory,
                          evictedInactive: evictedInactive, graphicsUsedBytes: usedGraphicsBytes(),
                          graphicsLimitBytes: limits.graphicsMemory, readyCount: ready)
    }

    /// Resident levels' slot arrays of `e` (not its uploads in flight). A pending pyramid (`CacheEntry.pending`)
    /// replaces the seeded one the moment an upload into it lands, so it holds nothing resident of its own; counted
    /// anyway, so a failed upload that left levels behind is not hidden.
    func pyramidBytes(_ e: CacheEntry<Pyramid>) -> Int {
        guard let info = e.info else { return 0 }
        let grid = TileGrid(imageSize: info.pixelSize)
        var used = 0
        for p in [e.pyramid, e.pending].compactMap({ $0 }) {
            if let finest = loader.finestResidentLevel(of: p) { used += grid.byteCount(levels: finest..<grid.levelCount) }
        }
        return used
    }

    /// What lives in graphics memory on a discrete card: every entry's resident levels plus the levels uploads are
    /// building (`CacheEntry.uploadReserve`). Held to `CacheLimits.graphicsMemory` when there is one.
    public func usedGraphicsBytes() -> Int { entries.values.reduce(0) { $0 + pyramidBytes($1) + $1.uploadReserve } }

    /// What lives in system memory whatever the card: the compressed bytes and the ready decodes (`CacheEntry.ready`,
    /// a discrete card only). Held to the effective `cache-memory` when there is a graphics tier.
    public func usedSystemBytes() -> Int {
        entries.values.reduce(0) { $0 + ($1.data?.count ?? 0) + ($1.ready?.image.buffer.length ?? 0) }
    }

    /// Everything the cache holds: with one budget (unified memory), what is held against `cache-memory`.
    func usedBytes() -> Int { usedSystemBytes() + usedGraphicsBytes() }

    /// `.current` while the current photo has a read, a job or a stamp check in flight or waiting (a job queued in
    /// the current class counts too: an ex-current one still ahead of the neighbours is the viewer's I/O), else
    /// `.neighbours` while any other read or job is, else `.idle`. A ready job (`CacheGoal.ready`) is background
    /// work whatever its photo: `.neighbours` at most while it runs, nothing while it waits, so a ready fill (seconds
    /// at 147 MP) never holds back thumbnails or Home covers as the photo on screen does.
    func currentActivity() -> CacheActivity {
        if stampChecks > 0 { return .current }
        var neighbours = false
        for (url, e) in entries {
            let jobs = e.jobs.filter { $0.key != .ready }
            let busy = e.read != nil || !jobs.isEmpty
            if busy && isCurrent(url) { return .current }
            if jobs.values.contains(where: { $0.phase.forCurrent }) { return .current }
            let readyRunning = e.jobs[.ready].map { !$0.phase.isWaiting } ?? false
            neighbours = neighbours || busy || readyRunning
        }
        return neighbours ? .neighbours : .idle
    }

    /// Reports the activity if it changed. Called wherever a read, job or stamp check starts, ends or is
    /// cancelled, and at the end of `reconcile`.
    func updateActivity() {
        let now = currentActivity()
        guard now != activity else { return }
        activity = now
        onActivity?(now)
    }

    /// Test hook: nothing in flight (no read, job task — cancelled ones included — or stamp check).
    var isIdle: Bool { stampChecks == 0 && runningJobs == 0 && entries.values.allSatisfy { $0.read == nil } }

    // MARK: Levels and state

    /// Lfit and the coarse preview's level for `info` on the screen of the focus of `url`'s holder (the active
    /// session if it lists `url`, else its most recently active owner, `CacheOwners.holder`; the active one for an
    /// entry nobody lists), laid out as that focus says (`appliesOrientation`); the grid is the stored one decoded
    /// levels go into.
    func levels(_ info: ImageInfo, _ url: URL) -> (grid: TileGrid, lfit: Int, coarse: Int) {
        let focus = CacheOwners.holder(of: url, sessions: owners).flatMap { sessions[$0]?.focus } ?? self.focus
        let grid = TileGrid(imageSize: info.pixelSize)
        let lfit = grid.previewLevel(forScreen: focus?.screen ?? PixelSize(width: 0, height: 0),
                                     orientation: info.displayOrientation(applying: focus?.appliesOrientation ?? true))
        return (grid, lfit, min(lfit + 1, grid.levelCount - 1))
    }

    /// The finest level `goal` needs resident (nil for `.bytes` and `.ready`, which are no pyramid state).
    func wantedLevel(_ goal: CacheGoal, _ info: ImageInfo, _ url: URL) -> Int? {
        let l = levels(info, url)
        switch goal {
        case .bytes, .ready: return nil
        case .coarse: return l.coarse
        case .preview: return l.lfit
        case .full: return 0
        }
    }

    /// A seeded level (the thumbnail, `seed`) satisfies `.coarse` at most: the preview and full resolution are
    /// still decoded from the file, even for a photo no larger than the thumbnail (seeded at level 0).
    func isSatisfied(_ url: URL, _ e: CacheEntry<Pyramid>, _ goal: CacheGoal) -> Bool {
        if goal == .bytes { return e.data != nil }
        if goal == .ready { return e.ready != nil }
        if e.seeded && goal > .coarse { return false }
        guard let info = e.info, let p = e.pyramid, let finest = loader.finestResidentLevel(of: p),
              let wanted = wantedLevel(goal, info, url) else { return false }
        return finest <= wanted
    }

    /// The finest pyramid goal resident, else `.bytes` if the file is; never `.ready` (not what the screen shows).
    func state(of url: URL, _ e: CacheEntry<Pyramid>) -> CacheGoal? {
        for goal in CacheGoal.allCases.reversed() where goal.isPyramid && isSatisfied(url, e, goal) { return goal }
        return e.data != nil ? .bytes : nil
    }

    /// Tells every session whose playlist lists `url` or which pins it.
    func notify(_ url: URL) {
        for s in sessions.values where s.fileIndex[url] != nil || s.pinned == url || s.pinnedCompanion == url {
            s.onUpdate?(url)
        }
    }

    // MARK: Planning

    private func facts(_ url: URL) -> EntryFacts {
        guard let e = entries[url] else { return EntryFacts() }
        return EntryFacts(pixelSize: e.info?.pixelSize, orientation: e.info?.orientation ?? .up, fileSize: e.stamp?.size,
                          failed: e.failure != nil, fullKept: isSatisfied(url, e, .full) || e.jobs[.full] != nil,
                          readyKept: e.ready != nil || e.jobs[.ready].map { !$0.phase.isWaiting } == true,
                          readyFailed: e.readyFailed)
    }

    /// Replans and brings jobs and residency in line: cancels what left the plan, starts what is missing in
    /// plan order, then evicts what does not fit (`evictToFit`). The plan is the active session's (none without
    /// one), followed by the visible inactive sessions' short plans. Synchronous, so no other actor work interleaves
    /// with it.
    func reconcile() {
        defer { updateActivity() }
        let files = self.files
        // Planned against the effective memory, so what pressure just evicted is not planned (and decoded) again.
        // Pressure divides only `cache-memory`: a graphics tier is planned against as it is.
        var planLimits = limits
        planLimits.memory = effectiveMemory
        let plan = focus.map { focus in CachePlan.make(focus: focus, limits: planLimits) { facts(files[$0]) } } ?? []
        let short = shortPlan()
        var wants: [URL: [CacheGoal: Int]] = [:]
        var first: [URL: CacheGoal] = [:]
        for (position, item) in (plan.map { (files[$0.index], $0.goal) } + short).enumerated() {
            let (url, goal) = item
            if wants[url]?[goal] == nil { wants[url, default: [:]][goal] = position }
            if first[url] == nil && goal.isPyramid { first[url] = goal }
        }
        planned = wants
        firstGoal = first

        // Only jobs that are still waiting (for bytes or a decode slot) are cancelled: those that left the plan,
        // and those queued in the wrong priority class (a neighbour that became current must not queue behind
        // neighbours, nor an ex-current one ahead of the new current), which are restarted below. A job that
        // is busy decoding or uploading stays registered even when its goal left the plan: if the goal comes
        // back (flipping A→B→A) it is reused instead of decoding again, otherwise it uploads its result only if
        // that fits `cache-memory` and starts no further stage (spec §11.1).
        for (url, e) in entries {
            for (goal, job) in e.jobs where job.phase.isWaiting {
                // `abandonIfWaiting`: a ready decode granted its slot a moment ago does not start after all.
                if wants[url]?[goal] == nil || job.phase.forCurrent != isCurrent(url), job.phase.abandonIfWaiting() {
                    job.task.cancel()
                    e.jobs[goal] = nil
                    emit(url, .jobCancelled, goal)
                }
            }
        }
        // While flipping (not dwelling) a neighbour starts no read: it would only queue ahead of the photo the user
        // lands on. Nor before the current photo's preview is up: until then the share is the current photo's alone
        // (a neighbour read already running would only pause for it). A read already in flight goes on (re-ranked); a
        // neighbour whose bytes are resident may still decode. The current photo (and its pair's other page,
        // `isCurrent`) always reads at once, and so does a visible session's.
        let neighboursRead = focus?.dwelling == true && currentPreviewUp()
        for item in plan {
            let url = files[item.index]
            start(url, item.goal, mayRead: isCurrent(url) || neighboursRead)
        }
        for (url, goal) in short { start(url, goal, mayRead: true) }
        for (url, e) in entries {
            // A read nothing waits for any more is stopped (its bytes would only be kept, not needed).
            if wants[url]?[.bytes] == nil, e.jobs.isEmpty, let read = e.read {
                read.cancel()
                e.read = nil
                e.readID += 1   // a late result of the cancelled read is ignored
                emit(url, .readCancelled)
            }
            // One still queued moves to its new rank: the photo just landed on goes ahead of those flipped past.
            reprioritizeRead(url, e)
            // Gone from the playlist: kept while it fits (the user may come back to the folder), evicted first when
            // it does not (`evictToFit`), and forgotten once it holds nothing (its facts are not asked for meanwhile).
            guard !isListed(url) else { continue }
            if e.pyramid == nil && e.data == nil && e.ready == nil && e.read == nil && e.jobs.isEmpty
                && e.uploadReserve == 0 {
                entries[url] = nil
            }
        }
        evictToFit()
    }

    /// The current photo, and its pair's other page, have their preview resident (or failed: nothing more is coming
    /// for them): neighbours may read now.
    private func currentPreviewUp() -> Bool {
        [currentURL, companionURL].compactMap { $0 }.allSatisfy { url in
            guard let e = entries[url] else { return false }
            return e.failure != nil || isSatisfied(url, e, .preview)
        }
    }

    /// A visible inactive session's short plan (spec windows-and-tabs §3.2): its current photo up to what its screen
    /// needs (its preview, or full resolution if its zoom needs it), nothing of its neighbours; most recently
    /// active session first.
    private func shortPlan() -> [(url: URL, goal: CacheGoal)] {
        sessions.filter { $0.key != active && $0.value.isVisible }
            .sorted { a, b in (b.value.lastActive, a.key.raw) < (a.value.lastActive, b.key.raw) }
            .compactMap { _, s in
                guard let url = s.currentURL, let focus = s.focus, !focus.scrubbing else { return nil }
                return (url, focus.needsFull ? .full : .preview)
            }
    }

    /// Starts what `goal` of `url` still needs; `mayRead`: a read of the file may start for it.
    private func start(_ url: URL, _ goal: CacheGoal, mayRead: Bool) {
        let e: CacheEntry<Pyramid>
        if let existing = entries[url] { e = existing } else { e = CacheEntry(); entries[url] = e }
        guard e.failure == nil else { return }
        if goal == .bytes {
            if e.data == nil && mayRead { _ = readTask(url, e) }
            return
        }
        if goal == .ready {
            // A full decode in flight keeps its pixels as the ready decode when it is done (and uses one in flight):
            // the file is never decoded twice side by side.
            guard e.jobs[.ready] == nil, e.jobs[.full] == nil, e.ready == nil, !e.readyFailed else { return }
            guard e.data != nil || e.read != nil || mayRead else { return }
            launch(url, e, goal)
            return
        }
        // A planned full decode in flight will satisfy the preview too.
        let fullComing = e.jobs[.full] != nil && planned[url]?[.full] != nil
        guard e.jobs[goal] == nil, !fullComing, !isSatisfied(url, e, goal) else { return }
        // Full resolution only once the preview is up, unless it is the first thing wanted (needsFull) or the photo
        // was just opened (`CacheFocus.opened`: both decode at once, on two slots).
        let openedNow = url == currentURL && focus?.opened == true
        if goal == .full && firstGoal[url] != .full && !openedNow && !isSatisfied(url, e, .preview) { return }
        guard e.data != nil || e.read != nil || mayRead else { return }
        launch(url, e, goal)
    }

    // MARK: Eviction (spec §3.3, §11.1)

    /// The steps an entry degrades by: levels finer than Lfit, then Lfit (down to the coarse preview), then the
    /// whole pyramid (`pyramidSteps`); in system memory the ready decode, then the compressed bytes (`systemSteps`).
    /// Each keeps whatever the plan still wants of the entry.
    enum EvictionStep: CaseIterable {
        case finerThanPreview, preview, pyramid, ready, bytes

        /// What frees the graphics tier on a discrete card (with one budget, all of memory but the files).
        static var pyramidSteps: [EvictionStep] { [.finerThanPreview, .preview, .pyramid] }
        /// What frees the system tier, each step a pass of its own over the candidates: every ready decode goes
        /// before any file (a decode costs a second or so to make again, a file an SMB re-read).
        static var systemSteps: [EvictionStep] { [.ready, .bytes] }
    }

    /// Evicts unplanned state until what is held fits: with one budget (unified memory) `usedBytes` ≤ the effective
    /// `cache-memory`; with a graphics tier (a discrete card) `usedGraphicsBytes` ≤ `CacheLimits.graphicsMemory` by the
    /// pyramid steps and `usedSystemBytes` ≤ the effective `cache-memory` by the system steps (ready decodes, then
    /// bytes), each tier on its own, so a full card never costs a file and memory pressure (which divides only
    /// `cache-memory`) never a level.
    /// In `CacheOwners.evictionOrder` (spec windows-and-tabs §3.4): entries no session lists first, then the inactive
    /// invisible sessions' (the longest unused first), the active one's last; within a session the farthest from its
    /// current photo first (ties: the one behind the direction of travel). Each entry's levels go step by step (§3.3)
    /// before the next entry is touched; with one budget, compressed bytes only once no candidate has levels left to
    /// give, in the same order. Bytes cost an SMB re-read (0.2–2 s) to get back, levels only a decode from them. Never
    /// the current photo of the active or a visible session (`CacheOwners.protected`), nor the photo such a session
    /// has on screen (`setPinned`), nor an entry while an upload into it is in flight; their ready decodes excepted,
    /// which go last (`readyCandidates`). What it takes from entries an inactive session holds
    /// (`CacheOwners.holder`) counts into `evictedInactive`, once per entry and call.
    func evictToFit() {
        if let graphics = limits.graphicsMemory {
            let usedGraphics = usedGraphicsBytes(), usedSystem = usedSystemBytes()
            guard usedGraphics > graphics || usedSystem > effectiveMemory else { return }
            var eviction = Eviction(order: evictionCandidates())
            var used = usedGraphics
            evict(&eviction, steps: EvictionStep.pyramidSteps, used: &used, target: graphics)
            used = usedSystem
            for step in EvictionStep.systemSteps {
                evict(&eviction, steps: [step], used: &used, target: effectiveMemory)
            }
        } else {
            // Unified memory holds no ready decode (none is planned), so the `.ready` pass finds nothing to take.
            var used = usedBytes()
            guard used > effectiveMemory else { return }
            var eviction = Eviction(order: evictionCandidates())
            evict(&eviction, steps: [.ready], used: &used, target: effectiveMemory)
            evict(&eviction, steps: EvictionStep.pyramidSteps, used: &used, target: effectiveMemory)
            evict(&eviction, steps: [.bytes], used: &used, target: effectiveMemory)
        }
    }

    /// One `evictToFit` call's walk: the candidates in eviction order, those whose ready decode may go
    /// (`readyCandidates`, made on first use), and the entries counted into `evictedInactive` so far.
    private struct Eviction {
        let order: [(url: URL, entry: CacheEntry<Pyramid>)]
        var ready: [(url: URL, entry: CacheEntry<Pyramid>)]?
        var counted = Set<URL>()

        init(order: [(url: URL, entry: CacheEntry<Pyramid>)]) { self.order = order }
    }

    /// The entries holding a ready decode eviction may drop: those `evictionCandidates` would give, in its order, then
    /// the protected and on-screen ones (the screen never draws from a ready decode, so pressure can take it even
    /// from the photo being viewed); none with an upload in flight.
    private func readyCandidates() -> [(url: URL, entry: CacheEntry<Pyramid>)] {
        let held = entries.filter { $0.value.ready != nil && $0.value.uploadReserve == 0 }
        guard !held.isEmpty else { return [] }
        let ordered = CacheOwners.evictionOrder(Array(held.keys), sessions: owners)
        let listed = Set(ordered)
        let last = held.keys.filter { !listed.contains($0) }.sorted { $0.path < $1.path }
        return (ordered + last).compactMap { url in held[url].map { (url, $0) } }
    }

    /// The entries eviction may touch, in `CacheOwners.evictionOrder`: not on screen, no upload in flight.
    private func evictionCandidates() -> [(url: URL, entry: CacheEntry<Pyramid>)] {
        let onScreen = Set(sessions.flatMap { id, s in id == active || s.isVisible ? s.pinnedPages : [] })
        return CacheOwners.evictionOrder(Array(entries.keys), sessions: owners)
            .compactMap { url -> (url: URL, entry: CacheEntry<Pyramid>)? in
                guard !onScreen.contains(url), let e = entries[url], e.uploadReserve == 0 else { return nil }
                return (url, e)
            }
    }

    /// Applies `steps` to each candidate in turn while `used` > `target`, taking what each frees off `used`. The
    /// `.ready` pass walks `readyCandidates`, the others `evictionCandidates`.
    private func evict(_ eviction: inout Eviction, steps: [EvictionStep], used: inout Int, target: Int) {
        guard used > target else { return }
        let order: [(url: URL, entry: CacheEntry<Pyramid>)]
        if steps == [.ready] {
            if eviction.ready == nil { eviction.ready = readyCandidates() }
            order = eviction.ready ?? []
        } else {
            order = eviction.order
        }
        for candidate in order {
            guard used > target else { return }
            var freed = 0
            for step in steps where used > target {
                let bytes = degrade(candidate.url, candidate.entry, step)
                used -= bytes
                freed += bytes
            }
            if freed > 0, let holder = CacheOwners.holder(of: candidate.url, sessions: owners), holder != active {
                if eviction.counted.insert(candidate.url).inserted { evictedInactive.count += 1 }
                evictedInactive.bytes += freed
            }
        }
    }

    /// Applies one eviction step to `e`, keeping what the plan wants of it; returns the bytes freed.
    func degrade(_ url: URL, _ e: CacheEntry<Pyramid>, _ step: EvictionStep) -> Int {
        let wants = planned[url] ?? [:]
        switch step {
        case .ready:
            // Not while a full job of the entry runs: it may have waited for this decode, to upload it next.
            guard wants[.ready] == nil, e.jobs[.full] == nil, let ready = e.ready else { return 0 }
            e.ready = nil
            return ready.image.buffer.length
        case .bytes:
            guard wants[.bytes] == nil, e.jobs.isEmpty, let data = e.data else { return 0 }
            e.data = nil
            notify(url)
            return data.count
        case .finerThanPreview, .preview, .pyramid:
            break
        }
        guard let p = e.pyramid else { return 0 }
        let top = wants.keys.filter(\.isPyramid).max()
        guard let info = e.info, let finest = loader.finestResidentLevel(of: p) else {
            // An empty pyramid (a failed upload left it): dropped with the pyramid step unless a level is planned.
            if step == .pyramid && top == nil { dropPyramid(e) }
            return 0
        }
        let l = levels(info, url)
        var keep: Int
        switch step {
        case .finerThanPreview: keep = l.lfit
        case .preview: keep = l.coarse
        case .pyramid: keep = l.grid.levelCount
        case .ready, .bytes: return 0   // handled above
        }
        if let top, let wanted = wantedLevel(top, info, url) { keep = min(keep, wanted) }
        guard finest < keep else { return 0 }
        if keep >= l.grid.levelCount {
            dropPyramid(e)
        } else {
            loader.evict(finerThan: keep, of: p)
        }
        notify(url)
        return l.grid.byteCount(levels: finest..<min(keep, l.grid.levelCount))
    }

    // MARK: Seeding (M2.5 spec §5.1)

    /// Makes `level`, the stretched thumbnail of `url` (`ThumbnailStore.seed`), its resident level without reading
    /// the file, so a far jump shows a picture at once. `info` is the stored header: the grid and transform are the
    /// real size's, so the preview and full resolution arriving later are finer levels of the same image. The
    /// thumbnail gets a pyramid of its own, in its own colour space and in oriented layout (thumbnails are made
    /// turned: its grid is `info.orientedSize`, drawn per `ImageInfo.drawOrientation(seeded: true)`); the first
    /// decoded level replaces it with one in the decoder's colour space and the stored layout (`CacheEntry.pending`).
    /// The first probe checks `info` and resets the entry if the file turned out to be another (`probe`).
    ///
    /// Nothing happens when the entry has a decoded level (of any size) or a seeded one as fine or finer, an upload into it is in flight (the decoded
    /// picture is on its way), it failed (its error stays on screen), its probed header disagrees with `info`, or
    /// `level` is not a level of `info`'s pyramid; all checked again once the upload is done, since the decoded
    /// picture always wins over the thumbnail. A refused seed leaves no entry behind. The level counts in
    /// `cache-memory` and is evicted like any other.
    public func seed(_ url: URL, info: ImageInfo, level: LevelImage) async {
        let grid = TileGrid(imageSize: info.orientedSize)
        guard grid.fitsTextureArrays, level.level >= 0, level.level < grid.levelCount,
              level.image.pixelSize == grid.levelSize(level.level),
              entries[url].map({ maySeed($0, info, level: level.level) }) ?? true
        else { return }
        let e: CacheEntry<Pyramid>
        if let existing = entries[url] { e = existing } else { e = CacheEntry(); entries[url] = e }
        let reserve = grid.byteCount(levels: level.level..<grid.levelCount)
        e.uploadReserve += reserve   // first, so making room never touches this entry
        evictToFit()
        let pyramid = loader.makePyramid(grid: grid, colorSpace: level.image.colorSpace)
        let uploaded = (try? await loader.upload(level, into: pyramid)) != nil
        e.uploadReserve -= reserve
        guard entries[url] === e else { return }
        guard uploaded, maySeed(e, info, level: level.level) else {
            if e.pyramid == nil && e.pending == nil && e.data == nil && e.read == nil && e.jobs.isEmpty
                && e.uploadReserve == 0 && e.info == nil && e.failure == nil {
                entries[url] = nil
            }
            return
        }
        if e.info == nil { e.info = info }
        e.pyramid = pyramid
        e.seeded = true
        emit(url, .seeded, level: level.level)
        notify(url)
        reconcile()   // the real size is known now: costs, Lfit, and whatever no longer fits
    }

    /// Whether `e` may take a seeded `level` of `info` now (see `seed`). The thumbnail only stands in for nothing
    /// decoded, or replaces a coarser thumbnail: never decoded levels, even coarser ones (a seed finer than Lfit,
    /// `thumb-size` 1024 in a small window), which would be thrown away and the preview decoded again.
    private func maySeed(_ e: CacheEntry<Pyramid>, _ info: ImageInfo, level: Int) -> Bool {
        guard e.failure == nil, e.uploadReserve == 0, e.info.map({ Self.sameFile($0, info) }) ?? true else { return false }
        guard let p = e.pyramid, let finest = loader.finestResidentLevel(of: p) else { return true }
        return e.seeded && finest > level
    }

    /// Evicts `e`'s whole pyramid, the seeded state with it.
    func dropPyramid(_ e: CacheEntry<Pyramid>) {
        e.pyramid = nil
        e.pending = nil
        e.seeded = false
    }

    /// Whether a probed header and a stored one describe the same file, as far as the pyramid is concerned (the
    /// orientation lays out a seeded one).
    static func sameFile(_ a: ImageInfo, _ b: ImageInfo) -> Bool {
        a.pixelSize == b.pixelSize && a.typeIdentifier == b.typeIdentifier && a.orientation == b.orientation
    }

    // MARK: Freshness and retries

    /// The new current photo: a failed one is retried (once per visit); a cached one is checked against the
    /// file on disk. The check queues behind the current photo's read (priority 1), as the current photo's I/O (the
    /// reader's thread kept for it; running neighbour reads pause for this one stat), and is dropped when the photo
    /// stops being current, or its session active, before it runs.
    func becameCurrent(_ url: URL, of session: CacheSessionID) {
        guard let e = entries[url] else { return }
        if e.failure != nil {
            reset(url)
        } else if let old = e.stamp {
            stampChecks += 1
            updateActivity()
            sessions[session]?.stampCheck = Task {
                let priority = ReadPriority(1)
                priority.isCurrent = true
                let now = try? await reader.stamp(url, priority: priority)
                stampChecks -= 1
                updateActivity()
                guard !Task.isCancelled, let now, now != old, entries[url] === e else { return }
                reset(url)
                reconcile()
            }
        }
    }

    /// Forgets everything about `url`; its jobs are cancelled and their results dropped (the entry differs).
    func reset(_ url: URL) {
        if let e = entries[url] {
            e.jobs.values.forEach { $0.task.cancel() }
            e.read?.cancel()
        }
        entries[url] = CacheEntry()
        notify(url)
        updateActivity()
    }
}
