import CoreGraphics
import Foundation
import LoupeCore
import LoupeRender

/// A window's auto colour and vibrance (M3c spec §3.1, §4.3): the analyses and colour cubes of the current photo and
/// its neighbours, in `ColorOrder`, `reach` (`cache-previews`) photos in all. Analyses come from the strip's stored
/// thumbnails (never the file) and go into the app's `AutoColorCache`; a photo whose thumbnail is not made yet waits
/// for it (`thumbnailArrived`), and one whose thumbnail cannot be made is left alone (`.noThumbnail`) until the store
/// tells of it again. The cubes are kept here by URL, not on the pyramid, so a seeded thumbnail and the
/// pyramid replacing it draw with the same cube.
///
/// One job at a time: a thumbnail read, then the analysis (only with `auto-color`) and the cube on one serial utility
/// queue. The next job is chosen only when the last one is done, from the order of that moment, so a new order drops
/// whatever of the old one has not started (newest request wins); a job whose photo left the order while its thumbnail
/// was read is dropped before the queue. A settings change rebuilds the cubes from the cached analyses, current photo
/// first, and keeps the cube of before until the new one is there (the view fades between them).
@MainActor final class ColorCorrector {
    /// Called when what `cube(for:)` gives for a URL changed (built, rebuilt, gone because nothing applies) or its
    /// analysis arrived (`status(for:)` leaves `.analysing`): the session passes it on when that photo is on screen.
    /// Never called from inside `update`.
    var onChange: ((URL) -> Void)?

    /// The photo on screen (the session's entry), which may still be the previous photo while the new one loads, or
    /// one of another folder: its cube is kept outside the order until another photo is shown.
    var pinned: URL? {
        didSet {
            if let old = oldValue, old != pinned, !planned.contains(old) { built[old] = nil }
        }
    }

    /// The window cannot be seen (windows spec §3.6): no job starts — `update` takes the order and keeps the cubes
    /// it has, the work waits until the pause is lifted. A job running finishes.
    var isPaused = false {
        didSet { if oldValue && !isPaused { pump() } }
    }

    /// A photo's cube: built for these stamp and settings; `lut` nil when nothing applies. `fingerprint` (the cube's
    /// values hashed) lets a rebuild that comes out the same keep the texture, so the view starts no fade.
    private struct Built {
        let stamp: FileStamp
        let settings: ColorSettings
        let lut: ColorLUT?
        let fingerprint: Int?
    }

    private struct Job: Sendable {
        let url: URL
        let stamp: FileStamp
        let settings: ColorSettings
        /// The cached analysis; nil: none needed (auto colour off) or to be made from the thumbnail.
        let analysis: AutoColorAnalysis?
        /// The photo's colour space when already known; nil: read the thumbnail (it carries it).
        let space: CGColorSpace?
        /// The photo was stale when the job started: only then does its analysis clear that (`ColorRestamps`).
        let wasStale: Bool
    }

    private struct Result: Sendable {
        let space: CGColorSpace
        let lut: ColorLUT?
        let fingerprint: Int?
        let analysed: Bool
    }

    /// A job's end: done, its thumbnail not made yet or never to be made, or dropped (the order moved on).
    private enum Outcome {
        case done(Result)
        case waitsForThumbnail
        case noThumbnail
        case dropped
    }

    private let thumbnails: ThumbnailStore
    private let analyses: AutoColorCache
    private let queue = DispatchQueue(label: "local.loupe.color", qos: .utility)

    /// The order's URLs, current first, and as a set.
    private var plan: [URL] = []
    private var planned: Set<URL> = []
    private var stamps: [URL: FileStamp] = [:]
    private var settings = ColorSettings.off
    private var built: [URL: Built] = [:]
    /// Colour spaces read from thumbnails, for rebuilds without a thumbnail read.
    private var spaces: [URL: (stamp: FileStamp, space: CGColorSpace)] = [:]
    /// Photos of the order whose thumbnail was not made yet: tried again when it arrives.
    private var waiting: Set<URL> = []
    /// Photos of the order whose thumbnail the store cannot make (`ThumbnailStatus.unavailable`): no analysis, no
    /// cube; tried again when the store tells of the file (a new try at the next opening of its folder) or it changes.
    private var noThumbnail: Set<URL> = []
    /// Photos whose file changed while in the order, analysed anew whatever the cache holds.
    private var restamps = ColorRestamps()
    /// The job running (thumbnail read or queue), and whether `startNext` is scheduled.
    private var running: URL?
    private var scheduled = false

