import AVFoundation
import CoreGraphics
import Darwin
import Foundation
import LoupeCore
import LoupeRender
import Metal

// LoupeBench replay [--script fit|100|burst|pingpong|jump10|jump10-100|jumpfar|all|a,b,...] [--screen 6144x3456]
//                   [--video out.mov] [--raw out.tsv] [--conf loupe.conf] [--nocache] [--trace out.txt]
//                   [--seed] [--limit N] <folder>
//
// Drives a real ImageCache<MetalPyramidLoader> (real reads, decoders and GPU uploads) through scripted navigation
// and records what the screen would show under show-blurry (`no` unless --conf sets it), mirroring ViewerSession:
// the focus is sent on every
// step (needsFull from the zoom until the header is known, exact afterwards), dwell after 150 ms, and the current
// photo replaces the previous one only once ShowPolicy says it is sharp enough for the scale. With --seed, a strip
// jump (`jumpfar`) first seeds the landing from its stored thumbnail (ReplaySeeds.swift) and shows it at once, as
// `strip-jump-preview=yes` does.

struct ReplayOptions {
    var scripts = ReplayScript.all
    var screen = PixelSize(width: 6144, height: 3456)
    var video: String?
    var raw: String?
    var limit = Int.max
    var folder = ""
    /// A loupe.conf whose cache-*, show-blurry and jxl-* settings replace the defaults.
    var conf: String?
    /// Reads with F_NOCACHE: every read goes to the SMB server, as on a folder's first visit.
    var noCache = false
    /// Landing photos' stage timelines (jump scripts), as text.
    var trace: String?
    /// Strip jumps seed their landing from the thumbnail made before the run (ReplaySeeds), as the app does.
    var seed = false
}

/// Process memory and GPU allocation, sampled by the replay.
enum ReplayMetrics {
    static func gpuAllocated() -> Int { MetalContext.shared.device.currentAllocatedSize }
}

func msSince(_ t: ContinuousClock.Instant) -> Double {
    let c = (ContinuousClock.now - t).components
    return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
}

/// One step of a script, as measured.
struct StepRecord {
    let number: Int
    let index: Int
    let name: String
    let move: Int
    let burst: Bool
    /// Already sharp enough to show when the step reached it (first entry read after the focus).
    var hit = false
    /// From the step to the moment the entry may be on screen (ShowPolicy under the run's show-blurry), to state ≥
    /// preview, to state full. Nil: not reached before the next step.
    var shownMs: Double?
    /// From the step to the moment the entry is sharp for the zoom (ShowPolicy under show-blurry=no) with a level
    /// decoded from the file: a seeded thumbnail never counts.
    var sharpMs: Double?
    var landing = false
    /// A seeded strip jump (`--seed`): from the step to the scrubbing focus being in the cache, and to
    /// `ThumbnailStore.seed` handing over the level (the upload follows; `seeded` in the landing table).
    var seedFocusMs: Double?
    var seedThumbMs: Double?
    /// Whether the entry was sharp enough (ShowPolicy) when it went on screen. False when it was shown only because
    /// it was already on screen (ViewerSession never hides a shown photo) while its levels had been evicted.
    var sharpAtShow: Bool?
    var previewMs: Double?
    var fullMs: Double?
    var failure: String?
    var neededLevel: Int?
    var lfit: Int?
    // At the end of the step:
    var endState: CacheGoal?
    var endFinest: Int?
    var decoder: String?
    var timings = LoadTimings()
    var stats: CacheStats?
    var ram = 0
    var gpu = 0
    var cpuMs = 0.0
}

/// What the screen shows at a moment, shared with the sampler thread (video frames).
struct FrameState {
    var script = ""
    var zoom = ReplayZoom.fit
    var step = 0
    var stepCount = 0
    var stepStart = ContinuousClock.now
    var shown: CacheEntryView<TiledImage>?
    var currentName = ""
    var usedBytes = 0
    var limitBytes = 0
}

final class FrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = FrameState()
    func set(_ change: (inout FrameState) -> Void) { lock.withLock { change(&value) } }
    var state: FrameState { lock.withLock { value } }
}

