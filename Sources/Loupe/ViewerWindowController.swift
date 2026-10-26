import AppKit
import HomeChrome
import HomeScreenKit
import InfoPanelKit
import LoupeCore
import LoupeRender
import StashKitUI
import UniformTypeIdentifiers

/// One viewer window: owns its `ViewerSession` and lays out the stats status, the viewer and the thumbnail strip
/// inside it. Windowed, the status sits above the viewer (the viewer shrinks to make room); in native full
/// screen the viewer fills the window and the status floats over its top edge. The thumbnail strip floats over the
/// viewer's bottom edge, except windowed with `strip-window=beside`, where the viewer ends at the strip's top. The info
/// panel (`⌘I`, M4a spec §3) floats at the viewer's top right while it is open.
@MainActor final class ViewerWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let session: ViewerSession
    let viewerView: ViewerView
    /// The app's viewer windows; set when added. The one whose `active` this is remembers full screen.
    weak var registry: WindowRegistry?
    private let statsBar = StatsBar()
    /// The key toast's column (`toast-position`): one of these is active.
    private let keyToastLeft: NSLayoutConstraint
    private let keyToastCenter: NSLayoutConstraint
    private let keyToastRight: NSLayoutConstraint
    /// The toast's rows: at the top under the bar or at the window's top, at the bottom over the bar or the strip.
    private let keyToastBelowBar: NSLayoutConstraint
    private let keyToastAtTop: NSLayoutConstraint
    private let keyToastAboveStrip: NSLayoutConstraint
    private let strip: StripController
    private let loadingIndicator = LoadingIndicator()
    /// Over the viewer while the photo navigated to cannot be shown yet (`switch-preview`, `ViewerSession.standIn`).
    private let standInView = SwitchStandInView()
    private let warningsOverlay = ConfigWarningsOverlay()
    private let cheatSheet = CheatSheetView()
    /// What `S`, `A` and their ⇧ forms just did, at the bottom centre.
    private let toast = ToastView()
    /// The Stash WebUI over the viewer (Stash spec §2.1); nil until first shown, dropped when its settings change.
    private var stash: StashLibrary?
    private var stashPicks = StashPickGate()
    /// File › Back (⌘[) goes back to this Home tab: what is shown was opened from it (Home spec §2.1).
    private var returnsTo: HomeTab? {
        didSet { updateBackButton() }
    }
    /// The Home tab a gallery being entered returns to (Recent when a Recent card opened it).
    private var galleryReturn = HomeTab.stash
    private let thumbnails: ThumbnailStore
    /// The Stash gallery last entered from this tab's Stash, or stepped to in its list, and its folder (or zip): the tab
    /// shows that gallery while it is in that folder (another open leaves it).
    private var stashGallery: (id: String, folder: URL)?
    /// The Stash list the gallery on screen was opened from, at its place in it (Recent keeps it).
    private var stashList: StashGalleryListContext?
    /// Asked before a gallery clicked in this tab's Stash is opened: true when it was handled elsewhere (the registry
    /// switched to a tab showing it), and this tab stays on Stash.
    var onStashPick: ((StashGalleryPick) -> Bool)?
    /// "‹ Recent" or "‹ Stash" (`backTarget`: whenever a photo is open), with the strip.
    private let backButton = BackButton()
    private var backButtonShown = false
    /// The app's per-folder values, which `S` and `A` write for this window's folder.
    private let folderSettings: FolderSettings
    /// The folder of the photo on screen (standardized), whose values the window's scaling takes; nil before the
    /// first photo, and then `S`, `⇧S`, `A`, `⇧A` do nothing.
    private var folder: URL?
    /// `folderSettings.values(for: folder)` as of the last recompute, less what `Config.applying` refused: what the
    /// stats line marks ` · folder` and what `⇧S` saves.
    private var folderValues: [String: String] = [:]
    /// loupe.conf with the folder's values on top (folder settings spec §7): what this window scales with. Recomputed
    /// when the folder changes, on `.settingsChanged` and on `.folderSettingsChanged`.
    private(set) var effectiveConfig = Settings.shared.config
    /// The folder entries already reported as refused, so a recompute does not print them again.
    private static var reportedRejections: Set<String> = []
    /// The warnings the overlay last showed, so a settings push that changes nothing does not bring a dismissed box back.
    private var shownWarnings: [String] = []
    private let warningsBelowBar: NSLayoutConstraint
    private let warningsAtTop: NSLayoutConstraint
    /// The back button's top: under the image status in a window, else from the window's top.
    private let backBelowBar: NSLayoutConstraint
    private let backAtTop: NSLayoutConstraint
    private let viewerAtTop: NSLayoutConstraint
    /// The pan pills' top: below the toolbar in a window, the container's top in full screen.
    private let pillsAtTop: NSLayoutConstraint
    private let viewerAboveStrip: NSLayoutConstraint
    private let viewerAtBottom: NSLayoutConstraint
    private let statsAtTop: NSLayoutConstraint
    private let viewerAtScreenTop: NSLayoutConstraint
    private let pillsAtScreenTop: NSLayoutConstraint
    /// What the toolbar's buttons do.
    private lazy var viewerActions = ViewerToolbarController.Actions(
        back: { [weak self] in self?.goBack(nil) },
        step: { [weak self] step in self?.performViewerAction(step < 0 ? .previous : .next) },
        zoom: { [weak self] action in self?.performViewerAction(action) },
        colour: { [weak self] action in self?.performViewerAction(action) },
        setValue: { [weak self] key, value in self?.setColourValue(key, value) },
        stats: { [weak self] in self?.toggleStats() },
        strip: { [weak self] in self?.strip.togglePin() },
        info: { [weak self] in self?.toggleInfoPanel(nil) })
    private lazy var viewerToolbar = ViewerToolbarController(actions: viewerActions)
    private var isFullScreen = false
    /// Full screen: the toolbar is the system's (it slides in with the menu bar when the pointer reaches the top edge);
    /// `⌥⌘T` takes it away or gives it back. The stats bar (`I`) is shown over the picture on its own.
    private var fullScreenToolbarOverride: Bool?
    private var fullScreenToolbar: Bool {
        get {
            if let fullScreenToolbarOverride { return fullScreenToolbarOverride }
            switch Settings.shared.config.fullScreenToolbar {
            case .shown: return true
            case .hidden: return false
            case .remember: return UserDefaults.standard.object(forKey: "fullScreenToolbar") as? Bool ?? true
            }
        }
        set {
            fullScreenToolbarOverride = newValue
            if Settings.shared.config.fullScreenToolbar == .remember { UserDefaults.standard.set(newValue, forKey: "fullScreenToolbar") }
        }
    }
    /// `⌥⌘T` in a window: the toolbar shown or hidden, in every window and across launches.
    private var windowToolbar: Bool {
        get { UserDefaults.standard.object(forKey: "viewerToolbar") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "viewerToolbar") }
    }
    private var toolbarWanted: Bool { isFullScreen ? fullScreenToolbar : windowToolbar }
    /// What the window's toolbar was last told, so the system's slide-in in full screen is not pinned by telling it again.
    private var toolbarWasWanted = true
    /// Remembered like the windowed `statsMode`, for the next full screen.
    private var fullScreenStatus: Bool {
        get { UserDefaults.standard.bool(forKey: "fullScreenStatus") }
        set { UserDefaults.standard.set(newValue, forKey: "fullScreenStatus") }
    }
    /// The photo the status last spoke of, so only a move to another photo brings back a bar that hides by itself.
    private var lastNavigationKey = ""
    private static let statsModeKey = "statsMode"
    /// The viewer windows' tabbing identifier, and the first window's frame autosave name.
    static let frameName = "LoupeViewer"
    private static let fullScreenKey = "fullScreen"
    /// The info panel is open, in every window and across launches (M4a spec §3.1).
    static let infoPanelKey = "infoPanelVisible"
    /// Set when the app starts quitting or the window closes: macOS leaves full screen while closing the window,
    /// and that exit is not the user's choice, so it must not clear the remembered flag.
    private var isTerminating = false

    /// The info panel (InfoPanelKit): shown, placed, dragged, resized and remembered by the package, the same in every
    /// window (`keyPrefix` `infoPanel`). Made with the window.
    private var infoPanel: InfoPanelController!
    /// The user wants the panel and this window reads for it (metadata, diagnostics); off: nothing read for it.
    private var infoActive = false
    /// Keeps the previous photo's File and Capture on screen until the new photo's are all known (`InfoPanelHold`), so a
    /// step swaps them at once; the timer ends a hold at its limit.
    private var infoHold = InfoPanelHold()
    private var infoHoldTimer: Timer?
    /// The app's one metadata cache (M4a spec §3.4): every window's panel reads through it. Made on first use, so
    /// a session that never opens the panel never makes it.
    private static let metadataCache = PhotoMetadataCache()
    /// The photo the panel's File and Capture sections are about (the current one), with what was read for it: the
    /// file's size from a stat, the metadata, and whether the read has taken a second already (`Reading…`).
    private var infoURL: URL?
    private var statSize: Int?
    private var metadata: PhotoMetadata?
    private var metadataPending = false
    private var metadataTask: Task<Void, Never>?
    private var slowReadTask: Task<Void, Never>?
    /// The panel's Diagnostics rows as of the last timer tick.
    private var diagnosticsRows: [InfoRow] = []
    /// The File and Display inputs the panel shows, so the session changes that alter neither (most frames of a pan)
    /// rebuild nothing.
    private var shownFile: InfoFileFacts?
    private var shownDisplay: InfoDisplayFacts?
    /// The 0.5 s refresh of the panel's Diagnostics and Display; exists only while the panel is open and the window
    /// can be seen (CPU at rest stays ~0).
    private var diagnosticsTimer: Timer?
    /// Set when the window closes: a late notification (a full-screen exit finishing) must not restart the
    /// timer or the frame recording.
    private var isClosed = false
    /// Observers of this window's notifications, removed when it closes.
    private var windowObservers: [NSObjectProtocol] = []
    /// The `background` the window and the viewer show, so a reload that leaves it alone touches neither.
    private var appliedBackground = Settings.shared.config.background
    /// The resampling keys the viewer draws with, so a reload that leaves them alone does not redraw.
    private var appliedResampling: ResampleSettings
    /// The transparency keys the viewer draws with (`background` included, for `transparency=background`).
    private var appliedTransparency = TransparencySettings(config: Settings.shared.config)

    /// Persisted in `UserDefaults`; compact unless the user chose otherwise.
    private var statsMode: StatsMode {
        get { StatsMode.stored(UserDefaults.standard.string(forKey: Self.statsModeKey)) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.statsModeKey) }
    }

    init(cache: ImageCache<MetalPyramidLoader>, thumbnails: ThumbnailStore, thumbnailsReady: Task<Void, Never>?,
         positions: FolderPositions, folderSettings: FolderSettings, recent: RecentStore?) {
        self.folderSettings = folderSettings
        self.thumbnails = thumbnails
        session = ViewerSession(cache: cache, thumbnails: thumbnails, thumbnailsReady: thumbnailsReady, positions: positions)
        session.recent = recent
        // No photo yet, so no folder: the effective config is loupe.conf's.
        appliedResampling = ResampleSettings(config: Settings.shared.config)
        viewerView = ViewerView(session: session, resampling: appliedResampling)
        strip = StripController(session: session, store: thumbnails)
        // The content runs under the title bar and the toolbar Home brings, as Home's grid does; the viewer's parts hold to
        // `contentLayoutGuide` (the area below them), so under a bare title bar they stand where they always stood.
        let window = ViewerWindow(contentRect: Self.initialFrame(),
                                  styleMask: [.titled, .resizable, .closable, .miniaturizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Loupe"
        window.collectionBehavior = .fullScreenPrimary
        window.tabbingMode = .preferred
        window.tabbingIdentifier = Self.frameName
        window.minSize = NSSize(width: 320, height: 240)
        window.backgroundColor = NSColor(cgColor: Settings.shared.config.background.cgColor)
        window.isReleasedWhenClosed = false

        let container = ViewerContainerView()
        window.contentView = container
        let top = (window.contentLayoutGuide as! NSLayoutGuide).topAnchor
        viewerView.translatesAutoresizingMaskIntoConstraints = false
        statsBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(viewerView)
        container.addSubview(standInView)   // right over the picture, under everything else
        container.addSubview(statsBar)   // above the viewer in z-order, including the full-screen overlay
        // Above both: as a sibling over the viewer it wins its hit tests, so the viewer's hand cursor and cursor
        // autohide leave it alone (`isMouseOverPicture`).
        container.addSubview(strip.view)
        // The pan position pills: over the strip (and its capsule, `strip.attach`) and the info panel, at the window's
        // edge, under the toast and the cheat sheet; takes no clicks.
        container.addSubview(viewerView.panIndicatorsView)
        // The info panel goes between the bar and the strip while it is shown (`makeInfoPanel`).
        // Over the strip: in the viewer's bottom-right corner, lifted above the band, which covers the viewer's
        // bottom while it floats (and is on screen whenever the strip just jumped).
        container.addSubview(loadingIndicator)
        // Over the strip too, centred above it; takes no clicks.
        container.addSubview(toast)
        container.addSubview(backButton)
        // Over everything, top centre; the sibling's hit test passes every click outside the box through.
        container.addSubview(warningsOverlay)
        // Over everything, the whole window: while open it takes every click (see CheatSheetView).
        container.addSubview(cheatSheet)
        warningsBelowBar = warningsOverlay.topAnchor.constraint(equalTo: statsBar.bottomAnchor, constant: 8)
        warningsAtTop = warningsOverlay.topAnchor.constraint(equalTo: top, constant: 8)
        backBelowBar = backButton.topAnchor.constraint(equalTo: statsBar.bottomAnchor, constant: 16)
        backAtTop = backButton.topAnchor.constraint(equalTo: top, constant: 16)
        let overlayWidth = warningsOverlay.widthAnchor.constraint(lessThanOrEqualToConstant: 640)
        let overlayFits = warningsOverlay.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -32)
        let overlayShort = warningsOverlay.heightAnchor.constraint(lessThanOrEqualTo: container.heightAnchor, constant: -100)
        viewerAtTop = viewerView.topAnchor.constraint(equalTo: top)
        pillsAtTop = viewerView.panIndicatorsView.topAnchor.constraint(equalTo: top)
        viewerAboveStrip = viewerView.bottomAnchor.constraint(equalTo: strip.view.topAnchor)
        viewerAtBottom = viewerView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        statsAtTop = statsBar.topAnchor.constraint(equalTo: top)
        viewerAtScreenTop = viewerView.topAnchor.constraint(equalTo: container.topAnchor)
        pillsAtScreenTop = viewerView.panIndicatorsView.topAnchor.constraint(equalTo: container.topAnchor)
        keyToastLeft = toast.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 26)
        keyToastCenter = toast.centerXAnchor.constraint(equalTo: container.centerXAnchor)
        keyToastRight = toast.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -26)
        keyToastBelowBar = toast.topAnchor.constraint(equalTo: statsBar.bottomAnchor, constant: 8)
        keyToastAtTop = toast.topAnchor.constraint(equalTo: top, constant: 12)
        keyToastAboveStrip = toast.bottomAnchor.constraint(equalTo: strip.view.topAnchor, constant: -12)
        NSLayoutConstraint.activate([
            viewerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            viewerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            viewerView.panIndicatorsView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            viewerView.panIndicatorsView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            viewerView.panIndicatorsView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            statsAtTop,
            statsBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statsBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            strip.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            strip.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            strip.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            warningsOverlay.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            overlayWidth, overlayFits, overlayShort,
            standInView.leadingAnchor.constraint(equalTo: viewerView.leadingAnchor),
            standInView.trailingAnchor.constraint(equalTo: viewerView.trailingAnchor),
            standInView.topAnchor.constraint(equalTo: viewerView.topAnchor),
            standInView.bottomAnchor.constraint(equalTo: viewerView.bottomAnchor),
            loadingIndicator.trailingAnchor.constraint(equalTo: viewerView.trailingAnchor, constant: -12),
            loadingIndicator.bottomAnchor.constraint(equalTo: strip.view.topAnchor, constant: -10),
            toast.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -32),
            backButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            cheatSheet.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            cheatSheet.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            cheatSheet.topAnchor.constraint(equalTo: top),
            cheatSheet.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.initialFirstResponder = viewerView
        window.center()
        super.init(window: window)
        window.toolbar = viewerToolbar.nsToolbar
        toolbarWasWanted = windowToolbar
        viewerToolbar.nsToolbar.isVisible = toolbarWasWanted

        session.onChange = { [weak self] in self?.sessionDidChange() }
        session.cellPicture = { [weak self] in self?.strip.cellPicture(for: $0) }
        // A Stash list step: the tab now shows that gallery (`tabFacts`).
        session.onListFolder = { [weak self] id, folder in
            guard let self else { return }
            self.stashGallery = id.map { ($0, folder.standardizedFileURL) }
            if let id { self.recordRecentGallery(id: id, at: folder) }
        }
        session.onFolderLabel = { [weak self] in
            if Settings.shared.config.folderToast { self?.toast.show($0) }
        }
        session.onSpreadRefusal = { [weak self] refusal in
            // Only right after `D`: the pair it showed was taken back once the other page's header was in.
            guard let self, let at = self.spreadKeyTime, ProcessInfo.processInfo.systemUptime - at < 2 else { return }
            self.toast.show(SpreadKeys.toast(on: true, refusal: refusal))
        }
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.alphaValue = 0
        backButton.isHidden = true
        backButton.onClick = { [weak self] in self?.goBack(nil) }
        viewerView.onToggleStats = { [weak self] in self?.toggleStats() }
        viewerView.onToggleStrip = { [weak self] in self?.strip.togglePin() }
        viewerView.onToggleStripPlacement = { [weak self] in self?.strip.togglePlacement() }
        viewerView.onToggleCheatSheet = { [weak self] in self?.toggleCheatSheet() }
        viewerView.onScalingKey = { [weak self] in self?.scalingKey($0) ?? false }
        viewerView.onColourKey = { [weak self] in self?.colourKey($0) ?? false }
        viewerView.onZoomKey = { [weak self] in self?.zoomKey($0) ?? false }
        viewerView.onSpreadKey = { [weak self] in self?.spreadKey($0) ?? false }
        viewerView.onPointerPageChanged = { [weak self] in self?.updateInfoPanel() }
        viewerView.onPanIndicatorKey = { [weak self] in self?.panIndicatorKey($0) ?? false }
        viewerView.onToggleInfoPanel = { [weak self] in self?.toggleInfoPanel(nil) }
        viewerView.onTabAction = { [weak self] in self?.tabAction($0) }
        viewerView.onPointerMoved = { [weak self] in self?.pointerMoved() }
        viewerView.isCovered = { [weak self] in self?.isShowingHome ?? false }
        viewerView.onAdjust = { [weak self] key, step, steps in self?.adjust(key: key, step: step, steps: steps) }
        // The folder of the photo asked about, not the window's: a folder step takes the new folder's rules.
        session.zoomRules = { [weak self] url in
            let config = self?.folderConfig(url.deletingLastPathComponent()).config ?? Settings.shared.config
            return ZoomRules(config: config)
        }
        session.spreadRules = { [weak self] url in
            SpreadRules(config: self?.folderConfig(url.deletingLastPathComponent()).config ?? Settings.shared.config)
        }
        viewerView.isCheatSheetOpen = { [weak cheatSheet] in cheatSheet?.isOpen ?? false }
        cheatSheet.onClose = { [weak self] in self?.setCheatSheet(open: false) }
        strip.attach(to: container)
        makeInfoPanel(in: container)
        strip.onReservesSpaceChange = { [weak self] in
            self?.applyStripLayout()
        }
        strip.onToast = { [weak self] in self?.toast.show($0) }
        strip.onShownChange = { [weak self] in
            self?.infoPanel.place()
            self?.updateBackButton()
        }
        // A resize, full screen, the strip's height: the panel keeps to its corner of the new area.
        container.onLayout = { [weak self] in self?.infoPanel.place() }
        window.onKeyDown = { [weak self] in self?.windowKey($0) ?? false }
        strip.view.onScroll = { [weak viewerView] in viewerView?.scrollWheel(with: $0) }
        viewerView.isStripPressed = { [weak strip] in strip?.view.isPressed ?? false }
        strip.isScrollSpent = { [weak viewerView] in viewerView?.stripScrollIsSpent($0) ?? false }
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ action: @escaping @MainActor (ViewerWindowController) -> Void) {
            windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { action(self) } }
            })
        }
        observe(NSWindow.willEnterFullScreenNotification) { $0.setFullScreen(true) }
        observe(NSWindow.didExitFullScreenNotification) { $0.setFullScreen(false) }
        observe(NSWindow.didChangeScreenNotification) { $0.updateScreenSize() }
        // The panel's diagnostics refresh only while the window can be seen.
        observe(NSWindow.didMiniaturizeNotification) { $0.updateDiagnosticsTimer() }
        observe(NSWindow.didDeminiaturizeNotification) { $0.updateDiagnosticsTimer() }
        observe(NSWindow.didChangeOcclusionStateNotification) { $0.updateDiagnosticsTimer() }
        observe(NSWindow.didBecomeKeyNotification) {
            $0.session.isKeyWindow = true
            $0.syncFullScreen()   // a tab moved into or out of a full-screen window
            $0.applyToolbarVisibility()   // `⌥⌘T` in another window or tab since this one was in front
        }
        observe(NSWindow.didResignKeyNotification) {
            // A press whose release goes to another window must not fire later; a tab step's press goes on (`tabAction`).
            if !MouseButtons.shared.keepsPresses { MouseButtons.shared.cancelAll() }
            $0.session.isKeyWindow = false
            $0.strip.windowDidResignKey()
        }
        // A reload that turns `strip-loading-indicator` on or off while a thumbnail is on screen, or changes
        // `background`, the transparency keys, `rubber-band`, the stats bar keys or `exif-orientation`.
        let settings = center.addObserver(forName: .settingsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.session.updateOrientationSetting()
                self?.applyBrowserSettings()
                self?.updateLoadingIndicator()
                self?.applyBackground()
                self?.applyTransparency()
                self?.viewerView.setRubberBand(Settings.shared.config.rubberBand)
                self?.viewerView.setPanIndicators(Settings.shared)   // `P` / the menu in any window, or a reload
                self?.updateEffectiveConfig()
                self?.session.setFitUpscale(Settings.shared.config.fitUpscale)
                self?.statsBar.apply(Settings.shared.config)
                self?.updateStatus()
                self?.applyStatsLayout()
                self?.applyToastPosition()
                self?.updateConfigWarnings()
                self?.cheatSheet.inputMapChanged(Settings.shared.inputMap)
            }
        }
        windowObservers.append(settings)
        // `S` or `A` here or in another window, which may show this folder or one above it; ⌥T in another window on
        // this folder with `grid-style-memory` per folder (cheap and idempotent elsewhere).
        let folders = center.addObserver(forName: .folderSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateEffectiveConfig()
                self?.applyGridStyle()
            }
        }
        windowObservers.append(folders)
        // ⌘I in any window: the package shows or hides every window's panel; each window starts or stops its reads.
        let panel = center.addObserver(forName: InfoPanelController.stateDidChange, object: UserDefaults.standard,
                                       queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyInfoPanel() }
        }
        windowObservers.append(panel)
        let terminate = center.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                           queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isTerminating = true }
        }
        windowObservers.append(terminate)
        window.delegate = self   // for windowDidFailToEnterFullScreen and windowWillClose
        updateScreenSize()
        applyStatsLayout()
        applyStripLayout()
        statsBar.apply(Settings.shared.config)
        applyToastPosition()
        updateStatus()
        updateConfigWarnings()
        applyInfoPanel()
    }

    /// The loupe.conf problems box: shown when the warnings differ from the ones this window showed last (a new window
    /// shows the current ones once), gone when the file is fixed or `config-warnings=no`.
    private func updateConfigWarnings() {
        let settings = Settings.shared
        guard settings.config.configWarnings, !settings.warnings.isEmpty else {
            warningsOverlay.hide()
            // With `config-warnings=no` the current warnings count as handled: switching it back on must not bring up
            // a box the user already dismissed (or never asked for).
            shownWarnings = settings.warnings
            return
        }
        guard settings.warnings != shownWarnings else { return }
        shownWarnings = settings.warnings
        warningsOverlay.show(settings.warnings)
    }

    /// The window goes away: nothing it does from here on is the user's choice of full screen or not.
    func windowWillClose(_ notification: Notification) {
        dropStash()
        homeView?.browser.stop()
        homeSources?.folders.stop()
        homeObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        homeObservers = []
        // First: closing in full screen (⌘W, the red button) exits full screen on the way out, and that exit must
        // not be remembered as the user choosing a window.
        isTerminating = true
        isClosed = true
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        MouseButtons.shared.cancelAll()
        applyInfoPanel()   // closed: its reads stop
        stopDiagnosticsTimer()
        viewerView.teardown()
        strip.close()
        session.close()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        applyStatsLayout()
        rememberFullScreen(true)
        viewerView.holdReveal(false)
        finishFullScreenEntry()
    }
    func windowDidExitFullScreen(_ notification: Notification) { rememberFullScreen(false) }

    /// The state the user last left the active window in, restored at the next launch (`restoreFullScreen`); the other
    /// windows' changes are not remembered (spec §2.4).
    private func rememberFullScreen(_ on: Bool) {
        guard !isTerminating, registry.map({ $0.active === self }) ?? true else { return }
        UserDefaults.standard.set(on, forKey: Self.fullScreenKey)
    }

    /// This window just became the active one (spec §2.4, "closed last"): its state is the one remembered, so a window
    /// closed or quit last is restored as it was. Not while it is still being put up (a launch, a new tab or window).
    func rememberFullScreenAsActive() {
        guard let window, window.isVisible else { return }
        rememberFullScreen(window.styleMask.contains(.fullScreen))
    }

    /// At quit: the active window's state is the one the next launch restores.
    func rememberFullScreenAtQuit() {
        guard let window else { return }
        UserDefaults.standard.set(window.styleMask.contains(.fullScreen), forKey: Self.fullScreenKey)
    }

    /// Called once the window is on screen: re-enters full screen if the last session ended in it.
    func restoreFullScreen() {
        guard UserDefaults.standard.bool(forKey: Self.fullScreenKey) else { return }
        enterFullScreen()
    }

    /// What runs once the window entered full screen, failed to, or `revealTimeout` passed (`enterFullScreen`).
    private var afterFullScreenEntry: (() -> Void)?

    /// Enters full screen once the window is on screen (a launch, a new window from a full-screen one). With
    /// `launch-reveal=settled` the photo is held back until the window is in full screen (or failed to get there), so
    /// the system's animation moves an empty window; `revealTimeout` lets it go should neither callback come. `then`
    /// runs once, at the first of these.
    func enterFullScreen(then: (() -> Void)? = nil) {
        afterFullScreenEntry = then
        let holds = Settings.shared.config.launchReveal == .settled
        if holds { viewerView.holdReveal(true) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealTimeout) { [weak self] in
            if holds { self?.viewerView.holdReveal(false) }
            self?.finishFullScreenEntry()
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window, !window.styleMask.contains(.fullScreen) else {
                self?.viewerView.holdReveal(false)
                self?.finishFullScreenEntry()
                return
            }
            window.toggleFullScreen(nil)
        }
    }

    private func finishFullScreenEntry() {
        let then = afterFullScreenEntry
        afterFullScreenEntry = nil
        then?()
    }

    /// A tab added to a full-screen window, or moved out of one, is in or out of full screen without the enter and exit
    /// notifications: its layout follows the window here.
    func syncFullScreen() {
        guard let window, !isClosed else { return }
        let on = window.styleMask.contains(.fullScreen)
        if on != isFullScreen { setFullScreen(on) }
    }

    /// The longest a launch holds the photo back for the full-screen animation (about 0.5–1 s on its own).
    private static let revealTimeout: TimeInterval = 3

    /// The system proposes full screen with the toolbar pinned under the hidden title bar; `autoHideToolbar` makes it
    /// slide in with the menu bar when the pointer reaches the top edge, as the comment on `fullScreenToolbar` says.
    /// The options are read once, as the window enters full screen.
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposed: NSApplication.PresentationOptions)
        -> NSApplication.PresentationOptions {
        proposed.union(.autoHideToolbar)
    }

    /// A failed enter reverts the layout chosen at `willEnterFullScreen`. (There is no matching failure
    /// callback for exit: the window stays in full screen then, and so does the layout.)
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        setFullScreen(false)
        viewerView.holdReveal(false)
        finishFullScreenEntry()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeFirstResponder(viewerView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// A closed tab's controller goes once the registry lets it go (the windows checklist counts these lines).
    deinit { DebugLog.log("viewer window freed") }

    /// Makes this window the one in front of the user: unhides the app, restores a miniaturized window, orders
    /// it front and activates the app. Ordering a window front while the app is active the window in its own Space, so a window in
    /// full screen is switched to.
    func bringToFront() {
        guard let window else { return }
        if NSApp.isHidden { NSApp.unhide(nil) }
        if window.isMiniaturized { window.deminiaturize(nil) }
        if let group = window.tabGroup, group.selectedWindow !== window { group.selectedWindow = window }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func forgetFolderListings() { session.forgetFolderListings() }

    // MARK: Tabs (spec §2.1)

    /// File › New Tab (⌘T) and the tab bar's +: a tab in this window.
    override func newWindowForTab(_ sender: Any?) { registry?.newTab(beside: self) }

    /// File › New Window (⌘N): a window cascaded from this one.
    @objc func newViewerWindow(_ sender: Any?) { registry?.newWindow(from: self) }

    /// File › Open in New Tab… (⌥⌘O) and Open in New Window… (⇧⌘O): the Open panel, then a tab in this window or a
    /// window of its own, whatever `open-in` says and whatever is open.
    @objc func openInNewTab(_ sender: Any?) { openPicked(force: .tab) }
    @objc func openInNewWindow(_ sender: Any?) { openPicked(force: .window) }

    private func openPicked(force: OpenForce) {
        let panel = Self.makeOpenPanel()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        registry?.open(.file(url), force: force, from: self)
    }

    /// `new-tab`, `new-window`, `close-tab`, `next-tab`, `previous-tab` (input.conf keys and buttons): what File › New
    /// Tab, New Window, Close and Window › Next / Previous Tab do; the tab steps go round the window's tabs. A held
    /// button that steps tabs stays held in the tab it lands on, so its wheel goes on stepping, unless Stash covers
    /// that tab: its page takes the release.
    func tabAction(_ action: KeyAction) {
        switch action {
        case .newTab: newWindowForTab(nil)
        case .newWindow: newViewerWindow(nil)
        case .closeTab: window?.performClose(nil)
        case .closeWindow: closeWindow(nil)
        case .back: goBack(nil)
        case .browse: browseFolder(nil)
        case .reopenTab: registry?.reopenClosedTab()
        case .openInNewTab: openInNewTab(nil)
        case .openInNewWindow: openInNewWindow(nil)
        case .home: showHome()
        case .nextTab, .previousTab:
            guard let window, let group = window.tabGroup, group.windows.count > 1 else { return }
            MouseButtons.shared.keepingPresses {
                if action == .nextTab { window.selectNextTab(nil) } else { window.selectPreviousTab(nil) }
            }
            let landed = group.selectedWindow?.windowController as? ViewerWindowController
            if landed?.isShowingHome != false { MouseButtons.shared.cancelAll() }
        default:
            assertionFailure("\(action) is no tab action")
        }
    }

    /// A new tab or window with nothing to show: Home (Home spec §2.1).
    func startEmpty() { showHome() }

    /// File › Open…'s panel: one image or zip.
    static func makeOpenPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .zip]
        return panel
    }

    /// What `OpenRouter` knows of this tab: nothing open while Stash is on screen (no file, folder or gallery). The tab
    /// is its session's id, the window its tab group as it is now.
    func tabFacts(rank: Int) -> TabFacts {
        let current = isShowingHome ? nil : session.playlist?.current.standardizedFileURL
        let folder = current.map(OpenRouter.folder(of:))
        let gallery = stashGallery.flatMap { $0.folder.path == folder?.path ? $0.id : nil }
        let group = window.map { $0.tabGroup.map(ObjectIdentifier.init) ?? ObjectIdentifier($0) }
        return TabFacts(tab: session.cacheID.raw, window: group.map { Int(bitPattern: $0) } ?? 0, current: current,
                        folder: folder, stashGallery: gallery, lastActive: rank)
    }

    /// An open routed here (`WindowRegistry.open`): a file, or a folder to enter. A Stash gallery is opened by the click:
    /// `stashPick` is the ⌘-click (or the Recent card) that asked for this tab, entered here as it would be from Stash
    /// (spec §2.3). `returnTo`: the Home tab ⌘W goes back to (a Recent card opened it here); nil: as from Stash.
    func open(_ target: OpenTarget, stashPick: StashGalleryPick? = nil, returnTo: HomeTab? = nil) {
        switch target {
        case .file(let url): open(url)
        case .folder(let url): openFolder(url)
        case .stashGallery:
            guard let stashPick else { break }
            galleryReturn = returnTo ?? .stash
            if returnTo == nil {
                showHome(tab: .stash)
            } else if attachedStash() == nil {
                return
            }
            enterFromStash(stashPick)
        }
    }

    func open(_ url: URL) {
        // A file from outside while Stash is shown: the viewer comes back, and ⌘W returns to Stash.
        if isShowingHome {
            returnsTo = shownTab
            hideHome()
        }
        stashPicks.cancel()
        restoredTab = nil
        session.entersFromOutside = true
        session.open(url)
    }

    /// A folder from outside (`open -a Loupe folder`, Open in New Tab on a folder card): entered as a zip is. One
    /// without photos of its own (only subfolders) or that cannot be listed shows in Folders instead, where its
    /// subfolders or the reason are, rather than leaving an empty viewer.
    private func openFolder(_ url: URL) {
        if isShowingHome {
            returnsTo = shownTab
            hideHome()
        }
        stashPicks.cancel()
        restoredTab = nil
        session.entersFromOutside = true
        session.openFolder(url) { [weak self] entered in
            guard !entered, let self else { return }
            self.restoreBrowserAt = (url, nil)
            self.showHome(tab: .folders)
        }
    }

    // MARK: Sessions (Home spec §2.6)

    /// A session tab not opened yet: it opens when the tab is first shown (`openPending`).
    private(set) var pending: SessionSnapshot.Tab?
    /// The session tab this tab was restored to but could not show (a file gone, a gallery Stash has not given yet):
    /// Last Session keeps it until something else is opened here.
    private var restoredTab: SessionSnapshot.Tab?

    /// This tab in a session snapshot: Home and its tab, a Stash gallery with its list and photo, a photo, or what it
    /// waits to open.
    func sessionTab() -> SessionSnapshot.Tab {
        if let pending { return pending }
        if let restoredTab { return restoredTab }
        if let homeView, isShowingHome {
            // A gallery under Home is not kept: entering it again would cover Home.
            let under = viewerTab().flatMap { tab -> SessionSnapshot.Tab? in if case .file = tab { tab } else { nil } }
            let browser = homeView.browser
            // A restored folder not shown yet (its Home tab is on Recent) is kept as it came.
            if !hasBrowsed, let restore = restoreBrowserAt {
                var kept = restore.browser ?? SessionSnapshot.Browser(selection: nil, anchor: nil, style: nil)
                kept.style = tabGridStyle.own ?? kept.style   // a toggle made on Recent meanwhile
                return .homeKeeping(shownTab, folder: restore.folder.path, under: under, browser: kept)
            }
            let folder: String? = if hasBrowsed, case .folder(let url) = browser.lastBrowsed { url.path } else { nil }
            // The selection and the scroll while the folder is on screen; the tab's own Square / Aspect always.
            let onFolder = folder != nil && browser.location == browser.lastBrowsed
            let state = SessionSnapshot.Browser(selection: onFolder ? browser.selection : nil,
                                                anchor: onFolder ? browser.anchor : nil, style: tabGridStyle.own)
            return .homeKeeping(shownTab, folder: folder, under: under, browser: state)
        }
        return viewerTab() ?? .home(.recent)
    }

    /// The photo on screen (in a Stash gallery or not), or nil. With two pages on screen, the current page: a restored
    /// tab opens the pair containing it.
    private func viewerTab() -> SessionSnapshot.Tab? {
        guard let current = session.playlist?.current else { return nil }
        let view = session.currentViewText
        if let gallery = stashGallery, gallery.folder == OpenRouter.folder(of: current) {
            return .gallery(id: gallery.id, list: stashList?.variables, index: stashList?.index, count: stashList?.count,
                            file: current.lastPathComponent, view: view)
        }
        return .file(path: current.path, view: view)
    }

    /// One tab of a restored session: opened now, kept for its first show, or Home (with a toast for a file gone).
    func restore(_ step: SessionRestorePlan.TabStep) {
        switch step {
        case .open(let tab): openSessionTab(tab)
        case .lazy(let tab):
            pending = tab
            updateTitle()
        case .home(let tab, let notAvailable, let keeps):
            showHome(tab: tab)
            restoredTab = keeps
            if let notAvailable { toast.show("\(notAvailable) is not available") }
        }
    }

    /// The pending tab opens: it was selected for the first time.
    func openPending() {
        guard let tab = pending else { return }
        pending = nil
        openSessionTab(tab)
    }

    private func openSessionTab(_ tab: SessionSnapshot.Tab) {
        // What a restore opens is not news for Recent until the first step in it.
        session.recordsRecent = false
        switch tab {
        case .file(let path, let view):
            session.open(URL(fileURLWithPath: path), view: view.flatMap(SavedView.init(text:)))
            window?.title = URL(fileURLWithPath: path).lastPathComponent
        case .gallery(let id, let list, let index, let count, _, _):
            let context = list.map { StashGalleryListContext(variables: $0, index: index ?? 0, count: count) }
            // As from a Recent card: Home stays while Stash is asked; a gallery that cannot be reached is a toast there.
            showHome(tab: .recent)
            open(.stashGallery(id: id), stashPick: StashGalleryPick(id: id, list: context), returnTo: .stash)
            restoredTab = tab   // until the gallery is entered
        case .home(let home):
            showHome(tab: home)
        case .homeOver(let home, let folder, let under, let browser):
            if let under { openSessionTab(under) }
            restoreBrowserAt = folder.map { (URL(fileURLWithPath: $0), browser) }
            tabGridStyle.restore(browser?.style, memory: Settings.shared.config.gridStyleMemory)
            showHome(tab: home)
        }
    }

    /// The tab's label (`WindowTitle.text`: Home's tab, a restored tab not shown yet, or the photo) and the window's own
    /// title, which is that too, except on Home, where the browser gives the folder's name and the line under it
    /// (`homeWindowText`). Every change of Home, the pending tab or the session ends here.
    private func updateTitle() {
        let home = isShowingHome ? shownTab : nil
        let text: String
        if home == nil, let pending {
            text = WindowTitle.text(of: pending)
        } else {
            // A pair names both pages, in reading order (spread spec, «Положение»).
            let list = session.playlist, pages = session.currentPages
            text = WindowTitle.text(home: home, file: pages.flatMap { p in list?.files[p.first] } ?? list?.current,
                                    companion: pages?.second.flatMap { k in list?.files[k] })
        }
        window?.tab.title = text
        if home != nil, let homeWindowText {
            window?.title = homeWindowText.title
            window?.subtitle = homeWindowText.subtitle
        } else {
            window?.title = text
            window?.subtitle = ""
        }
    }

    /// What the browser last said the window's title and subtitle are (`HomeBrowserView.onWindowText`).
    private var homeWindowText: (title: String, subtitle: String)?

    // MARK: Home (Home spec §2.1, Photos style spec §3)

    /// Home over the viewer: the sidebar beside the browser of folders, Recent, Sessions and Stash.
    var isShowingHome: Bool { homeView.map { !$0.isHidden } ?? false }
    /// The Home tab on screen, by the browser's location (a place or a folder is Folders).
    var shownTab: HomeTab { homeView.map { HomeCollections.tab(of: $0.browser.location) } ?? .recent }
    var isShowingRecent: Bool { isShowingHome && shownTab == .recent }
    var isShowingStash: Bool { isShowingHome && shownTab == .stash }
    var isShowingFolders: Bool { isShowingHome && shownTab == .folders }

    /// Home's browser while it is on screen and not on Stash's page: a mouse's back and forward buttons go to it.
    var browserView: HomeBrowserView? { isShowingHome && !isShowingStash ? homeView?.browser : nil }

    /// File › Stash Library (⇧⌘L): Home on Stash.
    @objc func showStashLibrary(_ sender: Any?) { showHome(tab: .stash) }

    /// File › Home (⇧⌘H), the `home` action.
    /// File › Home (⇧⌘H): Home over the viewer; on Home, its start page, as a browser's Home.
    @objc func showHomeScreen(_ sender: Any?) {
        if isShowingHome { showStartPage() } else { showHome() }
    }

    /// The toolbar's house and ⇧⌘H on Home: `home-start` (Stash only with `stash-url` set, else Recent; `folders`:
    /// Places). The browser's own move, so `home-tab` follows it as after a click in the sidebar.
    private func showStartPage() {
        guard let homeView else { return }
        let start = Settings.shared.config.homeStart
        let shown: HomeTab = start == .stash && StashLibrary.Source.current == nil ? .recent : start
        homeView.browser.show(HomeCollections.location(of: shown) ?? .places, selecting: nil)
    }

    /// File › Hide Sidebar / Show Sidebar (⌃⌘S) and the toolbar's button: kept as `home-sidebar`.
    @objc func toggleHomeSidebar(_ sender: Any?) {
        guard let homeView, isShowingHome else { return }
        homeView.isSidebarVisible.toggle()
        _ = Settings.shared.saveAsDefault(["home-sidebar": homeView.isSidebarVisible ? "yes" : "no"])
    }

    /// File › Hide Path Bar / Show Path Bar (⌥⌘P): kept as `home-path-bar`.
    @objc func toggleHomePathBar(_ sender: Any?) {
        guard let homeView, isShowingHome else { return }
        homeView.browser.showsPathBar.toggle()
        _ = Settings.shared.saveAsDefault(["home-path-bar": homeView.browser.showsPathBar ? "yes" : "no"])
    }

    @objc func toggleSidebar(_ sender: Any?) {
        toggleHomeSidebar(sender)
    }

    /// Home over the viewer on `tab` (nil: `home-tab`); Stash only with `stash-url` set, else Recent. Recent and the
    /// sessions are read afresh each time they are shown; Folders comes back where it was (`browseAt` and a restored
    /// tab's folder go first; the first time, the last folder of the last run).
    func showHome(tab: HomeTab? = nil) {
        guard let window else { return }
        let config = Settings.shared.config
        let wanted = tab ?? config.homeTab
        let shown: HomeTab = wanted == .stash && StashLibrary.Source.current == nil ? .recent : wanted
        let view = homeView ?? makeHome()
        if !isShowingHome { titleVisibilityBeforeHome = window.titleVisibility }
        attachHome(view)
        view.isHidden = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = view.browser.nsToolbar
        // The window's hidden state can follow the viewer's toolbar to the next one: Home's is always shown.
        if !view.browser.nsToolbar.isVisible { view.browser.nsToolbar.isVisible = true }
        view.sidebarWidth = CGFloat(config.homeSidebarWidth)
        view.isSidebarVisible = config.homeSidebar
        view.isParked = false
        homeSources?.folders.isPaused = false
        applyBrowserSettings()
        returnsTo = nil
        let browser = view.browser
        movingForApp = true
        if shown == .folders {
            if let start = browseAt {
                browser.show(start.location, selecting: start.select)
            } else if let restore = restoreBrowserAt {
                restoreBrowserAt = nil
                browser.show(.folder(restore.folder), selecting: restore.browser?.selection,
                             anchor: restore.browser?.anchor)
            } else if !hasBrowsed {
                startBrowser(browser, last: (registry?.browserPlaces ?? BrowserPlaces(database: nil)).lastFolder)
            } else if HomeCollections.tab(of: browser.location) != .folders {
                browser.show(browser.lastBrowsed, selecting: nil)
            }
        } else if let location = HomeCollections.location(of: shown) {
            if browser.location == location, hasShownHome { browser.reload() } else { browser.show(location, selecting: nil) }
        }
        movingForApp = false
        hasShownHome = true
        if shown != .stash { window.makeFirstResponder(browser) }
        DebugLog.log("home shown: \(shown)")
        updateTitle()
        updateBackButton()
    }

    func hideHome() {
        guard let homeView, !homeView.isHidden else { return }
        homeView.isHidden = true
        homeView.isParked = true
        window?.toolbar = viewerToolbar.nsToolbar
        // The toolbar comes back as it was left (Home's own toolbar had the window meanwhile).
        if !isFullScreen || !toolbarWanted { window?.toolbar?.isVisible = toolbarWanted }
        toolbarWasWanted = toolbarWanted
        window?.titlebarAppearsTransparent = true
        if let titleVisibilityBeforeHome {
            window?.titleVisibility = titleVisibilityBeforeHome
            self.titleVisibilityBeforeHome = nil
        }
        homeSources?.folders.isPaused = true
        updateBackButton()
        window?.makeFirstResponder(viewerView)
        updateTitle()
    }

    private func applyToastPosition() {
        // Deactivate first: the three are alternatives for one axis and must never be active together.
        keyToastLeft.isActive = false
        keyToastCenter.isActive = false
        keyToastRight.isActive = false
        let position = Settings.shared.config.toastPosition
        (position.column < 0 ? keyToastLeft : position.column > 0 ? keyToastRight : keyToastCenter).isActive = true
        applyToastRows()
    }

    /// The toast's row: a top one stands under the bar while the bar shows (it is always at the top), else at the window's
    /// edge; a bottom one stands above the strip.
    private func applyToastRows() {
        let top = Settings.shared.config.toastPosition.isTop
        for constraint in [keyToastAboveStrip, keyToastBelowBar, keyToastAtTop] { constraint.isActive = false }
        (top ? (!statsBar.isHidden ? keyToastBelowBar : keyToastAtTop) : keyToastAboveStrip).isActive = true
    }

    /// A toolbar slider of the colour values: recorded for the folder like the keys' steps.
    private func setColourValue(_ key: String, _ value: Double) {
        guard let folder else { return }
        folderSettings.set(key, FolderAdjust.text(value), for: folder)
    }

    private func performViewerAction(_ action: KeyAction) {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.representedObject = action.rawValue
        viewerView.performKeyAction(item)
    }

    /// Home goes into the window the first time it shows and stays there, hidden and parked (`HomeView.isParked`: its
    /// sidebar item collapsed, else the system keeps room for a sidebar in the viewer's toolbar, and in full screen
    /// put it a sidebar's width from the left edge) while the viewer shows. Taken out and put back on every Return it
    /// cost 25 ms of main thread each way on an M4 Max (docs/bench/2026-10-26-viewer-to-folders.md).
    private func attachHome(_ view: HomeView) {
        guard view.superview == nil, let container = window?.contentView else { return }
        container.addSubview(view, positioned: .below, relativeTo: cheatSheet)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    /// Home: the sidebar and the browser, made on first show; nil until then.
    private var homeView: HomeView?
    private var titleVisibilityBeforeHome: NSWindow.TitleVisibility?
    /// Home's sources (the view holds its source weakly: kept here).
    private var homeSources: (folders: FolderBrowserSource, collections: CollectionSource, home: LoupeHomeSource)?
    /// A place or a folder was shown: Folders goes back to it, not to the last run's folder.
    private var hasBrowsed = false
    private var hasShownHome = false
    /// Set while the window moves the browser itself (`showHome`): only the user's own moves change `home-tab`.
    private var movingForApp = false
    private var tabMemory = HomeTabMemory()
    private var homeObservers: [NSObjectProtocol] = []

    /// The browser's last folder goes to Loupe.db here (`BrowserPlaces.lastFolder`): one write after another, never on
    /// the main thread.
    private static let placesWriter = DispatchQueue(label: "local.loupe.browserPlaces", qos: .utility)

    private func makeHome() -> HomeView {
        let places = registry?.browserPlaces ?? BrowserPlaces(database: nil)
        let folders = FolderBrowserSource(thumbnails: thumbnails, places: places, settings: folderSettings,
                                          positions: registry?.positions ?? FolderPositions(database: nil),
                                          recent: session.recent, stores: registry?.pathStores ?? [])
        let collections = CollectionSource(thumbnails: thumbnails, recent: { [weak self] in
            self?.session.recent?.shown(limit: Settings.shared.config.recentCount) ?? []
        }, sessions: { [weak self] in self?.registry?.sessions?.all() ?? [] }, stashPage: { [weak self] in
            self?.attachedStash()?.container
        })
        let source = LoupeHomeSource(folders: folders, collections: collections,
                                     hasStash: { StashLibrary.Source.current != nil })
        let view = HomeView(source: source)
        source.view = view.browser
        folders.onFoldersChecked = { [weak view] entries, folder in view?.sidebarFoldersChanged(entries, in: folder) }
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        let browser = view.browser
        browser.onWindowText = { [weak self] title, subtitle in
            guard let self else { return }
            self.homeWindowText = (title, subtitle)
            if self.isShowingHome { self.updateTitle() }
        }
        browser.onLocation = { [weak self] location in
            guard let self else { return }
            // A write to Loupe.db: off the main thread, in the order of the moves.
            if case .folder(let url) = location { Self.placesWriter.async { places.lastFolder = url } }
            let tab = HomeCollections.tab(of: location)
            if tab == .folders { self.hasBrowsed = true }
            // A source chosen in the sidebar (or Back to it) is the one a new tab opens on.
            if let saved = self.tabMemory.moved(to: tab, byUser: !self.movingForApp, saved: Settings.shared.config.homeTab) {
                _ = Settings.shared.saveAsDefault(["home-tab": saved.rawValue])
            }
            if tab == .stash { self.stash?.page.focusPage() }
            // `grid-style-memory=folder`: each folder its own Square / Aspect, before its cards are laid out.
            self.applyGridStyle()
            self.updateTitle()
        }
        browser.onResize = { [weak self] in self?.resizeBrowserCards($0) }
        // ⌥T, the style button: kept for the tab, saved for the folder or as the default (`grid-style-memory`), then
        // shown. ⌥N: saved as the default, then shown.
        browser.onStyle = { [weak self, weak browser] style in
            guard let self, let browser else { return }
            let folder = Self.folder(of: browser.location)
            switch self.tabGridStyle.choose(style, memory: Settings.shared.config.gridStyleMemory, folder: folder) {
            case .none: break
            case .folder(let url, let style): self.folderSettings.set(GridStyle.settingKey, style.rawValue, for: url)
            case .global(let style): _ = Settings.shared.saveAsDefault(["grid-style": style.rawValue])
            }
            self.applyBrowserSettings()
        }
        browser.onNames = { [weak self] names in
            _ = Settings.shared.saveAsDefault(["grid-names": names.rawValue])
            self?.applyBrowserSettings()
        }
        browser.onOtherMouse = { event, down in
            down ? MouseButtons.shared.otherMouseDown(event) : MouseButtons.shared.otherMouseUp(event)
        }
        view.onSidebarToggle = { [weak self] in self?.toggleHomeSidebar(nil) }
        view.onHome = { [weak self] in self?.showStartPage() }
        view.onSidebarWidthChange = { width in
            _ = Settings.shared.saveAsDefault(["home-sidebar-width": String(Int(width.rounded()))])
        }
        view.onDrop = { [weak self] url in
            guard let self else { return }
            var isDirectory: ObjCBool = false
            let folder = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            self.registry?.open(folder ? .folder(url) : .file(url), openIn: .replace, from: self)
        }
        folders.onOpen = { [weak self] target, how in self?.openFromBrowser(target, how) }
        folders.onPlacesChanged = { [weak view] in view?.reloadSidebar() }
        // The toolbar's pill: after `thumbs-pill-delay` of work, out a second after it is done. The popover (View ›
        // Thumbnails…) has the counts whether or not anything is being prepared (`ThumbsProgress.display`).
        folders.onProgress = { [weak browser] progress in
            browser?.setProgress(progress.display, delay: Config.pillDelay(seconds: Settings.shared.config.thumbsPillDelay))
        }
        folders.confirmDelete = { [weak self] name, answer in
            guard let window = self?.window else { answer(false); return }
            let alert = NSAlert()
            alert.messageText = "Delete permanently?"
            alert.informativeText = "“\(name)” is on a volume without a Trash. It will be deleted right away."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true
            alert.beginSheetModal(for: window) { answer($0 == .alertFirstButtonReturn) }
        }
        collections.onRecent = { [weak self] entry, action in self?.recentChosen(entry, action) }
        collections.onSession = { [weak self] saved, action in self?.sessionChosen(saved, action) }
        collections.onStashFilter = { [weak self] i in
            let paths = ["/scenes", "/images", "/galleries"]
            guard let library = self?.attachedStash(), paths.indices.contains(i) else { return }
            library.page.navigate(to: paths[i])
        }
        // A volume mounted or unmounted: the sidebar's places and the Places page again.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            homeObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak view] _ in
                MainActor.assumeIsolated {
                    view?.reloadSidebar()
                    view?.browser.reloadPlaces()
                }
            })
        }
        homeView = view
        homeSources = (folders, collections, source)
        return view
    }

    /// View › as Posters / as Cards / as List (⌥⌘1–⌥⌘3, the item's tag the style's index): how Home draws this folder's
    /// folders and archives, saved for the folder (`folder-cards`).
    @objc func chooseCardStyle(_ sender: Any?) {
        guard canChooseCardStyle, let tag = (sender as? NSMenuItem)?.tag, CardStyle.allCases.indices.contains(tag) else {
            return
        }
        homeView?.browser.chooseCardStyle(CardStyle.allCases[tag])
    }

    /// View › Thumbnails…: the progress popover with the folder's counts (from the pill when it shows, else the sort).
    @objc func showThumbsProgress(_ sender: Any?) {
        guard canShowThumbsProgress else { return }
        homeView?.browser.showProgressPopover()
    }

    /// Home's browser is on screen with a folder (whether or not anything is being prepared), or its pill is lit.
    var canShowThumbsProgress: Bool { isShowingHome && homeView?.browser.canShowProgressPopover == true }

    /// Home is on screen on a folder: its folder cards' style can be chosen (the View items and ⌥⌘1–⌥⌘3 are theirs).
    var canChooseCardStyle: Bool { isShowingHome && homeView?.browser.canChooseCardStyle == true }

    /// File › Larger Cards / Smaller Cards / Default Card Size: Home's ⌘= / ⌘− / ⌘0 (the keys are Home's own, not the
    /// menu's: a menu key is taken even while its item is off).
    @objc func largerCards(_ sender: Any?) { resizeBrowserCards(.larger) }
    @objc func smallerCards(_ sender: Any?) { resizeBrowserCards(.smaller) }
    @objc func defaultCardSize(_ sender: Any?) { resizeBrowserCards(.reset) }

    /// A column step on Home (⌘= one fewer, ⌘− one more), saved as `browser-card-size` (⌘0: the default).
    private func resizeBrowserCards(_ resize: HomeResize) {
        guard let view = homeView?.browser else { return }
        let size = view.cardSize(after: resize, range: 60...480).map { Int($0.rounded()) } ?? Config().browserCardSize
        _ = Settings.shared.saveAsDefault(["browser-card-size": String(size)])
        view.cardSize = CGFloat(size)
        toast.show("Cards: \(size) pt")
    }

    // MARK: Folders (file browser spec §4)

    /// Return or a double click on a photo (`browse`): Home on its folder with it selected; with no photo, Folders
    /// where it was.
    @objc func browseFolder(_ sender: Any?) {
        DebugLog.measureTurn("browse")
        let target = session.playlist.map { BrowseTarget.location(for: $0.current) }
        browseAt = target
        showHome(tab: .folders)
        browseAt = nil
    }

    /// Where the next Folders show opens the browser (Return on a photo); nil: where it was.
    private var browseAt: (location: BrowserLocation, select: String)?

    /// The folder a restored session tab had in the browser, with its selection and scroll, opened on Folders' next
    /// show.
    private var restoreBrowserAt: (folder: URL, browser: SessionSnapshot.Browser?)?

    /// loupe.conf's `folder-cards` as `applyBrowserSettings` last applied it.
    private var shownFolderCards: CardStyle?

    /// This tab's Square / Aspect under `grid-style-memory` (its own choice, for the session).
    private var tabGridStyle = TabGridStyle()

    private static func folder(of location: BrowserLocation) -> URL? {
        if case .folder(let url) = location { return url }
        return nil
    }

    /// Square / Aspect for where Home's browser is: the tab's, the folder's or loupe.conf's (`grid-style-memory`).
    private func applyGridStyle() {
        guard let view = homeView?.browser else { return }
        let config = Settings.shared.config
        view.style = tabGridStyle.style(memory: config.gridStyleMemory, global: config.gridStyle,
                                        folder: Self.folder(of: view.location), settings: folderSettings)
    }

    /// `browser-card-size`, `grid-style` (with `grid-style-memory`), `grid-names`, `folder-cover`, `folder-cards`: on
    /// every show and every settings change.
    private func applyBrowserSettings() {
        guard let homeView else { return }
        let config = Settings.shared.config
        let view = homeView.browser
        view.cardSize = CGFloat(config.browserCardSize)
        applyGridStyle()
        view.names = config.gridNames
        let coverLayout = HomeMosaic.Layout(rawValue: config.folderCover.rawValue) ?? .hero
        homeSources?.folders.coverLayout = coverLayout
        homeSources?.collections.coverLayout = coverLayout
        // `folder-cards` is the browser's style where a folder has none of its own: another default shows at once.
        if let shown = shownFolderCards, shown != config.folderCards, view.canChooseCardStyle,
           homeSources?.folders.cardStyle(for: view.location) != view.cardStyle {
            view.reload()
        }
        shownFolderCards = config.folderCards
        homeView.sidebarWidth = CGFloat(config.homeSidebarWidth)
        homeView.sidebarCompactChains = config.homeSidebarCompact
        homeView.sidebarCompactIndent = config.homeSidebarIndent == .compact
        homeView.sidebarFoldersFirst = config.homeSidebarFoldersFirst
        homeView.sidebarRerootDepth = config.homeSidebarReroot
        if isShowingHome { homeView.isSidebarVisible = config.homeSidebar }
        homeView.browser.showsPathBar = config.homePathBar
    }

    /// The last folder when it answers within a second, else Places with the reason; nothing if the user went
    /// somewhere meanwhile (the sidebar is there at once).
    private func startBrowser(_ view: HomeBrowserView, last: URL?) {
        let before = view.location
        let show = { [weak self] (location: BrowserLocation) in
            self?.movingForApp = true
            view.show(location, selecting: nil)
            self?.movingForApp = false
        }
        guard let last else { show(.places); return }
        Task { [weak view] in
            let found = await HomeGrid.availability(of: [last.path], timeout: .seconds(1))
            guard let view, view.location == before else { return }
            if found[last.path] == .some(true) {
                show(.folder(last))
            } else {
                show(.places)
                view.showToast("Folder unavailable: \(last.path)")
            }
        }
    }

    /// A photo, folder or zip opened from the browser: here (unless another tab shows it), or in a new tab or window.
    private func openFromBrowser(_ target: OpenTarget, _ how: HomeClick) {
        DebugLog.measureTurn("open from browser")
        let force: OpenForce? = how == .openNewTab ? .tab : how == .openNewWindow ? .window : nil
        registry?.open(target, force: force, openIn: force == nil ? .replace : nil, from: self, returnTo: .folders)
    }

    /// The MX side wheel on Home: twelve size steps a turn, right larger (as it zooms a photo in).
    func homeThumbWheel(delta: Int, stepsPerRevolution: Int) {
        guard let browser = homeView?.browser, stepsPerRevolution > 0 else { return }
        let inward = Settings.shared.config.thumbZoomInvert ? delta : -delta
        browser.resize(notches: Double(inward) * 12 / Double(stepsPerRevolution))
    }

    /// The Stash library, made if needed with its page in (Home shows its container on Stash); nil without `stash-url`.
    private func attachedStash() -> StashLibrary? {
        guard let source = StashLibrary.Source.current else { return nil }
        if stash?.source != source { dropStash() }
        let library = stash ?? StashLibrary(source: source) { [weak self] pick in self?.openFromStash(pick) }
        if stash == nil {
            stash = library
            library.attachPage()
            DebugLog.log("stash made")
        }
        return library
    }

    /// A session card's action (Home spec §2.3): its windows open next to these, and this Home tab then closes.
    private func sessionChosen(_ saved: SavedSession, _ action: SessionCardAction) {
        guard let registry, let sessions = registry.sessions, let window else { return }
        switch action {
        case .open:
            registry.open(session: saved.snapshot) { [weak self] in
                guard let self, self.isShowingHome else { return }
                self.window?.performClose(nil)
            }
        case .rename:
            Self.askName(on: window, title: "Rename “\(saved.name)”", initial: saved.name) { [weak self] name in
                guard let self else { return }
                if !sessions.rename(saved.id, to: name) {
                    let alert = NSAlert()
                    alert.messageText = "A session named “\(name)” already exists."
                    alert.beginSheetModal(for: window)
                }
                self.sessionsChanged()
            }
        case .replaceWithCurrent:
            sessions.replace(saved.id, with: registry.snapshot())
            sessionsChanged()
        case .delete:
            let alert = NSAlert()
            alert.messageText = "Delete “\(saved.name)”?"
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                sessions.delete(saved.id)
                self?.sessionsChanged()
            }
        }
    }

    /// A sheet asking for a session name; `done` gets a non-empty one.
    static func askName(on window: NSWindow, title: String, initial: String, done: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard response == .alertFirstButtonReturn, !name.isEmpty else { return }
            done(name)
        }
    }

    /// File › Save Session As…: every viewer window under a name; a name taken asks first.
    @objc func saveSessionAs(_ sender: Any?) {
        guard let registry, let sessions = registry.sessions, let window else { return }
        Self.askName(on: window, title: "Save Session As", initial: "") { [weak self] name in
            let snapshot = registry.snapshot()
            guard sessions.all().contains(where: { !$0.isLast && $0.name == name }) else {
                sessions.save(snapshot, name: name)
                self?.sessionsChanged()
                return
            }
            let alert = NSAlert()
            alert.messageText = "Replace “\(name)”?"
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn else { return }
                sessions.save(snapshot, name: name)
                self?.sessionsChanged()
            }
        }
    }

    /// The saved sessions changed: every window showing them lists them again.
    private func sessionsChanged() {
        for controller in registry?.controllers ?? [] where controller.isShowingHome && controller.shownTab == .sessions {
            controller.homeView?.browser.reload()
        }
    }

    /// A Recent card's action (Home spec §2.3): this tab, a new tab or a new window; a gallery goes through Stash.
    private func recentChosen(_ entry: RecentEntry, _ action: HomeCardAction) {
        let force: OpenForce?
        switch action {
        case .open: force = nil
        case .openNewTab: force = .tab
        case .openNewWindow: force = .window
        case .remove:
            session.recent?.hide(entry.path)
            showHome(tab: .recent)
            return
        case .copyPath:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.path, forType: .string)
            toast.show("Path copied")
            return
        case .showInFinder:
            let file = entry.file.map { entry.url.appendingPathComponent($0) }
            NSWorkspace.shared.activateFileViewerSelecting([file.flatMap { ArchivePath.split($0)?.archive } ?? file ?? entry.url])
            return
        }
        // A share that does not answer within a second is tried as if it were there.
        Task { [weak self] in
            let file = entry.file.map { entry.url.appendingPathComponent($0) }
            let inArchive = entry.kind == .archive
            let paths = [entry.path] + (file.map { inArchive ? [] : [$0.path] } ?? [])
            let found = await HomeGrid.availability(of: paths, timeout: .seconds(1))
            guard let self else { return }
            let folderExists = found[entry.path].flatMap { $0 } ?? true
            let fileExists = inArchive ? folderExists : (file.flatMap { found[$0.path].flatMap { $0 } } ?? true)
            self.openRecent(RecentOpen.plan(entry, folderExists: folderExists, fileExists: fileExists && file != nil),
                            force: force)
        }
    }

    private func openRecent(_ plan: RecentOpen.Plan, force: OpenForce?) {
        // A plain click: this tab, unless another tab shows it already.
        let openIn: OpenIn? = force == nil ? .replace : nil
        switch plan {
        case .file(let url): registry?.open(.file(url), force: force, openIn: openIn, from: self, returnTo: .recent)
        case .folder(let url): registry?.open(.folder(url), force: force, openIn: openIn, from: self, returnTo: .recent)
        case .gallery(let id, let list):
            let context = list.map { StashGalleryListContext(variables: $0.variables, index: $0.index, count: $0.count) }
            let pick = StashGalleryPick(id: id, list: context, newTab: force == .tab, newWindow: force == .window)
            registry?.open(.stashGallery(id: id), force: force, openIn: openIn, from: self, stashPick: pick,
                           returnTo: .recent)
        case .notAvailable(let name):
            toast.show("\(name) is not available")
        }
    }

    /// `stash-url`, its key or the path rules changed: a new library next time; one on screen is made again now.
    func stashSettingsChanged() {
        guard let stash, stash.source != StashLibrary.Source.current else { return }
        let shown = isShowingStash
        dropStash()
        if shown { showHome(tab: .stash) }
    }

    private func dropStash() {
        stashPicks.cancel()
        stash?.container.removeFromSuperview()
        stash = nil
    }

    /// File › Back (⌘[), "‹ Recent" / "‹ Stash", the `back` action: back to the Home tab what is shown was opened
    /// from, as a browser's Back.
    @objc func goBack(_ sender: Any?) {
        guard let backTarget else { return }
        if HomeBack.showsCurrentPhoto(backTarget) { browseFolder(nil) } else { showHome(tab: backTarget) }
    }

    /// Where Back goes (`HomeBack`): the Home tab the photo was opened from, else Recent.
    private var backTarget: HomeTab? {
        HomeBack.target(returnsTo: returnsTo, showingHome: isShowingHome, hasPhoto: session.playlist?.current != nil,
                        stashAvailable: StashLibrary.Source.current != nil)
    }

    private var canGoBack: Bool { backTarget != nil }

    /// File › Close Window (⇧⌘W), the `close-window` action: every tab of this window.
    @objc func closeWindow(_ sender: Any?) {
        guard let window else { return }
        for tab in window.tabGroup?.windows ?? [window] { tab.performClose(sender) }
    }

    // MARK: Stash

    /// A gallery clicked in Stash (Stash spec §2.2): entered here, unless another tab takes it.
    private func openFromStash(_ pick: StashGalleryPick) {
        guard stash != nil else { return }
        DebugLog.log("stash pick gallery \(pick.id) list \(pick.list.map { "#\($0.index)" } ?? "none")")
        // Open in another tab (the one showing it, or a new one for a ⌘-click): this one stays on Stash (spec §2.3).
        if onStashPick?(pick) == true {
            stashPicks.cancel()
            return
        }
        enterFromStash(pick)
    }

    /// The gallery of `pick`, whichever tab it was clicked in: asked of Stash, mapped to this Mac (mounting its share),
    /// opened like a folder; Stash goes away only once the gallery is entered, and only for the latest click.
    private func enterFromStash(_ pick: StashGalleryPick) {
        guard let library = stash else { return }
        let token = stashPicks.begin()
        Task { [weak self] in
            let gallery: StashGallery?
            do {
                gallery = try await library.client.gallery(id: pick.id)
            } catch {
                self?.stashFailed(library, StashOpenError.noAnswer(error.localizedDescription).localizedDescription)
                return
            }
            guard let self, self.stashPicks.isCurrent(token) else { return }
            guard let gallery, let path = gallery.path else {
                if self.galleryReturn == .recent { self.showHome(tab: .stash) }
                library.page.navigate(to: "/galleries/\(pick.id)")   // a virtual gallery: Stash's own page
                return
            }
            switch await library.resolve(path) {
            case .failure(let error):
                guard self.stashPicks.isCurrent(token) else { return }
                self.stashFailed(library, error.localizedDescription)
            case .success(let url):
                guard self.stashPicks.isCurrent(token) else { return }
                self.session.openFolder(url, isWanted: { [weak self] in self?.stashPicks.isCurrent(token) ?? false }) {
                    [weak self] entered in
                    guard let self, self.stashPicks.isCurrent(token) else { return }
                    guard entered else {
                        // Why, as the stats line says it: no photos, a damaged archive, a share not answering.
                        self.stashFailed(library, self.session.folderMessage ?? "No photos in \(path)")
                        return
                    }
                    self.galleryEntered(gallery, id: pick.id, at: url, list: pick.list)
                }
            }
        }
    }

    /// A gallery could not be entered: Stash says why on its page; from a Recent card, the toast does (Home stays).
    private func stashFailed(_ library: StashLibrary, _ text: String) {
        if galleryReturn == .recent || !isShowingStash {
            galleryReturn = .stash
            toast.show(text)
        } else {
            library.showMessage(text)
        }
    }

    /// The gallery is on screen: Home steps aside, ⌘W brings it back.
    private func galleryEntered(_ gallery: StashGallery, id: String, at url: URL, list: StashGalleryListContext?) {
        hideHome()
        returnsTo = galleryReturn
        galleryReturn = .stash
        restoredTab = nil
        stashGallery = (id, url.standardizedFileURL)
        stashList = list
        let tidy = Settings.shared.config.stashTitleTidy
        session.recent?.entered(url, kind: ArchivePath.isArchive(url) ? .archive : .folder,
                                gallery: RecentGallery(id: id, list: list.map(Self.recentList)),
                                title: StashGalleryTitle.display(title: gallery.title, path: gallery.path, tidy: tidy),
                                clearsGallery: false)
        guard let library = stash else { return }
        session.stashNavigator = list.map { StashGalleryNavigator.make(list: $0, library: library, toast: toast) }
        let config = Settings.shared.config
        guard config.folderToast else { return }
        let title = StashGalleryTitle.display(title: gallery.title, path: gallery.path, tidy: config.stashTitleTidy)
        toast.show(list.map { ListFolderNavigator.label(title: title, index: $0.index, count: $0.count) } ?? title)
    }

    /// A Stash list step entered gallery `id`: Recent keeps it with the list at the gallery's place in it.
    private func recordRecentGallery(id: String, at folder: URL) {
        guard let navigator = session.stashNavigator else { return }
        Task { [weak self] in
            let index = await navigator.position
            guard let self else { return }
            let list = self.stashList.map { StashGalleryListContext(variables: $0.variables, index: index, count: $0.count) }
            self.stashList = list
            let title = StashGalleryTitle.display(title: folder.lastPathComponent, path: folder.path,
                                                  tidy: Settings.shared.config.stashTitleTidy)
            self.session.recent?.entered(folder, kind: ArchivePath.isArchive(folder) ? .archive : .folder,
                                         gallery: RecentGallery(id: id, list: list.map(Self.recentList)), title: title,
                                         clearsGallery: false)
        }
    }

    static func recentList(_ list: StashGalleryListContext) -> RecentGalleryList {
        RecentGalleryList(variables: list.variables, index: list.index, count: list.count)
    }

    /// "‹ Recent" / "‹ Stash" shows with the strip while Back can go there; it fades as the strip does.
    private static func tabTitle(_ tab: HomeTab) -> String { WindowTitle.title(of: tab) }

    /// The pointer moved: the ‹ button shows within its reveal zone (`BackButtonPolicy`).
    private func pointerMoved() { updateBackButton() }

    /// The pointer in the button's superview's coordinates; nil outside the window's content.
    private var pointerInButtonSpace: CGPoint? {
        guard let window, let container = backButton.superview else { return nil }
        let p = container.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return container.bounds.contains(p) ? p : nil
    }

    private func updateBackButton() {
        viewerToolbar.setBackEnabled(canGoBack)
        let shown = BackButtonPolicy.isShown(wasShown: backButtonShown, pointer: pointerInButtonSpace,
                                             button: backButton.frame, canGoBack: canGoBack)
        if let backTarget { backButton.title = Self.tabTitle(backTarget) }
        guard shown != backButtonShown else { return }
        backButtonShown = shown
        if shown { backButton.isHidden = false }
        infoPanel.place()   // a panel in the top left corner steps below the button, or back up
        // A soft fade both ways (ease-out in, ease-in out): it comes up as the pointer nears, without a pop.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Chrome.Motion.duration(shown ? Chrome.Motion.show : Chrome.Motion.hide)
            context.timingFunction = CAMediaTimingFunction(name: shown ? .easeOut : .easeIn)
            backButton.animator().alphaValue = shown ? 1 : 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.backButtonShown else { return }
                self.backButton.isHidden = true
            }
        })
    }

    /// The one status of the photo on screen, to the stats bar and the toolbar's chip. A move to another photo brings back a
    /// stats bar that hides by itself.
    private func updateStatus() {
        let status = session.imageStatus
        statsBar.update(status)
        viewerToolbar.updateStatus(status, zoomMode: (session.zoomTarget ?? session.transform).mode)
        if !status.navigationKey.isEmpty, status.navigationKey != lastNavigationKey {
            lastNavigationKey = status.navigationKey
            statsBar.reveal()
        }
    }

    private func sessionDidChange() {
        updateFolder()
        viewerView.sessionDidChange()
        updateStatus()
        strip.sessionDidChange()
        updateInfoPanel()
        updateLoadingIndicator()
        updateTitle()
        registry?.contentChanged()
    }

    /// `strip-loading-indicator`: the spinner turns while only the stretched thumbnail is on screen.
    private func applyBackground() {
        let color = Settings.shared.config.background
        guard color != appliedBackground else { return }
        appliedBackground = color
        window?.backgroundColor = NSColor(cgColor: color.cgColor)
        viewerView.setBackground(color)
        updateLoadingIndicator()   // the stand-in's background
    }

    /// `transparency`, `checker-size`, `checker-colors` (and `background`, which `transparency=background` shows): live,
    /// the next frame of a photo with alpha draws over the new backdrop.
    private func applyTransparency() {
        let settings = TransparencySettings(config: Settings.shared.config)
        guard settings != appliedTransparency else { return }
        appliedTransparency = settings
        viewerView.setTransparency(settings)
    }

    /// The folder of the photo on screen, nil before the first photo: the settings window's folder notes.
    var currentFolder: URL? { folder }

    /// The folder of the photo on screen; a step into another folder recomputes the effective config.
    private func updateFolder() {
        let current = session.playlist?.current.deletingLastPathComponent().standardizedFileURL
        guard current != folder else { return }
        let previous = folder
        folder = current
        announceFolder(current, after: previous)
        updateEffectiveConfig()
        NotificationCenter.default.post(name: .viewerFolderChanged, object: self)
    }

    /// `folder-toast`: another folder's name as the window enters it (not at the first photo). A Stash list step says
    /// the gallery's own label (`onFolderLabel`); an open from Stash says it in `galleryEntered`, right after this.
    private func announceFolder(_ folder: URL?, after previous: URL?) {
        guard previous != nil, let folder, session.stashNavigator == nil, Settings.shared.config.folderToast else { return }
        toast.show(FolderLabel.name(of: folder))
    }

    /// loupe.conf with the folder's values on top, then the filters from it. A folder entry `Config.applying` refuses
    /// (a hand-edited file) is skipped, reported once, and does not count as the folder's.
    private func updateEffectiveConfig() {
        let (config, values, rejected) = folderConfig(folder)
        let accepted = values.filter { key, value in !rejected.contains("\(key)=\(value)") }
        let changed = config != effectiveConfig || accepted != folderValues
        folderValues = accepted
        if let folder {
            for entry in rejected where Self.reportedRejections.insert("\(folder.path): \(entry)").inserted {
                let line = "folder settings for \(folder.path): ignored \(entry)"
                if DebugLog.isEnabled { DebugLog.log(line) } else { FileHandle.standardError.write(Data("loupe: \(line)\n".utf8)) }
            }
        }
        effectiveConfig = config
        viewerToolbar.updateColour(config)
        applyResampling()
        session.setColor(ColorSettings(config: config), reach: config.cachePreviews)
        session.updateSpreadRules()   // `D`, `⌥D` here or in another window, a reload: the pair follows at once
        // The panel names the filter and the colour (and ` · folder`): at once, not on the next tick.
        if changed { updateInfoPanel() }
    }

    /// loupe.conf with `folder`'s values on top (folder settings spec §7), the values and the entries `Config.applying`
    /// refused: this window's `effectiveConfig`, and for any other folder the session's zoom rules.
    private func folderConfig(_ folder: URL?) -> (config: Config, values: [String: String], rejected: [String]) {
        let values = folder.map { folderSettings.values(for: $0) } ?? [:]
        let (config, rejected) = Settings.shared.config.applying(values)
        return (config, values, rejected)
    }

    /// `upscale`, `downscale`, `lanczos-antiring`, `pixel-art`: live, the next frame draws with the new filter.
    private func applyResampling() {
        let settings = ResampleSettings(config: effectiveConfig)
        guard settings != appliedResampling else { return }
        appliedResampling = settings
        viewerView.setResampling(settings)
    }

    /// The stand-in over the viewer (`switch-preview`), and the spinner: always over the blank placeholder (nothing
    /// else says a photo is coming), and as `strip-loading-indicator` says while only a thumbnail stands for it.
    private func updateLoadingIndicator() {
        let standIn = session.standIn
        standInView.show(standIn, background: appliedBackground.cgColor)
        let thumbnailOnly = session.showsThumbnailOnly || standIn?.picture != nil
        loadingIndicator.isSpinning = (standIn != nil && standIn?.picture == nil)
            || (thumbnailOnly && Settings.shared.config.stripLoadingIndicator)
    }

    /// The pixel size of the screen the window is on (the main screen before it is placed): previews are sized
    /// for the screen, not the window, so a resize or full screen keeps them valid.
    private func updateScreenSize() {
        guard let screen = window?.screen ?? NSScreen.main else { return }
        let k = screen.backingScaleFactor
        session.screenSize = PixelSize(width: Int((screen.frame.width * k).rounded()),
                                       height: Int((screen.frame.height * k).rounded()))
    }

    /// `I` and View › Image Status: windowed hidden ↔ compact, fullscreen hidden ↔ shown.
    private func toggleStats() {
        if isFullScreen {
            fullScreenStatus.toggle()
        } else {
            statsMode = statsMode.next
        }
        statsBar.reveal()
        applyStatsLayout()
    }

    @objc func toggleViewerToolbar(_ sender: Any?) {
        if isFullScreen { fullScreenToolbar.toggle() } else { windowToolbar.toggle() }
        applyStatsLayout()
    }

    private func setFullScreen(_ on: Bool) {
        isFullScreen = on
        if on { fullScreenToolbarOverride = nil }   // `fullscreen-toolbar` decides at each entry
        applyStatsLayout()
        strip.setFullScreen(on)
    }

    /// F (or the key input.conf gives full screen) while the viewer does not have the keys: on Home's grid and sidebar,
    /// or with nothing focused (`KeyMap.windowLookup`). A text field (Home's filter, a rename, a selected info panel
    /// value) and Stash's page keep every key, so F types there; the viewer takes its own keys (`ViewerView`).
    private func windowKey(_ event: NSEvent) -> Bool {
        guard let window, window.isKeyWindow, !cheatSheet.isOpen else { return false }
        let responder = window.firstResponder
        guard responder !== viewerView, !(responder is NSTextInputClient) else { return false }
        // A name being typed in the grid ("Sofa") takes its F: full screen only as a first letter.
        if let browser = homeView?.browser, responder === browser, browser.isTypingName(at: event.timestamp) { return false }
        let flags = event.modifierFlags
        guard flags.isDisjoint(with: [.command, .control]) else { return false }
        var modifiers: KeyModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        let key = KeyboardLayout.characters(for: event)?.lowercased()
        switch Settings.shared.inputMap.keys.windowLookup(keyCode: event.keyCode, character: key, modifiers: modifiers,
                                                          isRepeat: event.isARepeat) {
        case .action: window.toggleFullScreen(nil)                      // full screen is the only window action
        case .ignoredRepeat: break                                      // a held F: not typed into Home's names
        case .unbound: return false
        }
        return true
    }

    /// `?`: opens or closes the cheat sheet.
    func toggleCheatSheet() { setCheatSheet(open: !cheatSheet.isOpen) }

    /// While the sheet is open a strip on screen stays, and the viewer's cursor is re-chosen on both edges (the sheet
    /// shows the arrow; the viewer's remembered hand would otherwise not be set again).
    private func setCheatSheet(open: Bool) {
        guard open != cheatSheet.isOpen else { return }
        if open { cheatSheet.show() } else { cheatSheet.hide() }
        strip.staysShown = open
        viewerView.overlayDidChange()
    }

    /// View › Thumbnail Strip: the same pin as `T`.
    @objc func toggleThumbnailStrip(_ sender: Any?) { strip.togglePin() }

    /// View › Strip Beside the Photo: the same as `⇧T`.
    @objc func toggleStripPlacement(_ sender: Any?) { strip.togglePlacement() }

    /// View › Image Status: the same as `I`.
    @objc func toggleStatsBar(_ sender: Any?) { toggleStats() }

    /// View › Two Pages: the same as `D`.
    @objc func toggleTwoPages(_ sender: Any?) { spreadKey(.toggleSpread) }

    /// View › Shift Pages: the same as `⌥D`.
    @objc func toggleShiftPages(_ sender: Any?) { spreadKey(.shiftSpread) }

    /// View › Right to Left: the folder's `spread-direction` the other way round (the folder's own value, as `D` writes
    /// `spread`). The session follows through `.folderSettingsChanged`, as for `D`.
    @objc func toggleRightToLeft(_ sender: Any?) {
        guard let folder else { return }
        let value = SpreadKeys.toggledDirection(effectiveConfig)
        folderSettings.set(SpreadKeys.directionKey, value, for: folder)
        toast.show(SpreadKeys.toast(rightToLeft: value == "rtl"))
    }

    /// View › Landscape Pages Alone: the folder's `spread-landscape` the other way round, as Right to Left.
    @objc func toggleLandscapeAlone(_ sender: Any?) {
        guard let folder else { return }
        let value = SpreadKeys.toggledLandscape(effectiveConfig)
        folderSettings.set(SpreadKeys.landscapeKey, value, for: folder)
        toast.show(SpreadKeys.toast(landscapeAlone: value == "alone"))
    }

    /// A viewer-key menu item (`NSMenuItem.viewerKey`) while the viewer is not the first responder (a value selected in
    /// the info panel): the viewer does it all the same.
    @objc func performKeyAction(_ sender: NSMenuItem) { viewerView.performKeyAction(sender) }

    /// Scaling › Reset Folder Scaling: drops this folder's own filter entries (the ancestors' stay, and the
    /// folder inherits them again). The toast is for `S` / `A`; a menu action needs none.
    @objc func resetFolderScaling(_ sender: Any?) {
        guard let folder else { return }
        folderSettings.clear(Config.scalingFolderKeys, for: folder)
    }

    /// The Scaling menu's `this folder: <value>`: `key`'s value in loupe.conf's spelling when this window gets it from a
    /// folder's record (its own or an ancestor's), nil when it comes from loupe.conf.
    func folderValueText(forKey key: String) -> String? {
        folderValues[key] != nil ? effectiveConfig.text(forKey: key) : nil
    }

    /// Colour › Reset Folder Colour: drops this folder's own colour entries (the ancestors' stay), like Reset Folder
    /// Scaling.
    @objc func resetFolderColour(_ sender: Any?) {
        guard let folder else { return }
        folderSettings.clear(Config.colorFolderKeys, for: folder)
        toast.show(ColourKeys.folderReset)
        refreshColourLine()
    }

    /// Colour › Method: the folder's `auto-color-method` (a radio on `AutoColorMethod.rawValue`).
    @objc func pickColourMethod(_ sender: NSMenuItem) {
        guard let folder, let name = sender.representedObject as? String, let method = AutoColorMethod(rawValue: name) else { return }
        folderSettings.set("auto-color-method", method.rawValue, for: folder)
        toast.show(ColourKeys.toast(method: method))
        refreshColourLine()
    }

    /// What the window draws with, for the Colour menu's checkmarks (the main window's, as `folderValueText`); the Zoom
    /// menu's Keep Zoom and Position reads `effectiveConfig` the same way.
    var colourConfig: Config { effectiveConfig }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(chooseCardStyle(_:)):
            let browser = isShowingHome ? homeView?.browser : nil
            item.state = browser?.canChooseCardStyle == true && CardStyle.allCases.indices.contains(item.tag)
                && browser?.cardStyle == CardStyle.allCases[item.tag] ? .on : .off
            return canChooseCardStyle
        case #selector(showThumbsProgress(_:)):
            return canShowThumbsProgress
        case #selector(largerCards(_:)), #selector(smallerCards(_:)), #selector(defaultCardSize(_:)):
            return isShowingHome && !isShowingStash
        case #selector(toggleHomeSidebar(_:)):
            item.title = homeView?.isSidebarVisible == false ? "Show Sidebar" : "Hide Sidebar"
            return isShowingHome
        case #selector(toggleHomePathBar(_:)):
            item.title = homeView?.browser.showsPathBar == false ? "Show Path Bar" : "Hide Path Bar"
            return isShowingHome
        case #selector(goBack(_:)):
            item.title = backTarget.map { "Back to \(Self.tabTitle($0))" } ?? "Back"
            return canGoBack
        case #selector(toggleThumbnailStrip(_:)):
            item.state = strip.isPinned ? .on : .off
            return strip.canTogglePin
        case #selector(toggleStripPlacement(_:)):
            item.state = Settings.shared.config.stripWindow == .beside && !isFullScreen ? .on : .off
        case #selector(toggleStatsBar(_:)):
            item.state = (isFullScreen ? fullScreenStatus : statsMode != .hidden) ? .on : .off
        case #selector(toggleViewerToolbar(_:)):
            item.state = toolbarWanted ? .on : .off
            return !isShowingHome
        case #selector(toggleTwoPages(_:)):
            item.state = effectiveConfig.spread ? .on : .off
            return folder != nil
        case #selector(toggleShiftPages(_:)):
            item.state = effectiveConfig.spreadShift ? .on : .off
            return folder != nil
        case #selector(toggleRightToLeft(_:)):
            item.state = effectiveConfig.spreadRightToLeft ? .on : .off
            return folder != nil
        case #selector(toggleLandscapeAlone(_:)):
            item.state = effectiveConfig.spreadLandscapeAlone ? .on : .off
            return folder != nil
        case #selector(toggleInfoPanel(_:)):
            item.title = infoPanel.isVisible ? "Hide Info" : "Show Info"
        case #selector(pickColourMethod(_:)):
            item.state = (item.representedObject as? String) == effectiveConfig.autoColorMethod.rawValue ? .on : .off
            return folder != nil
        case #selector(resetFolderColour(_:)):
            guard let folder else { return false }
            return ScalingKeys.canReset(own: folderSettings.ownValues(for: folder), keys: Config.colorFolderKeys)
        case #selector(resetFolderScaling(_:)):
            guard let folder else { return false }
            return ScalingKeys.canReset(own: folderSettings.ownValues(for: folder), keys: Config.scalingFolderKeys)
        default: break
        }
        return true
    }

    /// The viewer ends at the strip's top while the strip is a bar of its own, at the window's bottom otherwise.
    private func applyStripLayout() {
        // Deactivate first: both bottom constraints are required and must never be active together.
        if strip.reservesSpace {
            viewerAtBottom.isActive = false
            viewerAboveStrip.isActive = true
        } else {
            viewerAboveStrip.isActive = false
            viewerAtBottom.isActive = true
        }
    }

    /// The viewer's toolbar follows `⌥⌘T`. Left alone while it is wanted: the system slides it in and out with the menu
    /// bar in full screen, and setting it visible again pins it on screen. Only the viewer's own toolbar is touched, and
    /// only while it is the window's: Home's stays shown, and `hideHome` puts the viewer's back as it was left.
    private func applyToolbarVisibility() {
        guard !isClosed, !isShowingHome, window?.toolbar === viewerToolbar.nsToolbar else { return }
        guard toolbarWanted != toolbarWasWanted else { return }
        toolbarWasWanted = toolbarWanted
        viewerToolbar.nsToolbar.isVisible = toolbarWanted
    }

    /// The stats bar (`I`) floats over the picture and reserves no room, always at the top: windowed under the toolbar, in
    /// full screen at the window's top edge (the system's toolbar slides over it there). The picture always fills what is
    /// left of the toolbar.
    private func applyStatsLayout() {
        let toolbarWanted = toolbarWanted
        // `stats-bar-with-toolbar` off: the bar is the toolbar's stand-in and shows only without it. In full screen the toolbar
        // is not on screen but slides in on demand, so it does not count there: the bar shows as `I` says.
        let toolbarShown = !isFullScreen && toolbarWanted
        let visible = (isFullScreen ? fullScreenStatus : statsMode != .hidden)
            && (Settings.shared.config.statsBarWithToolbar || !toolbarShown)
        statsBar.isHidden = !visible
        guard !isClosed else { return }
        applyToolbarVisibility()
        infoPanel.place()   // away from the bar
        // Deactivate first: the alternatives of one edge are all required and must never be active together.
        if visible {
            warningsAtTop.isActive = false
            warningsBelowBar.isActive = true
            backAtTop.isActive = false
            backBelowBar.isActive = true
        } else {
            warningsBelowBar.isActive = false
            warningsAtTop.isActive = true
            backBelowBar.isActive = false
            backAtTop.isActive = true
        }
        statsAtTop.isActive = visible
        applyToastRows()
        viewerAtTop.isActive = false
        viewerAtScreenTop.isActive = false
        pillsAtTop.isActive = false
        pillsAtScreenTop.isActive = false
        (isFullScreen ? viewerAtScreenTop : viewerAtTop).isActive = true
        (isFullScreen ? pillsAtScreenTop : pillsAtTop).isActive = true
    }

    // MARK: Info panel (M4a spec §3, InfoPanelKit)

    /// The panel's controller: under the strip (magnified strip cells draw over it), kept to the viewer's area
    /// (`infoPanelArea`), off screen without sections (no photo), its mouse buttons and wheel the viewer's bindings, and
    /// a key typed in a selected value the viewer's or the menus' (`PanelKeyRoute`).
    private func makeInfoPanel(in container: NSView) {
        let panel = InfoPanelController(host: container, below: strip.view, keyPrefix: "infoPanel",
                                        defaultOrder: ["File", "Capture", "Display", "Diagnostics"],
                                        defaultPlacement: .standard,
                                        area: { [weak self, weak container] in
                                            guard let self, let container else { return .zero }
                                            return self.infoPanelArea(in: container)
                                        })
        panel.hidesWhenEmpty = true
        panel.isAvailable = true
        panel.middleTruncated = ["Folder"]
        panel.wheel = { MouseButtons.shared.wheel($0) }
        panel.otherMouse = { event in
            switch event.type {
            case .otherMouseDown: MouseButtons.shared.otherMouseDown(event)
            case .otherMouseDragged: MouseButtons.shared.moved(event)
            case .otherMouseUp: MouseButtons.shared.otherMouseUp(event)
            default: break
            }
        }
        panel.plainKey = { [weak self] event in
            guard let self else { return }
            self.window?.makeFirstResponder(self.viewerView)
            let flags = event.modifierFlags
            switch PanelKeyRoute.route(command: flags.contains(.command), control: flags.contains(.control)) {
            case .menu: _ = NSApp.mainMenu?.performKeyEquivalent(with: event)
            case .viewer: self.viewerView.keyDown(with: event)
            }
        }
        // The panel may have come up under the cursor, or gone from under it.
        panel.onShownChange = { [weak self] _ in self?.viewerView.overlayDidChange() }
        infoPanel = panel
    }

    /// View › Show Info / Hide Info (`⌘I`): the panel opens or closes in every window.
    @objc func toggleInfoPanel(_ sender: Any?) {
        infoPanel.toggle()
        applyInfoPanel()
    }

    /// Starts or stops this window's reads for the panel to match what the user wants (`isVisible`, any window's ⌘I).
    private func applyInfoPanel() {
        let wanted = !isClosed && infoPanel.isVisible
        guard wanted != infoActive else { return }
        infoActive = wanted
        if wanted {
            updateInfoPanel(force: true)
        } else {
            stopInfoPanel()
        }
        updateDiagnosticsTimer()
    }

    /// Forgets what was read for the panel; the panel is left empty (off screen).
    private func stopInfoPanel() {
        infoHold.cancel()
        infoHoldTimer?.invalidate()
        infoHoldTimer = nil
        metadataTask?.cancel()
        slowReadTask?.cancel()
        infoURL = nil
        statSize = nil
        metadata = nil
        metadataPending = false
        diagnosticsRows = []
        shownFile = nil
        shownDisplay = nil
        infoPanel.show([])
    }

    /// The part of the viewer the panel may cover, in the content view's points with y down: under the status (in a
    /// window it reserves the room, in full screen it floats over the picture), above the strip while it is on screen, and below the back
    /// button while it is shown for a panel in the top left corner.
    private func infoPanelArea(in container: NSView) -> CGRect {
        let viewer = viewerView.frame
        var top = viewer.maxY, bottom = viewer.minY
        if !statsBar.isHidden {
            top = min(top, statsBar.frame.minY)
        }
        if strip.isShown { bottom = max(bottom, strip.view.frame.maxY) }
        let area = CGRect(x: viewer.minX, y: container.bounds.height - top, width: viewer.width, height: max(0, top - bottom))
        guard backButtonShown else { return area }
        // The package keeps the place under this key (`keyPrefix` `infoPanel`); none: its default, the top left. While
        // the panel is on screen its corner is where it is now, so a drag out of the corner leaves the band at once.
        let stored = PanelPlacement(stored: UserDefaults.standard.string(forKey: "infoPanelPlacement")) ?? .standard
        let current = infoPanel?.panelFrame.map {
            CGRect(x: $0.minX, y: container.bounds.height - $0.maxY, width: $0.width, height: $0.height)
        }
        return PanelArea.area(area, backButtonShown: true,
                              corner: PanelArea.corner(current: current, stored: stored, in: area))
    }

    /// The window's field editor for the panel's values (the package's), nil for any other field.
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        infoPanel?.fieldEditor(for: client)
    }

    /// Brings the panel up to date: a new current photo starts its metadata read, and the File and Display sections
    /// are rebuilt when what they show changed (`force`: the metadata or the diagnostics changed). Called on every
    /// session change, so it only compares unless something did change.
    private func updateInfoPanel(force: Bool = false) {
        guard infoActive else { return }
        var force = force
        let current = infoPhoto
        if current != infoURL {
            force = true
            // A panel showing a photo keeps it until the new one's facts are in (none to keep on opening).
            if shownFile != nil { infoHold.photoChanged(at: ProcessInfo.processInfo.systemUptime) }
            readMetadata(of: current)
        }
        let file = fileFacts(of: current), display = displayFacts()
        let ready = current == nil || (metadata != nil && (file?.info != nil || file?.error != nil))
        if infoHold.holds(ready: ready, now: ProcessInfo.processInfo.systemUptime) {
            scheduleInfoHoldEnd()
            return
        }
        infoHoldTimer?.invalidate()
        infoHoldTimer = nil
        guard force || file != shownFile || display != shownDisplay else { return }
        shownFile = file
        shownDisplay = display
        // No photo, no sections: the panel is off screen (`hidesWhenEmpty`). The package places it for the new height
        // and gives the keys back to the viewer when a selected value's field went.
        infoPanel.show(InfoPanelContent.sections(file: file, metadata: metadata, metadataPending: metadataPending,
                                                 display: display, diagnostics: diagnosticsRows))
    }

    /// The photo the panel is about: the current one, or in a pair the page under the pointer, the first in reading
    /// order when the pointer is on neither (spread spec, «Положение»).
    private var infoPhoto: URL? {
        guard let list = session.playlist, let pages = session.currentPages, let second = pages.second else {
            return session.playlist?.current
        }
        return list.files[viewerView.pointerPage == 1 ? second : pages.first]
    }

    /// At the hold's limit the panel shows what is known of the new photo by then.
    private func scheduleInfoHoldEnd() {
        guard infoHoldTimer == nil, let deadline = infoHold.deadline else { return }
        let timer = Timer(timeInterval: max(0, deadline - ProcessInfo.processInfo.systemUptime), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.infoHoldTimer = nil
                self?.updateInfoPanel(force: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        infoHoldTimer = timer
    }

    /// What the window knows about `url` without the metadata: the header once the photo is the entry on screen,
    /// meanwhile its name, folder and (once stat'ed) size. Nil without a photo.
    private func fileFacts(of url: URL?) -> InfoFileFacts? {
        guard let url else { return nil }
        let entry = [session.entry, session.shownCompanion].lazy.compactMap { $0 }.first { $0.url == url }
        // The metadata read's header until the decoder's own is in: the same ImageIO header, read sooner on a cold photo.
        let info = entry?.info ?? (infoURL == url ? metadata?.header : nil)
        // An archive entry: the archive and its inner path, in the archive's folder (Stash spec §2.4).
        let archive = ArchivePath.split(url)?.archive
        return InfoFileFacts(name: ArchivePath.displayName(url),
                             folder: ((archive ?? url).deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath,
                             fileSize: info?.fileSize ?? statSize, info: info,
                             applyingOrientation: session.appliesOrientation, error: entry?.failure)
    }

    /// The zoom, filter and colour of the frame on screen; nil before any photo is shown. The zoom is the target of a
    /// running zoom animation (M4b spec §2.2), the filter the one each frame is drawn with.
    private func displayFacts() -> InfoDisplayFacts? {
        guard session.entry != nil else { return nil }
        return InfoDisplayFacts(mode: StatsLine.modeText(session.zoomTarget ?? session.transform), filter: filterName(),
                                colour: colourLine())
    }

    /// Asks the shared cache for `url`'s metadata off the main thread (the stat too: a share may be slow to answer).
    /// The Capture section says `Reading…` only once a second has passed without the result, so a quick read never
    /// flashes it; a result arriving after the photo changed (or the panel closed) is dropped.
    private func readMetadata(of url: URL?) {
        metadataTask?.cancel()
        slowReadTask?.cancel()
        infoURL = url
        statSize = nil
        metadata = nil
        metadataPending = false
        guard let url else { return }
        let cache = Self.metadataCache
        metadataTask = Task { [weak self] in
            let stamp = await Task.detached(priority: .utility) { Self.fileStamp(url) }.value
            guard let self, self.infoURL == url else { return }
            self.statSize = stamp.size
            self.updateInfoPanel()   // the size, while the header is read
            let result = await cache.metadata(for: url, size: stamp.size ?? -1, modified: stamp.modified)
            guard self.infoURL == url else { return }
            self.slowReadTask?.cancel()
            self.metadata = result
            self.metadataPending = false
            self.updateInfoPanel(force: true)
        }
        slowReadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, self.infoURL == url, self.metadata == nil else { return }
            self.metadataPending = true
            self.updateInfoPanel(force: true)
        }
    }

    /// The file's size and modification date, the cache's key with its path; nil for what cannot be read (a vanished
    /// file: the read then says so).
    nonisolated private static func fileStamp(_ url: URL) -> (size: Int?, modified: Date?) {
        if ArchivePath.split(url) != nil {
            let stamp = try? ArchiveReader.shared.stamp(url)
            return (stamp?.size, stamp?.modified)
        }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return (values?.fileSize, values?.contentModificationDate)
    }

    /// The frame counter and the 0.5 s timer run while the panel is open and the window can be seen (not closed,
    /// miniaturized or fully occluded): M4a spec §3.5.
    private func updateDiagnosticsTimer() {
        let seen = window.map { !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
        let on = !isClosed && infoActive && seen
        if on != (diagnosticsTimer != nil) { DebugLog.log("info panel diagnostics \(on ? "on" : "off")") }
        viewerView.setFrameStatsEnabled(on)
        if on { startDiagnosticsTimer() } else { stopDiagnosticsTimer() }
    }

    private func startDiagnosticsTimer() {
        guard diagnosticsTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDiagnostics() }
        }
        RunLoop.main.add(timer, forMode: .common)   // keeps ticking while a menu is open or the window resizes
        diagnosticsTimer = timer
        refreshDiagnostics()
    }

    private func stopDiagnosticsTimer() {
        diagnosticsTimer?.invalidate()
        diagnosticsTimer = nil
    }

    /// Builds the Diagnostics rows from the session, the cache's counts (an actor call, so asynchronous), the process
    /// and GPU memory and the render loop's frame statistics, and refreshes Display with them.
    private func refreshDiagnostics() {
        let cache = session.cache
        Task { [weak self] in
            let stats = await cache.stats()
            guard let self, self.diagnosticsTimer != nil else { return }
            let entry = self.session.entry
            self.diagnosticsRows = StatsLine.diagnostics(
                colorSpace: entry?.info?.colorSpaceName ?? entry?.pyramid.map { EmbeddedColorSpace.displayName(of: $0.colorSpace) },
                decoder: entry?.decoderName, timings: entry?.timings ?? LoadTimings(), fromCache: self.session.shownFromCache,
                state: entry?.state, isSeededOnly: self.session.showsThumbnailOnly, cache: stats,
                ramBytes: ProcessMemory.footprint(),
                gpuBytes: MetalContext.shared.device.currentAllocatedSize, frames: self.viewerView.frameStats())
            self.updateInfoPanel(force: true)
        }
    }

    /// The pyramid level the frame on screen is drawn from and its zoom: the level is the finer of the one the zoom
    /// wants and the finest resident, at the scale drawn (a zoom stretch included), as in the renderer. In a pair it is
    /// the page the panel is about (`infoPhoto`), at that page's own scale (`ViewerSession.drawnPage`). Nil without a
    /// picture (nothing decoded yet, a failed photo).
    private func drawnFrame() -> (level: Int, scale: Double)? {
        guard let (pyramid, scale) = session.drawnPage(infoPhoto), let finest = pyramid.finestResidentLevel else {
            return nil
        }
        return (pyramid.grid.drawnLevel(forScale: scale, finestResident: finest), scale)
    }

    /// The scaling regime and resampler of the frame on screen (spec §6), the path as drawn on this GPU (`metalfx` falls back to
    /// Lanczos-3 without MetalFX), with ` · folder` when the filter key behind it comes from a folder's record. Nil
    /// without a picture.
    private func filterName() -> String? {
        guard let (level, scale) = drawnFrame() else { return nil }
        let settings = ResampleSettings(config: effectiveConfig)
        let mode = MetalContext.shared.drawnMode(settings.mode(scale: scale, level: level))
        let regime = settings.activeKey(scale: scale, level: level)
        let fromFolder = regime.map { folderValues[$0.rawValue] != nil } ?? false
        return StatsLine.filterName(regime: regime, mode: mode, level: level, m: scale * Double(1 << level),
                                    fromFolder: fromFolder)
    }

    /// The panel's colour row for the photo on screen (the one `session.entry` holds), with the window's
    /// vibrance and ` · folder` when a colour value comes from a folder's record (M3c spec §2.3). Nil without a photo.
    private func colourLine() -> String? {
        guard let shown = session.entry?.url else { return nil }
        // In a pair: the page the panel is about, when it is on screen.
        let url = infoPhoto.flatMap { $0 == session.shownCompanion?.url ? $0 : nil } ?? shown
        let config = effectiveConfig
        return StatsLine.colour(session.colorStatus(for: url), vibrance: config.vibrance ? config.vibranceAmount : nil,
                                fromFolder: Config.colorFolderKeys.contains { folderValues[$0] != nil })
    }

    /// A colour change that leaves the shown cube as it is does not reach the session, so the panel is refreshed here.
    private func refreshColourLine() { updateInfoPanel() }

    // MARK: Scaling keys (folder settings spec §4)

    /// `S`, `⇧S`, `A`, `⇧A`. Without a photo there is no folder, and they do nothing. `S` and `A` also wait while the
    /// screen still shows the previous photo (a step into another folder): what they would change is not on screen.
    @discardableResult
    private func scalingKey(_ action: KeyAction) -> Bool {
        guard let folder else { return false }
        if action == .cycleFilter || action == .toggleAntiring {
            guard let entry = session.entry, entry.url == session.playlist?.current else { return false }
        }
        switch action {
        case .cycleFilter:
            return cycleFilter(in: folder)
        case .toggleAntiring:
            let value = ScalingKeys.toggledAntiring(effectiveConfig)
            folderSettings.set(ScalingKeys.antiringKey, value, for: folder)
            toast.show(ScalingKeys.toast(key: ScalingKeys.antiringKey, setForFolder: value))
        case .saveFilters:
            let keys = ScalingKeys.keysToSave(folderValues: folderValues, among: ScalingKeys.filterKeys)
            guard !keys.isEmpty else {
                toast.show(ScalingKeys.nothingToSave)
                return true
            }
            saveAsDefault(keys, from: folder)
        case .saveAntiring:
            // Even when the value is loupe.conf's already: the file gets the same line, the folder loses its own.
            saveAsDefault([ScalingKeys.antiringKey], from: folder)
        default:
            break
        }
        return true
    }

    // MARK: Colour keys (M3c spec §2.1)

    /// `C`, `⇧C`, `V`, `⇧V`, the same way: without a photo there is no folder and they do nothing, and `C` / `V` also
    /// wait while the screen still shows the previous photo. `⇧C` / `⇧V` save the window's values even when they are
    /// loupe.conf's already.
    @discardableResult
    private func colourKey(_ action: KeyAction) -> Bool {
        guard let folder else { return false }
        if action == .toggleAutoColor || action == .toggleVibrance {
            guard let entry = session.entry, entry.url == session.playlist?.current else { return false }
        }
        switch action {
        case .toggleAutoColor:
            let value = ColourKeys.toggled(effectiveConfig, key: "auto-color")
            folderSettings.set("auto-color", value, for: folder)
            toast.show(ColourKeys.toast(autoColor: value == "yes"))
        case .toggleVibrance:
            let value = ColourKeys.toggled(effectiveConfig, key: "vibrance")
            folderSettings.set("vibrance", value, for: folder)
            toast.show(ColourKeys.toast(vibrance: value == "yes"))
        case .saveAutoColor:
            saveAsDefault(ColourKeys.autoKeys, from: folder, toast: ColourKeys.autoColorSaved)
        case .saveVibrance:
            saveAsDefault(ColourKeys.vibranceKeys, from: folder, toast: ColourKeys.vibranceSaved)
        default:
            break
        }
        refreshColourLine()
        return true
    }

    // MARK: Folder value steps (M4c spec §2.3)

    /// input.conf's `add <key> <step>`, `steps` times (negative: down): the window's value of `key` moved, rounded to the
    /// step and held to the key's range (`FolderAdjust`), recorded for the folder like `C` / `V`; the cube follows at once
    /// (`.folderSettingsChanged` → `updateEffectiveConfig`). The toast says the value (with ` (off)` when the feature is
    /// off in the folder) on every step, at a bound too. Without a photo, or while the screen still shows the previous
    /// photo, it does nothing (`applied` false). `hitLimit`: the step pushed past the range. The mouse answers every
    /// applied step (M4c spec §5): `haptic-limit` at a bound, else `haptic-detent` when the value
    /// reached or crossed 25 / 50 / 75 % of the range (spec §11), else `haptic-step`; this is their one call site.
    @discardableResult
    private func adjust(key: String, step: Double, steps: Int) -> (applied: Bool, hitLimit: Bool) {
        guard let folder, let entry = session.entry, entry.url == session.playlist?.current,
              let current = FolderAdjust.current(key, in: effectiveConfig) else {   // nil: a key `add` does not take
            return (false, false)
        }
        let (value, hitLimit) = FolderAdjust.stepped(current.value, step: step, times: steps, key: key)
        // Pushing against a bound changes nothing: the folder is not pinned to a value it only inherits.
        if value != current.value { folderSettings.set(key, FolderAdjust.text(value), for: folder) }
        toast.show(FolderAdjust.toast(key: key, value: value, enabled: current.enabled))
        refreshColourLine()
        if hitLimit {
            MouseHaptics.shared.limit()
        } else if FolderAdjust.crossesDetent(from: current.value, to: value, key: key) {
            MouseHaptics.shared.detent()
        } else {
            MouseHaptics.shared.step()
        }
        return (true, hitLimit)
    }

    // MARK: Keep-zoom keys (M4b spec §4.4)

    /// `L`, `⇧L`: without a photo there is no folder and they do nothing. Unlike `C` they do not wait for the photo:
    /// `keep-zoom-position` decides the next switch, not what is on screen. `L` writes the folder's value even when it
    /// equals the inherited one; `⇧L` saves the window's value even when it is loupe.conf's already, and the window
    /// does not change.
    @discardableResult
    private func zoomKey(_ action: KeyAction) -> Bool {
        guard let folder else { return false }
        switch action {
        case .toggleKeepZoom:
            let value = ZoomKeys.toggled(effectiveConfig)
            folderSettings.set(ZoomKeys.keepKey, value, for: folder)
            toast.show(ZoomKeys.toast(keep: value == "yes"))
        case .saveKeepZoom:
            saveAsDefault([ZoomKeys.keepKey], from: folder, toast: ZoomKeys.keepSaved)
        case .toggleZoomCarry:
            let carry = ZoomKeys.toggledCarry(effectiveConfig)
            folderSettings.set(ZoomKeys.carryKey, carry.rawValue, for: folder)
            toast.show(ZoomKeys.toast(carry: carry))
        case .saveZoomCarry:
            saveAsDefault([ZoomKeys.carryKey], from: folder, toast: ZoomKeys.carrySaved)
        default:
            break
        }
        return true
    }

    // MARK: Two-page keys (spread spec 2026-10-23)

    /// When `D` last turned two pages on (system uptime): a pair taken back within 2 s says why (`onSpreadRefusal`).
    private var spreadKeyTime: TimeInterval?

    /// `D`, `⇧D`, `⌥D`, as `L` / `⇧L`: without a photo there is no folder and they do nothing. `D` turns two pages on or
    /// off for the folder and `⌥D` shifts its pairs by a page (the folder's own values, even when they equal the
    /// inherited ones); `⇧D` saves the window's `spread` as loupe.conf's default. The session follows through
    /// `.folderSettingsChanged` (`updateEffectiveConfig` → `updateSpreadRules`).
    @discardableResult
    private func spreadKey(_ action: KeyAction) -> Bool {
        guard let folder else { return false }
        switch action {
        case .toggleSpread:
            let value = SpreadKeys.toggled(effectiveConfig)
            folderSettings.set(SpreadKeys.key, value, for: folder)   // the session follows at once
            spreadKeyTime = value == "yes" ? ProcessInfo.processInfo.systemUptime : nil
            toast.show(SpreadKeys.toast(on: value == "yes", refusal: session.spreadRefusal))
        case .saveSpread:
            saveAsDefault([SpreadKeys.key], from: folder, toast: SpreadKeys.savedToast(on: effectiveConfig.spread))
        case .shiftSpread:
            let value = SpreadKeys.toggledShift(effectiveConfig)
            folderSettings.set(SpreadKeys.shiftKey, value, for: folder)
            toast.show(SpreadKeys.toast(shift: value == "yes"))
        default:
            break
        }
        return true
    }

    // MARK: Pan indicator keys (M4b spec §5.4)

    /// `P`, `⇧P`: the session's mode for every window, and saved as the default; they need no photo.
    @discardableResult
    private func panIndicatorKey(_ action: KeyAction) -> Bool {
        let settings = Settings.shared
        switch action {
        case .cyclePanIndicators:
            settings.cyclePanIndicators()
            toast.show(PanIndicators.toast(for: settings.panIndicators))
        case .savePanIndicators:
            toast.show(settings.savePanIndicators() ? PanIndicators.savedToast : ScalingKeys.couldNotSave)
        default:
            break
        }
        return true
    }

    /// `S`: the next filter of the key the photo is drawn with at this zoom, recorded for `folder` (even when it equals
    /// the inherited value: the folder is pinned to it). The key is judged on the level the zoom needs, which the photo
    /// settles on, not on a coarser preview stretched meanwhile (that could say `upscale-high` for `upscale` at 200 %,
    /// or for `downscale` at fit): the toast names the filter of the sharp photo; the stats line says what is drawn.
    /// Nothing without a picture; at a nearest-neighbour zoom, which no filter key affects, it only says so. True when it
    /// switched the filter (the toggle haptic).
    private func cycleFilter(in folder: URL) -> Bool {
        guard let pyramid = session.image, pyramid.finestResidentLevel != nil else { return false }
        let scale = (session.zoomTarget ?? session.transform).scale   // the zoom a running animation settles on
        let level = TileGrid.level(forScale: scale, levelCount: pyramid.grid.levelCount)
        guard let key = ResampleSettings(config: effectiveConfig).activeKey(scale: scale, level: level) else {
            toast.show(ScalingKeys.toast(pixelArtPercent: effectiveConfig.pixelArtPercent))
            return false
        }
        let next = ScalingKeys.cycle(effectiveConfig, key: key)
        folderSettings.set(next.key, next.value, for: folder)
        toast.show(ScalingKeys.toast(key: next.key, setForFolder: next.value))
        return true
    }

    /// `⇧S` / `⇧A` / `⇧C` / `⇧V` / `⇧L`: the window's values of `keys` (its folder's own or inherited) into loupe.conf. They never change
    /// what the window draws (spec §4): `folder`'s own entry for a key goes only where the folder then gets the same
    /// value anyway, from an ancestor or the new loupe.conf (`ScalingKeys.keysToClear`); ancestors are never touched.
    /// A failed write changes nothing.
    /// `message` is the toast on success (the keys, by default).
    private func saveAsDefault(_ keys: [String], from folder: URL, toast message: String? = nil) {
        let config = effectiveConfig
        let values = Dictionary(uniqueKeysWithValues: keys.compactMap { key in config.text(forKey: key).map { (key, $0) } })
        guard Settings.shared.saveAsDefault(values) else {
            toast.show(ScalingKeys.couldNotSave)
            return
        }
        let clear = ScalingKeys.keysToClear(saved: values, own: folderSettings.ownValues(for: folder),
                                            inheritedWithoutOwn: folderSettings.inheritedValues(for: folder))
        if !clear.isEmpty { folderSettings.clear(clear, for: folder) }
        toast.show(message ?? ScalingKeys.toast(savedAsDefault: keys))
    }

    /// 70 % of the main screen's visible area, centred (`center()` places it afterwards).
    private static func initialFrame() -> NSRect {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(x: screen.minX, y: screen.minY, width: (screen.width * 0.7).rounded(), height: (screen.height * 0.7).rounded())
    }
}

/// The window's content view; it tells the window controller when it lays out (a resize, full screen), so the info
/// panel, which is placed by frame rather than by constraints, keeps to its corner.
/// The viewer's window. It offers every key press to `onKeyDown` before any view sees it (true: taken), so a key Home's
/// grid would take as the first letter of a name can be the window's (`ViewerWindowController.windowKey`). A view's
/// `performKeyEquivalent` is no place for that: AppKit offers it only keys with ⌘ or ⌃.
private final class ViewerWindow: NSWindow {
    var onKeyDown: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKeyDown?(event) == true { return }
        super.sendEvent(event)
    }
}

private final class ViewerContainerView: NSView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}