    init(thumbnails: ThumbnailStore, analyses: AutoColorCache = .shared) {
        self.thumbnails = thumbnails
        self.analyses = analyses
    }

    /// The photo at `url`'s cube; nil while none is built, when nothing applies and for a file changed since its cube
    /// was built (new pixels never pair with a stale cube).
    func cube(for url: URL) -> ColorLUT? { built[url]?.lut }

    /// What the stats line says about `url`'s colour: `.analysing` while auto colour is on and its analysis is not
    /// there yet, `.noThumbnail` when it cannot be made, and `.nothingToApply` when the photo's cube came out nil
    /// although a share applies (its colour space takes no cube).
    func status(for url: URL) -> ColorStatus {
        guard settings.autoColor else { return .off }
        guard let stamp = stamps[url] else { return .analysing }
        if noThumbnail.contains(url) { return .noThumbnail }
        guard !restamps.isStale(url), let analysis = analyses.analysis(for: url, stamp: stamp) else { return .analysing }
        let status = ColorLUTBuilder.status(analysis, settings: settings)
        if case .applied(_, let share, let delta) = status, share > 0,
           let b = built[url], b.stamp == stamp, b.settings == settings, b.lut == nil {
            return .nothingToApply(delta: delta)
        }
        return status
    }

    /// The window's playlist, position and colour keys, on every change of any. Cubes of photos outside the new order
    /// (but the pinned one) and of files with another stamp are dropped.
    func update(files: [URL], current: Int, direction: Int, stamps: [URL: FileStamp], settings: ColorSettings,
                reach: Int, companion: Int? = nil) {
        plan = ColorOrder.order(count: files.count, current: current, direction: direction, reach: reach,
                                companion: companion)
            .map { files[$0] }
        planned = Set(plan)
        for url in plan {
            if let old = self.stamps[url], let new = stamps[url], old != new {
                restamps.restamp(url)
                noThumbnail.remove(url)
            }
        }
        built = built.filter { url, b in
            (planned.contains(url) || url == pinned) && (stamps[url].map { $0 == b.stamp } ?? !planned.contains(url))
        }
        spaces = spaces.filter { url, s in planned.contains(url) && stamps[url] == s.stamp }
        waiting.formIntersection(planned)
        noThumbnail.formIntersection(planned)
        restamps.keep(planned)
        self.stamps = stamps
        self.settings = settings
        pump()
    }

    /// The store announced `url`'s thumbnail (made, or found impossible to make): a photo waiting for it, or left
    /// without one, is tried again, and one whose file changed is analysed anew from it.
    func thumbnailArrived(_ url: URL) {
        guard planned.contains(url) else { return }
        let wasWaiting = waiting.remove(url) != nil
        let hadNone = noThumbnail.remove(url) != nil
        if restamps.thumbnailArrived(url) {
            spaces[url] = nil
        } else if !wasWaiting, !hadNone {
            return
        }
        pump()
    }

    // MARK: Jobs

    private func pump() {
        guard !isPaused, running == nil, !scheduled else { return }
        scheduled = true
        // On the next turn: an update made in the same turn (a navigation, then the folder's settings) is seen first.
        Task { [weak self] in self?.startNext() }
    }

    /// The first photo of the order that needs work: settled at once when nothing applies to it (no analysis to
    /// make, no vibrance, share 0), otherwise its job is started.
    private func startNext() {
        scheduled = false
        guard !isPaused, running == nil else { return }
        for url in plan where !waiting.contains(url) && !noThumbnail.contains(url) {
            guard let stamp = stamps[url] else { continue }   // no stamp, no key: the listing brings it
            // A stale analysis matters only while one is wanted (it stops being stale when one is made).
            let wasStale = restamps.isStale(url)
            let isStale = settings.autoColor && wasStale
            if !isStale, let b = built[url], b.stamp == stamp, b.settings == settings { continue }
            let analysis = settings.autoColor && !isStale ? analyses.analysis(for: url, stamp: stamp) : nil
            let needsAnalysis = settings.autoColor && analysis == nil
            if !needsAnalysis, !settings.vibrance, ColorLUTBuilder.share(analysis, settings: settings) == 0 {
                if settle(url, Built(stamp: stamp, settings: settings, lut: nil, fingerprint: nil)) { onChange?(url) }
                continue
            }
            let space = needsAnalysis ? nil : spaces[url].flatMap { $0.stamp == stamp ? $0.space : nil }
            start(Job(url: url, stamp: stamp, settings: settings, analysis: analysis, space: space, wasStale: wasStale))
            return
        }
    }