/// Mirrors ViewerSession's focus and show logic against the cache; one per script.
/// Keep in sync with ViewerSession: `levels(_:)` ↔ `levels(for:)`, `needsFull()` ↔ `needsFull()`, `sendFocus()`,
/// the dwell timer (`dwellDelay`), `consider(_:)` ↔ `consider(_:atNavigation:)` (show-blurry fixed to `.no`),
/// the pin of the photo on screen (`setPinned` when another photo goes on screen, ↔ `show(_:atNavigation:)`),
/// `previous` in the focus (the index current before the step, ↔ `previousIndex`), and a strip click (`strip` steps,
/// ↔ `scrub(to:)` with `seedCurrent()`, then `endScrub()`; `stripJump` ↔ `jumpedFromStrip`).
actor ReplayDriver {
    static let dwellDelay: Duration = .milliseconds(150)

    let cache: ImageCache<MetalPyramidLoader>
    let files: [URL]
    let zoom: ReplayZoom
    let screen: PixelSize
    let box: FrameBox
    let showBlurry: ShowBlurry
    /// The stored thumbnails strip jumps seed from (`--seed`); nil: a strip jump seeds nothing, as with
    /// `strip-jump-preview=no`.
    let seeds: ThumbnailStore?

    private var index = 0
    private var stepNo = -1
    private var start = ContinuousClock.now
    private var direction = 1
    /// The index current before this step (ViewerSession.previousIndex): it keeps its full resolution if it has it.
    private var previousIndex: Int?
    private var dwelling = false
    /// A strip click is pressed: the focus says `scrubbing` (ViewerSession.isScrubbing).
    private var scrubbing = false
    /// The current photo was reached by a strip click: its seeded thumbnail may go on screen at once.
    private var stripJump = false
    private var sentFocus: CacheFocus?
    /// The current photo's header, once an entry read showed it: makes `needsFull` exact.
    private var latestInfo: ImageInfo?
    /// What is on screen: the current photo's entry once it qualified, the previous photo's until then.
    private var shown: CacheEntryView<TiledImage>?
    private var cpu0 = 0.0
    private(set) var records: [StepRecord] = []
    private(set) var peakUsed = 0

    init(cache: ImageCache<MetalPyramidLoader>, files: [URL], zoom: ReplayZoom, screen: PixelSize, box: FrameBox,
         showBlurry: ShowBlurry, seeds: ThumbnailStore? = nil) {
        self.showBlurry = showBlurry
        self.seeds = seeds
        self.cache = cache
        self.files = files
        self.zoom = zoom
        self.screen = screen
        self.box = box
    }

    /// Navigates to `index` (step `number`) and returns the step's start instant. A `strip` step is a click on the
    /// strip: the press makes the photo current with a scrubbing focus and seeds its stored thumbnail (with
    /// `seeds`), the release sends the normal focus. The release is taken to come once the seed is in (a click lasts
    /// ~100 ms, a seed a few), so the seed's time delays the landing's reads as it does in the app.
    func begin(number: Int, index: Int, move: Int, burst: Bool, landing: Bool = false, strip: Bool = false) async
        -> ContinuousClock.Instant {
        previousIndex = number == 0 ? nil : self.index
        self.index = index
        stepNo = number
        start = .now
        cpu0 = cpuTimeMs()
        if move != 0 { direction = move.signum() }
        dwelling = false
        stripJump = strip
        latestInfo = nil
        records.append(StepRecord(number: number, index: index, name: files[index].lastPathComponent, move: move, burst: burst,
                                  landing: landing))
        publish()
        if strip {
            scrubbing = true
            await sendFocus()
            let url = files[index]
            if let seeds {
                records[records.count - 1].seedFocusMs = msSince(start)
                let seed = await seeds.seed(url)
                records[records.count - 1].seedThumbMs = msSince(start)
                if let seed, stepNo == number { await cache.seed(url, info: seed.info, level: seed.level) }
            }
            scrubbing = false
        }
        await sendFocus()
        if let e = await cache.entry(files[index]), e.url == files[self.index], stepNo == number {
            records[records.count - 1].hit = isSharp(e)
            await consider(e)
        }
        let n = number
        Task {
            try? await Task.sleep(for: Self.dwellDelay)
            await self.dwell(n)
        }
        return start
    }

    private func dwell(_ number: Int) async {
        guard number == stepNo else { return }
        dwelling = true
        await sendFocus()
    }

    /// The cache's notification: re-reads the current photo's entry and considers it for the screen.
    func update(_ url: URL) async {
        let stats = await cache.stats()
        peakUsed = max(peakUsed, stats.usedBytes)
        box.set { $0.usedBytes = stats.usedBytes; $0.limitBytes = stats.limitBytes }
        guard stepNo >= 0, url == files[index] else { return }
        if let e = await cache.entry(url) { await consider(e) }
    }

    /// Drops what is on screen (the viewer closes) and its pin, so the teardown measures what the cache itself
    /// still holds.
    func close() async {
        shown = nil
        box.set { $0.shown = nil }
        await cache.setPinned(nil)
    }

    /// Records the end-of-step state and metrics.
    func endStep() async {
        guard !records.isEmpty else { return }
        let url = files[index]
        let e = await cache.entry(url)
        let stats = await cache.stats()
        var r = records[records.count - 1]
        r.endState = e?.state
        r.endFinest = e?.pyramid?.finestResidentLevel
        r.decoder = e?.decoderName
        r.timings = e?.timings ?? LoadTimings()
        r.stats = stats
        r.ram = ProcessMemory.footprint()
        r.gpu = ReplayMetrics.gpuAllocated()
        r.cpuMs = cpuTimeMs() - cpu0
        records[records.count - 1] = r
        peakUsed = max(peakUsed, stats.usedBytes)
    }

    // MARK: ViewerSession logic

    /// The needed level at the script's zoom and Lfit on the screen (ViewerSession.levels(for:)).
    private func levels(_ info: ImageInfo) -> (needed: Int, lfit: Int) {
        let grid = TileGrid(imageSize: info.pixelSize)
        let view = CGSize(width: screen.width, height: screen.height)
        let needed = TileGrid.level(forScale: zoom.transform(imageSize: info.orientedSize, view: view).scale,
                                    levelCount: grid.levelCount)
        return (needed, grid.previewLevel(forScreen: screen, orientation: info.orientation))
    }

    /// ViewerSession.needsFull(): from the zoom until the header is known, then needed < Lfit.
    private func needsFull() -> Bool {
        guard let info = latestInfo else { return zoom == .actual }
        let l = levels(info)
        return l.needed < l.lfit
    }

    private func sendFocus() async {
        let focus = CacheFocus(count: files.count, current: index, direction: direction, dwelling: dwelling,
                               needsFull: needsFull(), screen: screen, previous: previousIndex, scrubbing: scrubbing)
        guard focus != sentFocus else { return }
        sentFocus = focus
        await cache.setFocus(files: files, focus: focus)
    }

    /// `jumpPreview`: a seeded thumbnail the strip jumped to goes on screen at once (ViewerSession.consider).
    private func qualifies(_ e: CacheEntryView<TiledImage>, mode: ShowBlurry, jumpPreview: Bool = false) -> Bool {
        if e.failure != nil { return true }
        guard let info = e.info, let pyramid = e.pyramid else { return false }
        let l = levels(info)
        return ShowPolicy.shouldShow(finestResident: pyramid.finestResidentLevel, neededLevel: l.needed,
                                     previewLevel: l.lfit, mode: mode, jumpPreview: jumpPreview)
    }

    /// Sharp for the zoom with a level decoded from the file. A seeded thumbnail is never sharp, even when it is at
    /// the needed level (a photo no larger than the thumbnail is seeded at level 0).
    private func isSharp(_ e: CacheEntryView<TiledImage>) -> Bool { !e.isSeededOnly && qualifies(e, mode: .no) }

    /// ViewerSession.consider: a photo already on screen stays (finer levels just arrive, `ShowPolicy.refinesShown`);
    /// otherwise it replaces the screen once it qualifies, or at once as the seeded thumbnail of a strip jump.
    private func consider(_ e: CacheEntryView<TiledImage>) async {
        guard stepNo >= 0, e.url == files[index] else { return }
        let ms = msSince(start)
        var r = records[records.count - 1]
        if let state = e.state {
            if state >= .preview && r.previewMs == nil { r.previewMs = ms }
            if state == .full && r.fullMs == nil { r.fullMs = ms }
        }
        if let info = e.info {
            let l = levels(info)
            r.neededLevel = l.needed
            r.lfit = l.lfit
        }
        let onScreen = ShowPolicy.refinesShown(e, shown: shown)
        if e.failure != nil { r.failure = e.failure }
        let sharp = isSharp(e)
        if sharp && r.sharpMs == nil { r.sharpMs = ms }
        if onScreen || qualifies(e, mode: showBlurry, jumpPreview: stripJump && e.isSeededOnly) {
            let pin = shown?.url != e.url
            shown = e
            if pin { await cache.setPinned(e.url) }   // ViewerSession.show pins the photo going on screen
            if r.shownMs == nil {
                r.shownMs = ms
                r.sharpAtShow = sharp
            }
        }
        records[records.count - 1] = r
        publish()
        let hadInfo = latestInfo != nil
        if !hadInfo, let info = e.info {
            latestInfo = info
            if needsFull() != sentFocus?.needsFull { await sendFocus() }   // the header arrived: needsFull is exact
        }
    }

    private func publish() {
        let shown = self.shown, number = stepNo, start = self.start, name = files[index].lastPathComponent
        box.set {
            $0.shown = shown
            $0.step = number
            $0.stepStart = start
            $0.currentName = name
        }
    }
}

