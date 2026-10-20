import Foundation

/// One strip's native cell aspects (spec §4.2, `strip-aspect=native`): what the thumbnail store knows of the
/// playlist's files, with the unknown ones guessed as the median of the known (`StripLayout.filledAspects`).
///
/// The store is asked for every unknown file when the playlist (or the mode) changes, for a file when the store
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

    public private(set) var mode = StripAspect.native
    /// `exif-orientation`: whether the aspects are the photos' oriented ones (the default) or the stored ones.
    public private(set) var appliesOrientation = true
    /// For `StripLayout`: one per playlist file in native mode, nil in crop mode.
    public private(set) var layoutAspects: StripLayout.Aspects?
    /// Aspects that arrived changed `layoutAspects`: lay out again. Not called for `setMode` / `setPlaylist`,
    /// whose callers lay out anyway.
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
    private var fileSet: Set<URL> = []
    /// What the store said, for the playlist's files only.
    private var known: [URL: Double] = [:]
    /// `known` changed since `layoutAspects` was made.
    private var stale = false
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

    /// `strip-aspect`. Aspects are not followed while cropped, so going native asks for all of them again.
    public func setMode(_ mode: StripAspect) {
        guard mode != self.mode else { return }
        self.mode = mode
        known = [:]
        askedAllAfterFirstCell = false
        makeLayoutAspects()
        ask(all: true)
    }

    /// `exif-orientation` changed: the known aspects (oriented or stored ones) are stale, all are asked for again.
    public func setAppliesOrientation(_ applies: Bool) {
        guard applies != appliesOrientation else { return }
        appliesOrientation = applies
        guard mode == .native else { return }
        known = [:]
        askedAllAfterFirstCell = false
        makeLayoutAspects()
        ask(all: true)
    }

    public func setPlaylist(_ files: [URL]) {
        guard files != self.files else { return }
        self.files = files
        fileSet = Set(files)
        known = known.filter { fileSet.contains($0.key) }
        askedAllAfterFirstCell = false
        makeLayoutAspects()
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

    private func makeLayoutAspects() {
        stale = false
        layoutAspects = mode == .native ? StripLayout.Aspects(StripLayout.filledAspects(files.map { known[$0] })) : nil
    }

    private func ask(_ urls: [URL] = [], all: Bool = false) {
        guard mode == .native, !closed else { return }
        wanted.formUnion(urls.lazy.filter { self.fileSet.contains($0) })
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
            // A playlist, mode or `exif-orientation` that changed meanwhile asked for its own.
            if self.files == playlist, self.mode == .native, self.appliesOrientation == applies {
                for (url, aspect) in found where self.fileSet.contains(url) && self.known[url] != aspect {
                    self.known[url] = aspect
                    self.stale = true
                }
                self.apply()
            }
            if !self.wanted.isEmpty || self.askAll { self.schedule() }
        }
    }

    private func apply() {
        guard stale, !paused, !closed else { return }
        makeLayoutAspects()
        lastChange = now()
        onChange?()
    }
}