    private func start(_ job: Job) {
        running = job.url
        let thumbnails = self.thumbnails, analyses = self.analyses, queue = self.queue
        Task { [weak self] in
            let (image, status) = job.space == nil ? await thumbnails.imageOrStatus(job.url) : (nil, .ready)
            guard let self else { return }
            guard job.space != nil || image != nil else {
                self.finish(job, status == .unavailable ? .noThumbnail : .waitsForThumbnail)
                return
            }
            // The order moved on while the thumbnail was read: the job is dropped before it takes the queue.
            guard self.planned.contains(job.url), self.stamps[job.url] == job.stamp else {
                self.finish(job, .dropped)
                return
            }
            let result = await withCheckedContinuation { (done: CheckedContinuation<Result, Never>) in
                queue.async { done.resume(returning: Self.run(job, image: image, analyses: analyses)) }
            }
            self.finish(job, .done(result))
        }
    }

    /// The job's work on the queue: the analysis (stored in the cache) when it has none and auto colour is on, then the
    /// cube in the photo's space, uploaded.
    nonisolated private static func run(_ job: Job, image: CGImage?, analyses: AutoColorCache) -> Result {
        let clock = ContinuousClock()
        var analysis = job.analysis, analysisTime: Duration?
        if analysis == nil, job.settings.autoColor, let image {
            let start = clock.now
            let made = AutoColorAnalyzer.analyse(image)
            analyses.store(made, for: job.url, stamp: job.stamp)
            if made.droppedSpatialSteps > 0 {
                DebugLog.log("colour \(job.url.lastPathComponent): dropped \(made.droppedSpatialSteps) spatial step(s)"
                             + " (shadows and highlights with a radius)")
            }
            analysis = made
            analysisTime = clock.now - start
        }
        let space = job.space ?? image?.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let start = clock.now
        let cube = ColorLUTBuilder.cube(analysis: analysis, settings: job.settings, colorSpace: space)
        let lut = cube.flatMap { ColorLUT.make($0) }
        let cubeTime = clock.now - start
        let name = job.url.lastPathComponent
        if cube == nil, space.model != .rgb || CGColorSpaceCreateLinearized(space) == nil,
           job.settings.vibrance || ColorLUTBuilder.share(analysis, settings: job.settings) > 0 {
            let spaceName = space.name.map { $0 as String } ?? "\(space.model)"
            DebugLog.log("colour \(name): no cube, \(spaceName) has no linear RGB variant")
        }
        func ms(_ d: Duration?) -> String { d.map { String(format: "%.1f", $0 / .milliseconds(1)) } ?? "-" }
        DebugLog.log("colour \(name): analysis \(ms(analysisTime)) ms, cube \(ms(cubeTime)) ms"
                     + (lut == nil ? " (none)" : ""))
        var hasher = Hasher()
        cube.map { hasher.combine($0.values) }
        return Result(space: space, lut: lut, fingerprint: cube == nil ? nil : hasher.finalize(),
                      analysed: analysisTime != nil)
    }

    /// Back on the main actor: the result is kept only for the photo's stamp of now, and the cube only for the
    /// settings of now (otherwise the next job rebuilds it from the analysis just cached).
    private func finish(_ job: Job, _ outcome: Outcome) {
        running = nil
        defer { pump() }
        guard planned.contains(job.url), stamps[job.url] == job.stamp else { return }
        let result: Result
        switch outcome {
        case .done(let r): result = r
        case .waitsForThumbnail: waiting.insert(job.url); return
        case .noThumbnail:
            noThumbnail.insert(job.url)
            if settings.autoColor { onChange?(job.url) }   // `status(for:)` leaves `.analysing`
            return
        case .dropped: return
        }
        // A job that started before the photo went stale may have analysed the old thumbnail: it stays stale.
        if result.analysed { restamps.analysed(job.url, startedStale: job.wasStale) }
        spaces[job.url] = (job.stamp, result.space)
        var changed = result.analysed
        if job.settings == settings {
            let old = built[job.url]
            let same = result.fingerprint != nil && old?.stamp == job.stamp && old?.fingerprint == result.fingerprint
            changed = settle(job.url, Built(stamp: job.stamp, settings: job.settings, lut: same ? old?.lut : result.lut,
                                            fingerprint: result.fingerprint)) || changed
        }
        if changed { onChange?(job.url) }
    }

    /// Keeps `b` as `url`'s cube; true when `cube(for:)` changed.
    private func settle(_ url: URL, _ b: Built) -> Bool {
        let before = built[url]?.lut
        built[url] = b
        return b.lut !== before
    }
}