/// Samples RAM and GPU every 33 ms on its own thread (peaks), and renders a video frame each time when asked.
final class Sampler: @unchecked Sendable {
    private let box: FrameBox
    private let video: ReplayVideo?
    private let lock = NSLock()
    private var stopped = false
    private let done = DispatchSemaphore(value: 0)
    private(set) var peakRAM = 0
    private(set) var peakGPU = 0

    init(box: FrameBox, video: ReplayVideo?) {
        self.box = box
        self.video = video
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "replay sampler"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Stops sampling and waits for the thread to finish its frame.
    func stop() {
        lock.withLock { stopped = true }
        done.wait()
    }

    private func run() {
        let t0 = Date()
        var frame = 0
        while !lock.withLock({ stopped }) {
            let due = t0.addingTimeInterval(Double(frame) / 30)
            let wait = due.timeIntervalSinceNow
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            let ram = ProcessMemory.footprint(), gpu = ReplayMetrics.gpuAllocated()
            peakRAM = max(peakRAM, ram)
            peakGPU = max(peakGPU, gpu)
            video?.frame(box.state, index: frame, ram: ram, gpu: gpu)
            // A late frame skips ahead on the timeline rather than drifting.
            frame = max(frame + 1, Int(-t0.timeIntervalSinceNow * 30))
        }
        done.signal()
    }
}

struct ScriptResult {
    let script: ReplayScript
    let records: [StepRecord]
    let skipped: Int
    let wallMs: Double
    let cpuMs: Double
    let startRAM, startGPU: Int
    let peakRAM, peakGPU, peakUsed: Int
    let teardownRAM, teardownGPU: Int
    /// phys_footprint after `malloc_zone_pressure_relief`: what of `teardownRAM` is freed memory libmalloc still held.
    let reliefRAM: Int
    let video: ReplayVideo.Summary?
    let limits: CacheLimits
    let landings: [LandingRecord]
    let files: [URL]
}

enum Replay {
    static let usage = "usage: LoupeBench replay [--script fit|100|burst|pingpong|jump10|jump10-100|jumpfar|all|a,b,...] "
        + "[--screen WxH] [--video out.mov] [--raw out.tsv] [--conf loupe.conf] [--nocache] [--trace out.txt] [--seed] "
        + "[--limit N] <folder>"

    static func main(_ arguments: [String]) -> Never {
        let options = parse(arguments)
        Task {
            await run(options)
            exit(0)
        }
        dispatchMain()
    }

