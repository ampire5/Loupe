import AppKit
import LogiHIDPP
import LoupeCore
import LoupeRender
import LoupeSettings
import UniformTypeIdentifiers

/// App lifecycle, the main menu and the ways a file arrives: Finder / `open` (open events),
/// a path argument (`swift run Loupe photo.jpg`) and File › Open….
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    /// The viewer windows (tabs) and which one is in front.
    private let registry = WindowRegistry()
    /// The process-wide photo cache (M2): every viewer reads from it. Made after the first config read.
    private var cache: ImageCache<MetalPyramidLoader>?
    /// The app's one thumbnail store (one per cache directory): every window's strip asks it.
    private var thumbnails: ThumbnailStore?
    /// Finishes once the store knows the cache's activity (`connect`); every session waits for it.
    private var thumbnailsReady: Task<Void, Never>?
    /// Tells the cache about system memory pressure; primary instance only.
    private var pressureMonitor: MemoryPressureMonitor?
    /// Finder open events can arrive before `applicationDidFinishLaunching` has built the window.
    private var pendingURLs: [URL] = []
    /// `Loupe.db` (positions and folder settings). Opened only by the primary instance: a secondary launch
    /// neither reads nor writes it.
    private var stateDatabase: StateDatabase?
    /// The photo last viewed in each folder, kept across launches; flushed on quit. In memory only until the
    /// primary instance has opened the database.
    private var positions = FolderPositions(database: nil)
    /// Home's Recent (`Loupe.db`); nil in a secondary instance.
    private(set) var recent: RecentStore?
    /// Last Session and the named ones (`Loupe.db`); nil in a secondary instance.
    private(set) var sessions: SessionStore?
    /// The scaling values saved per folder (`S`, `A`), kept across launches; flushed on quit. Made only by the
    /// primary instance.
    private var folderSettings: FolderSettings?
    /// True for a launch that handed over to an already running Loupe and is quitting: it builds no window,
    /// no cache, and writes neither `Loupe.db` nor defaults.
    private var isSecondary = false
    private var handOverObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?
    /// The layout the menus' key equivalents show; a reload that changes it shows them again (`refreshShownKeys`).
    private var menuInputMap: InputMap?
    /// `LOUPE_AUTOPAN` (debug): the synthetic pan driver for latency runs.
    private var autoPan: AutoPan?
    /// The Logitech mouse (M4c spec §3.1): the `MX_*` buttons and the thumb wheel `input.conf` binds, and the haptics.
    /// Made after the first window is up, by the primary instance only.
    private var logiMouse: LogiMouse?
    /// What `logiMouse` was last asked to divert and watch; a reload that changes it diverts / watches again.
    private var divertedInputs: (cids: Set<UInt16>, watched: Set<UInt16>, thumbWheel: Bool)?
    /// The `haptic-strength` `logiMouse` was last given; a reload that changes it writes it again.
    private var appliedHapticStrength: Int?
    /// The settings window's store over loupe.conf, made on the first ⌘, (`Settings.settingsStore` holds it weakly).
    private var settingsStore: ConfigSettingsStore?
    /// What refreshes the settings window's folder notes (`observeFolderNotes`).
    private var folderNoteObservers: [NSObjectProtocol] = []
    /// Set when the app quits: windows closing then are not the user closing the photo windows.
    private var isTerminating = false

    private static let openFileNotification = Notification.Name("local.loupe.openFile")

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let primary = Self.primaryInstance() {
            becomeSecondary(primary)
            return
        }
        // The Dock icon (~10 ms for an alternate's .icns) waits until the window is up.
        Settings.shared.reload(applyingIcon: false)
        stateDatabase = Self.openStateDatabase()
        positions = FolderPositions(database: stateDatabase)
        recent = RecentStore(database: stateDatabase)
        sessions = SessionStore(database: stateDatabase)
        sessions?.beginRun()   // the run before becomes Last Session; this run saves beside it
        registry.sessions = sessions
        let folderSettings = FolderSettings(database: stateDatabase)
        self.folderSettings = folderSettings
        Settings.shared.folderSettings = folderSettings
        let browserPlaces = BrowserPlaces(database: stateDatabase)
        registry.browserPlaces = browserPlaces
        registry.positions = positions
        var pathStores: [any PathMoving] = [positions, folderSettings, browserPlaces]
        if let recent { pathStores.append(recent) }
        if let sessions { pathStores.append(sessions) }
        registry.pathStores = pathStores
        let config = Settings.shared.config
        // One reader for photos and thumbnails: the generator's lowest priority then really yields to the viewer
        // (spec §3.6). Four threads: the viewer's two, and two only background reads may use. The thumbnails decode
        // in a pool of their own, at utility QoS.
        let reader = FileReader(threads: 4), pool = DecodePool()
        // pyramid-filter: read by the loader at each upload, set again on every reload (Settings).
        let pyramidFilter = PyramidFilterSetting(config.pyramidFilter)
        Settings.shared.pyramidFilter = pyramidFilter
        let cache = ImageCache(loader: MetalPyramidLoader(filter: pyramidFilter), reader: reader, pool: pool,
                               limits: CacheLimits(config: config))
        self.cache = cache
        Settings.shared.cache = cache
        pressureMonitor = MemoryPressureMonitor(cache: cache)
        var thumbnailLog: (@Sendable (String) -> Void)?
        if DebugLog.isEnabled { thumbnailLog = { line in DebugLog.log(line) } }
        let thumbnails = ThumbnailStore(directory: Self.thumbnailDirectory, reader: reader,
                                        thumbSize: config.thumbSize, limitBytes: config.thumbCacheBytes,
                                        cachedBytes: { await cache.cachedBytes($0, stamp: $1) }, log: thumbnailLog)
        self.thumbnails = thumbnails
        registry.pathStores.append(thumbnails)   // a folder renamed in the browser keeps its card's summary
        Settings.shared.thumbnails = thumbnails
        thumbnailsReady = Self.connect(cache, to: thumbnails)
        registry.makeController = { [unowned self] in self.makeController() }
        // Active as it is added: its first photo is planned at once.
        let controller = makeController()
        // The first window takes the place and size it was left at and keeps them; the others cascade from the front one.
        controller.window?.setFrameUsingName(ViewerWindowController.frameName)
        controller.window?.setFrameAutosaveName(ViewerWindowController.frameName)
        // The file to show goes to the cache before the menu is built and the window shown: its read and decode
        // run while AppKit puts the window up (docs/bench/2026-10-15-startup.md).
        // The window is empty: the first file opens in it without a route, the others are routed once it is up.
        let launchURLs = Self.fileArgument(CommandLine.arguments.dropFirst()).map { [URL(fileURLWithPath: $0)] } ?? pendingURLs
        pendingURLs = []
        let launchTargets = OpenRouter.firstPerFolder(Self.targets(launchURLs))
        if let first = launchTargets.first { controller.open(first) }
        let menu = Self.makeMainMenu()
        menu.onTabKey = { [weak self] key in self?.registry.tabKey(key) ?? false }
        menu.canChooseCardStyle = { [weak self] in self?.registry.keyWindowCanChooseCardStyle ?? false }
        NSApp.mainMenu = menu
        menuInputMap = Settings.shared.inputMap
        observeSettings()
        observeHandOver()
        observeLastViewerClose()
        controller.showWindow(nil)
        NSApp.activate()
        // Off the launch path, like the Dock icon: `start()` opens the receivers synchronously. `follow` takes the
        // app's state as it is then, so a `didBecomeActive` that came before is not missed.
        DispatchQueue.main.async { self.startLogiMouse() }
        // `LOUPE_SCREEN=<index into NSScreen.screens>` (debug): the window starts on that screen, so scripted runs
        // always measure the same display.
        if DebugLog.isEnabled, let i = ProcessInfo.processInfo.environment["LOUPE_SCREEN"].flatMap(Int.init),
           NSScreen.screens.indices.contains(i), let window = controller.window {
            let area = NSScreen.screens[i].visibleFrame, size = window.frame.size
            window.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2))
            DebugLog.log("window on screen \(i): \(NSScreen.screens[i].frame.size)")
        }
        controller.restoreFullScreen()
        if !launchTargets.isEmpty { controller.bringToFront() }   // to the front, as for any file opened from outside
        for target in launchTargets.dropFirst() { registry.open(target) }
        // No photo to show: Home (Home spec §2.1); WebKit is touched only when Home opens on Stash.
        refreshStashItem()
        if launchTargets.isEmpty {
            if Settings.shared.config.sessionRestore == .last, let last = sessions?.last() {
                registry.open(session: last, first: controller)
            } else {
                controller.showHome()
            }
        }
        DispatchQueue.main.async { Settings.shared.applyAppIcon() }
        // `LOUPE_CHEATSHEET` (debug): the `?` sheet open from the start, to look at it without pressing a key.
        if DebugLog.isEnabled, ProcessInfo.processInfo.environment["LOUPE_CHEATSHEET"] != nil { controller.toggleCheatSheet() }
        // `LOUPE_SETTINGS=<page id>` (debug): the settings window open from the start (empty: on its last page).
        if DebugLog.isEnabled, let page = ProcessInfo.processInfo.environment["LOUPE_SETTINGS"] {
            DispatchQueue.main.async { self.openSettings(page: page.isEmpty ? nil : page) }
        }
        if DebugLog.isEnabled, let seconds = AutoPanPath.seconds(environment: ProcessInfo.processInfo.environment) {
            let environment = ProcessInfo.processInfo.environment
            let mode = AutoPanPath.mode(environment: environment)
            autoPan = AutoPan(seconds: seconds,
                              scale: environment["LOUPE_AUTOPAN_SCALE"] == nil && mode == .zoom ? 2 : AutoPanPath.scale(environment: environment),
                              mode: mode, controller: controller)
            autoPan?.begin()
        }
    }

    /// A viewer window with the app's shared cache, thumbnails, positions and folder settings, in the registry.
    private func makeController() -> ViewerWindowController {
        guard let cache, let thumbnails, let folderSettings else { preconditionFailure("made before the shared stores") }
        let controller = ViewerWindowController(cache: cache, thumbnails: thumbnails, thumbnailsReady: thumbnailsReady,
                                                positions: positions, folderSettings: folderSettings, recent: recent)
        registry.add(controller)
        return controller
    }

    /// `~/Library/Caches/Loupe`, made if missing; nil (memory-only thumbnails) if it cannot be. Worked out once, at
    /// launch (the store), not again on each Settings open.
    private static let thumbnailDirectory: URL? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let directory = caches.appendingPathComponent("Loupe", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("loupe: could not create \(directory.path): \(error.localizedDescription)\n".utf8))
            return nil
        }
        return directory
    }()

    /// Forwards the cache's activity to the store, in order (the cache calls its handler inside its actor, so the
    /// values go through a stream rather than a task each, which could overtake one another), and the store's
    /// status changes to every strip. The task returned finishes once the first activity reached the store: the
    /// store starts out `.idle`, so the sessions hold their first request until then. Nonisolated: the forwarding
    /// never waits for the main thread.
    nonisolated private static func connect(_ cache: ImageCache<MetalPyramidLoader>, to store: ThumbnailStore) -> Task<Void, Never> {
        let (activities, sink) = AsyncStream.makeStream(of: CacheActivity.self)
        return Task {
            await store.setOnThumbnail { url in
                Task { @MainActor in NotificationCenter.default.post(name: .thumbnailChanged, object: url) }
            }
            // On the store's actor: the main thread is told asynchronously, never waited for.
            await store.setOnVolumeAnswered { volume in
                Task { @MainActor in NotificationCenter.default.post(name: .coverVolumeAnswered, object: volume) }
            }
            // Some client's covers counted anew, or a pause began or ended: Home's progress (coalesced there).
            await store.coverQueue.setOnProgress { _ in
                Task { @MainActor in NotificationCenter.default.post(name: .thumbsProgressChanged, object: nil) }
            }
            await withCheckedContinuation { (first: CheckedContinuation<Void, Never>) in
                Task {
                    await cache.setOnActivity { sink.yield($0) }   // yields the current activity at once
                    var waiting: CheckedContinuation<Void, Never>? = first
                    for await activity in activities {
                        await store.setViewerActivity(activity)
                        waiting?.resume()
                        waiting = nil
                    }
                }
            }
        }
    }

    /// The first argument naming an existing file, for `swift run Loupe photo.jpg`. A `-Key value` pair
    /// (`-AppleLanguages (en)`, `-NSDocumentRevisionsDebugMode YES`) is a user-defaults override, so the
    /// token after each `-Key` is its value, never a path.
    private static func fileArgument(_ arguments: ArraySlice<String>) -> String? {
        var tokens = arguments.makeIterator()
        while let token = tokens.next() {
            if token.hasPrefix("-") {
                _ = tokens.next()
                continue
            }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: token, isDirectory: &isDirectory), !isDirectory.boolValue { return token }
        }
        return nil
    }

    /// Finder "Open With", `open -a Loupe file…` and drops on the Dock icon: every file, the first of each folder
    /// (spec §2.2), each to its tab (`WindowRegistry.open`).
    func application(_ application: NSApplication, open urls: [URL]) {
        guard !urls.isEmpty else { return }
        if isSecondary { Self.postHandOver(paths: urls.map(\.path)); return }
        guard !registry.controllers.isEmpty else {
            pendingURLs += urls
            return
        }
        for target in OpenRouter.firstPerFolder(Self.targets(urls)) { registry.open(target) }
    }

    /// What each URL is to the router: a directory is a folder to enter, anything else (a photo, a zip) a file.
    private static func targets(_ urls: [URL]) -> [OpenTarget] {
        urls.map { url in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue && !ArchivePath.isArchive(url) ? .folder(url) : .file(url)
        }
    }

    /// The delegate form of `NSApplication.didBecomeActiveNotification`: loupe.conf may have been edited
    /// in another app while this one was in the background.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !isSecondary else { return }
        let showBlurry = Settings.shared.config.showBlurry
        Settings.shared.reload()
        // A photo waiting to be sharp enough may qualify under the new rule.
        let showBlurryChanged = Settings.shared.config.showBlurry != showBlurry
        for controller in registry.controllers {
            if showBlurryChanged { controller.session.refresh() }
            // Files may have come or gone while Loupe was in the background (spec §4.5): each tab that can be seen
            // re-reads its folder, the others once they are shown (`FolderWatcher`).
            controller.forgetFolderListings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        if let handOverObserver { DistributedNotificationCenter.default().removeObserver(handOverObserver) }
        if !isSecondary {
            // Every tab's photo keeps its zoom and position; the active window's full screen is the one restored.
            for controller in registry.controllers { controller.session.recordView() }
            registry.active?.rememberFullScreenAtQuit()
            registry.saveLastNow()
            positions.flush()
            recent?.flush()
            folderSettings?.flush()
        }
    }

    /// `Loupe.db` in Application Support, or nil (positions and folder settings then live in memory for this
    /// run) when it cannot be opened.
    private static func openStateDatabase() -> StateDatabase? {
        guard let directory = StateDatabase.defaultDirectory else { return nil }
        do {
            return try StateDatabase(directory: directory)
        } catch {
            FileHandle.standardError.write(Data("loupe: \(directory.path)/Loupe.db unusable, keeping folder state in memory: \(error)\n".utf8))
            return nil
        }
    }

    // MARK: Single instance

    /// The different running copy of Loupe that launched before us and so must keep running, if any.
    /// Keyed by bundle id, or by executable path for a raw binary launch with no bundle.
    private static func primaryInstance() -> NSRunningApplication? {
        func instance(_ app: NSRunningApplication) -> RunningInstance? {
            guard let key = app.bundleIdentifier ?? app.executableURL?.path else { return nil }
            return RunningInstance(pid: app.processIdentifier, key: key, launchDate: app.launchDate)
        }
        guard let me = instance(.current) else { return nil }
        let apps = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        guard let primary = SingleInstance.primary(over: me, among: apps.compactMap(instance)) else { return nil }
        return apps.first { $0.processIdentifier == primary.pid }
    }

    /// Passes this launch's file to the running instance and quits without ever building a window.
    private func becomeSecondary(_ primary: NSRunningApplication) {
        isSecondary = true
        DebugLog.log("single instance: handing over to pid \(primary.processIdentifier)")
        // We are the active app; on macOS 14+ the primary's own activate() may be refused unless we yield.
        NSApp.yieldActivation(to: primary)
        if let path = Self.fileArgument(CommandLine.arguments.dropFirst()) {
            Self.postHandOver(paths: [URL(fileURLWithPath: path).path])
        } else {
            Self.postHandOver(paths: pendingURLs.map(\.path))   // none: just bring the running window forward
        }
        // A Finder open event can still arrive after launch; application(_:open:) forwards it while we wait.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
    }

    private static func postHandOver(paths: [String]) {
        DistributedNotificationCenter.default().postNotificationName(
            openFileNotification, object: nil, userInfo: ["paths": paths], deliverImmediately: true)
    }

    private func observeHandOver() {
        handOverObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.openFileNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, !self.isSecondary, let front = self.registry.current ?? self.registry.controllers.last else { return }
                // Any process can post this name, so only absolute paths to existing files and folders are opened.
                let paths = note.userInfo?["paths"] as? [String] ?? []
                DebugLog.log("single instance: hand-over received paths=\(paths.isEmpty ? "none" : paths.joined(separator: ", "))")
                let urls = paths.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0) }.filter {
                    let values = try? $0.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
                    return values?.isRegularFile == true || values?.isDirectory == true
                }
                // Nothing to open: the running window comes forward, as it would for a file.
                guard !urls.isEmpty else { return front.bringToFront() }
                for target in OpenRouter.firstPerFolder(Self.targets(urls)) { self.registry.open(target) }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Closing the last photo window quits Loupe, as before the settings window: an open settings window closes with it
    /// (a field being edited is written first), so the last-window rule above still applies. Not while quitting.
    private func observeLastViewerClose() {
        registry.onLastClosed = { [weak self] in
            guard let self, !self.isTerminating else { return }
            DebugLog.log("last viewer closed: settings window closes too")
            SettingsPanel.close()
        }
    }

    /// File › Reopen Closed Tab (⇧⌘T): the tab closed last, beside the current one.
    @objc func reopenClosedTab(_ sender: Any?) { registry.reopenClosedTab() }

    @objc func openDocument(_ sender: Any?) {
        let panel = ViewerWindowController.makeOpenPanel()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        registry.open(.file(url))
    }

    /// File › Open in New Tab… / Open in New Window… while the key window is not a viewer (Settings), the same way as
    /// New Tab: a viewer's own come first in its responder chain.
    @objc func openInNewTab(_ sender: Any?) { openPicked(force: .tab) }
    @objc func openInNewWindow(_ sender: Any?) { openPicked(force: .window) }

    private func openPicked(force: OpenForce) {
        let panel = ViewerWindowController.makeOpenPanel()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        registry.open(.file(url), force: force)
    }

    /// File › Home (⇧⌘H) while the key window is not a viewer (Settings): Home in the current viewer tab.
    @objc func showHomeScreen(_ sender: Any?) { registry.current?.showHome() }

    /// File › Clear Recent: every Recent card goes (Home spec §2.3); a Home on screen shows it at once.
    @objc func clearRecent(_ sender: Any?) {
        recent?.hideAll()
        for controller in registry.controllers where controller.isShowingRecent {
            controller.showHome(tab: .recent)
        }
    }

    /// Window › Next Tab (⌘⇧]) and Previous Tab (⌘⇧[): the key window's tab group, as ⌃Tab / ⌃⇧Tab.
    @objc func showNextTab(_ sender: Any?) { NSApp.keyWindow?.selectNextTab(sender) }
    @objc func showPreviousTab(_ sender: Any?) { NSApp.keyWindow?.selectPreviousTab(sender) }

    /// File › New Tab (⌘T) while the key window is not a viewer (Settings): a tab in the current viewer's window. A
    /// viewer's own `newWindowForTab` comes first in its responder chain.
    @objc func newWindowForTab(_ sender: Any?) { registry.newTab() }

    /// File › New Window (⌘N), the same way.
    @objc func newViewerWindow(_ sender: Any?) { registry.newWindow() }

    /// File › Show in Finder (`⌘R`, M4a spec §2.5): Finder opens the photo's folder with the file selected. With two
    /// pages on screen it is the current page (the one the last step landed on: the pair's first page after a step).
    @objc func showInFinder(_ sender: Any?) {
        guard let url = registry.current?.session.playlist?.current else { return }
        NSWorkspace.shared.activateFileViewerSelecting([ArchivePath.split(url)?.archive ?? url])
    }

    /// File › Copy Path (⌥⌘C, as Finder's Copy as Pathname): the photo's path; in an archive, the archive's and the
    /// inner path. With two pages on screen, the current page's, as Show in Finder.
    @objc func copyPath(_ sender: Any?) {
        guard let url = registry.current?.session.playlist?.current else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ArchivePath.copyText(url), forType: .string)
    }

    /// Loupe › About Loupe: the standard panel naming the build (BuildInfo), its credits selectable to copy.
    @objc func showAbout(_ sender: Any?) {
        let build = BuildInfo(info: Bundle.main.infoDictionary ?? [:])
        let credits = NSAttributedString(string: build.credits, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion: build.version, .version: build.short, .credits: credits,
        ])
        NSApp.activate()
    }

    /// Loupe › Settings… (⌘,): the settings window, made with its store on the first call.
    @objc func showSettings(_ sender: Any?) {
        openSettings(page: nil)
    }

    private func openSettings(page: String?) {
        let settings = Settings.shared
        if settingsStore == nil {
            settingsStore = ConfigSettingsStore(
                fileURL: settings.fileURL, current: { Settings.shared.config }, reload: { Settings.shared.reload() },
                folder: { [weak self] in self?.settingsFolder() },
                // `clear` announces itself (`.folderSettingsChanged`, Settings.folderSettings).
                clearFolder: { [weak self] key, url in self?.folderSettings?.clear([key], for: url) })
            observeFolderNotes()
        }
        guard let store = settingsStore else { return }
        settings.settingsStore = store
        let context = SettingsPanelContext(configURL: settings.fileURL, inputURL: settings.inputFileURL,
                                           iconChoices: { Settings.appIconChoices() }, iconFolder: Settings.userIcons,
                                           translateKey: { KeyboardLayout.translate(keyCode: $0, shift: $1) },
                                           reloadInput: { Settings.shared.reload() },
                                           menuRows: { MenuShortcuts.rows() },
                                           catalogDirectory: Self.thumbnailDirectory,
                                           clearThumbnails: { [weak self] in
                                               await self?.confirmAndClearThumbnails() ?? false
                                           })
        SettingsPanel.show(store: store, context: context, page: page)
    }

    /// The settings window's folder (spec §4.3): the viewer's folder and what it records for itself (an ancestor's
    /// values are not this folder's, and «Use Default» could not drop them); nil before the first photo.
    private func settingsFolder() -> (url: URL, values: [String: String])? {
        guard let folderSettings, let folder = registry.current?.currentFolder else { return nil }
        return (url: folder, values: folderSettings.ownValues(for: folder))
    }

    /// The folder notes follow the viewer's folder, its values and the window in front. Made with the settings
    /// window, never at launch.
    private func observeFolderNotes() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [.folderSettingsChanged, .viewerFolderChanged, NSWindow.didBecomeMainNotification,
                                          NSWindow.didBecomeKeyNotification]
        for name in names {
            folderNoteObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { SettingsPanel.refreshFolderOverrides() }
            })
        }
    }

    /// Show in Finder needs a photo.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(showInFinder(_:)) || item.action == #selector(copyPath(_:)) {
            return registry.current?.session.playlist?.current != nil
        }
        if item.action == #selector(reopenClosedTab(_:)) { return registry.canReopenTab }
        if item.action == #selector(showNextTab(_:)) || item.action == #selector(showPreviousTab(_:)) {
            return (NSApp.keyWindow?.tabGroup?.windows.count ?? 0) > 1
        }
        return true
    }

    /// File › Clean Up Thumbnails: forget the thumbnails of files gone from the mounted volumes.
    @objc func cleanUpThumbnails(_ sender: Any?) {
        guard let thumbnails else { return }
        DebugLog.log("thumbnails: clean up")
        Task { await thumbnails.cleanUp() }
    }

    /// File › Clear Thumbnail Cache…: after a confirmation, every thumbnail goes (the open folders' are made again).
    @objc func clearThumbnailCache(_ sender: Any?) {
        Task { await confirmAndClearThumbnails() }
    }

    /// The menu's and Settings › Performance › Catalog's: false when there is no store or the user cancelled.
    func confirmAndClearThumbnails() async -> Bool {
        guard let thumbnails else { return false }
        let alert = NSAlert()
        alert.messageText = "Clear the thumbnail cache?"
        alert.informativeText = "All thumbnails are deleted. Those of the open folders are made again in the background."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        DebugLog.log("thumbnails: clear")
        await thumbnails.clear()
        NotificationCenter.default.post(name: .thumbnailsCleared, object: nil)
        return true
    }

    /// An input.conf edit (read again on activation) moves the menus' keys: an item shows its action's new first key,
    /// or none when the file left it without one.
    private func observeSettings() {
        let center = NotificationCenter.default
        settingsObserver = center.addObserver(forName: .settingsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.divertMouseInputs()
                self.applyMouseSettings()
                self.refreshStashItem()
                self.registry.controllers.forEach { $0.stashSettingsChanged() }
                guard let menu = NSApp.mainMenu, Settings.shared.inputMap != self.menuInputMap else { return }
                self.menuInputMap = Settings.shared.inputMap
                NSMenuItem.refreshShownKeys(in: menu)
            }
        }
    }

    // MARK: Logitech mouse (M4c spec §3.1, §5)

    /// The mouse after the window is up (its search runs off the launch path): the bound `MX_*` buttons and, with a
    /// `+MX_THUMB` binding, the thumb wheel diverted while Loupe is in front (`follow`), the side buttons watched or
    /// taken by `mx-side-buttons` (§12.1), their events into `MouseButtons`, and the mouse as `MouseHaptics`' player.
    /// No mouse: nothing arrives, nothing fails.
    private func startLogiMouse() {
        let mouse = LogiMouse()
        logiMouse = mouse
        MouseButtons.shared.heardSideButtons = { [weak mouse] in Set(mouse?.watching.map(\.rawValue) ?? []) }
        divertMouseInputs()
        applyMouseSettings()
        mouse.start()
        mouse.follow(app: NSApp)
        MouseHaptics.shared.player = LogiHapticPlayer(mouse: mouse)
        Task { @MainActor in
            for await event in mouse.events { Self.handle(event, from: mouse) }
        }
    }

    /// Diverts what the layout binds, plus the side buttons with `mx-side-buttons=take`, and watches them with `watch`
    /// (M4c spec §12.1), when that changed since the last call (a reload of input.conf or loupe.conf).
    private func divertMouseInputs() {
        guard let logiMouse else { return }
        let map = Settings.shared.inputMap
        let side = Settings.shared.config.mxSideButtons
        let wanted = (cids: map.divertedCIDs.union(side.divertedCIDs), watched: side.watchedCIDs,
                      thumbWheel: map.wantsThumbWheel || Settings.shared.config.thumbWheelZoom)
        if let divertedInputs, divertedInputs == wanted { return }
        divertedInputs = wanted
        DebugLog.log("mx divert \(wanted.cids.sorted().map(Self.hex)) watch \(wanted.watched.sorted().map(Self.hex)) "
                     + "thumb wheel \(wanted.thumbWheel)")
        logiMouse.divert(Set(wanted.cids.map { CID(rawValue: $0) }))
        logiMouse.watch(Set(wanted.watched.map { CID(rawValue: $0) }))
        logiMouse.divertThumbWheel(wanted.thumbWheel)
    }

    /// The mouse's own settings from loupe.conf (M4c spec §10.3, §10.4): `haptic-strength` when it changed since the
    /// last call (the package keeps it and writes it at every setup), and `mx-panel-force` once the mouse has reported
    /// its range (here when connected, again on `.connected`). `keep` writes nothing; a value written earlier in this
    /// run stays in the mouse (and the package writes it again on reconnect) until Loupe quits.
    private func applyMouseSettings() {
        guard let logiMouse else { return }
        if let strength = Settings.shared.config.hapticStrength, strength != appliedHapticStrength {
            appliedHapticStrength = strength
            DebugLog.log("mx haptic strength \(strength)")
            logiMouse.setHapticStrength(UInt8(strength))   // Config holds it to 0…100
        }
        Self.applyPanelForce(to: logiMouse)
    }

    /// `mx-panel-force` mapped over the range the mouse reported; nothing before the mouse is set up, for `keep`, for
    /// a force the mouse does not let change, or when the mouse already has that value.
    private static func applyPanelForce(to mouse: LogiMouse) {
        guard let force = mouse.panelForce, force.info.changeable,
              let value = Settings.shared.config.mxPanelForce.value(range: force.info.range,
                                                                   defaultValue: force.info.defaultValue),
              value != force.current else { return }
        DebugLog.log("mx panel force \(force.current) -> \(value) (\(Settings.shared.config.mxPanelForce.text), range "
                     + "\(force.info.range.lowerBound)…\(force.info.range.upperBound))")
        mouse.setPanelForce(value)
    }

    /// A button by its control ID goes to `MouseButtons` like an AppKit button; an unknown ID is ignored. A watched
    /// side button (`mx-side-buttons=watch`) comes the same way as a diverted one, through `AppKitButtonFilter`. Times
    /// are taken on delivery, on NSEvent's clock (`systemUptime`): the package's own clock may be another.
    private static func handle(_ event: MouseEvent, from mouse: LogiMouse) {
        let now = ProcessInfo.processInfo.systemUptime
        switch event {
        case .pressed(let cid, _):
            DebugLog.log("mx pressed \(hex(cid.rawValue))")
            // Watched, not taken: the system delivers it too (only the side buttons, with `mx-side-buttons=watch`).
            let watched = Settings.shared.config.mxSideButtons == .watch
                && SideButtonsMode.watch.watchedCIDs.contains(cid.rawValue)
            if let b = button(cid) { MouseButtons.shared.mousePress(b, at: now, watched: watched) }
        case .released(let cid, _):
            DebugLog.log("mx released \(hex(cid.rawValue))")
            if let b = button(cid) { MouseButtons.shared.mouseRelease(b, at: now) }
        case .thumbWheel(let delta, let touching, let phase, _):
            DebugLog.log("mx thumb wheel \(delta) touching \(touching) \(phase) "
                         + "per turn \(mouse.stepsPerRevolution ?? 0)")
            // The turn size comes with the mouse's setup, before the package reports any wheel step; a step without it
            // (which should not happen) cannot be scaled to `input.conf`'s steps and is dropped, logged above.
            // With no button holding it, the wheel zooms (`thumb-wheel-zoom`) in the key window's viewer.
            if let perTurn = mouse.stepsPerRevolution,
               !MouseButtons.shared.thumbWheel(delta: delta, stepsPerRevolution: perTurn),
               Settings.shared.config.thumbWheelZoom {
                // On Home the same wheel sizes the cards, the way it zooms a photo.
                if let controller = NSApp.keyWindow?.windowController as? ViewerWindowController, controller.isShowingHome {
                    controller.homeThumbWheel(delta: delta, stepsPerRevolution: perTurn)
                }
                MouseButtons.shared.target()?.thumbWheelZoom(delta: delta, stepsPerRevolution: perTurn,
                                                             began: phase == .began)
            }
        case .connected:
            DebugLog.log("mx connected")
            applyPanelForce(to: mouse)
        case .disconnected:
            DebugLog.log("mx disconnected")
        case .highResolutionWheel:
            break   // Loupe never asks for the hi-res wheel.
        case .wheelMode:
            break   // Loupe never asks for a wheel mode.
        }
    }

    private static func button(_ cid: CID) -> MouseButton? { MouseButton(cid: cid.rawValue) }

    private static func hex(_ cid: UInt16) -> String { "0x" + String(format: "%04x", cid) }

    /// File › Stash Library's tag, to find it again (`refreshStashItem`).
    private static let stashItemTag = 0x5354

    /// File › Stash Library shows only with `stash-url`.
    private func refreshStashItem() {
        let item = NSApp.mainMenu?.items.lazy.compactMap { $0.submenu?.item(withTag: Self.stashItemTag) }.first
        item?.isHidden = Settings.shared.config.stashURL == nil
    }

    private static func makeMainMenu() -> MainMenu {
        let main = MainMenu()

        let app = NSMenu(title: "Loupe")
        app.addItem(withTitle: "About Loupe", action: #selector(showAbout(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Loupe", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Loupe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: app, title: "Loupe")

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New Window", action: #selector(newViewerWindow(_:)), keyEquivalent: "n")
        // The standard selector: the tab bar's + sends it too.
        file.addItem(withTitle: "New Tab", action: #selector(newWindowForTab(_:)), keyEquivalent: "t")
        file.addItem(withTitle: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        file.addItem(withTitle: "Open in New Tab…", action: #selector(openInNewTab(_:)), keyEquivalent: "o")
            .keyEquivalentModifierMask = [.command, .option]
        file.addItem(withTitle: "Open in New Window…", action: #selector(openInNewWindow(_:)), keyEquivalent: "o")
            .keyEquivalentModifierMask = [.command, .shift]
        file.addItem(withTitle: "Show in Finder", action: #selector(showInFinder(_:)), keyEquivalent: "r")
        file.addItem(withTitle: "Copy Path", action: #selector(copyPath(_:)), keyEquivalent: "c")
            .keyEquivalentModifierMask = [.command, .option]
        file.addItem(.separator())
        // A viewer's own `showHomeScreen` comes first in its responder chain.
        file.addItem(withTitle: "Home", action: #selector(showHomeScreen(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .shift]
        // Retitled Show Sidebar while it is hidden; on Home only.
        file.addItem(withTitle: "Hide Sidebar", action: #selector(ViewerWindowController.toggleHomeSidebar(_:)),
                     keyEquivalent: "s").keyEquivalentModifierMask = [.control, .command]
        // Retitled Back to Recent / Back to Stash (ViewerWindowController validates it); in Stash's page ⌘[ is the page's.
        file.addItem(withTitle: "Back", action: #selector(ViewerWindowController.goBack(_:)), keyEquivalent: "[")
        file.addItem(withTitle: "Clear Recent", action: #selector(clearRecent(_:)), keyEquivalent: "")
        // Home's own keys (⌘= / ⌘− / ⌘0, ⌘ + wheel, pinch, the MX side wheel); listed here to be found in Help.
        file.addItem(withTitle: "Larger Cards", action: #selector(ViewerWindowController.largerCards(_:)), keyEquivalent: "")
        file.addItem(withTitle: "Smaller Cards", action: #selector(ViewerWindowController.smallerCards(_:)), keyEquivalent: "")
        file.addItem(withTitle: "Default Card Size", action: #selector(ViewerWindowController.defaultCardSize(_:)),
                     keyEquivalent: "")
        file.addItem(withTitle: "Save Session As…", action: #selector(ViewerWindowController.saveSessionAs(_:)),
                     keyEquivalent: "")
        file.addItem(.separator())
        file.addItem(withTitle: "Clean Up Thumbnails", action: #selector(cleanUpThumbnails(_:)), keyEquivalent: "")
        file.addItem(withTitle: "Clear Thumbnail Cache…", action: #selector(clearThumbnailCache(_:)), keyEquivalent: "")
        file.addItem(.separator())
        // Shown only with `stash-url` (`refreshStashItem`).
        let stash = file.addItem(withTitle: "Stash Library", action: #selector(ViewerWindowController.showStashLibrary(_:)),
                                 keyEquivalent: "l")
        stash.keyEquivalentModifierMask = [.command, .shift]
        stash.tag = stashItemTag
        file.addItem(.separator())
        // ⌘W closes the tab, ⇧⌘W the window with all its tabs, ⇧⌘T brings the last closed tab back, as in a browser.
        file.addItem(withTitle: "Close Tab", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "Close Window", action: #selector(ViewerWindowController.closeWindow(_:)), keyEquivalent: "w")
            .keyEquivalentModifierMask = [.command, .shift]
        file.addItem(withTitle: "Reopen Closed Tab", action: #selector(reopenClosedTab(_:)), keyEquivalent: "t")
            .keyEquivalentModifierMask = [.command, .shift]
        main.addItem(submenu: file, title: "File")

        // The standard text commands, for the settings window's fields (and the info panel's values). Nil targets:
        // the first responder answers, so in the viewer they are disabled; every item has ⌘, so no plain key of the
        // viewer is taken (`MainMenu`), and none of the viewer's own ⌘ items uses Z, X, C, V or A.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: edit, title: "Edit")

        let view = NSMenu(title: "View")
        // How Home's browser draws a folder's folders and archives (folder cards spec): ⌥⌘1–⌥⌘3 (`CardStyleKeys`; ⌘
        // digits are the tabs'), on Home on a folder only, checked at its style (ViewerWindowController validates
        // them; `CardStyleMenuReset` unchecks them where no viewer answers). Elsewhere `MainMenu` lets the keys go on.
        for (index, title) in ["as Posters", "as Cards", "as List"].enumerated() {
            let item = view.addItem(withTitle: title, action: #selector(ViewerWindowController.chooseCardStyle(_:)),
                                    keyEquivalent: String(index + 1))
            item.keyEquivalentModifierMask = [.option, .command]
            item.tag = index
        }
        view.delegate = CardStyleMenuReset.shared
        // The toolbar pill's popover for the key window's Home (thumbs-ahead spec): also there while a narrow window
        // hides the pill; off with nothing being prepared.
        view.addItem(withTitle: "Thumbnails…", action: #selector(ViewerWindowController.showThumbsProgress(_:)),
                     keyEquivalent: "")
        view.addItem(.separator())
        // AppKit retitles this item "Exit Full Screen" while the window is in full screen.
        let fullScreen = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.control, .command]
        view.addItem(.separator())
        let toolbar = view.addItem(withTitle: "Toggle Toolbar", action: #selector(ViewerWindowController.toggleViewerToolbar(_:)),
                                   keyEquivalent: "t")
        toolbar.keyEquivalentModifierMask = [.option, .command]
        let tuning = view.addItem(withTitle: "Pocket Tuning…", action: #selector(ViewerWindowController.showPocketTuning(_:)),
                                  keyEquivalent: "t")
        tuning.keyEquivalentModifierMask = [.option, .command, .shift]
        // The same pin as `T` in the viewer, whose key it shows; the checkmark is the pin (ViewerWindowController
        // validates it). `F` toggles full screen in the viewer too; the item shows the macOS-standard key.
        let strip = view.addItem(withTitle: "Thumbnail Strip", action: #selector(ViewerWindowController.toggleThumbnailStrip(_:)),
                                 keyEquivalent: "")
        strip.showKey(of: .toggleStrip)
        // The same as `⇧T`, whose key it shows: beside ↔ over, written to loupe.conf; checked while `beside`.
        let placement = view.addItem(withTitle: "Strip Beside the Photo",
                                     action: #selector(ViewerWindowController.toggleStripPlacement(_:)), keyEquivalent: "")
        placement.showKey(of: .toggleStripPlacement)
        // The same as `I`, whose key it shows; the checkmark reflects the status card's visibility.
        let stats = view.addItem(withTitle: "Image Status", action: #selector(ViewerWindowController.toggleStatsBar(_:)),
                                 keyEquivalent: "")
        stats.showKey(of: .cycleStats)
        // Retitled Hide Info while the panel is open (ViewerWindowController validates it).
        view.addItem(withTitle: "Show Info", action: #selector(ViewerWindowController.toggleInfoPanel(_:)), keyEquivalent: "i")
        // The Dock icon picker (Settings), the same choices as the settings window's `app-icon` pop-up.
        let icon = view.addItem(withTitle: "App Icon…", action: #selector(Settings.showIconPicker(_:)), keyEquivalent: "i")
        icon.keyEquivalentModifierMask = [.control, .option, .command]
        icon.target = Settings.shared
        // The session's mode in every window, checked (Settings); `P` is its Next Mode item, `⇧P` the item below.
        view.addItem(submenu: Settings.shared.makePanIndicatorsMenu(), title: "Pan Indicators")
        view.addItem(.viewerKey("Save Pan Indicators as Default", .savePanIndicators))
        view.addItem(.separator())
        // Two pages (spread spec 2026-10-23): the same as `D` and `⌥D`, whose keys they show, checked at the window's
        // folder values (ViewerWindowController validates them); Right to Left has no key and writes the folder's
        // `spread-direction`; `⇧D` saves.
        let spread = view.addItem(withTitle: "Two Pages", action: #selector(ViewerWindowController.toggleTwoPages(_:)),
                                  keyEquivalent: "")
        spread.showKey(of: .toggleSpread)
        let shift = view.addItem(withTitle: "Shift Pages", action: #selector(ViewerWindowController.toggleShiftPages(_:)),
                                 keyEquivalent: "")
        shift.showKey(of: .shiftSpread)
        view.addItem(withTitle: "Right to Left", action: #selector(ViewerWindowController.toggleRightToLeft(_:)),
                     keyEquivalent: "")
        view.addItem(withTitle: "Landscape Pages Alone",
                     action: #selector(ViewerWindowController.toggleLandscapeAlone(_:)), keyEquivalent: "")
        view.addItem(.viewerKey("Save Two Pages as Default", .saveSpread))
        main.addItem(submenu: view, title: "View")

        main.addItem(submenu: Settings.shared.makeZoomMenu(), title: "Zoom")
        main.addItem(submenu: Settings.shared.makeScalingMenu(), title: "Scaling")
        main.addItem(submenu: Settings.shared.makeColourMenu(), title: "Colour")

        // AppKit adds the tab items (Show Tab Bar, Show All Tabs, Show Previous / Next Tab ⌃⇧Tab / ⌃Tab, Move Tab to
        // New Window, Merge All Windows) and the window list to the windows menu.
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        // ⌘⇧] / ⌘⇧[ (spec §2.1): AppKit gives only ⌃Tab / ⌃⇧Tab. Selectors of our own, so that AppKit, which adds
        // its tab items (Show Next Tab ⌃Tab, Move Tab to New Window, …) only where they are missing, still adds them.
        // `}` / `{` with ⌘, as Safari and Finder have them: the shifted bracket is what the keyboard sends.
        window.addItem(withTitle: "Next Tab", action: #selector(showNextTab(_:)), keyEquivalent: "}")
        window.addItem(withTitle: "Previous Tab", action: #selector(showPreviousTab(_:)), keyEquivalent: "{")
        window.addItem(.separator())
        main.addItem(submenu: window, title: "Window")
        NSApp.windowsMenu = window

        // macOS puts its search over every menu item at the top of the help menu.
        let help = NSMenu(title: "Help")
        help.addItem(.viewerKey("Keyboard Shortcuts", .cheatSheet))
        main.addItem(submenu: help, title: "Help")
        NSApp.helpMenu = help

        return main
    }
}

/// The menu bar. It matches only keys with ⌘ or ⌃: every item of its own (Hide, Quit, Open…, Show in Finder, Close,
/// Enter Full Screen, Show Info) carries one, and the plain keys the View, Zoom, Scaling and Colour items show (`T`, `S`,
/// `0`, …) are the viewer's, which it claims before the menu is asked (`ViewerView.performKeyEquivalent`). Declining
/// them here keeps them typing in any other key window: the modal Open panel's search field and Go To Folder sheet would
/// otherwise lose `t`, `i` or `?` to a View item (a matching item takes the key even when disabled). The Zoom, Scaling
/// and Colour menus also decline them through their delegate (`Settings.menuHasKeyEquivalent`).
///
/// The browser's tab chords no item carries (⌘1…⌘9, ⌥⌘→ / ⌥⌘←, `BrowserTabKeys`) go to `onTabKey` first; it declines
/// them outside a viewer window. ⌥⌘1–⌥⌘3 (`CardStyleKeys`) reach View › as Posters / as Cards / as List only while
/// the key window can choose a card style: elsewhere (the settings window and its key recorder, the Open panel) a
/// disabled item would take them.
final class MainMenu: NSMenu {
    var onTabKey: ((BrowserTabKeys.Key) -> Bool)?
    var canChooseCardStyle: (() -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !event.modifierFlags.isDisjoint(with: [.command, .control]) else { return false }
        let flags = event.modifierFlags
        if event.type == .keyDown,
           CardStyleKeys.match(keyCode: event.keyCode, command: flags.contains(.command), shift: flags.contains(.shift),
                               option: flags.contains(.option), control: flags.contains(.control)) != nil,
           canChooseCardStyle?() != true {
            return false
        }
        if event.type == .keyDown,
           let key = BrowserTabKeys.match(keyCode: event.keyCode, command: flags.contains(.command),
                                          shift: flags.contains(.shift), option: flags.contains(.option),
                                          control: flags.contains(.control)),
           onTabKey?(key) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The View menu's delegate: before it opens or matches a key, its card style items lose their checkmark, which the
/// key viewer's `validateMenuItem` puts back on its style; with no viewer answering (the settings window in front)
/// none stays checked from before.
@MainActor final class CardStyleMenuReset: NSObject, NSMenuDelegate {
    static let shared = CardStyleMenuReset()

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.action == #selector(ViewerWindowController.chooseCardStyle(_:)) {
            item.state = .off
        }
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}

/// `MouseHaptics`' player: the pattern on the Logitech mouse, strong plays at their strength.
@MainActor private final class LogiHapticPlayer: HapticPlaying {
    private let mouse: LogiMouse

    init(mouse: LogiMouse) { self.mouse = mouse }

    func play(_ pattern: HapticPattern, strength: UInt8?) {
        mouse.play(haptic: pattern, strength: strength)
    }
}
