import CoreGraphics
import Foundation
import HomeScreenModel
import LoupeCore
import LoupeRender

/// What one viewer shows: the folder's playlist, the cache entry on screen and the view transform.
/// Loading belongs to the process-wide `ImageCache` (M2 spec §4.5): the session tells it where the viewer is
/// (`CacheFocus`), reads the current photo's entry and shows it once it is sharp enough (`ShowPolicy`); until
/// then the previous photo stays with "Loading…". The photo on screen is pinned in the cache (`setPinned`), so it
/// is never evicted while shown. It knows nothing about AppKit or Metal layers, so a tab per
/// session (M6) is just another instance.
@MainActor final class ViewerSession {
    /// The dwell delay: a photo the user stays on this long is worth its full resolution (spec §3.5, a constant).
    static let dwellDelay: Duration = .milliseconds(150)

    let cache: ImageCache<MetalPyramidLoader>
    /// The app's one thumbnail store, shared by every window: it hears this session's folder, position and
    /// visible strip cells (`setRequest`) on every change of them.
    let thumbnails: ThumbnailStore
    private let positions: FolderPositions
    private let navigator: FolderNavigator
    private(set) var playlist: Playlist? {
        didSet {
            // Leaving a photo (any navigation, a re-read that lost it, another folder) saves how it was looked at.
            if let left = oldValue?.current, left != playlist?.current { recordView(of: left) }
            // The pair the new position is in (no cache call here: the navigation that set the playlist makes them).
            updateSpread()
            // Entering another folder (open, folder switch) moves the watcher with it.
            guard !closed, let folder = playlist?.current.deletingLastPathComponent(),
                  folder != oldValue?.current.deletingLastPathComponent() else { return }
            watcher.watch(folder)
        }
    }
    /// What is on screen: the current photo's entry once it qualified, or the previous photo's until then.
    /// A failed current photo is shown too (its `failure` set, nothing drawn).
    private(set) var entry: CacheEntryView<TiledImage>?
    /// The entry was already resident (sharp enough) when navigation reached it.
    private(set) var shownFromCache = false
    /// The current photo's failure, including the file name; cleared on navigation.
    private(set) var error: String?
    /// File name of the photo waiting to become sharp enough, for a "Loading…" line; nil when it is shown.
    private(set) var loadingName: String?
    /// A line about folder navigation that wins over everything else in the stats bar: "Loading folder…" while
    /// the neighbour is being found, or why it failed. Cleared when the photo changes or a file is opened.
    private(set) var folderMessage: String?
    /// The folder an open entered whose listing is not in yet: its interim one-file playlist says nothing of the count,
    /// so the stats bar gives `N / …` (`folderCounted`). Cleared by the quick names pass or the listing, whichever is first.
    private var uncountedFolder: URL?
    /// False while the current photo's folder is still being listed after an open.
    var folderCounted: Bool { uncountedFolder == nil || uncountedFolder != playlist?.current.deletingLastPathComponent() }

    /// The colour cube (auto colour, vibrance; M3c) of the photo at `url`, nil: none ready or none wanted. The view asks
    /// for the entry on screen on every change and hands it to the render loop with the image (`ShownColor`); a cube of
    /// that photo arriving or changing later is a change (`onChange`).
    func colorCube(for url: URL) -> ColorLUT? { colorCorrector.cube(for: url) }

    /// What the stats line says about the colour of the photo at `url` (M3c spec §2.3).
    func colorStatus(for url: URL) -> ColorStatus { colorCorrector.status(for: url) }

    /// The window's colour keys (folder-aware, `ViewerWindowController.effectiveConfig`) and `cache-previews`, the
    /// number of photos around the current one that get a cube; set by the window controller.
    func setColor(_ settings: ColorSettings, reach: Int) {
        guard settings != colorSettings || reach != colorReach else { return }
        colorSettings = settings
        colorReach = reach
        sendColorPlan()
    }

    /// The pyramid to draw: nothing for a failed photo.
    var image: TiledImage? { entry?.failure == nil ? entry?.pyramid : nil }

    /// The colour space the current photo's pixels will come in (from its header), while nothing is drawn yet (a
    /// launch, after a failure): the view tags its layer with it ahead of them (`RenderLoop.expectColorSpace`). Nil
    /// while an image is drawn, before the header is read, and for a non-RGB header (the decoder converts those).
    var incomingColorSpace: CGColorSpace? {
        guard image == nil, let latest, latest.url == playlist?.current, latest.failure == nil,
              let space = latest.info?.colorSpace, space.model == .rgb else { return nil }
        return space
    }

    /// The screen shows only the photo's stretched thumbnail (its one resident level is the seeded one): the stats
    /// bar's `thumb` and the loading spinner.
    var showsThumbnailOnly: Bool { entry.map { $0.isSeededOnly && $0.failure == nil } ?? false }

    /// `exif-orientation` as this session lays photos out: the transform's image size is the photo's `displaySize`
    /// with it, so it changes only together with the transform (`updateOrientationSetting`).
    private(set) var appliesOrientation = Settings.shared.config.exifOrientation

    /// The orientation `image` is drawn with: the photo's for its decoded levels, none of its own for a seeded
    /// thumbnail, which is turned already (`ImageInfo.drawOrientation`, review focus 1).
    var drawOrientation: ImageOrientation {
        guard let entry, let info = entry.info else { return .up }
        return info.drawOrientation(applying: appliesOrientation, seeded: entry.pyramidIsSeeded)
    }

    /// How well the screen shows the current photo (`ShownQuality`), nil while it still shows another one (or
    /// nothing): the wheel and the keys wait on it (`StepGate.photoShown`), read on every `onChange`.
    var shownQuality: ShownQuality? {
        guard let entry, entry.url == playlist?.current else { return nil }
        let needed = entry.info.map { levels(for: $0, of: entry.url).needed } ?? 0
        return ShownQuality.of(finestResident: entry.pyramid?.finestResidentLevel, neededLevel: needed,
                               seededOnly: entry.isSeededOnly, failed: entry.failure != nil)
    }

    /// The pixel size of the screen the window is on (set by the window controller): the cache sizes previews
    /// for it (Lfit).
    var screenSize = PixelSize(width: 0, height: 0) {
        didSet {
            guard screenSize != oldValue else { return }
            sendFocus()
            refresh()
        }
    }

    /// The view sets `viewSize`; switching photos gives the new photo the view `PhotoSwitchView` chooses (M4b spec §4.2:
    /// with keep-zoom-position=yes the mode and relative centre stay). Every change is reported through `onChange`.
    var transform = ViewTransform(imageSize: .zero, viewSize: .zero) {
        didSet {
            guard transform != oldValue else { return }
            onChange?()
            transformDidChange()
            if transform.viewSize != oldValue.viewSize { viewSizeDidChange() }
        }
    }

    /// Where a running zoom animation of the view ends (M4b spec §2.2), nil when none runs: the stats bar, the info
    /// panel, the cache's judgement (`needsFull`, the show rules) and the saved view read it instead of `transform`,
    /// so 100 % starts loading its full resolution on the first frame and a navigation keeps the mode the key asked
    /// for. The view sets it with the animation and clears it at the end; `settleZoom()` jumps there.
    var zoomTarget: ViewTransform? {
        didSet {
            guard zoomTarget != oldValue else { return }
            onChange?()
            transformDidChange()
        }
    }

    /// The transform the zoom is going to: the target while an animation runs, else what is on screen.
    private var judgedTransform: ViewTransform { zoomTarget ?? transform }

    /// A running zoom animation jumps to its end (spec §2.3): before a navigation, a resize or an orientation change,
    /// so the operation starts from the mode the key asked for. The view's animation sees the target gone and stops.
    func settleZoom() {
        guard let target = zoomTarget else { return }
        transform = target
        zoomTarget = nil
    }

    /// `fit-upscale` changed (a config reload, the Zoom menu's checkbox): the photo on screen takes it at once (M4b spec
    /// §4.3); a free zoom keeps the scale it is drawn at (`withFitUpscale`). A running zoom animation jumps to its end
    /// first, so its frames do not bring the old flag back.
    func setFitUpscale(_ on: Bool) {
        guard judgedTransform.fitUpscale != on || transform.fitUpscale != on else { return }
        settleZoom()
        transform = transform.withFitUpscale(on)   // didSet notifies; the window redraws
    }

    /// The zoom rules of the folder a photo is in (`keep-zoom-position`, `default-zoom-mode`, `fit-upscale`): the window
    /// controller sets it from that folder's settings over loupe.conf. Asked with the photo, so a folder step takes the
    /// new folder's rules.
    var zoomRules: (URL) -> ZoomRules = { _ in ZoomRules(config: Settings.shared.config) }

    /// A window resize keeps the free zoom's scale rather than its framing (`keep-zoom-as=scale` in the photo's folder).
    var resizeKeepsScale: Bool { playlist.map { zoomRules($0.current).carry == .scale } ?? false }

    /// Called on the main actor after any state change above.
    var onChange: (() -> Void)?

    /// The analyses and cubes of the current photo and its neighbours; told the playlist and position with the cache.
    private let colorCorrector: ColorCorrector
    private var colorSettings = ColorSettings(config: Settings.shared.config)
    private var colorReach = Settings.shared.config.cachePreviews
    private var thumbnailObserver: NSObjectProtocol?

    /// File indices of the strip's visible cells (`FilmstripView.visibleItems`, from the centre outwards), `[]` while
    /// the strip is hidden: the store makes those thumbnails first.
    var stripVisibleFiles: [Int] = [] {
        didSet { if stripVisibleFiles != oldValue { sendThumbnailRequest() } }
    }