    private static func parse(_ arguments: [String]) -> ReplayOptions {
        var o = ReplayOptions()
        var args = arguments[...]
        var folder: String?
        while let arg = args.popFirst() {
            switch arg {
            case "--script":
                guard let v = args.popFirst() else { fail(usage) }
                if v == "all" { o.scripts = ReplayScript.all } else {
                    let keys = v.split(separator: ",").map(String.init)
                    for key in keys where ReplayScript.named(key) == nil {
                        fail("unknown script \(key) (\(ReplayScript.known.joined(separator: ", ")), all, or a comma-separated list)")
                    }
                    o.scripts = keys
                }
            case "--screen":
                let parts = (args.popFirst() ?? "").split(separator: "x").compactMap { Int($0) }
                guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { fail("--screen needs WxH") }
                o.screen = PixelSize(width: parts[0], height: parts[1])
            case "--video":
                guard let v = args.popFirst() else { fail(usage) }
                o.video = safeOutput(v)
            case "--raw":
                guard let v = args.popFirst() else { fail(usage) }
                o.raw = safeOutput(v)
            case "--conf":
                guard let v = args.popFirst() else { fail(usage) }
                guard FileManager.default.fileExists(atPath: v) else { fail("no such file: \(v)") }
                o.conf = v
            case "--nocache":
                o.noCache = true
            case "--seed":
                o.seed = true
            case "--trace":
                guard let v = args.popFirst() else { fail(usage) }
                o.trace = safeOutput(v)
            case "--limit":
                guard let v = args.popFirst(), let n = Int(v), n > 0 else { fail("--limit needs a positive integer") }
                o.limit = n
            case _ where arg.hasPrefix("--"):
                fail("unknown option \(arg)\n\(usage)")
            default:
                guard folder == nil else { fail(usage) }
                folder = arg
            }
        }
        guard let folder else { fail(usage) }
        o.folder = folder
        return o
    }

    /// Outputs never go onto a share (the photo folders are read-only).
    private static func safeOutput(_ path: String) -> String {
        let full = URL(fileURLWithPath: path).standardizedFileURL.path
        if full.hasPrefix("/Volumes/") { fail("refusing to write under /Volumes: \(full)") }
        return full
    }

    private static func run(_ o: ReplayOptions) async {
        let listed = imageFiles(at: o.folder)
        guard let first = listed.first else { fail("no images in \(o.folder)") }
        // The app's playlist order and extension filter.
        let files = Array(Playlist(files: listed, current: first).files.prefix(o.limit))
        _ = MetalContext.shared   // shader compilation is not part of the first step
        var seeds: ReplaySeeds?
        if o.seed {
            warn("replay: making the thumbnails of \(files.count) files to seed from (not timed)…")
            let made = await ReplaySeeds.prefill(files: files, thumbSize: config(o).thumbSize)
            warn("replay: \(made.ready)/\(files.count) thumbnails in \(String(format: "%.1f", made.prefillSeconds)) s")
            seeds = made
        }
        defer { seeds?.remove() }
        var results: [ScriptResult] = []
        let started = Date()
        for key in o.scripts {
            let script = ReplayScript.named(key)!
            var videoURL: URL?
            if let v = o.video {
                let url = URL(fileURLWithPath: v)
                videoURL = o.scripts.count == 1 ? url : url.deletingLastPathComponent()
                    .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-\(script.name).\(url.pathExtension)")
            }
            FileHandle.standardError.write(Data("replay: \(script.name) on \(files.count) files…\n".utf8))
            results.append(await runScript(script, files: files, screen: o.screen, video: videoURL, limits: limits(o),
                                           noCache: o.noCache, seeds: seeds))
        }
        print(markdown(o, files: files, results: results, started: started, seeds: seeds))
        if let raw = o.raw { writeRaw(results, to: raw) }
        if let trace = o.trace { writeTrace(results, to: trace) }
        // Diagnostics: keep the process alive so `footprint` / `vmmap` can look at what is left.
        if let hold = ProcessInfo.processInfo.environment["LOUPE_REPLAY_HOLD"].flatMap(Double.init) {
            warn("replay: holding \(hold) s, pid \(getpid())")
            try? await Task.sleep(for: .seconds(hold))
        }
    }

    /// The defaults, or `--conf` (its problems are reported by `limits`).
    static func config(_ o: ReplayOptions) -> Config {
        o.conf.map { Config.load(from: URL(fileURLWithPath: $0)).0 } ?? Config()
    }

    /// The defaults with show-blurry=no, or the cache-* and show-blurry settings of `--conf`.
    static func limits(_ o: ReplayOptions) -> CacheLimits {
        guard let conf = o.conf else {
            var limits = CacheLimits()
            limits.showBlurry = .no
            return limits
        }
        let (config, problems) = Config.load(from: URL(fileURLWithPath: conf))
        problems.forEach { warn("replay: \(conf): \($0)") }
        // jxl-* reach the decoders as in the app (Settings.reload).
        JXLSetting.shared.options = JXLOptions(config: config)
        return CacheLimits(config: config)
    }

