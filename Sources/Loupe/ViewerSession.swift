import CoreGraphics
import Foundation
import HomeScreenModel
import LoupeCore
import LoupeRender

/// What one viewer shows: the folder's playlist, the cache entry on screen and the view transform.
/// Loading belongs to the process-wide `ImageCache` (M2 spec §4.5): the session tells it where the viewer is
/// (`CacheFocus`), reads the current photo's entry and shows it once it is sharp enough (`ShowPolicy`); until
/// then a stand-in covers the previous photo (`standIn`, `switch-preview`) with "Loading…". The photo on screen is
/// pinned in the cache (`setPinned`), so it
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
    var fileViewHistory: FileViewHistory { positions.fileViews }
    private let navigator: FolderNavigator
    private(set) var playlist: Playlist? {
        didSet {
            // Leaving a photo (any navigation, a re-read that lost it, another folder) saves how it was looked at.
            if let left = oldValue?.current, left != playlist?.current { recordView(of: left) }
            // The pair the new position is in (no cache call here: the navigation that set the playlist makes them).
            updateSpread()
            if playlist?.isSourceOrdered != oldValue?.isSourceOrdered {
                setActivity(active: requestedCacheActive, visible: requestedCacheVisible, lastActive: lastActive)
            }
            if playlist?.isSourceOrdered == true { watcher.stop(); return }
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

    /// What covers the photo on screen while the current one cannot be shown yet (`switch-preview`, decided on the
    /// cache's first answer after a navigation, `ShowPolicy.atNavigation`): the strip's decoded cell of the new photo,
    /// scaled up, or a blank placeholder. Nil while the screen shows the current photo, or keeps the one before
    /// (`keep`). The window draws it over the viewer (`SwitchStandInView`).
    private(set) var standIn: SwitchStandIn?

    /// The strip's decoded cell picture of a file, nil when it holds none (set by the window controller): the
    /// stand-in that needs no read or decode at all.
    var cellPicture: ((URL) -> CGImage?)?

    /// `exif-orientation` as this session lays photos out: the transform's image size is the photo's `displaySize`
    /// with it, so it changes only together with the transform (`updateOrientationSetting`).
    private(set) var appliesOrientation = Settings.shared.config.exifOrientation

    /// The orientation `image` is drawn with: the photo's for its decoded levels, none of its own for a seeded
    /// thumbnail, which is turned already (`ImageInfo.drawOrientation`, review focus 1).
    var drawOrientation: ImageOrientation {
        guard let entry, let info = entry.info else { return .up }
        return info.drawOrientation(applying: appliesOrientation, seeded: entry.pyramidIsSeeded)
    }

    /// The photos next in the step direction whose pyramids have a resident level, with their draw orientations, for
    /// `SubjectFinder` to look at ahead (`limit` of them); `body` on main.
    func subjectNeighbours(limit: Int, _ body: @escaping @MainActor ([(URL, TiledImage, ImageOrientation)]) -> Void) {
        guard let list = playlist, limit > 0 else { return }
        let files = list.files, index = list.index, step = direction, applying = appliesOrientation, cache = self.cache
        let urls = (1...limit).map { index + $0 * step }.filter { files.indices.contains($0) }.map { files[$0] }
        Task.detached(priority: .utility) {
            var found: [(URL, TiledImage, ImageOrientation)] = []
            for url in urls {
                guard let entry = await cache.entry(url), let image = entry.pyramid, !entry.pyramidIsSeeded,
                      image.finestResidentLevel != nil, let info = entry.info else { continue }
                found.append((url, image, info.drawOrientation(applying: applying, seeded: false)))
            }
            let ready = found
            await MainActor.run { body(ready) }
        }
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
    /// The subjects of a photo when they are known already (`SubjectFinder`'s memory; set by the window controller),
    /// for `step-pan=subject`.
    var subjectBoxes: (URL) -> SubjectBoxes? = { _ in nil }
    /// Zoom to Subject is on (smart zoom spec §3): a step opens the next photo framed on its subject, or at Fit until
    /// its subjects are in. Any other zoom command or a gesture turns it off (`ViewerView`).
    var smartZoom = SmartZoomState()
    var smartZoomRevision: UInt64 = 0
    var manualZoomPhoto: URL?
    func noteManualZoom() { manualZoomPhoto = entry?.url }
    var subjectZoom = false {
        didSet { if !subjectZoom { subjectStep = nil } }
    }
    /// The kind ⇧Z's step frames (`PhotoSwitchView.subjectSteps`), which later photos frame first; nil: the chain's.
    var subjectStep: SubjectKind?

    /// Framing while browsing (`step-zoom=subject`): how big each kind of subject was shown and the photo left
    /// (`BrowseFraming`), so the next photo shows its subject as big, a burst its view as it was.
    var browse = BrowseFraming()
    /// The step `browse` was last told about, so a step planned again (a finer level, the cache asking) is not one more.
    private var browseStep: (from: URL, to: URL)?

    /// The photo `from`, shown at `view`, is left for `to`: `browse` measures it once per step.
    private func leaveForBrowse(_ from: URL, to: URL, view: ViewTransform) {
        guard browseStep.map({ $0 != (from, to) }) ?? true else { return }
        browseStep = (from, to)
        browse.useProfile(zoomRules(from).detector?.name ?? "vision")
        browse.leave(from, view: view, boxes: subjectBoxes(from), chain: zoomRules(from).chain, options: zoomRules(from).composition, manualZoom: false)
    }

    /// Framing while browsing's view of `url` from `shown` (nil: nothing of the chain found), remembered as framed.
    func browseFraming(_ url: URL, shown: ViewTransform, boxes: SubjectBoxes) -> ViewTransform? {
        guard let framed = browse.frame(shown, boxes: boxes, rules: zoomRules(url)) else { return nil }
        browse.framed = (url, framed)
        return framed
    }

    func smartFraming(_ url: URL, shown: ViewTransform, boxes: SubjectBoxes) -> ViewTransform? {
        guard smartZoom.mode != .off else { return nil }
        let rules = zoomRules(url)
        browse.useProfile(rules.detector?.name ?? "vision")
        let chain = browse.chain(rules.chain)
        guard let kind = chain.first(where: { SubjectFraming.composition(boxes, kind: $0, options: rules.composition) != nil }),
              let c = SubjectFraming.composition(boxes, kind: kind, options: rules.composition) else { return nil }
        let framed = c.transform(shown, autoZoom: smartZoom.mode == .frame,
                                 size: rules.subjectSize)
        if smartZoom.mode == .frame { browse.framed = (url, framed); manualZoomPhoto = nil }
        return framed
    }

    /// `url`'s rules for subject mode: the step's kind ahead of the chain.
    func subjectRules(_ url: URL) -> ZoomRules {
        var rules = zoomRules(url)
        if let kind = subjectStep { rules.chain = [kind] + rules.chain.filter { $0 != kind } }
        return rules
    }

    /// What a window resize keeps of a free zoom: `keep-zoom-as` in the photo's folder (its framing by default).
    var resizeCarry: ZoomCarry { smartZoom.mode == .off ? (playlist.map { zoomRules($0.current).carry } ?? .share) : .share }

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
    /// A pair gave way to one page for a reason the screen does not show (a page's header proved it wide, the view
    /// narrowed): the window controller says why when it follows a `D` (`SpreadKeys.toast(on:refusal:)`).
    var onSpreadRefusal: ((SpreadRefusal) -> Void)?
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
    /// resolution if it has it); nil after opening a file or when the playlist was replaced. With two pages its pair's
    /// other page keeps it too, taken from the plan (`SpreadNavigation.previousCompanion`): for a strip scrub this is
    /// the scrub's origin, not the cell passed last.
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
    /// `switch-preview=thumb` put a stand-in up for the current photo and no other navigation came since: its stored
    /// thumbnail is seeded and shown at once, as for a strip jump (`seedsCurrent`, `consider`).
    private var previewsCurrent = false
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
    /// The photo `open` brought, kept after it is shown (unlike `freshOpen`): a step did not bring it, so its subjects
    /// do not move its view (`ViewerView.subjectsArrived`).
    private(set) var openedPhoto: URL?
    /// The photo the transform is laid out for (the last one shown with its header): a later show of it (a finer
    /// level) keeps the view it has; any other photo gets the view `PhotoSwitchView` chooses.
    private var laidOut: URL?

    /// `thumbnailsReady` finishes once the store knows the viewer cache's activity: it starts out `.idle`, and a
    /// request before that could start a thumbnail read while the first photo loads.
    init(cache: ImageCache<MetalPyramidLoader>, thumbnails: ThumbnailStore, thumbnailsReady: Task<Void, Never>? = nil,
         positions: FolderPositions, navigator: FolderNavigator = FolderNavigator(),
         photosLibrary: any PhotosLibraryAccess = PhotosLibrary.shared) {
        self.cache = cache
        self.thumbnails = thumbnails
        self.positions = positions
        self.navigator = navigator
        thumbnailChain = thumbnailsReady
        stripAspects = StripAspects(fetch: { urls, applies in
            if urls.first.flatMap(PhotosLocation.asset(in:)) != nil {
                return (try? await photosLibrary.aspects(urls)) ?? [:]
            }
            return await thumbnails.aspects(urls, applyingOrientation: applies)
        })
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
            }
        }
        watcher.onChange = { [weak self] isPoll in self?.rereadFolder(isPoll ? .idle : .event) }
        stripAspects.onChange = { [weak self] in self?.stripAspectsChanged() }
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
    private var requestedCacheActive = false
    private var requestedCacheVisible = false
    private var photosViewerVisible = true

    func setPhotosViewerVisible(_ visible: Bool) {
        guard photosViewerVisible != visible else { return }
        photosViewerVisible = visible
        guard playlist?.isSourceOrdered == true else { return }
        setActivity(active: requestedCacheActive, visible: requestedCacheVisible, lastActive: lastActive)
    }
    /// How recently the window was key (`WindowRegistry.activityRank`): the other windows' thumbnails go by it.
    private var lastActive = 0 {
        didSet { if lastActive != oldValue { sendThumbnailRequest() } }
    }

    /// Tells the cache whether this session is the active one and whether it is on screen. An activation is sent when
    /// the session becomes active, numbered so the cache drops one overtaken by a later one from another session's
    /// chain; the active session coming into view or leaving it (a Space switch, an occlusion change) sends only its
    /// visibility, so one activation is one stamp check and one `activate` line; anything else only when it changed.
    /// The cache checks the current photo's stamp on the activation itself (a file changed while another window was in
    /// front). A window that cannot be seen polls no folder and starts no colour analysis (windows spec §3.6);
    /// `lastActive` goes to the thumbnails.
    /// With `LOUPE_DEBUG` an activation logs what it found (`StatsLine.activationLog`, windows spec §3.8).
    func setActivity(active: Bool, visible: Bool, lastActive: Int) {
        guard !closed else { return }
        requestedCacheActive = active
        requestedCacheVisible = visible
        let sourceVisible = playlist?.isSourceOrdered != true || photosViewerVisible
        let active = active && sourceVisible, visible = visible && sourceVisible
        self.lastActive = lastActive
        watcher.isPaused = !visible
        colorCorrector.isPaused = !visible
        guard active != isCacheActive || visible != isCacheVisible else { return }
        let cache = self.cache, id = cacheID
        if active, isCacheActive {
            isCacheVisible = visible
            enqueue { await cache.setVisibility(id, visible: visible) }
            return
        }
        isCacheActive = active
        isCacheVisible = visible
        let order = Self.nextActivation
        if active { Self.nextActivation += 1 }
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
        guard url.isFileURL else { return }
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

    /// The source supplies membership and order. No folder reads, watcher or filename sort are involved.
    func openPhotos(_ files: [URL], current: URL, refreshing: Bool = false) {
        guard let list = Playlist(ordered: files, current: current) else { return }
        stashNavigator = nil
        cancelOpenFolder()
        cancelFolderRequest()
        uncountedFolder = nil
        if refreshing, playlist?.isSourceOrdered == true {
            _ = apply(list)
            return
        }
        playlist = list
        endScrubOnReplace()
        navigated(direction: 1, from: nil, fresh: true, opened: true)
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
        openFolderTask = Task(priority: .userInitiated) { [weak self] in
            let result: Result<FolderTarget?, Error>
            do { result = .success(try await navigator.contents(of: folder)) } catch { result = .failure(error) }
            guard !Task.isCancelled, let self, self.wantsOpenFolder(token, isWanted: isWanted) else { return }
            switch result {
            case .success(let target?):
                let positions = self.positions
                let sort = BrowserSort.forFolder(target.folder, settings: Settings.shared.folderSettings)
                guard let list = try? await FolderPlaylistPreparation.shared.prepare(target, sort: sort, remembered: {
                    positions.recall(in: $0, among: $1)
                }), !Task.isCancelled, self.wantsOpenFolder(token, isWanted: isWanted) else { return }
                self.playlist = list
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

    /// A folder selected in the filmstrip has already been listed off main. Prepare it there too;
    /// commit and call completion only if still wanted (a superseded request must not cancel a newer interaction).
    func openFolderStripTarget(_ target: FolderTarget, isWanted: @escaping @MainActor () -> Bool,
                               completion: @escaping @MainActor (Bool) -> Void) {
        guard !closed, !target.images.isEmpty, isWanted() else { completion(false); return }
        cancelOpenFolder(); cancelFolderRequest()
        let positions = self.positions
        let sort = BrowserSort.forFolder(target.folder, settings: Settings.shared.folderSettings)
        let token = openFolderToken
        folderMessage = FolderRequest.loadingText
        onChange?()
        openFolderTask = Task(priority: .userInitiated) { [weak self] in
            let list = try? await FolderPlaylistPreparation.shared.prepare(target, sort: sort, remembered: {
                positions.recall(in: $0, among: $1)
            })
            guard let self, !Task.isCancelled, self.wantsOpenFolder(token, isWanted: isWanted) else { return }
            guard let list else { completion(false); return }
            self.playlist = list
            self.endScrubOnReplace()
            self.navigated(direction: 1, from: nil, fresh: true)
            if let label = target.label { self.onFolderLabel?(label) }
            if target.listID != nil { self.onListFolder?(target.listID, target.folder) }
            completion(true)
        }
    }

    /// Only the current request may clear its message when an external selection is cancelled.
    private func wantsOpenFolder(_ token: Int, isWanted: (@MainActor () -> Bool)?) -> Bool {
        guard !closed, token == openFolderToken else { return false }
        guard isWanted?() ?? true else {
            folderMessage = nil
            onChange?()
            return false
        }
        return true
    }

    /// A later navigation wins over a folder still listing or preparing.
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
        guard let wanted = spread.target(from: before, by: step, count: list.files.count),
              let target = folderSpread.on ? wanted : indexPastBroken(wanted, step: step, in: list),
              list.move(by: target - before) else {
            stepAfterReread(step)
            return false
        }
        playlist = list
        navigated(direction: step.signum(), from: before, wait: wait)
        return true
    }

    /// `index`, or the first one beyond it in the direction of `step` that is not a known broken file (`UnreadableFiles`:
    /// found by the viewer, the strip or Home in this run, and not changed since); nil past the end.
    private func indexPastBroken(_ index: Int, step: Int, in list: Playlist) -> Int? {
        list.index(from: index, step: step) { UnreadableFiles.app.contains($0, stamp: list.stamps[$0]) }
    }

    /// A step onto a file the decoders cannot read goes on in its direction, to the next one that may be shown (the
    /// other way at the end of the folder), and the failure is not shown: a photo the user did not ask for by name is not
    /// worth an error. The file the user opened, one the strip jumped to and a folder of two pages show it as ever. The
    /// photo before stays on screen until the next one is in, so the viewer does not flash.
    private func skipBroken(_ e: CacheEntryView<TiledImage>, failure: String) -> Bool {
        guard LoadErrorText.isBroken(failure) else { return false }
        UnreadableFiles.app.mark(e.url, stamp: playlist?.stamps[e.url])   // also when shown: Home and the strip learn it
        guard !opened, !jumpedFromStrip, !folderSpread.on, let list = playlist, list.current == e.url else { return false }
        DebugLog.log("skip broken \(e.url.lastPathComponent)")
        for direction in [self.direction, -self.direction] {
            guard let target = indexPastBroken(list.index + direction, step: direction, in: list) else { continue }
            var moved = list
            guard moved.move(by: target - list.index) else { continue }
            playlist = moved
            navigated(direction: direction, from: list.index)
            return true
        }
        return false
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
        guard !closed, playlist?.isSourceOrdered != true, let folder = playlist?.current.deletingLastPathComponent() else { return }
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
        let ordered = listed.isSourceOrdered ? listed : listed.sorted(BrowserSort.forFolder(folder, settings: Settings.shared.folderSettings))
        let new = old.replacing(with: ordered)
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
        guard playlist?.isSourceOrdered != true, let current = playlist?.current, let token = folderRequest.begin(from: current) else { return }
        cancelOpenFolder()
        folderMessage = FolderRequest.loadingText
        onChange?()
        let navigator = self.navigator, stash = stashNavigator
        let archives = Settings.shared.config.archiveFolders
        let folder = current.deletingLastPathComponent()
        // Siblings in the order Home shows their parent in.
        let siblingSort = BrowserSort.forFolder(folder.standardizedFileURL.deletingLastPathComponent(),
                                                settings: Settings.shared.folderSettings)
        folderTask = Task(priority: .userInitiated) { [weak self] in
            let result: Result<FolderTarget?, Error>
            do {
                // A gallery opened from a Stash list steps through that list (Stash spec §2.3); any other folder by disk.
                let target = if let stash { try await stash.neighbour(of: folder, step: step) }
                             else { try await navigator.neighbour(of: folder, step: step, archives: archives, sort: siblingSort) }
                result = .success(target)
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled, let self, !self.closed else { return }
            let found = (try? result.get()) ?? nil
            let label = found?.label
            let prepared: Result<Playlist?, Error>
            if let found {
                let positions = self.positions
                let sort = BrowserSort.forFolder(found.folder, settings: Settings.shared.folderSettings)
                do {
                    prepared = .success(try await FolderPlaylistPreparation.shared.prepare(found, sort: sort, remembered: {
                        positions.recall(in: $0, among: $1)
                    }))
                } catch { return }   // cancelled while preparing; navigation owns the new state
            } else {
                prepared = result.map { _ in nil }
            }
            guard !Task.isCancelled, !self.closed else { return }
            let outcome = self.folderRequest.finish(token, prepared: prepared, current: self.playlist?.current)
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
        (jumpedFromStrip && Settings.shared.config.stripJumpPreview) || stepWait == .thumb || previewsCurrent
    }

    /// Seeds the current photo from its stored thumbnail (`ThumbnailStore.seed`, no file read), when `seedsCurrent`
    /// (with `strip-jump-preview=no` a jump is a plain navigation). Seeded after the focus that made it current went
    /// out, so a failed photo reset for its retry gets its thumbnail; dropped when the cursor moved on meanwhile.
    private func seedCurrent() {
        guard !closed, seeding == nil, seedsCurrent, let url = playlist?.current, url.isFileURL else { return }
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
        if collapseView?.page != current { collapseView = nil }
        cancelOpenFolder()
        cancelFolderRequest()   // any navigation outranks a folder switch still being resolved
        jumpedFromStrip = fromStrip
        stepWait = wait
        // The stand-in of the photo before stays until the cache's first answer for this one decides (`received`), so
        // a photo already cached appears within a frame without a blank flash between.
        previewsCurrent = false
        self.direction = direction == 0 ? 1 : direction
        previousIndex = previous
        dwelling = false
        self.opened = opened
        freshOpen = opened ? current : nil
        openedPhoto = opened ? current : nil
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
        let saved = fresh && current.isFileURL ? positions.view(in: folder) : nil
        let savedFile = current.isFileURL ? positions.fileName(in: folder) : nil
        if current.isFileURL {
            positions.record(folder: folder, file: name, keepingView: Settings.shared.config.folderViewMemory == .folder)
        }
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
                               companion: pages.companion, step: pages.step,
                               previousCompanion: spread.previousCompanion(of: previousIndex))
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
        if list.isSourceOrdered {
            sentThumbnailRequest = nil
            let thumbnails = self.thumbnails, window = thumbnailWindowID
            enqueueThumbnails { await thumbnails.setRequest(window: window, nil, stamps: [:]) }
            return
        }
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
        if list.isSourceOrdered {
            colorCorrector.update(files: [], current: 0, direction: direction, stamps: [:], settings: colorSettings, reach: 0)
            return
        }
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

    /// The mode the current photo arrives in before its header is known: the saved one while a saved view waits
    /// (assuming its size), else the one `PhotoSwitchView` gives it (which does not depend on the size).
    private var arrivalMode: ZoomMode {
        restore.map { transform(showing: $0.file, size: $0.view.imageSize, over: judgedTransform).mode }
            ?? playlist.map { transform(showing: $0.current, size: judgedTransform.imageSize, over: judgedTransform).mode }
            ?? judgedTransform.mode
    }

    /// Whether the current mode needs a level finer than Lfit for the current photo. Before its header is known:
    /// whether the mode is not a fit mode (the saved one, while a saved view waits, assuming its size; else the one
    /// `PhotoSwitchView` gives it, which does not depend on the size).
    private func needsFull() -> Bool {
        guard let latest, let info = latest.info, latest.url == playlist?.current else {
            switch arrivalMode {
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
        spreadState.forgetSizes()
        stripAspects.setAppliesOrientation(applies)
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
        if smartZoom.mode != .frame, let saved = restored(url, size: size, over: current) {
            // Retained scale is a starting view; active SmartZoom still owns the point of interest.
            guard url != laidOut else { return saved }
            return subjectBoxes(url).flatMap { smartFraming(url, shown: saved, boxes: $0) } ?? saved
        }
        if smartZoom.mode != .frame, let collapsed = collapseView?.transform(for: url, size: size, over: current) { return collapsed }
        let arrival: PhotoSwitchView.Arrival = url == laidOut ? .laidOut : url == freshOpen ? .opened : .switched
        // The photo on screen keeps the transform it has (a frame of a zoom animation included), as before.
        let shown = PhotoSwitchView.shown(arrival, current: arrival == .laidOut ? base ?? transform : current,
                                          imageSize: size, rules: rules, subject: arrival == .switched ? subjectBoxes(url) : nil)
        guard arrival != .laidOut else { return shown }
        guard smartZoom.mode != .off else { return shown }
        if smartZoom.mode == .frame, let from = entry?.url, from != url { leaveForBrowse(from, to: url, view: current) }
        return subjectBoxes(url).flatMap { smartFraming(url, shown: shown, boxes: $0) }
            ?? (smartZoom.mode == .frame ? shown.withMode(.fit) : shown)
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
        let shownBefore = self.entry?.url
        if let entry {
            consider(entry, atNavigation: atNavigation)
        } else if self.entry?.url != url {
            loadingName = url.lastPathComponent
        }
        if atNavigation { putStandIn(for: url, shownBefore: shownBefore) }
        if atNavigation, stepWait == .thumb || previewsCurrent { seedCurrent(ifNotResidentIn: entry) }
    }

    /// The first answer for `url` after a navigation (`received`) did not put it on screen: a stand-in covers the photo
    /// before, as `switch-preview` says (`ShowPolicy.atNavigation`). `thumb` also seeds the stored thumbnail, which
    /// replaces the strip's cell or the blank once it lands (`previewsCurrent`).
    private func putStandIn(for url: URL, shownBefore: URL?) {
        let setting = Settings.shared.config.switchPreview
        // The strip's cell stands in only where it lies as the photo will: one page at Fit (the stand-in is drawn
        // fitted). Zoomed or in a two-page folder, the blank placeholder until the stored thumbnail (seeded into the
        // pyramid, laid out by the transform) or the photo itself.
        let cellFits = arrivalMode == .fit && !folderSpread.on
        let picture = setting == .thumb && cellFits ? cellPicture?(url) : nil
        let action = ShowPolicy.atNavigation(shownURL: shownBefore, currentURL: url, showable: entry?.url == url,
                                             seedAvailable: picture != nil, setting: setting)
        let next: SwitchStandIn?
        switch action {
        case .keep: next = nil
        case .seed: next = picture.map { SwitchStandIn(url: url, picture: $0) }
        case .placeholder: next = SwitchStandIn(url: url, picture: nil)
        }
        previewsCurrent = setting == .thumb && next != nil
        if action != .keep { DebugLog.log("stand-in \(url.lastPathComponent): \(action == .seed ? "strip cell" : "blank")") }
        guard next != standIn else { return }
        standIn = next
        onChange?()
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
            if skipBroken(e, failure: failure) { return }
            show(e, atNavigation: atNavigation)
            return
        }
        if e.pyramid != nil { UnreadableFiles.app.clear(e.url) }   // read after all (mended, or a wrong mark)
        let onScreen = ShowPolicy.refinesShown(e, shown: entry)
        var allowed = onScreen
        var shownByStep = false
        var detail = "on screen"
        if !onScreen {
            if let info = e.info, let pyramid = e.pyramid {
                let levels = levels(for: info, of: e.url)
                let finest = pyramid.finestResidentLevel
                let jumpPreview = (jumpedFromStrip && Settings.shared.config.stripJumpPreview || previewsCurrent)
                    && e.isSeededOnly
                allowed = ShowPolicy.shouldShow(finestResident: finest, neededLevel: levels.needed,
                                                previewLevel: levels.lfit, mode: Settings.shared.config.showBlurry,
                                                jumpPreview: jumpPreview)
                let byStep = !allowed && ShowPolicy.shownByStep(stepWait, finestResident: finest,
                                                                seededOnly: e.isSeededOnly)
                allowed = allowed || byStep
                shownByStep = byStep
                detail = "finest \(finest.map(String.init) ?? "-") needed \(levels.needed) lfit \(levels.lfit)"
                    + (jumpPreview ? " jump preview" : "") + (byStep ? " step-wait \(stepWait?.rawValue ?? "")" : "")
            } else {
                detail = "no pyramid"
            }
        }
        let state = e.isSeededOnly ? "thumb" : e.state.map { "\($0)" } ?? "nil"
        DebugLog.log("entry \(name): \(state) \(detail) -> \(allowed ? "show" : "wait")"
                     + timingsText(e.timings))
        if allowed, !onScreen, holdsForFraming(e, byStep: shownByStep, atNavigation: atNavigation) { return }
        if allowed {
            show(e, atNavigation: atNavigation)
        } else if entry?.url != e.url || entry?.failure != nil {
            if loadingName != name {
                loadingName = name
                onChange?()
            }
        }
    }

    /// Asks the window for the subjects of a photo not shown yet (`FramingHold`), drawn from `image` at `orientation`;
    /// `done` on main once they are in or could not be found. False when it cannot ask (analysis off, two pages).
    var askSubjectsNow: ((URL, TiledImage, ImageOrientation, @escaping @MainActor () -> Void) -> Bool)?
    /// The photo waiting for its subjects before it is shown (`FramingHold`), and whether the wait is over.
    private var framingHold: (url: URL, ended: Bool, atNavigation: Bool)?

    /// Whether `e`, allowed on screen, waits for its subjects first (`FramingHold`): asks for them and holds it until
    /// they are in or `FramingHold.wait` passes, then considers it again.
    private func holdsForFraming(_ e: CacheEntryView<TiledImage>, byStep: Bool, atNavigation: Bool) -> Bool {
        let url = e.url
        if let hold = framingHold, hold.url == url { return !hold.ended }
        guard let info = e.info, let pyramid = e.pyramid,
              FramingHold.holds(framing: smartZoom.mode == .frame,
                                known: subjectBoxes(url) != nil, seeded: e.pyramidIsSeeded, byStep: byStep,
                                opened: url == freshOpen || restore?.file == url || entry == nil) else { return false }
        framingHold = (url, false, atNavigation)
        let orientation = info.drawOrientation(applying: appliesOrientation, seeded: false)
        guard askSubjectsNow?(url, pyramid, orientation, { [weak self] in self?.endFramingHold(url) }) == true else {
            framingHold = nil
            return false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + FramingHold.wait) { [weak self] in
            MainActor.assumeIsolated { self?.endFramingHold(url) }
        }
        DebugLog.log("entry \(url.lastPathComponent): waits for its subjects")
        return true
    }

    /// The wait for `url`'s subjects is over (they are in, or the time is up): the photo is considered again.
    private func endFramingHold(_ url: URL) {
        guard let hold = framingHold, hold.url == url, !hold.ended else { return }
        framingHold?.ended = true
        DebugLog.log("entry \(url.lastPathComponent): subjects \(subjectBoxes(url) == nil ? "not in, shown" : "in")")
        guard isOpen(on: url), let latest, latest.url == url, entry?.url != url else { return }
        consider(latest, atNavigation: hold.atNavigation)
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
            if folderSpread.on { stripAspects.cellPictureArrived(e.url) }
        }
        entry = e
        // The current photo is on screen: no stand-in over it any more.
        if e.url == playlist?.current { standIn = nil }
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
            if collapseView?.page == e.url { collapseView = nil }
            if let restore, restore.file == e.url {
                // The pair's other page has a stand-in size, or none yet (the photo alone until its header is in):
                // the saved view (recorded at the pair's real size) is decided once that page's size is in
                // (`relayout`), while the view stays untouched (a zoom key pressed during the load, a zoom or pan since
                // an earlier show drop it).
                let provisional = pairProvisional
                if let waiting = restore.waiting(atShowOf: next.imageSize, provisional: provisional,
                                                 before: judgedTransform, shown: next) {
                    DebugLog.log("saved view of \(e.url.lastPathComponent) waits for the pair's size")
                    self.restore = waiting
                } else if provisional, !restore.view.applies(to: next.imageSize) {
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
        } else if e.failure != nil {
            if restore?.file == e.url { restore = nil }
            // A failed page in a pair: laid out at its stand-in beside the good page, which draws (`ownSize`).
            if shownLayout != nil {
                relayout(from: nil)
                return
            }
        }
        onChange?()
    }

    // MARK: Two pages (spread spec 2026-10-23)

    /// The spread keys of a photo's folder (`spread`, `spread-shift`, `spread-direction`, `spread-landscape`,
    /// `spread-wide-ratio`): the window controller sets it from that folder's settings over loupe.conf, like
    /// `zoomRules`. Asked with the photo when the current folder changes, so a folder step takes the new folder's own
    /// flag; `updateSpreadRules` asks again.
    var spreadRules: (URL) -> SpreadRules = { _ in SpreadRules(config: Settings.shared.config) }

    /// The folder's rules, the known page sizes, the plan and the companion (`updateSpread`).
    private var spreadState = SpreadState()
    /// The rules of the current photo's folder when they were last asked.
    private var folderSpread: SpreadRules { spreadState.rules }
    /// How steps go and which page pairs with the current one.
    private var spread: SpreadNavigation { spreadState.navigation }
    /// The thumbnail store's aspects of the playlist's files (its catalog and memory: no file is read): one per window,
    /// shared with the strip, which lays its cells out by them (`StripController`), so the catalog is asked once. The
    /// strip feeds it the playlist, `exif-orientation`, the store's thumbnail notices and its cells' pictures; the session
    /// gives it the same playlist and orientation when it builds a plan (no-ops when they are the same) and the photo it
    /// shows. An arrival rebuilds the plan while the folder shows two pages (`stripAspectsChanged`).
    let stripAspects: StripAspects
    /// New aspects arrived (`stripAspects.onChange`): the strip lays its cells out again.
    var onStripAspectsChange: (() -> Void)?
    /// The other page of the current photo's pair (playlist index and file), nil for one page. The current photo is
    /// any page of the pair: turning two pages on mid-folder shows the pair containing it, a step lands on a first page.
    var companionIndex: Int? { spreadState.companionIndex }
    var companionURL: URL? { spreadState.companionURL }
    /// The latest entry read for `companionURL`.
    private var latestCompanion: CacheEntryView<TiledImage>?
    /// The page on screen beside `entry`, nil for one page or while its slot waits for it. It is what was read of the
    /// current companion while `entry` is the current photo; a previous photo still on screen keeps the page it had.
    private(set) var shownCompanion: CacheEntryView<TiledImage>?
    /// Photos' EXIF for the status (megapixels, exposure), by file: the window asks for the photo on screen
    /// (`ViewerWindowController.askPhotoFacts`); a few hundred at most, emptied past that.
    var photoFacts: [URL: FileFacts] = [:]
    /// `shownCompanion` comes first in reading order.
    private(set) var companionFirst = false
    /// Where the pages on screen sit in the transform's (virtual) picture, nil for one page: the view draws by it and
    /// finds the page under the pointer with it. Kept, not made per frame.
    private(set) var shownLayout: SpreadLayout?
    /// `shownLayout`'s other page has a stand-in size: a saved view of the pair waits for the real one.
    private var shownLayoutProvisional = false
    /// The view a pair's first page gets when the pair gives way to it alone (`spreadChanged`), until it is shown.
    private var collapseView: SpreadCollapse?
    private var sentPins: (URL?, URL?) = (nil, nil)
    private var spreadSyncPending = false
    private var spreadRebuildPending = false

    /// The companion's pyramid to draw: nothing for one page, a page not read yet or a failed one.
    var companionImage: TiledImage? {
        guard shownLayout != nil, let c = shownCompanion, c.failure == nil else { return nil }
        return c.pyramid
    }

    /// A page on screen and the scale it is drawn at, for the info panel's filter row: `url` is the companion while it is
    /// drawn, anything else the photo on screen. In a pair the transform is the virtual picture's, and a page's scale is
    /// the transform's times its share of that picture (every page is as tall as it), so the row names the level and
    /// filter that page is drawn with, not the other's. Nil without a picture.
    func drawnPage(_ url: URL?) -> (image: TiledImage, scale: Double)? {
        let companion = url != nil && url == shownCompanion?.url
        // The pair's other page while it is not drawn (not read yet, failed): nothing to describe, not the photo beside it.
        if !companion, url != nil, url == companionURL, url != entry?.url { return nil }
        guard let image = companion ? companionImage : self.image, let info = (companion ? shownCompanion : entry)?.info
        else { return nil }
        let scale = transform.drawnScale
        guard let layout = shownLayout else { return (image, scale) }
        return (image, layout.pageScale(scale, pageHeight: Double(displaySize(info).height)))
    }

    /// The orientation `companionImage` is drawn with (as `drawOrientation`).
    var companionDrawOrientation: ImageOrientation {
        guard let c = shownCompanion, let info = c.info else { return .up }
        return info.drawOrientation(applying: appliesOrientation, seeded: c.pyramidIsSeeded)
    }

    /// Why the current photo shows alone with two pages on, when the screen does not say it; nil for a pair or off.
    var spreadRefusal: SpreadRefusal? { playlist.flatMap { spread.refusal(at: $0.index) } }

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
        guard let current = playlist?.current,
              spreadState.setRules(spreadRules(current), folder: current.deletingLastPathComponent()) else { return }
        let rules = spreadState.rules, options = rules.options
        DebugLog.log("spread \(rules.on ? "on" : "off")\(options.shift ? " shifted" : "")"
                     + (options.rightToLeft ? " rtl" : "")
                     + (options.landscapeAlone ? " wide from \(options.wideRatio)" : " landscape paired"))
        spreadChanged(rebuild: true)
    }

    /// Brings the spread state up to the folder's rules, the playlist, the known sizes and the view: the plan when one
    /// of its inputs changed or `rebuild`, then the current photo's companion. No cache call and no notification: the
    /// callers make them (a navigation sends the focus once, with the companion). True when the companion changed.
    @discardableResult
    private func updateSpread(rebuild: Bool = false) -> Bool {
        let changed = spreadState.update(files: playlist?.files ?? [], index: playlist?.index, rebuild: rebuild,
                                         rules: spreadRules, aspects: aspectsFor)
        if latestCompanion?.url != companionURL { latestCompanion = nil }
        return changed
    }

    /// The store's aspects of `files` as known now (an asynchronous fetch follows for the rest; its arrival rebuilds).
    private func aspectsFor(_ files: [URL]) -> [Double?] {
        stripAspects.setAppliesOrientation(appliesOrientation)
        stripAspects.setPlaylist(files)
        return stripAspects.aspects
    }

    /// The shared aspects changed: the strip lays out again, and a folder showing two pages pairs by them anew.
    private func stripAspectsChanged() {
        if folderSpread.on { scheduleSpreadSync(rebuild: true) }
        onStripAspectsChange?()
    }

    /// The view's size crossed width = height: two pages give way to one, or come back (spread spec, «Узкое окно»).
    private func viewSizeDidChange() {
        if spreadState.setViewSize(transform.viewSize) { scheduleSpreadSync(rebuild: false) }
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
        let changed = updateSpread(rebuild: rebuild)
        if shown?.second != nil, companionIndex == nil, let refusal = spreadRefusal { onSpreadRefusal?(refusal) }
        if !spread.isActive, let first = SpreadNavigation.single(after: shown, current: index) {
            // The first page was on screen beside the current one: it keeps its spot and its drawn scale
            // (`SpreadZoom`), as a page that stays does, rather than a switch's carried zoom.
            if let page = shownCompanion, let files = playlist?.files, page.url == files[first],
               entry?.url == playlist?.current, page.failure == nil, let info = page.info, let rect = companionRect {
                settleZoom()
                collapseView = SpreadCollapse(page: page.url, rect: rect, pageSize: displaySize(info), from: transform)
            }
            navigate { _ = $0.move(by: first - $0.index) }
            return
        }
        sendFocus()
        if changed {
            companionDidChange()
        } else if makeLayout()?.layout != shownLayout {
            // The same companion in another layout (`spread-direction`, a stand-in's aspect): laid out again, not read.
            let before = shownPageRect
            adoptCompanion()
            relayout(from: before)
        }
        // Otherwise (an aspect batch that pairs the same, the usual case) nothing changed on screen.
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
    /// page taken for portrait is landscape) the plan is rebuilt, after the entry has been dealt with; true then. Two
    /// pages off, the size is kept all the same, so `D` plans the photo on screen at its real size.
    @discardableResult
    private func noteSpreadSize(_ e: CacheEntryView<TiledImage>, at index: Int?) -> Bool {
        guard let info = e.info else { return false }
        let size = info.displaySize(applying: appliesOrientation)
        guard spreadState.note(e.url, size: size, at: index, aspects: stripAspects.aspects) else { return false }
        scheduleSpreadSync(rebuild: true)
        return true
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
        // A page that pairs otherwise (wide) is not laid out beside the photo for the frame before the plan follows.
        if noteSpreadSize(e, at: companionIndex) { return }
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
        // A failed page first laid out in a pair (its companion's header came after it): the switch's view at the pair.
        if let e = entry, e.failure != nil, e.url != laidOut, let own = ownSize(e) {
            laidOut = e.url
            let next = transform(showing: e.url, size: layoutSize(own))
            if next != transform {
                transform = next   // didSet notifies
                return
            }
        } else if let e = entry, e.url == laidOut, let own = ownSize(e) {
            let size = layoutSize(own), now = shownPageRect
            var next: ViewTransform?
            if let restore, restore.file == e.url, !pairProvisional {
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
        guard let e = entry, let own = ownSize(e), let layout = layout(of: e.url, size: own) else { return nil }
        return (layout, !companionRead)
    }

    /// The page beside the photo on screen (the current companion while that is the current photo) is read: its header
    /// is in, or it failed (then it keeps the stand-in for good). False without one.
    private var companionRead: Bool {
        let other = entry?.url == playlist?.current ? companionURL : shownCompanion?.url
        return [shownCompanion, latestCompanion].contains { page in
            guard let page, page.url == other else { return false }
            return page.info != nil || page.failure != nil
        }
    }

    /// The photo on screen is laid out at a size its pair does not keep (`SpreadSizes.isProvisional`): its other page
    /// has a stand-in size, or no size at all yet (no header, no store aspect: the photo shows alone until it comes). A
    /// saved view of the pair waits meanwhile (`show`) and is decided in `relayout` once this is false.
    private var pairProvisional: Bool {
        let planned = entry != nil && entry?.url == playlist?.current && companionURL != nil
        return SpreadSizes.isProvisional(standIn: shownLayoutProvisional, companionPlanned: planned,
                                         companionRead: companionRead)
    }

    /// The pair `url` (the photo on screen, or the current one about to be; `own` its size) is laid out in, nil for one
    /// page. A companion not read yet takes the store's aspect at `own`'s height, so the photo keeps its place when the
    /// page comes; without one the photo shows alone until the page's header is in, and a failed page takes `own`
    /// (`SpreadSizes.pageSize`).
    private func layout(of url: URL, size own: CGSize) -> SpreadLayout? {
        let other: URL?, otherFirst: Bool
        var aspect: Double?
        if url == playlist?.current {
            other = companionURL
            otherFirst = (companionIndex ?? 0) < (playlist?.index ?? 0)
            if let k = companionIndex, k < stripAspects.aspects.count { aspect = stripAspects.aspects[k] }
        } else if url == entry?.url {
            other = shownCompanion?.url
            otherFirst = companionFirst
        } else {
            return nil
        }
        guard let other else { return nil }
        let pages = [shownCompanion, latestCompanion].compactMap { $0 }.filter { $0.url == other }
        let page = pages.first { $0.failure == nil }
        // Unknown yet: one page until its header is in (`SpreadSizes.pageSize`); failed: a stand-in for good.
        guard let size = SpreadSizes.pageSize(known: page?.info.map(displaySize), aspect: aspect, other: own,
                                              failed: page == nil && !pages.isEmpty) else { return nil }
        let rtl = folderSpread.options.rightToLeft
        return otherFirst ? SpreadLayout(first: size, second: own, rightToLeft: rtl)
            : SpreadLayout(first: own, second: size, rightToLeft: rtl)
    }

    /// The size the transform lays the photo on screen out at: the pair's virtual picture, else the photo's own.
    private func layoutSize(_ info: ImageInfo) -> CGSize { layoutSize(displaySize(info)) }

    private func layoutSize(_ own: CGSize) -> CGSize {
        guard let size = shownLayout?.virtualSize, size.width > 0, size.height > 0 else { return own }
        return size
    }

    /// The size the photo on screen `e` takes in a layout: its header's, as shown. A failed current page whose
    /// companion is read takes a stand-in, the store's aspect at the companion's height (else the companion's size,
    /// `SpreadSizes.pageSize`), so the good page still draws beside its gap and stays reachable; nil otherwise (the
    /// failed page alone: nothing to lay out).
    private func ownSize(_ e: CacheEntryView<TiledImage>) -> CGSize? {
        if e.failure == nil { return e.info.map(displaySize) }
        guard let list = playlist, e.url == list.current, let other = companionURL,
              let info = [shownCompanion, latestCompanion].lazy.compactMap({ $0 })
                .first(where: { $0.url == other && $0.failure == nil && $0.info != nil })?.info else { return nil }
        let aspects = stripAspects.aspects
        return SpreadSizes.pageSize(known: nil, aspect: list.index < aspects.count ? aspects[list.index] : nil,
                                    other: displaySize(info), failed: true)
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
        return layout.pageScale(t.scale, pageHeight: Double(size.height))
    }

    /// Tells Recent of the photo on screen: its folder is entered when it is not the last one told. With two pages on
    /// screen it is the current page (its index and the folder's remembered file), so reopening shows the pair
    /// containing it.
    private func recordRecent(folder: URL, file: String) {
        guard folder.isFileURL, recordsRecent, let recent, let playlist else { return }
        if folder != recentFolder {
            recentFolder = folder
            recent.entered(folder, kind: ArchivePath.isArchive(folder) ? .archive : .folder, gallery: nil, title: nil,
                           clearsGallery: entersFromOutside)
            entersFromOutside = false
        }
        recent.viewed(folder, file: file, index: playlist.index, count: playlist.files.count)
        // The folder card's progress: in memory now, written with the position (no extra write per photo).
        positions.recordVisit(folder: folder, index: playlist.index, count: playlist.files.count)
    }

    /// Saves how `photo` is looked at for its folder (`FolderPositions`): only while it is the photo on screen (the
    /// transform has its size, not a previous photo's while it loads) and the photo its folder remembers.
    private func recordView(of photo: URL) {
        guard photo.isFileURL, let entry, entry.url == photo, entry.failure == nil, entry.info != nil else { return }
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
        stripAspects.close()
        rereads.reset()   // a listing in flight is dropped
        cancelOpenFolder()
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

/// What covers the screen while the current photo cannot be shown yet (`ViewerSession.standIn`): `picture`, the strip's
/// decoded cell of `url`, scaled up to fit; nil, a blank placeholder (with the loading spinner).
struct SwitchStandIn: Equatable {
    let url: URL
    let picture: CGImage?

    static func == (a: SwitchStandIn, b: SwitchStandIn) -> Bool { a.url == b.url && a.picture === b.picture }
}
