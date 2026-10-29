#if DEBUG
import AppKit
import LoupeCore
import LoupeRender

/// Real-window integration check for the shared native full-screen toolbar policy.
/// Uses an empty session and disposable configuration; never opens user media.
@MainActor enum NativeToolbarBench {
    static func run() async -> Never {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("loupe-native-toolbar-bench")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        setenv("LOUPE_CONFIG_DIR", scratch.path, 1)
        Settings.shared.reload(applyingIcon: false)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
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
            report.append("\(condition ? "PASS" : "FAIL") \(name)")
            if !condition { failed = true }
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
        for round in 1...3 {
            let start = ThreadCPU.milliseconds()
            controller.showHome(tab: .recent)
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            let homeToolbar = window.toolbar
            let homeCPU = ThreadCPU.milliseconds() - start
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
        center.removeObserver(enter); center.removeObserver(leave)
        let text = report.joined(separator: "\n") + "\n"
        await Task.detached(priority: .utility) {
            try? text.write(to: scratch.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
        }.value
        controller.session.close()
        exit(failed ? 1 : 0)
    }
}
#endif