    private static func runScript(_ script: ReplayScript, files: [URL], screen: PixelSize, video: URL?,
                                  limits: CacheLimits, noCache: Bool, seeds: ReplaySeeds?) async -> ScriptResult {
        let box = FrameBox()
        let stepCount = script.steps.count
        box.set { $0.script = script.name; $0.zoom = script.zoom; $0.stepCount = stepCount }
        let recorder = video.flatMap { url -> ReplayVideo? in
            do { return try ReplayVideo(url: url, screen: screen) } catch { fail("cannot write \(url.path): \(error)") }
        }
        let startRAM = ProcessMemory.footprint(), startGPU = ReplayMetrics.gpuAllocated()
        let log = TraceLog()
        let reader = TracingReader(log: log, noCache: noCache)
        let pool = DecodePool()
        let cache = ImageCache(loader: MetalPyramidLoader(), reader: reader, pool: pool, limits: limits)
        let seedStore = await seeds?.store(cache: cache, reader: reader)
        let driver = ReplayDriver(cache: cache, files: files, zoom: script.zoom, screen: screen, box: box,
                                  showBlurry: limits.showBlurry, seeds: seedStore?.store)
        await cache.setOnUpdate { url in Task { await driver.update(url) } }
        if script.steps.contains(where: \.landing) { await cache.setTrace { log.add($0) } }
        var landings: [LandingRecord] = []
        func snapshot(_ stop: ContinuousClock.Instant) async -> LoadSnapshot {
            let stats = await cache.stats()
            let io = reader.load, decode = pool.load
            return LoadSnapshot(atMs: msSince(stop), ioQueued: io.queued, ioRunning: io.running,
                                decodeWaiting: decode.waiting, decodeRunning: decode.running,
                                usedBytes: stats.usedBytes, limitBytes: stats.limitBytes)
        }
        let sampler = Sampler(box: box, video: recorder)

        let cpu0 = cpuTimeMs()
        let t0 = ContinuousClock.now
        sampler.start()
        var index = 0
        var deadline = await driver.begin(number: 0, index: 0, move: 0, burst: false) + script.openDwell
        try? await Task.sleep(until: deadline, clock: .continuous)
        await driver.endStep()
        var skipped = 0
        var number = 0
        for step in script.steps {
            let target = index + step.move
            guard files.indices.contains(target) else {
                // The folder is shorter than the script: the move goes nowhere, the time still passes.
                skipped += 1
                deadline = deadline + step.dwell
                try? await Task.sleep(until: deadline, clock: .continuous)
                continue
            }
            index = target
            number += 1
            let start = await driver.begin(number: number, index: index, move: step.move, burst: step.burst,
                                           landing: step.landing, strip: step.strip)
            // The schedule is absolute (a slow step does not delay the next one), like a user's key presses.
            deadline = max(deadline + step.dwell, start)
            if step.landing {
                // The stop: what the cache holds around it, then the I/O and decode load every 100 ms.
                var landing = LandingRecord(step: number, index: index, url: files[index], stop: start)
                landing.atStop = await snapshot(start)
                let offsets = Array(-3...12)
                let urls = offsets.map { files.indices.contains(index + $0) ? files[index + $0] : nil }
                let probes = await cache.inspect(urls.compactMap { $0 })
                var it = probes.makeIterator()
                landing.window = zip(offsets, urls).map { offset, url in (offset, url == nil ? nil : it.next() ?? nil) }
                var tick = start
                while true {
                    tick = tick + .milliseconds(100)
                    guard tick < deadline else { break }
                    try? await Task.sleep(until: tick, clock: .continuous)
                    landing.series.append(await snapshot(start))
                }
                landings.append(landing)
            }
            try? await Task.sleep(until: deadline, clock: .continuous)
            await driver.endStep()
        }
        let wallMs = msSince(t0)
        let cpuMs = cpuTimeMs() - cpu0
        sampler.stop()
        let records = await driver.records
        let peakUsed = await driver.peakUsed
        let summary = await recorder?.finish()
        await cache.setTrace(nil)
        // Each landing's records since the previous landing's stop (the photo may have been a neighbour before).
        var since = t0
        for i in landings.indices {
            landings[i].events = log.events(for: landings[i].url).filter { $0.time >= since }
            let from = landings[i].stop - .seconds(1), to = landings[i].stop + .seconds(3)
            landings[i].reads = log.all.filter {
                $0.time >= from && $0.time <= to && ($0.kind.hasPrefix("read") || $0.kind == "jobLaunched")
            }
            since = landings[i].stop
        }

        // Teardown: the viewer closes (the handler held the driver, the driver the cache: break that cycle) and an
        // empty playlist plans nothing, so every entry is evicted; memory should return to where it started.
        await cache.setOnUpdate { _ in }
        await seedStore?.close(cache)
        await driver.close()
        await cache.setFocus(files: [], focus: CacheFocus(count: 0, current: 0, direction: 1, dwelling: false,
                                                          needsFull: false, screen: screen))
        try? await Task.sleep(for: .seconds(3))
        let teardownRAM = ProcessMemory.footprint(), teardownGPU = ReplayMetrics.gpuAllocated()
        _ = malloc_zone_pressure_relief(nil, 0)
        let reliefRAM = ProcessMemory.footprint()
        return ScriptResult(script: script, records: records, skipped: skipped, wallMs: wallMs, cpuMs: cpuMs,
                            startRAM: startRAM, startGPU: startGPU,
                            peakRAM: sampler.peakRAM, peakGPU: sampler.peakGPU, peakUsed: peakUsed,
                            teardownRAM: teardownRAM, teardownGPU: teardownGPU, reliefRAM: reliefRAM,
                            video: summary, limits: limits, landings: landings, files: files)
    }

    // MARK: Report

    private static func mb(_ bytes: Int) -> String { String(Int((Double(bytes) / 1_048_576).rounded())) }
    private static func f0(_ v: Double?) -> String { v.map { String(Int($0.rounded())) } ?? "–" }

