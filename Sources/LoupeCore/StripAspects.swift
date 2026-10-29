import Foundation

/// One strip's photo aspects (width / height, spec 2026-10-21): what the thumbnail store knows of the playlist's
/// files, nil for the rest. `FilmstripLayout` needs no guess: a narrow cell is as wide without its photo's aspect,
/// and the current photo's cell takes `unknownCurrentAspect` until its own arrives.
///
/// The store is asked for every unknown file when the playlist (or `exif-orientation`) changes, for a file when the store
/// reports a thumbnail for it, and once more for every unknown file when the playlist's first cell picture
/// arrives: the folder is synced into the catalog by then, and thumbnails already stored turn up without a
/// notification, so the fetch at the playlist change may have come too early. Fetches run one at a time and no
/// sooner than `interval` after the last change they caused, so a generation pass moves the cells at most that
/// often; what is asked for meanwhile goes with the next fetch. While `paused` (the strip's edge is dragged)
/// arrivals wait and are applied on release.
///
/// Main-actor state with an injected fetch, clock and sleep, so the timing is testable without AppKit.
@MainActor public final class StripAspects {
    /// The sizes the store knows of these files, as shown: turned by EXIF orientation, or as stored when the
    /// second argument (`exif-orientation`) is false.
    public typealias Fetch = @MainActor ([URL], Bool) async -> [URL: Double]

    public nonisolated static let defaultInterval: Duration = .milliseconds(250)

    /// `exif-orientation`: whether the aspects are the photos' oriented ones (the default) or the stored ones.
    public private(set) var appliesOrientation = true
    /// One per playlist file, by index; nil while the store does not know it.
    public private(set) var aspects: [Double?] = []
    /// Aspects that arrived changed `aspects`: lay out again. Not called for `setAppliesOrientation` /
    /// `setPlaylist`, whose callers lay out anyway.
    public var onChange: (() -> Void)?
    /// True while the strip's edge is dragged: the cells keep still. Back to false applies what arrived.
    public var paused = false {
        didSet { if oldValue, !paused { apply() } }
    }

    private let fetch: Fetch
    private let interval: Duration
    private let now: @MainActor () -> ContinuousClock.Instant
    private let sleep: @MainActor (Duration) async -> Void

    private var files: [URL] = []
    /// Each playlist file's index, so an arrival changes its own place in `aspects` (owner, 2026-10-28: making all of
    /// them again on every fetch was ~5 ms on the main thread for 50 000 photos, every 250 ms of a generation pass).
    private var positions: [URL: Int] = [:]
    /// What the store said, for the playlist's files only.
    private var known: [URL: Double] = [:]
    /// Arrived, not in `aspects` yet: by index.
    private var arrived: [Int: Double] = [:]
    /// Asked for at the next fetch: these files, and every unknown one when `askAll`.
    private var wanted: Set<URL> = []
    private var askAll = false
    private var askedAllAfterFirstCell = false
    private var task: Task<Void, Never>?
    private var lastChange: ContinuousClock.Instant?
    private var closed = false

    public init(fetch: @escaping Fetch, interval: Duration = defaultInterval,
                now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
                sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.fetch = fetch
        self.interval = interval
        self.now = now
        self.sleep = sleep
    }

    /// How many of the playlist's files have a known aspect (diagnostics).
    public var knownCount: Int { known.count }

    /// `exif-orientation` changed: the known aspects (oriented or stored ones) are stale, all are asked for again.
    public func setAppliesOrientation(_ applies: Bool) {
        guard applies != appliesOrientation else { return }
        appliesOrientation = applies
        known = [:]
        askedAllAfterFirstCell = false
        makeAspects()
        ask(all: true)
    }

    public func setPlaylist(_ files: [URL]) {
        guard files != self.files else { return }
        self.files = files
        positions = Dictionary(files.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        known = known.filter { positions[$0.key] != nil }
        askedAllAfterFirstCell = false
        makeAspects()
        ask(all: true)
    }

    /// The store reported a status change for `url` (any window's file: others are ignored).
    public func thumbnailArrived(_ url: URL) {
        ask([url])
    }

    /// A cell got `url`'s picture: its `ImageInfo` is known to the store.
    public func cellPictureArrived(_ url: URL) {
        guard known[url] == nil else { return }
        let all = !askedAllAfterFirstCell
        askedAllAfterFirstCell = true
        ask([url], all: all)
    }

    /// The window closed: no more fetches or changes.
    public func close() {
        closed = true
        task?.cancel()
        task = nil
    }

    // MARK: -

    private func makeAspects() {
        arrived = [:]
        aspects = files.map { known[$0] }
    }

    private func ask(_ urls: [URL] = [], all: Bool = false) {
        guard !closed else { return }
        wanted.formUnion(urls.lazy.filter { self.positions[$0] != nil })
        askAll = askAll || all
        guard !wanted.isEmpty || askAll else { return }
        schedule()
    }

    private func schedule() {
        guard task == nil, !closed else { return }
        let due = lastChange.map { $0 + interval }
        task = Task { [weak self] in
            guard let self else { return }
            if let due, due > self.now() { await self.sleep(due - self.now()) }
            guard !Task.isCancelled else { return }
            let playlist = self.files, applies = self.appliesOrientation
            var urls = Array(self.wanted)
            if self.askAll { urls += playlist.filter { self.known[$0] == nil && !self.wanted.contains($0) } }
            self.wanted = []
            self.askAll = false
            let found = urls.isEmpty ? [:] : await self.fetch(urls, applies)
            guard !Task.isCancelled else { return }
            self.task = nil
            // A playlist or `exif-orientation` that changed meanwhile asked for its own.
            if self.files == playlist, self.appliesOrientation == applies {
                for (url, aspect) in found where self.known[url] != aspect {
                    guard let index = self.positions[url] else { continue }
                    self.known[url] = aspect
                    self.arrived[index] = aspect
                }
                self.apply()
            }
            if !self.wanted.isEmpty || self.askAll { self.schedule() }
        }
    }

    private func apply() {
        guard !arrived.isEmpty, !paused, !closed else { return }
        for (index, aspect) in arrived { aspects[index] = aspect }
        arrived = [:]
        lastChange = now()
        onChange?()
    }
}