    /// Whether this session's window is the key window (set by the window controller): the key window's
    /// thumbnails come first.
    var isKeyWindow = false {
        didSet { if isKeyWindow != oldValue { sendThumbnailRequest() } }
    }

    /// Re-reads the folder when it changes (kqueue, polling); armed for the current playlist's folder.
    private let watcher = FolderWatcher()
    /// The folder listings out or queued (`rereadFolder`).
    private var rereads = Rereads()
    private var folderTask: Task<Void, Never>?
    /// While set, folder steps go through this list (a gallery opened from a Stash list) instead of the disk; any open
    /// that is not from Stash clears it (`open`).
    var stashNavigator: ListFolderNavigator?
    /// Home's Recent (Home spec §2.4): every folder entered goes to its front, every photo shown updates it. Nil: none
    /// kept (a secondary instance).
    var recent: RecentStore?
    /// False for a tab a session restore opened, until the first step in it (Home spec §2.4): restoring a session
    /// would otherwise reorder all of Recent.
    var recordsRecent = true
    /// The next folder entered was opened from outside (Finder, ⌘O, Home): it forgets a Stash gallery Recent kept for it.
    var entersFromOutside = false
    /// The folder Recent was last told was entered.
    private var recentFolder: URL?
    /// A folder step entered a target with a label (a Stash gallery's title and place): the window shows it.
    var onFolderLabel: ((String) -> Void)?
    /// A folder step through `stashNavigator` entered a list item: its id there (the Stash gallery's) and its folder.
    var onListFolder: ((String?, URL) -> Void)?
    /// `openFolder`'s listing, and the token that makes the latest call win.
    private var openFolderTask: Task<Void, Never>?
    private var openFolderToken = 0
    private var folderRequest = FolderRequest()
    private var dwellTask: Task<Void, Never>?
    /// Every cache call goes through this chain, so focus changes and entry reads reach the actor in the order
    /// they were made (a read after a navigation sees the focus it set). It runs off the main actor (`enqueue`).
    private var chain: Task<Void, Never>?
    /// The last step's sign (+1 / -1) and whether the current photo has been dwelt on.
    private var direction = 1
    /// The playlist index of the photo that was current before this one (spec §11.1.7: it keeps its full
    /// resolution if it has it); nil after opening a file or when the playlist was replaced.
    private var previousIndex: Int?
    private var dwelling = false
    /// The current photo was opened from outside (`open`) and no other navigation came since: its full resolution is
    /// decoded with its preview, without the dwell (`CacheFocus.opened`).
    private var opened = false
    /// The strip scrub (`scrub(to:)` until `endScrub()`) and the photo it started from: while it is on, the focus
    /// says `scrubbing`, so the cache reads and decodes nothing while the cursor moves (M2.5 spec §5.3).
    private var scrubState = StripScrub()
    private var isScrubbing: Bool { scrubState.isOn }
    /// The current photo was reached from the strip (a scrub or a click on it) and no other navigation came since:
    /// its seeded thumbnail is shown at once (`strip-jump-preview`, spec §5.2).
    private var jumpedFromStrip = false
    /// The current photo was reached by a wheel or key step that waits for it (`wheel-step`, `key-step`) and no other
    /// navigation came since: it is shown as soon as it is what the wait asks for (`ShowPolicy.shownByStep`), and for
    /// `thumb` its stored thumbnail is seeded when nothing of it is resident, whatever `strip-jump-preview` says.
    private var stepWait: StepWait?
    /// The file whose thumbnail is being turned into a seed: one at a time, so a fast sweep queues nothing; when it
    /// is done, the file under the cursor then is next.
    private var seeding: URL?
    private var sentFocus: CacheFocus?
    /// The playlist sent with `sentFocus`: a new folder of the same length at the same index is still a change.
    private var sentFiles: [URL] = []
    /// What the thumbnail store last heard from this window, so a pan (every frame) sends nothing.
    private var sentThumbnailRequest: ThumbnailRequest?
    private var sentStamps: [URL: FileStamp] = [:]
    /// Every store call goes through this chain, so requests arrive in the order they were made; its first link
    /// waits for `thumbnailsReady` (the cache's activity has reached the store).
    private var thumbnailChain: Task<Void, Never>?
    /// Set by `close()`: the store has been told the window is gone, so no request may follow.
    private var closed = false
    /// The latest entry read for the current photo (shown or not): its header decides `needsFull`, and a
    /// zoom change re-checks it against the new scale.
    private var latest: CacheEntryView<TiledImage>?
    /// `needsFull` as last computed for the transform, to resend the focus when a zoom crosses Lfit.
    private var lastNeedsFull: Bool?
    /// The folder's saved view, which a fresh arrival of the current photo brought (`navigated(fresh:)`), until its
    /// first show applies it or not (`ViewRestore`); nil for any other arrival.
    private var restore: ViewRestore?
    /// The photo `open` brought (a launch, Finder's Open) until its first show lays it out: it opens in its folder's
    /// `default-zoom-mode` (M4b spec §4.2). Nil after any other navigation.
    private var freshOpen: URL?
    /// The photo the transform is laid out for (the last one shown with its header): a later show of it (a finer
    /// level) keeps the view it has; any other photo gets the view `PhotoSwitchView` chooses.
    private var laidOut: URL?