    private static func markdown(_ o: ReplayOptions, files: [URL], results: [ScriptResult], started: Date,
                                 seeds: ReplaySeeds?) -> String {
        var out: [String] = []
        let stamp = ISO8601DateFormatter().string(from: started)
        out.append("## replay: \(o.folder)")
        out.append("")
        out.append("\(files.count) files, screen \(o.screen.width)×\(o.screen.height), started \(stamp), "
                   + limitsText(results.first?.limits ?? limits(o)) + (o.conf.map { " (from \($0))" } ?? " (defaults)")
                   + (o.noCache ? ", reads F_NOCACHE" : "")
                   + (seeds.map { ", strip jumps seeded: \($0.ready)/\(files.count) thumbnails (thumb-size \($0.thumbSize)) made "
                                  + "in \(String(format: "%.1f", $0.prefillSeconds)) s before the run" } ?? ""))
        out.append("")
        out.append("| script | zoom | steps | shown sharp | shown blurry | not shown | hit | shown p50 | p90 | max | preview p50 "
                   + "| full p50 | full p90 | CPU s | open CPU s | CPU s/step | RAM start/peak/end/after/relief | GPU start/peak/end/after | cache peak MB | wall s |")
        out.append("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|---:|---:|")
        for r in results {
            let steps = r.records.filter { $0.number > 0 }
            var shown = Samples(), preview = Samples(), full = Samples()
            for s in steps {
                if let v = s.shownMs, s.sharpAtShow == true { shown.add(v) }
                if let v = s.previewMs { preview.add(v) }
                if let v = s.fullMs { full.add(v) }
            }
            let hits = steps.filter(\.hit).count
            let blurry = steps.filter { $0.shownMs != nil && $0.sharpAtShow != true }.count
            let last = r.records.last
            // CPU per step: the steps' own CPU, without the open (step 0, the folder's first decodes).
            let stepCPU = steps.reduce(0) { $0 + $1.cpuMs }
            let openCPU = r.records.first(where: { $0.number == 0 })?.cpuMs ?? 0
            out.append("| \(r.script.name) | \(r.script.zoom.rawValue) | \(steps.count)\(r.skipped > 0 ? " (+\(r.skipped) skipped)" : "") "
                       + "| \(shown.count) | \(blurry) | \(steps.count - shown.count - blurry) | \(hits)/\(steps.count) "
                       + "| \(f0(shown.median)) | \(f0(shown.percentile(90))) | \(f0(shown.percentile(100))) "
                       + "| \(f0(preview.median)) | \(f0(full.median)) | \(f0(full.percentile(90))) "
                       + "| \(String(format: "%.1f", r.cpuMs / 1000)) | \(String(format: "%.1f", openCPU / 1000)) "
                       + "| \(String(format: "%.2f", stepCPU / 1000 / Double(max(steps.count, 1)))) "
                       + "| \(mb(r.startRAM))/\(mb(r.peakRAM))/\(mb(last?.ram ?? 0))/\(mb(r.teardownRAM))/\(mb(r.reliefRAM)) "
                       + "| \(mb(r.startGPU))/\(mb(r.peakGPU))/\(mb(last?.gpu ?? 0))/\(mb(r.teardownGPU)) "
                       + "| \(mb(r.peakUsed)) | \(String(format: "%.1f", r.wallMs / 1000)) |")
        }
        out.append("")
        out.append("Times in ms from the step. shown sharp: the entry qualified under show-blurry=no (ShowPolicy, needed "
                   + "level for the zoom) before the next step; shown blurry: it was on screen only because it already was "
                   + "(ViewerSession never hides a shown photo) with its needed level evicted; the shown percentiles are over "
                   + "sharp shows only, i.e. over steps that made it in time (survivor-biased, most visibly in burst). "
                   + "hit: it already qualified when the step reached it. CPU s/step: the steps' own CPU without the open "
                   + "(open CPU s). RAM = phys_footprint MB, "
                   + "GPU = MTLDevice.currentAllocatedSize MB; \"after\" is 3 s after the teardown (empty playlist), "
                   + "\"relief\" right after malloc_zone_pressure_relief (freed blocks libmalloc still held).")
        for r in results {
            out.append("")
            out.append("### \(r.script.name) (\(r.script.zoom.rawValue))")
            out.append("")
            let burst = r.records.filter(\.burst)
            if !burst.isEmpty {
                let caught = burst.filter { $0.shownMs != nil }.count
                out.append("Burst: \(caught)/\(burst.count) wheel steps had their photo on screen before the next step "
                           + "(the shown percentiles above cover only those).")
                out.append("")
            }
            let dwelt = r.records.filter { !$0.burst && $0.number > 0 }
            var shown = Samples()
            dwelt.filter { $0.sharpAtShow == true }.compactMap(\.shownMs).forEach { shown.add($0) }
            if !burst.isEmpty, !dwelt.isEmpty {
                out.append("Dwelt steps after the burst: shown p50 \(f0(shown.median)) / max \(f0(shown.percentile(100))) ms, "
                           + "hits \(dwelt.filter(\.hit).count)/\(dwelt.count).")
                out.append("")
            }
            if let v = r.video {
                out.append("Video: \(v.path) — \(v.frames) frames, \(String(format: "%.1f", v.duration)) s, "
                           + "\(mb(v.bytes)) MB; frame render p50 \(String(format: "%.1f", v.renderP50)) / p99 "
                           + "\(String(format: "%.1f", v.renderP99)) / max \(String(format: "%.1f", v.renderMax)) ms.")
                out.append("")
            }
            if !r.landings.isEmpty {
                out.append(contentsOf: landingTable(r))
                out.append("")
            }
            out.append(stepHeader)
            out.append(stepRule)
            let shownRows = r.records.count <= 16 ? r.records : Array(r.records.prefix(11)) + Array(r.records.suffix(5))
            for (i, s) in shownRows.enumerated() {
                if r.records.count > 16 && i == 11 { out.append("| … |" + String(repeating: " |", count: 16)) }
                out.append(stepRow(s))
            }
        }
        return out.joined(separator: "\n")
    }

    private static let stepHeader = "| step | file | move | hit | shown | preview | full | end state | finest/need/Lfit | "
        + "decoder | read | look | prev | full dec | upload | cache MB | RAM | GPU | CPU ms |"
    private static let stepRule = "|---:|---|---:|---|---:|---:|---:|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|"

