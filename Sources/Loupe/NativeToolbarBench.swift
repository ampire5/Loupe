#if DEBUG
import AppKit
import LoupeCore
import LoupeRender

/// Real-window integration check for Photos-style native toolbar pinning.
/// Uses an empty session and disposable configuration; never opens user media.
@MainActor enum NativeToolbarBench {
    static func run() async -> Never {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("loupe-native-toolbar-bench")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        // Do not browse NSTemporaryDirectory: following its ancestors can expose
        // tens of thousands of host build directories in the sidebar. Keep the
        // browser fixture under the workspace's ignored build directory instead.
        let fixturePath = Bundle.main.object(forInfoDictionaryKey: "LoupeToolbarBenchFolder") as? String
        let fixture = fixturePath.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("build/NativeToolbarBench", isDirectory: true)
        try? FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let preferenceKeys = ["viewerToolbar", "fullScreenToolbar", "fullScreenStatus", "statsMode"]
        let savedPreferences = Dictionary(uniqueKeysWithValues: preferenceKeys.compactMap { key in
            UserDefaults.standard.object(forKey: key).map { (key, $0) }
        })
        let detectorSuite = "loupe.native-toolbar-bench.\(ProcessInfo.processInfo.processIdentifier)"
        setenv("LOUPE_DETECTOR_PREFERENCES_SUITE", detectorSuite, 1)
        setenv("LOUPE_CONFIG_DIR", scratch.path, 1)
        Settings.shared.reload(applyingIcon: false)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        // Native full-screen reveal needs a real application menu, as the app has.
        let menu = NSMenu()
        let appMenu = NSMenuItem()
        appMenu.submenu = NSMenu(title: "Loupe Toolbar Probe")
        appMenu.submenu?.addItem(withTitle: "Quit Probe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(appMenu)
        app.mainMenu = menu
        app.finishLaunching()
        let reader = FileReader(threads: 1)
        let cache = ImageCache(loader: MetalPyramidLoader(), reader: reader, pool: DecodePool(), limits: CacheLimits(config: Config()))
        let thumbs = ThumbnailStore(directory: nil, reader: reader, thumbSize: 320, limitBytes: 0)
        let controller = ViewerWindowController(cache: cache, thumbnails: thumbs, thumbnailsReady: nil,
            positions: FolderPositions(database: nil), folderSettings: FolderSettings(database: nil), recent: nil)
        let window = controller.window!
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        var entered = false, exited = false
        let center = NotificationCenter.default
        let enter = center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { entered = true }
        }
        let leave = center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { exited = true }
        }
        var report: [String] = [], failed = false
        func check(_ name: String, _ condition: Bool) {
            let line = "\(condition ? "PASS" : "FAIL") \(name)"
            report.append(line)
            print(line)
            fflush(stdout)
            if !condition { failed = true }
        }
        func hasExtendedBackground(_ view: NSView) -> Bool {
            if #available(macOS 26.0, *), view is NSBackgroundExtensionView { return true }
            return view.subviews.contains(where: hasExtendedBackground)
        }
        let proposed: NSApplication.PresentationOptions = [.fullScreen, .autoHideMenuBar, .autoHideDock]
        check("delegate requests native auto-hide", controller.window(window, willUseFullScreenPresentationOptions: proposed).contains(.autoHideToolbar))
        window.toggleFullScreen(nil)
        for _ in 0..<250 {
            if entered { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        check("entered full screen", entered)
        check("system accepted native auto-hide", app.currentSystemPresentationOptions.contains(.autoHideToolbar))
        let viewerToolbar = window.toolbar
        func nativeHost(_ toolbar: NSToolbar?) -> NSWindow? {
            toolbar?.items.compactMap(\.view).compactMap(\.window).first
        }
        check("viewer hosted by native full-screen window", nativeHost(viewerToolbar) != nil && nativeHost(viewerToolbar) !== window)
        UserDefaults.standard.set(true, forKey: "fullScreenStatus")
        let statusBar = window.contentView?.subviews.compactMap { $0 as? StatsBar }.first
        let pinStart = ThreadCPU.milliseconds()
        controller.toggleToolbarPin()
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        check("B pins viewer native toolbar in full screen", (window.contentView?.safeAreaInsets.top ?? 0) > 0)
        check("pinned toolbar suppresses stats", statusBar?.isHidden == true)
        let statusMenu = NSMenuItem(title: "Image Status", action: #selector(ViewerWindowController.toggleStatsBar(_:)), keyEquivalent: "")
        _ = controller.validateMenuItem(statusMenu)
        check("pinned stats menu reports actual hidden state", statusMenu.state == .off)
        report.append(String(format: "B pin CPU %.3f ms", ThreadCPU.milliseconds() - pinStart))
        let unpinStart = ThreadCPU.milliseconds()
        controller.toggleToolbarPin()
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        check("B restores native autohiding", window.contentView?.safeAreaInsets.top == 0)
        check("unpin restores saved stats visibility", statusBar?.isHidden == false)
        report.append(String(format: "B unpin CPU %.3f ms", ThreadCPU.milliseconds() - unpinStart))
        for round in 1...3 {
            let start = ThreadCPU.milliseconds()
            controller.showHome(tab: .recent)
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            let homeToolbar = window.toolbar
            let homeCPU = ThreadCPU.milliseconds() - start
            check("round \(round): Home reserves native toolbar safe area", (window.contentView?.safeAreaInsets.top ?? 0) > 0)
            check("round \(round): Home draws the native titlebar backdrop", !window.titlebarAppearsTransparent)
            check("round \(round): Home does not reflect browser content under toolbar", !hasExtendedBackground(window.contentView!))
            if #available(macOS 26.0, *), let browser = controller.browserView {
                // Without a background-extension wrapper the browser itself
                // spans the content view and its native safe area supplies the
                // toolbar inset. Check that usable area, not the outer frame.
                let usableTop = browser.convert(browser.safeAreaLayoutGuide.frame, to: nil).maxY
                check("round \(round): browser content stays below native toolbar", usableTop <= window.contentLayoutRect.maxY + 0.5)
                check("round \(round): browser avoids a second toolbar inset", abs(usableTop - window.contentLayoutRect.maxY) < 0.5)
            }
            // NSToolbar schedules item attachment for the next AppKit update. A
            // synchronous layout of the content view does not run that update.
            for _ in 0..<25 {
                if nativeHost(homeToolbar) != nil && nativeHost(homeToolbar) !== window { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            check("round \(round): same toolbar with Home items", homeToolbar === viewerToolbar && homeToolbar?.isVisible == true && homeToolbar?.items.contains(where: { $0.itemIdentifier.rawValue.hasPrefix("home.") }) == true)
            check("round \(round): Home hosted by native full-screen window", nativeHost(homeToolbar) != nil && nativeHost(homeToolbar) !== window)
            let returnStart = ThreadCPU.milliseconds()
            controller.hideHome()
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            let returnCPU = ThreadCPU.milliseconds() - returnStart
            check("round \(round): viewer toolbar auto-hides over full content", window.contentView?.safeAreaInsets.top == 0)
            check("round \(round): viewer keeps native titlebar backdrop", !window.titlebarAppearsTransparent)
            for _ in 0..<25 {
                if nativeHost(viewerToolbar) != nil && nativeHost(viewerToolbar) !== window { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            check("round \(round): viewer toolbar restored and enabled", window.toolbar === viewerToolbar && viewerToolbar?.isVisible == true)
            check("round \(round): viewer reattached to native full-screen window", nativeHost(viewerToolbar) != nil && nativeHost(viewerToolbar) !== window)
            check("round \(round): native auto-hide retained", app.currentSystemPresentationOptions.contains(.autoHideToolbar))
            report.append(String(format: "round %d Home CPU %.3f ms; viewer CPU %.3f ms", round, homeCPU, returnCPU))
            try? await Task.sleep(for: .milliseconds(100))
        }
        controller.showHome(tab: .folders)
        controller.browserView?.show(.folder(fixture), selecting: nil)
        try? await Task.sleep(for: .milliseconds(150))
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        if let sort = window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "home.sort" })?.view as? NSSegmentedControl,
           let action = sort.action {
            let start = ThreadCPU.milliseconds()
            sort.selectedSegment = 1
            NSApp.sendAction(action, to: sort.target, from: sort)
            let elapsed = ThreadCPU.milliseconds() - start
            check("native sort selects date", sort.selectedSegment == 1 && sort.label(forSegment: 1)?.contains("Date") == true)
            report.append(String(format: "native sort CPU %.3f ms", elapsed))
        } else {
            check("native sort available in folder", false)
        }
        controller.hideHome()
        controller.toggleViewerToolbar(nil)
        check("toolbar shortcut disables viewer toolbar", viewerToolbar?.isVisible == false)
        controller.showHome(tab: .recent)
        check("Home stays enabled when viewer toolbar disabled", window.toolbar?.isVisible == true)
        controller.hideHome()
        check("return restores disabled viewer toolbar", viewerToolbar?.isVisible == false)
        controller.toggleViewerToolbar(nil)
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        check("toolbar shortcut re-enables native toolbar", viewerToolbar?.isVisible == true && nativeHost(viewerToolbar) != nil && nativeHost(viewerToolbar) !== window)
        window.toggleFullScreen(nil)
        for _ in 0..<250 {
            if exited { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        check("exited full screen", exited)
        check("windowed toolbar remains unified", window.toolbarStyle == .unified)
        // didExit is delivered before AppKit's deferred titlebar teardown/display.
        // Let that native update finish before starting a second transition.
        try? await Task.sleep(for: .milliseconds(300))
        controller.showHome(tab: .folders)
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))
        entered = false
        exited = false
        window.toggleFullScreen(nil)
        for _ in 0..<250 {
            if entered { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        check("entered full screen directly from Home", entered)
        check("direct Home entry reserves native toolbar safe area", (window.contentView?.safeAreaInsets.top ?? 0) > 0)
        check("direct Home entry draws the native titlebar backdrop", !window.titlebarAppearsTransparent)
        controller.hideHome()
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        check("viewer after direct Home entry auto-hides", window.contentView?.safeAreaInsets.top == 0)
        controller.showHome(tab: .folders)
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        check("Home repins after direct Home entry", (window.contentView?.safeAreaInsets.top ?? 0) > 0)
        window.toggleFullScreen(nil)
        for _ in 0..<250 {
            if exited { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        check("exited second full screen", exited)
        // An explicit pin must outrank fullscreen-toolbar=hidden, including
        // entry from a window and exit/re-entry with AppKit's host recreated.
        controller.hideHome()
        controller.toggleToolbarPin() // Legacy windowed visibility -> auto.
        controller.toggleToolbarPin() // Explicit B pin to carry into full screen.
        check("B pins windowed toolbar", window.toolbar?.isVisible == true)
        let originalFullScreenPolicy = Settings.shared.config.fullScreenToolbar.rawValue
        _ = Settings.shared.saveAsDefault(["fullscreen-toolbar": "hidden"])
        for round in 1...2 {
            entered = false; exited = false
            window.toggleFullScreen(nil)
            for _ in 0..<250 {
                if entered { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            check("pin entry \(round): enters full screen", entered)
            check("pin entry \(round): pin overrides hidden preference", (window.contentView?.safeAreaInsets.top ?? 0) > 0 && window.toolbar?.isVisible == true)
            if round == 2 {
                controller.toggleToolbarPin()
                window.contentView?.superview?.layoutSubtreeIfNeeded()
                check("B unpins after hidden-policy re-entry", window.contentView?.safeAreaInsets.top == 0)
                check("stats restore after pinned re-entry", statusBar?.isHidden == false)
            }
            window.toggleFullScreen(nil)
            for _ in 0..<250 {
                if exited { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            check("pin entry \(round): exits full screen", exited)
            try? await Task.sleep(for: .milliseconds(300))
        }
        _ = Settings.shared.saveAsDefault(["fullscreen-toolbar": originalFullScreenPolicy])
        center.removeObserver(enter); center.removeObserver(leave)
        let text = report.joined(separator: "\n") + "\n"
        await Task.detached(priority: .utility) {
            try? text.write(to: scratch.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
        }.value
        controller.session.close()
        for key in preferenceKeys {
            if let value = savedPreferences[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults(suiteName: detectorSuite)?.removePersistentDomain(forName: detectorSuite)
        exit(failed ? 1 : 0)
    }
}
#endif
