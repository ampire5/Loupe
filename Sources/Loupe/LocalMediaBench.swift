import AppKit
import HomeScreenKit
import LoupeCore
import LoupeRender
import Metal

/// Opt-in AppKit replay. A new process resets Loupe's cache. A second pass reuses the same live viewer.
@MainActor enum LocalMediaBench {
    static func run(root: URL, scenario: String) async -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        Settings.shared.reload(applyingIcon: false)
        let config = Settings.shared.config
        let reader = FileReader(threads: 4)
        let cache = ImageCache(loader: MetalPyramidLoader(filter: PyramidFilterSetting(config.pyramidFilter)), reader: reader, pool: DecodePool(), limits: CacheLimits(config: config))
        let catalog = ProcessInfo.processInfo.environment["LOUPE_BENCH_CATALOG"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        let thumbnails = ThumbnailStore(directory: catalog, reader: reader, thumbSize: config.thumbSize,
            limitBytes: config.thumbCacheBytes, cachedBytes: { await cache.cachedBytes($0, stamp: $1) })
        await thumbnails.setOnThumbnail { url in
            Task { @MainActor in NotificationCenter.default.post(name: .thumbnailChanged, object: url) }
        }
        let (activities, sink) = AsyncStream<CacheActivity>.makeStream(bufferingPolicy: .bufferingNewest(1))
        await cache.setOnActivity { sink.yield($0) }
        Task { for await activity in activities { await thumbnails.setViewerActivity(activity) } }
        let folderSettings = FolderSettings(database: nil)
        Settings.shared.folderSettings = folderSettings
        let controller = ViewerWindowController(cache: cache, thumbnails: thumbnails, thumbnailsReady: nil,
            positions: FolderPositions(database: nil), folderSettings: folderSettings, recent: nil)
        let session = controller.session
        guard let window = controller.window else { exit(2) }
        window.setContentSize(CGSize(width: 1200, height: 800))
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        session.setActivity(active: true, visible: true, lastActive: 1)
        controller.playbackVisibilityChanged(true, active: true)
        let large = root.appendingPathComponent("large", isDirectory: true)
        let a = root.appendingPathComponent("a", isDirectory: true)
        let b = root.appendingPathComponent("b", isDirectory: true)
        let clip = b.appendingPathComponent("clip.mp4")
        print("pass\tscenario\tok\twall_ms\tmain_cpu_ms\tread_bytes\twrite_bytes\tfootprint_bytes\tmetal_bytes")
        func showing(_ url: URL?) -> Bool { session.entry?.url == url && session.image != nil }
        for pass in ["first", "repeat"] {
            switch scenario {
            case "folder":
                await measure(pass, "open-large", action: { controller.open(.folder(large)) }) {
                    showing(session.playlist?.current) && session.playlist?.current.deletingLastPathComponent() == large
                }
                await measure(pass, "change-folder", action: { controller.open(.folder(a)) }) {
                    showing(session.playlist?.current) && session.playlist?.current.deletingLastPathComponent() == a
                }
            case "sorted-open":
                folderSettings.set("browser-sort", "name-desc", for: large)
                let photo = large.appendingPathComponent("img3.jpg")
                await measure(pass, "open-sorted-photo", action: { controller.open(photo) }) { showing(photo) }
                await measure(pass, "sorted-list-and-stamps", action: {}) {
                    session.playlist?.files.first?.lastPathComponent == "img12000.jpg"
                        && session.playlist?.stamps.count == 12000
                }
                await measure(pass, "leave-sorted-folder", action: { controller.open(.folder(a)) }) {
                    showing(session.playlist?.current) && session.playlist?.current.deletingLastPathComponent() == a
                }
            case "navigate":
                await measure(pass, "open-navigation", action: { controller.open(.folder(a)) }) {
                    showing(session.playlist?.current) && session.playlist?.current.deletingLastPathComponent() == a
                }
                for delta in Array(repeating: 1, count: 14) + Array(repeating: -1, count: 14) {
                    var target: URL?
                    await measure(pass, delta > 0 ? "forward" : "reverse", budget: .milliseconds(60), action: {
                        if session.go(by: delta) { target = session.playlist?.current }
                    }) { target != nil && showing(target) }
                }
                controller.open(.folder(large))
                await measure(pass, "supersede-folder", action: { controller.open(.folder(b)) }) {
                    showing(session.playlist?.current) && session.playlist?.current.deletingLastPathComponent() == b
                }
                try? await Task.sleep(for: .milliseconds(400))
                guard session.playlist?.current.deletingLastPathComponent() == b else { exit(3) }
            case "zoom":
                let photo = a.appendingPathComponent("003.jpg")
                await measure(pass, "open-zoom", action: { controller.open(photo) }) { showing(photo) }
                for _ in 0..<12 {
                    await measure(pass, "zoom-in", action: { controller.viewerView.debugPerform(.actual200) }) {
                        session.zoomTarget == nil && session.transform.scale == 2 && session.image?.finestResidentLevel == 0
                    }
                    await measure(pass, "zoom-fit", action: { controller.viewerView.debugPerform(.fit) }) {
                        session.zoomTarget == nil && session.transform.mode == .fit
                    }
                }
            case "interactive":
                controller.showHome(tab: .folders)
                guard let browser = controller.browserView else { exit(4) }
                await measure(pass, "file-view-first", action: { browser.show(.folder(large), selecting: nil) }) {
                    controller.benchFileViewThumbnails.ready > 0
                }
                await measure(pass, "file-view-fill", action: {}) {
                    let counts = controller.benchFileViewThumbnails
                    return counts.visible > 0 && counts.visible == counts.ready
                }
                if let scroll = gridScroll(in: browser) {
                    let original = browser.visibleIDs
                    await measure(pass, "file-view-jump-fill", action: {
                        let clip = scroll.contentView
                        let height = scroll.documentView?.bounds.height ?? 0
                        let target = clip.bounds.minY < height / 3 ? 0.55 : 0.15
                        clip.scroll(to: CGPoint(x: 0, y: target * height))
                        scroll.reflectScrolledClipView(clip)
                    }) {
                        let counts = controller.benchFileViewThumbnails
                        return browser.visibleIDs != original && counts.visible > 0 && counts.visible == counts.ready
                    }
                }
                controller.hideHome()
                controller.showBenchStrip()
                await measure(pass, "viewer-photo", action: { controller.open(.folder(large)) }) {
                    showing(session.playlist?.current) && session.playlist?.files.count == 12000
                }
                let stripFill = Task { @MainActor in
                    await measure(pass, "strip-fill", action: {}) {
                        let counts = controller.benchStripThumbnails
                        return counts.visible > 0 && counts.visible == counts.ready
                    }
                }
                await measure(pass, "strip-first", action: {}) { controller.benchStripThumbnails.ready > 0 }
                await measure(pass, "viewer-zoom", action: { controller.viewerView.debugPerform(.actual200) }) {
                    session.zoomTarget == nil && session.transform.scale == 2 && session.image?.finestResidentLevel == 0
                }
                await pan(controller.viewerView, pass: pass)
                await stripFill.value
                for delta in [1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1, -1] {
                    var target: URL?
                    await measure(pass, "viewer-step", budget: .milliseconds(60), action: {
                        if session.go(by: delta) { target = session.playlist?.current }
                    }) { target != nil && showing(target) }
                }
                controller.open(.folder(b))
                try? await Task.sleep(for: .milliseconds(300))
            case "video":
                func playback() -> EmbeddedPlayback? {
                    window.contentViewController?.children.compactMap { $0 as? EmbeddedPlayback }.first
                }
                await measure(pass, "poster", action: { controller.open(clip) }) {
                    playback()?.view.subviews.compactMap { $0 as? NSImageView }.contains { $0.image?.representations.contains { $0.pixelsWide >= 100 } == true } == true
                }
                let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                    isARepeat: false, keyCode: 49)!
                await measure(pass, "provider-picture", budget: .seconds(5), action: {
                    _ = playback()?.playbackKey(space)
                }) { playback()?.hasRemotePicture == true }
                if let player = playback(), player.hasRemotePicture {
                    await scrubAndResume(player, space: space, pass: pass)
                }
                controller.open(a.appendingPathComponent("001.jpg"))
                try? await Task.sleep(for: .milliseconds(300))
            default: exit(2)
            }
        }
        session.close()
        exit(0)
    }

    private static func gridScroll(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, (scroll.documentView?.bounds.height ?? 0) > scroll.bounds.height {
            return scroll
        }
        for child in view.subviews { if let scroll = gridScroll(in: child) { return scroll } }
        return nil
    }

    private static func pan(_ view: ViewerView, pass: String) async {
        view.setFrameStatsEnabled(false)
        view.setFrameStatsEnabled(true)
        func event(x: Int32, y: Int32, phase: CGScrollPhase) -> NSEvent? {
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0)
            cg?.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            return cg.flatMap(NSEvent.init(cgEvent:))
        }
        guard let start = event(x: 1, y: 1, phase: .began), let end = event(x: 0, y: 0, phase: .ended),
              let forward = event(x: 3, y: 4, phase: .changed), let back = event(x: -3, y: -4, phase: .changed) else { return }
        view.scrollWheel(with: start)
        var cpu: [Double] = []
        var next = ContinuousClock.now
        for i in 0..<120 {
            next += .milliseconds(8)
            try? await Task.sleep(until: next, clock: .continuous)
            let before = cpuMs()
            view.scrollWheel(with: (i / 10).isMultiple(of: 2) ? forward : back)
            cpu.append(cpuMs() - before)
        }
        view.scrollWheel(with: end)
        try? await Task.sleep(for: .milliseconds(60))
        let frames = view.frameStats()
        cpu.sort()
        print("PAN\t\(pass)\tcpu50=\(cpu[59]) cpu95=\(cpu[113]) cpu99=\(cpu[118]) gpu50=\(frames.gpuP50 ?? -1) gpu90=\(frames.gpuP90 ?? -1) missed=\(frames.dropped)")
        view.setFrameStatsEnabled(false)
    }

    /// Frame steps are acknowledged by the provider after presentation. Query the actual picture
    /// timestamp both before and after the burst, then wait for an advancing post-resume picture.
    private static func scrubAndResume(_ player: EmbeddedPlayback, space: NSEvent, pass: String) async {
        _ = player.playbackKey(space)
        let anchor = PlaybackTimeProbe()
        await measure(pass, "scrub-anchor", action: {}) { anchor.poll(player); return anchor.time >= 0 }
        for delta in Array(repeating: 1, count: 24) + Array(repeating: -1, count: 11) {
            player.step(delta)
            try? await Task.sleep(for: .milliseconds(8))
        }
        let landed = PlaybackTimeProbe()
        let expected = anchor.time + 13.0 / 30
        await measure(pass, "scrub-drain", budget: .seconds(2), action: {}) {
            guard !player.hasPendingFrameSteps else { return false }
            landed.poll(player)
            return abs(landed.time - expected) < 0.5 / 30
        }
        print("VIDEO\t\(pass)\tanchor=\(anchor.time) landed=\(landed.time) expected=\(expected)")
        guard landed.time >= 0 else { return }
        let resumed = PlaybackTimeProbe()
        await measure(pass, "resume-picture", budget: .seconds(2), action: {
            _ = player.playbackKey(space)
        }) {
            resumed.poll(player)
            return resumed.time > landed.time
        }
    }

    @MainActor private final class PlaybackTimeProbe {
        private(set) var time = -1.0
        private var pending = false
        private var next = ContinuousClock.now

        func poll(_ player: EmbeddedPlayback) {
            guard !pending, ContinuousClock.now >= next else { return }
            pending = true
            next = .now + .milliseconds(5)
            player.readPresentedTime { [weak self] time in
                Task { @MainActor in
                    self?.time = time
                    self?.pending = false
                }
            }
        }
    }

    private static func measure(_ pass: String, _ name: String, budget: Duration = .seconds(3),
                                action: () -> Void, ready: () -> Bool) async {
        let start = ContinuousClock.now
        let before = usage()
        let cpu = cpuMs()
        action()
        while !ready(), ContinuousClock.now - start < budget {
            try? await Task.sleep(for: .milliseconds(1))
        }
        let completed = ready()
        let elapsed = ContinuousClock.now - start
        let parts = elapsed.components
        let wall = Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
        let main = cpuMs() - cpu
        let after = usage()
        print("\(pass)\t\(name)\t\(completed && elapsed <= budget)\t\(wall)\t\(main)\t\(after.ri_diskio_bytesread - before.ri_diskio_bytesread)\t\(after.ri_diskio_byteswritten - before.ri_diskio_byteswritten)\t\(ProcessMemory.footprint())\t\(MetalContext.shared.device.currentAllocatedSize)")
        fflush(stdout)
    }

    private static func usage() -> rusage_info_v4 {
        var info = rusage_info_v4()
        withUnsafeMutablePointer(to: &info) {
            _ = proc_pid_rusage(getpid(), RUSAGE_INFO_V4, UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self))
        }
        return info
    }

    private static func cpuMs() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return Double(time.tv_sec) * 1000 + Double(time.tv_nsec) / 1e6
    }
}