    private static func stepRow(_ s: StepRecord) -> String {
        let t = s.timings
        let levels = "\(s.endFinest.map(String.init) ?? "–")/\(s.neededLevel.map(String.init) ?? "–")/\(s.lfit.map(String.init) ?? "–")"
        let move = s.move == 0 ? "open" : s.move > 0 ? "→" : "←"
        let state = s.failure != nil ? "failed" : s.endState.map { "\($0)" } ?? "–"
        let shown = s.shownMs == nil ? "–" : f0(s.shownMs) + (s.sharpAtShow == true ? "" : " (blurry)")
        return "| \(s.number) | \(s.name) | \(move) | \(s.hit ? "yes" : "") | \(shown) | \(f0(s.previewMs)) "
            + "| \(f0(s.fullMs)) | \(state) | \(levels) | \(s.decoder ?? "–") | \(f0(t.readMs)) | \(f0(t.firstLookMs)) "
            + "| \(f0(t.previewMs)) | \(f0(t.fullMs)) | \(f0(t.uploadMs)) | \(mb(s.stats?.usedBytes ?? 0)) | \(mb(s.ram)) "
            + "| \(mb(s.gpu)) | \(f0(s.cpuMs)) |"
    }

    static func limitsText(_ l: CacheLimits) -> String {
        "cache-full \(l.full) / previews \(l.previews) / far \(l.farPreviewsCoarse ? "coarse" : "full") / files \(l.files) / "
            + "memory \(mb(l.memory)) MB / show-blurry \(l.showBlurry.rawValue)"
    }

    /// One row per landing: the load at the stop and the photo's stages, ms relative to the stop.
    private static func landingTable(_ r: ScriptResult) -> [String] {
        var out = ["Landings (ms from the stop, negative = before it; w/s/d/u = slot asked / decode started / decoded / "
                   + "uploaded; I/O q+r = reads queued + running, dec w+r = decodes waiting + running; at stop; "
                   + "seed focus / thumb = the scrubbing focus in the cache / ThumbnailStore.seed returned, seeded = the "
                   + "stored thumbnail resident, --seed):", "",
                   "| step | file | at stop | I/O q+r | dec w+r | cache MB | read sub / start / done | probe w/s/d "
                   + "| coarse w/s/d/u | preview w/s/d/u | full w/s/d/u | seed focus / thumb | seeded | shown | sharp | I/O empty at |",
                   "|---:|---|---|---|---|---|---|---|---|---|---|---|---:|---:|---:|---:|"]
        for l in r.landings {
            let rec = r.records.first { $0.number == l.step }
            let t = LandingTimes(l)
            let at = l.window.first { $0.offset == 0 }?.probe
            let state = at.map { p in (p.state.map { "\($0)" } ?? "none") + (p.reading ? "+reading" : "")
                + (p.jobs.isEmpty ? "" : " jobs " + p.jobs.map { "\($0.key)\($0.value ? "(w)" : "(b)")" }.sorted().joined(separator: ",")) } ?? "no entry"
            let s = l.atStop
            let empty = l.series.first { $0.ioQueued + $0.ioRunning == 0 }.map { f0($0.atMs) } ?? ">3000"
            out.append("| \(l.step) | \(l.url.lastPathComponent) | \(state) | \(s.map { "\($0.ioQueued)+\($0.ioRunning)" } ?? "") "
                       + "| \(s.map { "\($0.decodeWaiting)+\($0.decodeRunning)" } ?? "") "
                       + "| \(s.map { "\(mb($0.usedBytes))/\(mb($0.limitBytes))" } ?? "") "
                       + "| \(t.read) | \(t.probe) | \(t.stage(.coarse)) | \(t.stage(.preview)) | \(t.stage(.full)) "
                       + "| \(rec?.seedFocusMs == nil ? "–" : "\(f0(rec?.seedFocusMs)) / \(f0(rec?.seedThumbMs))") "
                       + "| \(f0(t.seededMs)) | \(f0(rec?.shownMs)) | \(f0(rec?.sharpMs)) | \(empty) |")
        }
        return out
    }