    /// `thumbnailsReady` finishes once the store knows the viewer cache's activity: it starts out `.idle`, and a
    /// request before that could start a thumbnail read while the first photo loads.
    init(cache: ImageCache<MetalPyramidLoader>, thumbnails: ThumbnailStore, thumbnailsReady: Task<Void, Never>? = nil,
         positions: FolderPositions, navigator: FolderNavigator = FolderNavigator()) {
        self.cache = cache
        self.thumbnails = thumbnails
        self.positions = positions
        self.navigator = navigator
        thumbnailChain = thumbnailsReady
        colorCorrector = ColorCorrector(thumbnails: thumbnails)
        colorCorrector.onChange = { [weak self] url in
            guard let self, url == self.entry?.url || url == self.shownCompanion?.url else { return }
            self.onChange?()
        }
        // A thumbnail the corrector waits for (spec §3.1: the file is never read for an analysis).
        thumbnailObserver = NotificationCenter.default.addObserver(forName: .thumbnailChanged, object: nil,
                                                                   queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let url = note.object as? URL else { return }
                self?.colorCorrector.thumbnailArrived(url)
                if self?.folderSpread.on == true { self?.spreadAspects?.thumbnailArrived(url) }   // its aspect is known now
            }
        }
        watcher.onChange = { [weak self] isPoll in self?.rereadFolder(isPoll ? .idle : .event) }
        // First in the chain, so no update of the first photo is missed.
        let handler: @Sendable (URL) -> Void = { [weak self] url in
            Task { @MainActor in self?.cacheDidUpdate(url) }
        }
        let id = cacheID
        // Inactive and invisible until its window's registry says otherwise (`WindowRegistry`): the first window's is
        // made active as it is added, before its first photo is asked for.
        enqueue { await cache.register(id, onUpdate: handler) }
    }

    /// This session in the shared cache: the same id as its window's in the thumbnail store.
    var cacheID: CacheSessionID { CacheSessionID(sessionID) }

    /// Never reused, unlike an object's address: a closed session's `unregister` may still be on its way when the
    /// next session is made, and must not remove that one. Above `CacheSessionID.solo` (0).
    private let sessionID: Int = {
        defer { ViewerSession.nextID += 1 }
        return ViewerSession.nextID
    }()
    private static var nextID = 1
    /// Numbers every activation sent (`setActivity`), so the cache can tell a stale one from another session's chain.
    private static var nextActivation: UInt64 = 1

    /// Whether this session's window is the one in front (`active`: the cache plans its playlist) and on screen, as
    /// last told the cache.
    private var isCacheActive = false
    private var isCacheVisible = false
    /// How recently the window was key (`WindowRegistry.activityRank`): the other windows' thumbnails go by it.
    private var lastActive = 0 {
        didSet { if lastActive != oldValue { sendThumbnailRequest() } }
    }

    /// Tells the cache whether this session is the active one and whether it is on screen. An activation is always
    /// sent (the cache may have made another session active meanwhile), numbered so the cache drops one overtaken by a
    /// later one from another session's chain; anything else only when it changed. The cache checks the current
    /// photo's stamp on the activation itself (a file changed while another window was in front). A window that cannot
    /// be seen polls no folder and starts no colour analysis (windows spec §3.6); `lastActive` goes to the thumbnails.
    /// With `LOUPE_DEBUG` an activation logs what it found (`StatsLine.activationLog`, windows spec §3.8).
    func setActivity(active: Bool, visible: Bool, lastActive: Int) {
        guard !closed else { return }
        self.lastActive = lastActive
        watcher.isPaused = !visible
        colorCorrector.isPaused = !visible
        guard active || active != isCacheActive || visible != isCacheVisible else { return }
        isCacheActive = active
        isCacheVisible = visible
        let order = Self.nextActivation
        if active { Self.nextActivation += 1 }
        let cache = self.cache, id = cacheID
        enqueue {
            let activation = await cache.setActivity(id, active: active, visible: visible, order: active ? order : nil)
            if let activation { DebugLog.log(StatsLine.activationLog(session: id.raw, activation)) }
        }
    }

    /// Shows `url` and lists its folder in parallel; a slow SMB listing never delays the image. A file of the
    /// folder already shown keeps that playlist meanwhile; any other starts as just this file (navigation goes
    /// nowhere yet). The cache keeps whatever the interim playlist leaves out while it fits, so neither way drops
    /// what is cached (spec §11.1: entries leave lazily). The listing is a re-read (`rereadFolder`): the user may
    /// move within a reused playlist meanwhile, and the listing keeps that photo.
    /// A session tab's photo (Home spec §2.6): its saved view goes to the folder's memory first, so the open restores it.
    func open(_ url: URL, view: SavedView?) {
        if let view, !ArchivePath.isArchive(url) {
            positions.record(folder: url.deletingLastPathComponent(), file: url.lastPathComponent, view: view)
        }
        open(url)
    }

    /// How the photo on screen is looked at (`SavedView.text`), for a session snapshot; nil while none is shown.
    var currentViewText: String? {
        guard let entry, entry.failure == nil, entry.info != nil, entry.url == playlist?.current else { return nil }
        return SavedView(judgedTransform).text
    }

    func open(_ url: URL) {
        stashNavigator = nil
        cancelOpenFolder()
        // A zip from Finder, `open` or Open… opens like a folder (Stash spec §2.4); `openFolder` lists it off the main
        // thread, a directory that happens to be named `.zip` too.
        if ArchivePath.isArchive(url) {
            openFolder(url)
            return
        }
        let file = url.standardizedFileURL
        // A photo that is not on screen (Finder, a launch) arrives fresh and gets its folder's saved view
        // (`folder-view-memory`); the photo on screen keeps the view it has.
        let fresh = file != playlist?.current
        if var list = playlist, let index = list.files.firstIndex(of: file) {
            // Moved within the list as it is: no re-sort, and a hidden or odd file it keeps stays in it.
            _ = list.move(by: index - list.index)
            playlist = list
        } else {
            playlist = Playlist(files: [file], current: file)
            uncountedFolder = file.deletingLastPathComponent()
            endScrubOnReplace()
        }
        navigated(direction: 1, from: nil, fresh: fresh, opened: true)
        rereadFolder(.open)
        if uncountedFolder == file.deletingLastPathComponent() { quickList(file) }
    }

    /// Opens a folder or a zip archive (Finder, Stash): its photos, landing on the one last viewed there (or the
    /// first), as a folder step lands. Listed off the main thread, the stats line saying "Loading folder…" meanwhile;
    /// the latest call wins. `completion` gets true once the folder is entered, false when it cannot be listed or has
    /// no photos (the stats line then says why).
    /// `isWanted` is asked once the listing is in: false (a newer Stash click) leaves the photos as they are.
    func openFolder(_ folder: URL, isWanted: (@MainActor () -> Bool)? = nil,
                    completion: (@MainActor (Bool) -> Void)? = nil) {
        cancelOpenFolder()
        let token = openFolderToken, navigator = self.navigator, name = folder.lastPathComponent
        folderMessage = FolderRequest.loadingText
        onChange?()
        openFolderTask = Task { [weak self] in
            let result: Result<FolderTarget?, Error>
            do { result = .success(try await navigator.contents(of: folder)) } catch { result = .failure(error) }
            guard let self, token == self.openFolderToken, isWanted?() ?? true else { return }
            switch result {
            case .success(let target?):
                let positions = self.positions
                let sort = BrowserSort.forFolder(target.folder, settings: Settings.shared.folderSettings)
                self.playlist = FolderRequest.playlist(for: target, sort: sort) { positions.recall(in: $0, among: $1) }
                self.endScrubOnReplace()
                self.navigated(direction: 1, from: nil, fresh: true)   // clears the message
                completion?(true)
            case .success(nil):
                self.folderMessage = "No photos in “\(name)”"
                self.onChange?()
                completion?(false)
            case .failure(let error):
                self.folderMessage = FolderRequest.listErrorText(error, name: name)
                self.onChange?()
                completion?(false)
            }
        }
    }

    /// A later open or folder step wins over a folder still listing.
    private func cancelOpenFolder() {
        openFolderToken &+= 1
        openFolderTask?.cancel()
        openFolderTask = nil
    }

    /// The names-only pass after an open (`Playlist.quickList`): on a slow share it gives the folder's photos in
    /// ~0.05 s where the listing takes seconds. Applied only while that listing is still out (its stamps then follow
    /// as an ordinary re-read); the steps waiting on the listing are answered by it.
    private func quickList(_ file: URL) {
        let folder = file.deletingLastPathComponent()
        Task { [weak self] in
            let started = ContinuousClock.now
            let listed = await Playlist.quickList(current: file)
            guard let self, !self.closed, self.uncountedFolder == folder,
                  self.playlist?.current.deletingLastPathComponent() == folder else { return }
            DebugLog.log("folder names \(folder.lastPathComponent): \(listed.map { "\($0.files.count) files" } ?? "failed") "
                         + "in \(Int((ContinuousClock.now - started) / .milliseconds(1))) ms")
            guard let listed else { return }
            self.uncountedFolder = nil
            if !self.apply(listed) { self.onChange?() }   // the count is known now, even where nothing changed
            for waiter in self.rereads.takeWaiters(folder) { waiter() }
        }
    }

    /// Next (`step` > 0) or previous file, or pair of pages while two are shown (`SpreadNavigation`: the first page
    /// of the pair `step` pairs away). Returns false at either end of the playlist (no wrap-around); the
    /// folder is then re-read, and the step made once more if files were added (spec §4.5). `wait`: the wheel's
    /// `wheel-step` or the keys' `key-step`, which decides what of the new photo is shown at once (see `stepWait`);
    /// nil for other steps.
    @discardableResult
    func go(by step: Int, wait: StepWait? = nil) -> Bool {
        guard var list = playlist else { return false }
        let before = list.index
        guard let target = spread.target(from: before, by: step, count: list.files.count),
              list.move(by: target - before) else {
            stepAfterReread(step)
            return false
        }
        playlist = list
        navigated(direction: step.signum(), from: before, wait: wait)
        return true
    }

    /// A step past the end of the known list: once a re-read that started after it is in, the step is retried if
    /// the user is still on the photo the step left from (a burst of steps at the end makes at most one; at a list
    /// that did not grow the retry just fails again).
    private func stepAfterReread(_ step: Int) {
        guard let from = playlist?.current else { return }
        rereadFolder(.step { [weak self] in
            guard let self, var list = self.playlist, list.current == from else { return }
            let before = list.index
            guard let target = self.spread.target(from: before, by: step, count: list.files.count),
                  list.move(by: target - before) else { return }
            DebugLog.log("folder grew at the end: step \(step) retried")
            self.playlist = list
            self.navigated(direction: step.signum(), from: before)
        })
    }

    // MARK: Folder changes

    typealias Rereads = FolderRereads<@MainActor () -> Void>

    /// Re-reads the current folder off the main thread (spec §4.5: `.open`, `.event` for kqueue, `.idle` for a poll
    /// or the app's activation, `.step` past an end) and applies it: the current photo stays by URL; gone, the file
    /// now at its index is shown. An unchanged folder changes nothing; one that cannot be listed keeps the playlist.
    /// When a listing starts, how requests fold into one and when one is dropped is `FolderRereads`'s.
    func rereadFolder(_ request: Rereads.Request = .idle) {
        guard !closed, let folder = playlist?.current.deletingLastPathComponent() else { return }
        perform(rereads.request(request, folder: folder, now: .now), folder: folder)
    }

    private func perform(_ action: Rereads.Action, folder: URL) {
        switch action {
        case .none:
            break
        case .start:
            startListing(folder)
        case .startAfter(let delay):
            DebugLog.log("folder re-read \(folder.lastPathComponent) in \(Int(delay / .milliseconds(1))) ms (ten listings apart)")
            Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard let self else { return }
                let isCurrent = !self.closed && self.playlist?.current.deletingLastPathComponent() == folder
                if self.rereads.begin(folder, isCurrent: isCurrent) { self.startListing(folder) }
            }
        }
    }

    private func startListing(_ folder: URL) {
        guard !closed, let list = playlist, list.current.deletingLastPathComponent() == folder else {
            _ = rereads.finish(folder, took: .zero, now: .now, outcome: .dropped)
            return
        }
        let anchor = list.current, keeping = list.files
        Task { [weak self] in
            let started = ContinuousClock.now
            let listed = await Playlist.relist(current: anchor, keeping: keeping)
            let took = ContinuousClock.now - started
            guard let self else { return }
            var outcome = Rereads.Outcome.dropped
            if !self.closed, let now = self.playlist?.current, now.deletingLastPathComponent() == folder {
                // The listing checked only its anchor for a photo it leaves out: one opened or reached meanwhile that
                // it does not show is settled by another listing, anchored on it.
                outcome = listed.map { now != anchor && !$0.files.contains(now) } == true ? .rerun : .applied
            }
            DebugLog.log("folder re-read \(folder.lastPathComponent): \(listed.map { "\($0.files.count) files" } ?? "failed") "
                         + "in \(Int(took / .milliseconds(1))) ms, \(outcome)")
            let (waiters, next) = self.rereads.finish(folder, took: took, now: .now, outcome: outcome)
            if case .dropped = outcome { return }
            if case .applied = outcome {
                let counting = self.uncountedFolder == folder
                if counting { self.uncountedFolder = nil }
                if let listed { self.apply(listed) } else if counting { self.onChange?() }
            }
            self.watcher.listed(in: took, succeeded: listed != nil)
            for waiter in waiters { waiter() }
            self.perform(next, folder: folder)
        }
    }

    /// Replaces the playlist with a re-read one if anything changed. A new current photo (the old one is gone) is
    /// a navigation in the direction of travel; otherwise the cache and the store just get the new list. False: nothing
    /// changed.
    @discardableResult
    private func apply(_ listed: Playlist) -> Bool {
        guard let old = playlist else { return false }
        let folder = listed.current.deletingLastPathComponent()
        let new = old.replacing(with: listed.sorted(BrowserSort.forFolder(folder, settings: Settings.shared.folderSettings)))
        guard new.files != old.files || new.stamps != old.stamps else { return false }
        DebugLog.log("folder changed: \(old.files.count) -> \(new.files.count) files, "
                     + "current \(new.current == old.current ? "kept" : "gone, now \(new.current.lastPathComponent)")")
        playlist = new
        let scrubEnded = endScrubOnReplace()
        if new.current != old.current {
            navigated(direction: direction, from: nil)
            return true
        }
        // The photo before this one keeps its full resolution by URL, wherever it moved in the list.
        previousIndex = previousIndex.flatMap { old.files.indices.contains($0) ? new.files.firstIndex(of: old.files[$0]) : nil }
        sendFocus()
        if scrubEnded { startDwell(on: new.current) }
        sendThumbnailRequest()
        sendColorPlan()
        companionDidChange()   // the list grew or shrank around the photo: its pair may have another page
        onChange?()
        return true
    }

    /// Next (`step` > 0) or previous sibling folder that has images, landing on the photo last viewed there
    /// (or its first). The siblings are found off the main thread; meanwhile the stats line says "Loading
    /// folder…" and the current photo stays. At the first / last sibling nothing happens; a failure keeps the
    /// current folder and says why. A second request while one is pending is ignored.
    func goFolder(by step: Int) {
        guard let current = playlist?.current, let token = folderRequest.begin(from: current) else { return }
        cancelOpenFolder()
        folderMessage = FolderRequest.loadingText
        onChange?()
        let navigator = self.navigator, stash = stashNavigator
        let archives = Settings.shared.config.archiveFolders
        let folder = current.deletingLastPathComponent()
        folderTask = Task { [weak self] in
            let result: Result<FolderTarget?, Error>
            do {
                // A gallery opened from a Stash list steps through that list (Stash spec §2.3); any other folder by disk.
                let target = if let stash { try await stash.neighbour(of: folder, step: step) }
                             else { try await navigator.neighbour(of: folder, step: step, archives: archives) }
                result = .success(target)
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            let found = (try? result.get()) ?? nil
            let label = found?.label
            let positions = self.positions
            let settings = Settings.shared.folderSettings
            let outcome = self.folderRequest.finish(token, result: result, current: self.playlist?.current,
                                                    sort: { BrowserSort.forFolder($0, settings: settings) }) {
                positions.recall(in: $0, among: $1)
            }
            switch outcome {
            case .drop:
                return
            case .stay:
                self.folderMessage = nil
                self.onChange?()
            case .enter(let list):
                // Replaces the playlist; the cache gets the new files with the focus. The old folder's entries stay
                // while they fit (going back finds them) and are the first evicted when they do not. An unfinished
                // listing of the old folder is dropped when it arrives (`startListing` checks the folder).
                // The photo landed on (the remembered one, else the first) arrives fresh: the folder's saved view.
                self.playlist = list
                self.endScrubOnReplace()
                self.navigated(direction: 1, from: nil, fresh: true)   // clears the message
                if let label { self.onFolderLabel?(label) }
                if let found, stash != nil { self.onListFolder?(found.listID, found.folder) }
            case .fail(let text):
                self.folderMessage = text
                self.onChange?()
            }
        }
    }

    /// The sibling lists and empty-folder marks are remembered per session; the app calls this when it comes
    /// to the front so folders added or filled meanwhile are found.
    func forgetFolderListings() {
        let navigator = self.navigator
        Task { await navigator.invalidate() }
    }

    /// A press or drag on the strip reached the file at `index` (spec §4.3, §5.3): it becomes current with a
    /// scrubbing focus (nothing is read or decoded for any file meanwhile), and its stored thumbnail is seeded into
    /// the cache and shown stretched at once. `endScrub()` gives it the normal plan; a click is both. The photo the
    /// scrub started from stays the previous one (it keeps its full resolution), not each file passed over; a press
    /// on the current photo's cell does nothing until the drag leaves it (`StripScrub`).
    func scrub(to index: Int) {
        guard var list = playlist, list.files.indices.contains(index) else { return }
        let before = list.index, wasScrubbing = isScrubbing
        switch scrubState.reach(index, current: before) {
        case .none:
            return
        case .stay:
            jumpedFromStrip = true
            dwellTask?.cancel()
            sendFocus()
        case .move(let previous):
            if !wasScrubbing { DebugLog.log("scrub start at \(before + 1)") }
            guard list.move(by: index - before) else { return }
            playlist = list
            navigated(direction: (index - before).signum(), from: previous, fromStrip: true)
        }
        seedCurrent()
    }

    /// The press ended or the cursor rested `dwellDelay` on one file: the normal plan for the current photo
    /// (preview, neighbours, full resolution after the dwell, which starts now). A no-op without a scrub.
    func endScrub() {
        guard scrubState.end(), let current = playlist?.current else { return }
        dwelling = false
        DebugLog.log("scrub end on \(current.lastPathComponent)")
        sendFocus()
        startDwell(on: current)
    }

    /// The playlist was just replaced (a re-read, another folder, a file of another folder opened): a strip scrub on
    /// the old list ends here, since its origin is an index of that list and would name another photo in the new one.
    /// The caller then gives the current photo the normal plan (`navigated`, or the dwell for a kept photo); the strip
    /// cancels its press when it sees the new files (`StripController.sessionDidChange`). True when a scrub was on.
    @discardableResult
    private func endScrubOnReplace() -> Bool {
        guard scrubState.end() else { return false }
        DebugLog.log("scrub ended: playlist replaced")
        return true
    }

    /// Whether the current photo is shown as its stored thumbnail until decoded: a strip jump with
    /// `strip-jump-preview` on, or a wheel or key step with `thumb`.
    private var seedsCurrent: Bool {
        (jumpedFromStrip && Settings.shared.config.stripJumpPreview) || stepWait == .thumb
    }

    /// Seeds the current photo from its stored thumbnail (`ThumbnailStore.seed`, no file read), when `seedsCurrent`
    /// (with `strip-jump-preview=no` a jump is a plain navigation). Seeded after the focus that made it current went
    /// out, so a failed photo reset for its retry gets its thumbnail; dropped when the cursor moved on meanwhile.
    private func seedCurrent() {
        guard !closed, seeding == nil, seedsCurrent, let url = playlist?.current else { return }
        seeding = url
        let thumbnails = self.thumbnails, cache = self.cache
        Task { [weak self] in
            let seed = await thumbnails.seed(url)
            guard let self else { return }
            self.seeding = nil
            if let seed, self.playlist?.current == url {
                self.enqueue { [weak self] in
                    guard await self?.isOpen(on: url) == true else { return }
                    await cache.seed(url, info: seed.info, level: seed.level)
                }
                self.refresh()
            }
            if self.seedsCurrent, let now = self.playlist?.current, now != url {
                self.enqueue { [weak self] in
                    guard await self?.playlist?.current == now else { return }
                    let entry = await cache.entry(now)
                    await self?.seedCurrent(ifNotResidentIn: entry)
                }
            }
        }
    }

    /// `seedCurrent` unless `entry` (the current photo's, nil: none yet) already failed (its failure is shown as it
    /// is) or has a decoded level resident, so a thumbnail read and a cache hop are not spent on it.
    private func seedCurrent(ifNotResidentIn entry: CacheEntryView<TiledImage>?) {
        guard entry?.failure == nil, entry?.pyramid?.finestResidentLevel == nil else { return }
        seedCurrent()
    }

    /// Home / End: the first / last photo, or the first page of the first / last pair (`SpreadNavigation`).
    func goFirst() {
        guard let list = playlist, let target = spread.first(from: list.index, count: list.files.count) else { return }
        navigate { _ = $0.move(by: target - $0.index) }
    }

    func goLast() {
        guard let list = playlist, let target = spread.last(from: list.index, count: list.files.count) else { return }
        navigate { _ = $0.move(by: target - $0.index) }
    }

    private func navigate(_ move: (inout Playlist) -> Void) {
        guard var list = playlist else { return }
        let before = list.index
        move(&list)
        guard list.index != before else { return }
        playlist = list
        navigated(direction: (list.index - before).signum(), from: before)
    }

    // MARK: Focus

    /// A new current photo: focus without dwell, then the cache's entry for it; the dwell timer restarts (not
    /// while scrubbing: `endScrub` starts it). Only the strip's own navigation (`fromStrip`) keeps the jump preview,
    /// only the wheel's and the keys' (`wait`) their step wait. `fresh`: the photo arrives anew (a folder step, `open`
    /// of a photo not on screen), so the folder's saved view waits for its first show (`restore`; which photos it
    /// applies to is `folder-view-memory`'s, `ViewRestore.pending`).
    /// `opened`: `open` brought it, so its full resolution needs no dwell (`opened`).
    private func navigated(direction: Int, from previous: Int?, fromStrip: Bool = false, wait: StepWait? = nil,
                           fresh: Bool = false, opened: Bool = false) {
        guard let current = playlist?.current else { return }
        settleZoom()            // the new photo inherits the mode a zoom key asked for, not a frame on the way
        if collapseView?.url != current { collapseView = nil }
        cancelFolderRequest()   // any navigation outranks a folder switch still being resolved
        jumpedFromStrip = fromStrip
        stepWait = wait
        self.direction = direction == 0 ? 1 : direction
        previousIndex = previous
        dwelling = false
        self.opened = opened
        freshOpen = opened ? current : nil
        latest = nil
        lastNeedsFull = nil
        error = nil
        folderMessage = nil
        shownFromCache = false
        // Not "Loading" yet: a cached photo is shown within a frame, and the line would flicker. Until the cache
        // answers, the bar describes what is on screen (`entry`); a photo that must wait gets its line in `consider`.
        loadingName = nil
        DebugLog.log("navigate -> \(current.lastPathComponent)")
        let folder = current.deletingLastPathComponent(), name = current.lastPathComponent
        // The folder's view and the file it was saved with, read before recording this photo as the folder's file.
        let saved = fresh ? positions.view(in: folder) : nil, savedFile = positions.fileName(in: folder)
        positions.record(folder: folder, file: name, keepingView: Settings.shared.config.folderViewMemory == .folder)
        // A step of the user's own in a restored tab: Recent hears of it from now on.
        if !opened, !recordsRecent { recordsRecent = true }
        recordRecent(folder: folder, file: name)
        // Before the focus: the saved mode decides whether the full resolution is needed.
        restore = ViewRestore.pending(file: current, savedFile: savedFile, saved: saved, arrival: transform,
                                      memory: Settings.shared.config.folderViewMemory)
        if let restore {
            DebugLog.log("saved view \(restore.view.text) waits for \(name) "
                         + "(\(restore.ofSamePhoto ? "same photo: mode and centre, size must match" : "folder mode: centre if the size matches"))")
        }
        sendFocus()
        sendThumbnailRequest()
        sendColorPlan()
        refresh(atNavigation: true)
        refreshCompanion()
        onChange?()

        dwellTask?.cancel()
        if !isScrubbing { startDwell(on: current) }
    }

    private func startDwell(on current: URL) {
        dwellTask?.cancel()
        dwellTask = Task { [weak self] in
            try? await Task.sleep(for: Self.dwellDelay)
            guard !Task.isCancelled, let self, self.playlist?.current == current else { return }
            self.dwelling = true
            DebugLog.log("dwell \(current.lastPathComponent)")
            self.sendFocus()
        }
    }

    private func cancelFolderRequest() {
        folderRequest.cancel()
        folderTask?.cancel()
        folderTask = nil
    }

    /// Sends the focus to the cache when it changed since the last one sent.
    private func sendFocus() {
        guard let list = playlist else { return }
        let needsFull = needsFull()
        lastNeedsFull = needsFull
        let pages = spread.focus(current: list.index)
        let focus = CacheFocus(count: list.files.count, current: list.index, direction: direction, dwelling: dwelling,
                               needsFull: needsFull, screen: screenSize, previous: previousIndex,
                               scrubbing: isScrubbing, appliesOrientation: appliesOrientation, opened: opened,
                               companion: pages.companion, step: pages.step)
        guard focus != sentFocus || list.files != sentFiles else { return }
        sentFocus = focus
        sentFiles = list.files
        DebugLog.log("focus \(focus.current + 1)/\(focus.count) dir \(focus.direction) dwell \(focus.dwelling) "
                     + "full \(focus.needsFull) screen \(focus.screen.width)x\(focus.screen.height)"
                     + (focus.previous.map { " prev \($0 + 1)" } ?? "") + (focus.scrubbing ? " scrubbing" : "")
                     + (focus.opened ? " opened" : "") + (focus.companion.map { " pair \($0 + 1)" } ?? ""))
        let files = list.files, cache = self.cache, id = cacheID
        enqueue { await cache.setFocus(id, files: files, focus: focus) }
    }

    /// Tells the thumbnail store this window's playlist, position, visible cells, key status and recency when any of
    /// them changed since the last request (window id: this session).
    private func sendThumbnailRequest() {
        guard !closed, let list = playlist else { return }
        let request = ThumbnailRequest(files: list.files, current: list.index, visible: stripVisibleFiles,
                                       isKey: isKeyWindow, lastActive: lastActive)
        guard request != sentThumbnailRequest || list.stamps != sentStamps else { return }
        sentThumbnailRequest = request
        sentStamps = list.stamps
        let stamps = list.stamps, thumbnails = self.thumbnails, window = thumbnailWindowID
        enqueueThumbnails { await thumbnails.setRequest(window: window, request, stamps: stamps) }
    }

    private var thumbnailWindowID: Int { sessionID }

    /// Tells the colour corrector the playlist, position, direction of travel and colour keys (it drops whatever of
    /// its old order has not started).
    private func sendColorPlan() {
        guard !closed, let list = playlist else { return }
        colorCorrector.update(files: list.files, current: list.index, direction: direction, stamps: list.stamps,
                              settings: colorSettings, reach: colorReach, companion: companionIndex)
    }

    private func enqueueThumbnails(_ operation: @escaping @Sendable () async -> Void) {
        let previous = thumbnailChain
        thumbnailChain = Task {
            await previous?.value
            await operation()
        }
    }

    /// Whether the current mode needs a level finer than Lfit for the current photo. Before its header is known:
    /// whether the mode is not a fit mode (the saved one, while a saved view waits, assuming its size; else the one
    /// `PhotoSwitchView` gives it, which does not depend on the size).
    private func needsFull() -> Bool {
        guard let latest, let info = latest.info, latest.url == playlist?.current else {
            let mode = restore.map { transform(showing: $0.file, size: $0.view.imageSize, over: judgedTransform).mode }
                ?? playlist.map { transform(showing: $0.current, size: judgedTransform.imageSize, over: judgedTransform).mode }
                ?? judgedTransform.mode
            switch mode {
            case .fit, .fitWidth, .fitHeight: return false
            case .free(let r): return r > 1
            case .fill, .actual: return true
            }
        }
        let levels = levels(for: info, of: latest.url)
        return levels.needed < levels.lfit || companionNeedsFull()
    }

    /// The pair's other page needs a level finer than its Lfit at the scale it gets (a pair at 100 % of its taller
    /// page, the shorter page magnified more): the focus's `needsFull` covers both pages. False before its header.
    private func companionNeedsFull() -> Bool {
        guard let c = latestCompanion, c.url == companionURL, c.failure == nil, let info = c.info else { return false }
        let levels = levels(for: info, of: c.url)
        return levels.needed < levels.lfit
    }

    /// The level the photo `url` (header `info`) needs at the scale it gets (or has) on screen, laid out at its
    /// `displaySize`, and its Lfit on this screen, the fit of that same layout (as the cache plans it, told by the
    /// focus's `appliesOrientation`). A running zoom animation is judged by its target.
    /// In a pair the transform is the virtual picture's: the page's scale is its share of it (`pageScale`).
    private func levels(for info: ImageInfo, of url: URL) -> (needed: Int, lfit: Int) {
        let grid = TileGrid(imageSize: info.pixelSize)
        let needed = TileGrid.level(forScale: pageScale(of: url, size: displaySize(info)), levelCount: grid.levelCount)
        return (needed, grid.previewLevel(forScreen: screenSize,
                                          orientation: info.displayOrientation(applying: appliesOrientation)))
    }

    /// The size the transform lays the photo out at: oriented, or stored with `exif-orientation=no`.
    private func displaySize(_ info: ImageInfo) -> CGSize {
        let size = info.displaySize(applying: appliesOrientation)
        return CGSize(width: size.width, height: size.height)
    }

    /// `exif-orientation` changed (a config reload): the photo on screen is laid out anew at once, not reopened. A
    /// photo the change turns keeps its zoom mode and goes back to the middle (`ViewTransform.reoriented`, review
    /// focus 4), and redraws with the new orientation even when its size stays (a half turn, a mirror); one it leaves
    /// alone (orientation 1) keeps its view. The cache hears the new layout with the focus (Lfit follows it).
    func updateOrientationSetting() {
        let applies = Settings.shared.config.exifOrientation
        guard applies != appliesOrientation else { return }
        settleZoom()   // the turned photo keeps the mode a zoom key asked for
        let before = drawOrientation
        appliesOrientation = applies
        DebugLog.log("exif-orientation \(applies ? "yes" : "no")")
        // Pages planned and laid out at their old orientation's sizes are measured anew.
        spreadHeaders = [:]
        spreadAspects?.setAppliesOrientation(applies)
        updateSpread(rebuild: true)
        let made = makeLayout()
        shownLayout = made?.layout
        shownLayoutProvisional = made?.provisional ?? false
        if let entry, let info = entry.info, entry.failure == nil,
           layoutSize(info) != transform.imageSize || drawOrientation != before {
            transform = transform.reoriented(to: layoutSize(info))   // didSet notifies when it changed
        }
        sendFocus()
        companionDidChange()
        refresh()   // a photo waiting for sharpness is judged against its new Lfit
        onChange?()
    }

    /// The transform the photo `url` is shown with at `size`, so the show rules and the focus judge sharpness at the
    /// scale it will get: its saved view when that applies (`restore`); the photo laid out already keeps its view;
    /// any other gets `PhotoSwitchView`'s from `base` (the transform of now, a running zoom animation's target) with
    /// the rules of its folder, the default zoom mode when `open` brought it.
    private func transform(showing url: URL, size: CGSize, over base: ViewTransform? = nil) -> ViewTransform {
        let current = base ?? judgedTransform
        let rules = zoomRules(url)
        if let saved = restored(url, size: size, over: current) { return saved }
        if let collapse = collapseView, collapse.url == url, collapse.transform.imageSize == size {
            return collapse.transform
        }
        let arrival: PhotoSwitchView.Arrival = url == laidOut ? .laidOut : url == freshOpen ? .opened : .switched
        // The photo on screen keeps the transform it has (a frame of a zoom animation included), as before.
        return PhotoSwitchView.shown(arrival, current: arrival == .laidOut ? base ?? transform : current,
                                     imageSize: size, rules: rules)
    }

    /// The saved view `url` gets at `size` over `base` (`restore`), nil when none applies.
    private func restored(_ url: URL, size: CGSize, over base: ViewTransform) -> ViewTransform? {
        guard let restore else { return nil }
        let rules = zoomRules(url)
        if let saved = restore.transform(for: url, imageSize: size, over: base, carry: rules.carry,
                                         fitUpscale: rules.fitUpscale) {
            return saved
        }
        return nil
    }

    /// A zoom that moves the needed level across Lfit re-plans the current photo's full resolution (otherwise
    /// zooming into a photo loaded for Fit would wait for the dwell); a photo still waiting is re-checked
    /// against the new scale.
    private func transformDidChange() {
        if lastNeedsFull != nil, needsFull() != lastNeedsFull { sendFocus() }
        if loadingName != nil, let latest, latest.url == playlist?.current { consider(latest, atNavigation: false) }
    }

    // MARK: Entries

    private func cacheDidUpdate(_ url: URL) {
        if url == playlist?.current { refresh() } else if url == companionURL { refreshCompanion() }
    }

    /// Reads the current photo's entry (after every cache call made so far) and considers it for the screen. The
    /// app also calls it when `show-blurry` changed, so a photo waiting for sharpness is re-checked. A wheel or key
    /// step with `thumb` to a photo with nothing resident seeds its thumbnail then (one already decoded or
    /// seeded shows that instead, with no thumbnail read).
    func refresh(atNavigation: Bool = false) {
        guard let url = playlist?.current else { return }
        let cache = self.cache
        enqueue { [weak self] in
            let entry = await cache.entry(url)
            await self?.received(entry, of: url, atNavigation: atNavigation)
        }
    }

    /// `refresh`'s answer: the cache's entry for `url` (nil: none yet), read after every cache call made before it.
    private func received(_ entry: CacheEntryView<TiledImage>?, of url: URL, atNavigation: Bool) {
        guard playlist?.current == url else { return }
        if let entry {
            consider(entry, atNavigation: atNavigation)
        } else if self.entry?.url != url {
            loadingName = url.lastPathComponent
        }
        if atNavigation, stepWait == .thumb { seedCurrent(ifNotResidentIn: entry) }
    }

    /// Still open and `url` still the current photo.
    private func isOpen(on url: URL) -> Bool { !closed && playlist?.current == url }

    /// Shows `e` (the current photo's entry) if allowed: always when it refines what is on screen
    /// (`ShowPolicy.refinesShown`: its pyramid, or any pyramid of a photo shown as its seeded thumbnail), otherwise
    /// when `ShowPolicy` says it is sharp enough, or at once for a seeded thumbnail the strip jumped to, or when it is
    /// what the wheel step to it waits for (`ShowPolicy.shownByStep`).
    private func consider(_ e: CacheEntryView<TiledImage>, atNavigation: Bool) {
        let incoming = incomingColorSpace
        latest = e
        noteSpreadSize(e, at: playlist?.index)
        if lastNeedsFull != needsFull() { sendFocus() }   // the header arrived: needsFull is now exact
        if incomingColorSpace != incoming { onChange?() }   // the header arrived: the view can tag its layer
        let name = e.url.lastPathComponent
        if let failure = e.failure {
            DebugLog.log("entry \(name): failed \(failure)")
            show(e, atNavigation: atNavigation)
            return
        }
        let onScreen = ShowPolicy.refinesShown(e, shown: entry)
        var allowed = onScreen
        var detail = "on screen"
        if !onScreen {
            if let info = e.info, let pyramid = e.pyramid {
                let levels = levels(for: info, of: e.url)
                let finest = pyramid.finestResidentLevel
                let jumpPreview = jumpedFromStrip && Settings.shared.config.stripJumpPreview && e.isSeededOnly
                allowed = ShowPolicy.shouldShow(finestResident: finest, neededLevel: levels.needed,
                                                previewLevel: levels.lfit, mode: Settings.shared.config.showBlurry,
                                                jumpPreview: jumpPreview)
                let byStep = !allowed && ShowPolicy.shownByStep(stepWait, finestResident: finest,
                                                                seededOnly: e.isSeededOnly)
                allowed = allowed || byStep
                detail = "finest \(finest.map(String.init) ?? "-") needed \(levels.needed) lfit \(levels.lfit)"
                    + (jumpPreview ? " jump preview" : "") + (byStep ? " step-wait \(stepWait?.rawValue ?? "")" : "")
            } else {
                detail = "no pyramid"
            }
        }
        let state = e.isSeededOnly ? "thumb" : e.state.map { "\($0)" } ?? "nil"
        DebugLog.log("entry \(name): \(state) \(detail) -> \(allowed ? "show" : "wait")"
                     + timingsText(e.timings))
        if allowed {
            show(e, atNavigation: atNavigation)
        } else if entry?.url != e.url || entry?.failure != nil {
            if loadingName != name {
                loadingName = name
                onChange?()
            }
        }
    }

    /// Puts `e` on screen: the transform follows its header size as shown (`displaySize`, from probe, not the
    /// resident level, so a preview becoming full resolution never moves the picture). The first show of a photo with
    /// a saved view waiting (a stretched thumbnail or the photo itself) applies that view or drops it; later shows keep
    /// the view the screen has.
    private func show(_ e: CacheEntryView<TiledImage>, atNavigation: Bool) {
        let samePhoto = entry?.url == e.url
        if !samePhoto {
            settleZoom()   // a zoom key pressed while the photo loaded: the photo gets the mode it asked for
            shownFromCache = atNavigation
            colorCorrector.pinned = e.url   // its cube stays while it is shown, wherever the order went (and its pair's)
            // The store's catalog has this folder by now: aspects it did not have at the playlist change are asked again.
            if folderSpread.on { spreadAspects?.cellPictureArrived(e.url) }
        }
        entry = e
        // The cache never evicts the photo on screen (spec §11.2): its levels stay while it is shown. The pin moves only
        // here (and with the pair's other page, `adoptCompanion`), so the old photo stays pinned (and on screen) until
        // the new one is shown. In a pair the transform is the virtual picture's (`layoutSize`).
        adoptCompanion()
        loadingName = nil
        error = e.failure
        if let info = e.info, e.failure == nil {
            let next = transform(showing: e.url, size: layoutSize(info))
            laidOut = e.url   // before the transform changes: what its observers ask of this photo keeps this view
            if freshOpen == e.url { freshOpen = nil }
            if collapseView?.url == e.url { collapseView = nil }
            if let restore, restore.file == e.url {
                // The pair's other page has a stand-in size: the saved view (recorded at the pair's real size) is
                // decided once that page's size is in (`relayout`), while the view stays untouched (a zoom key pressed
                // during the load, a zoom or pan since an earlier show drop it).
                if let waiting = restore.waiting(atShowOf: next.imageSize, provisional: shownLayoutProvisional,
                                                 before: judgedTransform, shown: next) {
                    DebugLog.log("saved view of \(e.url.lastPathComponent) waits for the pair's size")
                    self.restore = waiting
                } else if shownLayoutProvisional, !restore.view.applies(to: next.imageSize) {
                    DebugLog.log("saved view of \(e.url.lastPathComponent) not restored (zoomed while it waited)")
                    self.restore = nil
                } else {
                    let target = restore.target(imageSize: next.imageSize)
                    let applied = target.map { next.mode == $0.mode && next.center == $0.center } ?? false
                    DebugLog.log("saved view of \(e.url.lastPathComponent) "
                                 + (applied ? "restored (\(target?.rule.text ?? ""))" : "not restored (size or zoom changed)"))
                    self.restore = nil
                }
            }
            // A level arriving for the photo on screen changes only its resolution: the transform keeps what is
            // transient in it (a zoom animation's frame, a stretch held by a gesture), which `withImageSize` drops.
            let transientOnly = samePhoto && next.imageSize == transform.imageSize
                && next == transform.withImageSize(next.imageSize)
            if next != transform, !transientOnly {
                transform = next   // didSet notifies
                return
            }
        } else if e.failure != nil, restore?.file == e.url {
            restore = nil
        }
        onChange?()
    }

    // MARK: Two pages (spread spec 2026-10-23)

    /// The spread keys of a photo's folder (`spread`, `spread-shift`, `spread-direction`, `spread-landscape`): the window
    /// controller sets it from that folder's settings over loupe.conf, like `zoomRules`. Asked with the photo when the
    /// current folder changes, so a folder step takes the new folder's own flag; `updateSpreadRules` asks again.
    var spreadRules: (URL) -> SpreadRules = { _ in SpreadRules(config: Settings.shared.config) }

    /// The rules of `spreadFolder`, the current photo's folder when they were last asked.
    private var folderSpread = SpreadRules.off
    private var spreadFolder: URL?
    /// How steps go and which page pairs with the current one. Its plan is rebuilt (O(n)) only when one of its inputs
    /// changes (`updateSpread`): the playlist, the rules, a page size that pairs otherwise; never per frame or event.
    private var spread = SpreadNavigation(plan: nil, showsTwo: false)
    /// The playlist the plan was built for ([] while the folder shows one page).
    private var planFiles: [URL] = []
    /// The view is at least as wide as it is tall (`SpreadLayout.showsTwo`), as of the last view size.
    private var viewShowsTwo = false
    /// The thumbnail store's aspects of the playlist's files (its catalog and memory: no file is read), made the first
    /// time a folder shows two pages and fed only while one does.
    private var spreadAspects: StripAspects?
    /// The headers' sizes (as shown) of the pages read in this folder: exact where the store has no aspect yet.
    private var spreadHeaders: [URL: PixelSize] = [:]
    /// The other page of the current photo's pair (playlist index and file), nil for one page. The current photo is
    /// any page of the pair: turning two pages on mid-folder shows the pair containing it, a step lands on a first page.
    private(set) var companionIndex: Int?
    private(set) var companionURL: URL?
    /// The latest entry read for `companionURL`.
    private var latestCompanion: CacheEntryView<TiledImage>?
    /// The page on screen beside `entry`, nil for one page or while its slot waits for it. It is what was read of the
    /// current companion while `entry` is the current photo; a previous photo still on screen keeps the page it had.
    private(set) var shownCompanion: CacheEntryView<TiledImage>?
    /// `shownCompanion` comes first in reading order.
    private(set) var companionFirst = false
    /// Where the pages on screen sit in the transform's (virtual) picture, nil for one page: the view draws by it and
    /// finds the page under the pointer with it. Kept, not made per frame.
    private(set) var shownLayout: SpreadLayout?
    /// `shownLayout`'s other page has a stand-in size: a saved view of the pair waits for the real one.
    private var shownLayoutProvisional = false
    /// The view a pair's first page gets when the pair gives way to it alone (`spreadChanged`), until it is shown.
    private var collapseView: (url: URL, transform: ViewTransform)?
    private var sentPins: (URL?, URL?) = (nil, nil)
    private var spreadSyncPending = false
    private var spreadRebuildPending = false

    /// The companion's pyramid to draw: nothing for one page, a page not read yet or a failed one.
    var companionImage: TiledImage? {
        guard shownLayout != nil, let c = shownCompanion, c.failure == nil else { return nil }
        return c.pyramid
    }

    /// The orientation `companionImage` is drawn with (as `drawOrientation`).
    var companionDrawOrientation: ImageOrientation {
        guard let c = shownCompanion, let info = c.info else { return .up }
        return info.drawOrientation(applying: appliesOrientation, seeded: c.pyramidIsSeeded)
    }

    /// The current photo's pages in reading order (playlist indices), `second` nil for one page: the stats bar's
    /// `12–13 / 380` and the title's two names. Everything else that names one file acts on the current page
    /// (`playlist.current`): Show in Finder, Copy Path, the session tab, Recent and the folder's remembered file.
    var currentPages: (first: Int, second: Int?)? {
        guard let list = playlist else { return nil }
        guard let k = companionIndex else { return (list.index, nil) }
        return (min(list.index, k), max(list.index, k))
    }

    /// The window's folder settings changed (`D`, `⌥D`, a reload): the current folder's rules are asked again and the
    /// pair follows them at once.
    func updateSpreadRules() {
        guard let current = playlist?.current else { return }
        let rules = spreadRules(current)
        spreadFolder = current.deletingLastPathComponent()
        guard rules != folderSpread else { return }
        let options = rules.options
        DebugLog.log("spread \(rules.on ? "on" : "off")\(options.shift ? " shifted" : "")"
                     + (options.rightToLeft ? " rtl" : "") + (options.landscapeAlone ? "" : " landscape paired"))
        folderSpread = rules
        spreadChanged(rebuild: true)
    }

    /// Brings the spread state up to the folder's rules, the playlist, the known sizes and the view: the plan when one
    /// of its inputs changed or `rebuild`, then the current photo's companion. No cache call and no notification: the
    /// callers make them (a navigation sends the focus once, with the companion). True when the companion changed.
    @discardableResult
    private func updateSpread(rebuild: Bool = false) -> Bool {
        var rebuild = rebuild
        if let current = playlist?.current, current.deletingLastPathComponent() != spreadFolder {
            spreadFolder = current.deletingLastPathComponent()
            spreadHeaders = [:]
            let rules = spreadRules(current)
            rebuild = rebuild || rules != folderSpread
            folderSpread = rules
        }
        let files = folderSpread.on ? playlist?.files ?? [] : []
        var plan = spread.plan
        if rebuild || files != planFiles {   // the same list compares in O(1) (one storage)
            planFiles = files
            if files.isEmpty {
                plan = nil
            } else {
                let aspects = aspectsFor(files)
                plan = SpreadPlan(sizes: SpreadSizes.sizes(files: files, aspects: aspects, headers: spreadHeaders),
                                  options: folderSpread.options)
            }
        }
        spread = SpreadNavigation(plan: plan, showsTwo: viewShowsTwo)
        let index = playlist.flatMap { spread.companion(of: $0.index) }
        let url = index.flatMap { i in playlist.map { $0.files[i] } }
        let changed = index != companionIndex || url != companionURL
        companionIndex = index
        companionURL = url
        if latestCompanion?.url != url { latestCompanion = nil }
        return changed
    }

    /// The store's aspects of `files` as known now (an asynchronous fetch follows for the rest; its arrival rebuilds).
    private func aspectsFor(_ files: [URL]) -> [Double?] {
        let aspects: StripAspects
        if let made = spreadAspects {
            aspects = made
        } else {
            let store = thumbnails
            aspects = StripAspects(fetch: { urls, applies in await store.aspects(urls, applyingOrientation: applies) })
            aspects.onChange = { [weak self] in self?.scheduleSpreadSync(rebuild: true) }
            spreadAspects = aspects
        }
        aspects.setAppliesOrientation(appliesOrientation)
        aspects.setPlaylist(files)
        return aspects.aspects
    }

    /// The view's size crossed width = height: two pages give way to one, or come back (spread spec, «Узкое окно»).
    private func viewSizeDidChange() {
        let two = SpreadLayout.showsTwo(viewSize: transform.viewSize)
        guard two != viewShowsTwo else { return }
        viewShowsTwo = two
        if folderSpread.on { scheduleSpreadSync(rebuild: false) }
    }

    /// `spreadChanged` once, after what is running now (a transform's observer, an entry being considered) is done.
    private func scheduleSpreadSync(rebuild: Bool) {
        spreadRebuildPending = spreadRebuildPending || rebuild
        guard !spreadSyncPending else { return }
        spreadSyncPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let rebuild = self.spreadRebuildPending
            self.spreadSyncPending = false
            self.spreadRebuildPending = false
            self.spreadChanged(rebuild: rebuild)
        }
    }

    /// The rules, the plan's inputs or the view changed: the current photo's pair is taken anew. A pair giving way to
    /// one page (a narrow view, `D` off) keeps its first page in reading order, which is a navigation when the current
    /// photo was the second; otherwise the cache hears the new companion and its page is read and laid out.
    private func spreadChanged(rebuild: Bool) {
        guard !closed, let index = playlist?.index else { return }
        let shown = spread.pair(at: index)
        updateSpread(rebuild: rebuild)
        if !spread.isActive, let first = SpreadNavigation.single(after: shown, current: index) {
            // The first page was on screen beside the current one: it keeps its spot and its drawn scale
            // (`SpreadZoom`), as a page that stays does, rather than a switch's carried zoom.
            if let page = shownCompanion, let files = playlist?.files, page.url == files[first],
               entry?.url == playlist?.current, page.failure == nil, let info = page.info, let rect = companionRect {
                settleZoom()
                collapseView = (page.url, SpreadZoom.carried(transform, from: rect, to: displaySize(info), at: nil))
            }
            navigate { _ = $0.move(by: first - $0.index) }
            return
        }
        sendFocus()
        companionDidChange()
    }

    /// The companion may be another page: it is read, and the pair on screen laid out again.
    private func companionDidChange() {
        sendColorPlan()   // its cube is built next to the current photo's
        refreshCompanion()
        let before = shownPageRect
        adoptCompanion()
        relayout(from: before)
    }

    /// A page's header is in: its size joins the known ones, and when it pairs the page otherwise than the plan did (a
    /// page taken for portrait is landscape) the plan is rebuilt, after the entry has been dealt with.
    private func noteSpreadSize(_ e: CacheEntryView<TiledImage>, at index: Int?) {
        guard folderSpread.on, let info = e.info, let index, planFiles.indices.contains(index),
              planFiles[index] == e.url else { return }
        let size = info.displaySize(applying: appliesOrientation)
        guard spreadHeaders[e.url] != size else { return }
        let aspects = spreadAspects?.aspects ?? []
        let aspect = index < aspects.count ? aspects[index] : nil
        let planned = spreadHeaders[e.url] ?? aspect.flatMap(SpreadSizes.size(aspect:))
        spreadHeaders[e.url] = size
        if SpreadSizes.changesPairing(from: planned, to: size) { scheduleSpreadSync(rebuild: true) }
    }

    /// Reads the companion's entry (after every cache call made so far).
    private func refreshCompanion() {
        guard let url = companionURL else { return }
        let cache = self.cache
        enqueue { [weak self] in
            let entry = await cache.entry(url)
            await self?.receivedCompanion(entry, of: url)
        }
    }

    private func receivedCompanion(_ e: CacheEntryView<TiledImage>?, of url: URL) {
        guard url == companionURL, let e else { return }
        latestCompanion = e
        noteSpreadSize(e, at: companionIndex)
        if lastNeedsFull != nil, needsFull() != lastNeedsFull { sendFocus() }   // its header: its own needed level
        let before = shownPageRect
        adoptCompanion()
        relayout(from: before)
    }

    /// Puts the current companion beside the photo on screen when that is the current photo (a previous photo still on
    /// screen keeps the page it had, so a pair is never shown half old, half new), lays the pair out and moves the pins.
    /// The companion is shown with whatever it has: it never holds the current photo back.
    private func adoptCompanion() {
        if entry == nil {
            shownCompanion = nil
        } else if entry?.url == playlist?.current {
            shownCompanion = latestCompanion
            companionFirst = (companionIndex ?? 0) < (playlist?.index ?? 0)
        }
        let made = makeLayout()
        shownLayout = made?.layout
        shownLayoutProvisional = made?.provisional ?? false
        let pins = (entry?.url, shownLayout == nil ? nil : shownCompanion?.url)
        colorCorrector.pinnedCompanion = pins.1
        guard let first = pins.0, pins != sentPins else { return }
        sentPins = pins
        let cache = self.cache, id = cacheID, companion = pins.1
        enqueue { await cache.setPinned(id, first, companion: companion) }
    }

    /// Where the photo on screen sits in the transform's picture (its rect in `shownLayout`; nil: the whole picture,
    /// one page), for `relayout` to keep the view on it.
    private var shownPageRect: CGRect? { rect(ofCompanion: false) }

    /// Where the page beside it (`shownCompanion`) sits; nil for one page.
    private var companionRect: CGRect? { rect(ofCompanion: true) }

    private func rect(ofCompanion companion: Bool) -> CGRect? {
        guard let layout = shownLayout else { return nil }
        let page = companionFirst == companion ? 0 : 1   // reading order
        return layout.order.firstIndex(of: page).map { layout.rects[$0] }
    }

    /// The transform follows the pair on screen (`from`: the photo's rect before): a new layout (two pages on or off, a
    /// narrow view, a page's real size replacing a stand-in, the other side in `rtl`) keeps the spot of the photo under
    /// the view's centre and a free zoom's scale on it (`SpreadZoom`); otherwise the view redraws. A saved view that
    /// waited for the pair's real size (`show`) is decided here, once that size is in.
    private func relayout(from before: CGRect?) {
        if let e = entry, let info = e.info, e.failure == nil, e.url == laidOut {
            let size = layoutSize(info), now = shownPageRect
            var next: ViewTransform?
            if let restore, restore.file == e.url, !shownLayoutProvisional {
                settleZoom()
                next = restored(e.url, size: size, over: transform)
                DebugLog.log("saved view of \(e.url.lastPathComponent) "
                             + (next != nil ? "restored with the pair's size" : "not restored (size or zoom changed)"))
                self.restore = nil
            }
            if next == nil, size != transform.imageSize || before != now {
                settleZoom()
                let carried = SpreadZoom.carried(transform, from: before, to: size, at: now)
                // A restore still waiting (another stand-in) goes on waiting from the carried view, not dropped by it.
                if let restore, restore.file == e.url { self.restore = restore.following(from: transform, to: carried) }
                next = carried
            }
            if let next, next != transform {
                transform = next   // didSet notifies
                return
            }
        }
        onChange?()
    }

    /// The layout of the photo on screen and its companion, nil for one page; `provisional` while the companion has a
    /// stand-in size (not read yet).
    private func makeLayout() -> (layout: SpreadLayout, provisional: Bool)? {
        guard let e = entry, let info = e.info, e.failure == nil else { return nil }
        guard let layout = layout(of: e.url, size: displaySize(info)) else { return nil }
        // Read: its header is in, or it failed (then it keeps the stand-in for good).
        let other = entry?.url == playlist?.current ? companionURL : shownCompanion?.url
        let read = [shownCompanion, latestCompanion].contains { page in
            guard let page, page.url == other else { return false }
            return page.info != nil || page.failure != nil
        }
        return (layout, !read)
    }

    /// The pair `url` (the photo on screen, or the current one about to be; `own` its size) is laid out in, nil for one
    /// page. A companion not read yet takes the store's aspect at `own`'s height, else `own` (`SpreadSizes.pageSize`),
    /// so the photo keeps its place when the page comes.
    private func layout(of url: URL, size own: CGSize) -> SpreadLayout? {
        let other: URL?, otherFirst: Bool
        var aspect: Double?
        if url == playlist?.current {
            other = companionURL
            otherFirst = (companionIndex ?? 0) < (playlist?.index ?? 0)
            if let k = companionIndex, let aspects = spreadAspects?.aspects, k < aspects.count { aspect = aspects[k] }
        } else if url == entry?.url {
            other = shownCompanion?.url
            otherFirst = companionFirst
        } else {
            return nil
        }
        guard let other else { return nil }
        let page = [shownCompanion, latestCompanion].lazy.compactMap { $0 }.first { $0.url == other && $0.failure == nil }
        let size = SpreadSizes.pageSize(known: page?.info.map(displaySize), aspect: aspect, other: own)
        let rtl = folderSpread.options.rightToLeft
        return otherFirst ? SpreadLayout(first: size, second: own, rightToLeft: rtl)
            : SpreadLayout(first: own, second: size, rightToLeft: rtl)
    }

    /// The size the transform lays the photo on screen out at: the pair's virtual picture, else the photo's own.
    private func layoutSize(_ info: ImageInfo) -> CGSize {
        guard let size = shownLayout?.virtualSize, size.width > 0, size.height > 0 else { return displaySize(info) }
        return size
    }

    /// The scale the page `url` (of size `size`) gets on screen: the transform's for one page; in a pair its share of
    /// the virtual picture's (every page is as tall as the picture), so a pair at 1:1 of its taller page asks the other
    /// page for the finer level it needs.
    private func pageScale(of url: URL, size: CGSize) -> Double {
        // The photo the transform is judged with: the companion's scale is its share of the current photo's picture.
        var anchor = url
        var layout: SpreadLayout?
        if url == entry?.url, shownLayout != nil {
            layout = shownLayout
        } else if url == companionURL, let current = playlist?.current {
            anchor = current
            if entry?.url == current {
                layout = shownLayout
            } else if let latest, latest.url == current, let info = latest.info {
                layout = self.layout(of: current, size: displaySize(info))
            }
        } else {
            layout = self.layout(of: url, size: size)
        }
        guard let layout, layout.virtualSize.height > 0, size.height > 0 else {
            return transform(showing: url, size: size, over: judgedTransform).scale
        }
        let t = transform(showing: anchor, size: layout.virtualSize, over: judgedTransform)
        return t.scale * layout.virtualSize.height / size.height
    }

    /// Tells Recent of the photo on screen: its folder is entered when it is not the last one told. With two pages on
    /// screen it is the current page (its index and the folder's remembered file), so reopening shows the pair
    /// containing it.
    private func recordRecent(folder: URL, file: String) {
        guard recordsRecent, let recent, let playlist else { return }
        if folder != recentFolder {
            recentFolder = folder
            recent.entered(folder, kind: ArchivePath.isArchive(folder) ? .archive : .folder, gallery: nil, title: nil,
                           clearsGallery: entersFromOutside)
            entersFromOutside = false
        }
        recent.viewed(folder, file: file, index: playlist.index, count: playlist.files.count)
    }

    /// Saves how `photo` is looked at for its folder (`FolderPositions`): only while it is the photo on screen (the
    /// transform has its size, not a previous photo's while it loads) and the photo its folder remembers.
    private func recordView(of photo: URL) {
        guard let entry, entry.url == photo, entry.failure == nil, entry.info != nil else { return }
        let folder = photo.deletingLastPathComponent(), name = photo.lastPathComponent
        guard positions.fileName(in: folder) == name else { return }
        positions.record(folder: folder, file: name, view: SavedView(judgedTransform))
    }

    /// The current photo's view, saved before the app quits (and flushes the positions).
    func recordView() {
        guard !closed, let current = playlist?.current else { return }
        recordView(of: current)
    }

    /// The viewer goes away: its view is saved, its timers stop and it leaves the shared cache (its photos are kept
    /// but go first when memory runs short).
    func close() {
        recordView()
        watcher.stop()
        spreadAspects?.close()
        rereads.reset()   // a listing in flight is dropped
        cancelFolderRequest()
        dwellTask?.cancel()
        if let thumbnailObserver { NotificationCenter.default.removeObserver(thumbnailObserver) }
        colorCorrector.pinned = nil
        colorCorrector.update(files: [], current: 0, direction: 1, stamps: [:], settings: colorSettings, reach: 0)
        closed = true
        let thumbnails = self.thumbnails, window = thumbnailWindowID
        enqueueThumbnails { await thumbnails.setRequest(window: window, nil, stamps: [:]) }
        let cache = self.cache, id = cacheID
        enqueue { await cache.unregister(id) }   // last: the cache ignores whatever of this session comes after it
    }

    /// Appends `operation` to the cache chain (`chain`). The chain runs off the main actor, so a cache call never waits
    /// for the main thread: at launch that thread is busy for tens of ms putting the window up, which held the first
    /// photo's read and decode back (docs/bench/2026-10-15-startup.md). A step that needs the session's state hops to
    /// the main actor itself, and the chain waits for it, so cache calls and entry reads still reach the actor, and
    /// their answers the session, in the order they were made.
    private func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        let previous = chain
        chain = Task.detached(priority: .userInitiated) {
            await previous?.value
            await operation()
        }
    }

    private func timingsText(_ t: LoadTimings) -> String {
        let parts: [(String, Double?)] = [("read", t.readMs), ("look", t.firstLookMs), ("preview", t.previewMs),
                                          ("full", t.fullMs), ("upload", t.uploadMs)]
        let text = parts.compactMap { label, ms in ms.map { "\(label) \(Int($0.rounded()))" } }.joined(separator: " ")
        return text.isEmpty ? "" : " [\(text) ms]"
    }
}