    /// Writes each landing's window (entries around the stop), load series and full event timeline.
    private static func writeTrace(_ results: [ScriptResult], to path: String) {
        var out: [String] = []
        func ms(_ t: ContinuousClock.Instant, _ stop: ContinuousClock.Instant) -> String {
            let c = (t - stop).components
            return String(format: "%+.0f", Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15)
        }
        for r in results where !r.landings.isEmpty {
            out.append("# \(r.script.name) (\(r.script.zoom.rawValue)) — \(limitsText(r.limits))")
            for l in r.landings {
                let rec = r.records.first { $0.number == l.step }
                out.append("")
                out.append("## step \(l.step): \(l.url.lastPathComponent) (index \(l.index)); shown \(f0(rec?.shownMs)) sharp \(f0(rec?.sharpMs)) "
                           + "full \(f0(rec?.fullMs)) ms")
                if let s = l.atStop {
                    out.append("at stop: I/O queued \(s.ioQueued) running \(s.ioRunning); decode waiting \(s.decodeWaiting) "
                               + "running \(s.decodeRunning); cache \(mb(s.usedBytes))/\(mb(s.limitBytes)) MB")
                }
                out.append("window (offset: state finest bytes reading jobs(w=waiting,b=busy) planned goal@rank):")
                for (offset, p) in l.window {
                    guard let p else { out.append("  \(String(format: "%+3d", offset)): –"); continue }
                    let jobs = p.jobs.map { "\($0.key)(\($0.value ? "w" : "b"))" }.sorted().joined(separator: ",")
                    let planned = p.planned.sorted { $0.value < $1.value }.map { "\($0.key)@\($0.value)" }.joined(separator: ",")
                    out.append("  \(String(format: "%+3d", offset)): \(p.state.map { "\($0)" } ?? "none") L\(p.finest.map(String.init) ?? "-") "
                               + "\(p.hasBytes ? "bytes" : "-") \(p.reading ? "reading" : "-") jobs[\(jobs)] planned[\(planned)]")
                }
                out.append("load every 100 ms (ms: io q+r, dec w+r, cache MB): "
                           + l.series.map { "\(f0($0.atMs)):\($0.ioQueued)+\($0.ioRunning),\($0.decodeWaiting)+\($0.decodeRunning),\(mb($0.usedBytes))" }
                    .joined(separator: " "))
                let index = Dictionary(r.files.enumerated().map { ($1.lastPathComponent, $0) }, uniquingKeysWith: { a, _ in a })
                out.append("reads and job launches of all photos, stop-1 s … stop+3 s (offset from landing):")
                for e in l.reads {
                    let off = index[e.url.lastPathComponent].map { String(format: "%+d", $0 - l.index) } ?? e.url.lastPathComponent
                    out.append("  \(ms(e.time, l.stop)) \(off) \(e.kind)\(e.goal.map { " \($0)" } ?? "")\(e.priority.map { " p\($0)" } ?? "")")
                }
                out.append("events:")
                for e in l.events {
                    out.append("  \(ms(e.time, l.stop)) \(e.kind)\(e.goal.map { " \($0)" } ?? "")\(e.level.map { " L\($0)" } ?? "")"
                               + (e.priority.map { " p\($0)" } ?? ""))
                }
            }
            out.append("")
        }
        do {
            try (out.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            warn("cannot write \(path): \(error)")
        }
    }

    private static func writeRaw(_ results: [ScriptResult], to path: String) {
        var lines = ["script\tstep\tindex\tfile\tmove\tburst\thit\tshown_ms\tpreview_ms\tfull_ms\tfailure\tend_state\tfinest\t"
                     + "needed\tlfit\tdecoder\tread_ms\tlook_ms\tpreview_dec_ms\tfull_dec_ms\tupload_ms\tbytes_n\tpreviews_n\t"
                     + "full_n\tcache_used\tram\tgpu\tcpu_ms\tsharp_at_show\tsharp_ms\tlanding\tseeded_ms\tseed_focus_ms\tseed_thumb_ms"]
        func o(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "" }
        func i(_ v: Int?) -> String { v.map(String.init) ?? "" }
        for r in results {
            let seeded = Dictionary(r.landings.map { ($0.step, LandingTimes($0).seededMs) }, uniquingKeysWith: { a, _ in a })
            for s in r.records {
                let t = s.timings, st = s.stats
                lines.append([r.script.name, "\(s.number)", "\(s.index)", s.name, "\(s.move)", s.burst ? "1" : "0",
                              s.hit ? "1" : "0", o(s.shownMs), o(s.previewMs), o(s.fullMs), s.failure ?? "",
                              s.endState.map { "\($0)" } ?? "", i(s.endFinest), i(s.neededLevel), i(s.lfit),
                              s.decoder ?? "", o(t.readMs), o(t.firstLookMs), o(t.previewMs), o(t.fullMs), o(t.uploadMs),
                              i(st?.bytesCount), i(st?.previewCount), i(st?.fullCount), i(st?.usedBytes),
                              "\(s.ram)", "\(s.gpu)", String(format: "%.1f", s.cpuMs),
                              s.sharpAtShow.map { $0 ? "1" : "0" } ?? "", o(s.sharpMs), s.landing ? "1" : "0",
                              o(seeded[s.number] ?? nil), o(s.seedFocusMs), o(s.seedThumbMs)].joined(separator: "\t"))
            }
        }
        do {
            try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            warn("cannot write \(path): \(error)")
        }
    }
}


/// A landing's stage times relative to its stop, picked from the trace: per goal the last slot request, start and
/// decode before its first upload (or the last ones if it never uploaded).
struct LandingTimes {
    let landing: LandingRecord

    init(_ landing: LandingRecord) { self.landing = landing }

    private func ms(_ t: ContinuousClock.Instant?) -> String {
        guard let t else { return "–" }
        let c = (t - landing.stop).components
        return String(Int((Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15).rounded()))
    }

    private func last(_ kind: String, goal: CacheGoal? = nil, before: ContinuousClock.Instant? = nil) -> ContinuousClock.Instant? {
        landing.events.last { $0.kind == kind && (goal == nil || $0.goal == goal) && (before == nil || $0.time <= before!) }?.time
    }

    private func first(_ kind: String, goal: CacheGoal? = nil) -> ContinuousClock.Instant? {
        landing.events.first { $0.kind == kind && (goal == nil || $0.goal == goal) }?.time
    }

    var read: String {
        guard let done = first("readDone") else {
            return landing.events.contains { $0.kind == "readSubmitted" } ? "unfinished" : "earlier"
        }
        return "\(ms(last("readSubmitted", before: done))) / \(ms(last("readStarted", before: done))) / \(ms(done))"
    }

    /// When the stored thumbnail became resident (`ImageCache.seed`, `--seed`); nil: never seeded.
    var seededMs: Double? {
        guard let t = first("seeded") else { return nil }
        let c = (t - landing.stop).components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }

    var probe: String {
        guard let done = first("probeDone") else { return "–" }
        return "\(ms(last("probeWait", before: done)))/\(ms(last("probeStart", before: done)))/\(ms(done))"
    }

    func stage(_ goal: CacheGoal) -> String {
        let upload = first("uploadDone", goal: goal)
        let done = last("decodeDone", goal: goal, before: upload)
        let start = last("decodeStart", goal: goal, before: done ?? upload)
        let wait = last("decodeWait", goal: goal, before: start ?? done ?? upload)
        if upload == nil && done == nil && start == nil && wait == nil { return "–" }
        return "\(ms(wait))/\(ms(start))/\(ms(done))/\(ms(upload))"
    }
}
