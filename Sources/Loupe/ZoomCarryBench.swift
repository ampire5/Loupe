import AppKit
import LoupeCore
import LoupeRender

/// Exercises the real session's asynchronous photo-switch path, including thumbnail-to-image arrivals.
@MainActor enum ZoomCarryBench {
    static func run(folder: URL) async -> Never {
        setbuf(stdout, nil)
        let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
        let reader = FileReader(threads: 1)
        let cache = ImageCache(loader: MetalPyramidLoader(), reader: reader, pool: DecodePool(), limits: CacheLimits(config: Config()))
        let thumbs = ThumbnailStore(directory: nil, reader: reader, thumbSize: 320, limitBytes: 0)
        Settings.shared.reload(applyingIcon: false)
        func cpu() -> Double { var t = timespec(); clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t); return Double(t.tv_sec) + Double(t.tv_nsec) / 1e9 }
        let windowStart = cpu()
        let stateDatabase = ProcessInfo.processInfo.environment["LOUPE_BENCH_STATE_DIRECTORY"].flatMap { try? StateDatabase(directory: URL(fileURLWithPath: $0)) }
        let folderSettings = FolderSettings(database: stateDatabase)
        let controller = ViewerWindowController(cache: cache, thumbnails: thumbs, thumbnailsReady: nil,
            positions: FolderPositions(database: nil), folderSettings: folderSettings, recent: nil)
        let session = controller.session
        controller.window?.setContentSize(CGSize(width: 1000, height: 700))
        controller.window?.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        print("WINDOW\tfirst-window\t\((cpu() - windowStart) * 1000)")
        var config = Config(); config.keepZoomPosition = true; _ = config.set("keep-zoom-as", "screen")
        _ = config.set("step-pan", "keep"); _ = config.set("step-zoom", "keep")
        let useWindowRules = ProcessInfo.processInfo.environment["LOUPE_BENCH_WINDOW_RULES"] == "1"
        if !useWindowRules { session.zoomRules = { _ in ZoomRules(config: config) } }
        if !useWindowRules {
            session.transform.viewSize = CGSize(width: 1600, height: 1000)
            session.screenSize = PixelSize(width: 1600, height: 1000)
        }
        session.setActivity(active: true, visible: true, lastActive: 1)
        let ext = ProcessInfo.processInfo.environment["LOUPE_BENCH_EXTENSION"] ?? "png"
        let first = folder.appendingPathComponent("001." + ext)
        controller.open(first)
        await wait { session.entry?.url == first && session.playlist?.files.count == 2 && session.transform.imageSize.width > 0 }
        if let phase = ProcessInfo.processInfo.environment["LOUPE_BENCH_REMEMBER"] {
            let ok = await SmartZoomProfileBench.remember(phase, controller: controller, folderSettings: folderSettings, folder: folder)
            session.close(); exit(ok ? 0 : 1)
        }
        if ProcessInfo.processInfo.environment["LOUPE_BENCH_PROFILE_EDITOR"] == "1" {
            let ok = await SmartZoomProfileBench.editor(controller: controller)
            session.close(); exit(ok ? 0 : 1)
        }
        var failed = false
        for mode in [ZoomMode.actual(1), .free(3), .fitWidth] {
            var before = session.transform.withMode(mode)
            before.center = CGPoint(x: 0.4, y: 0.65)
            session.transform = before
            let old = session.entry?.url
            let delta = session.playlist?.index == 0 ? 1 : -1
            if useWindowRules { controller.viewerView.debugPerform(delta > 0 ? .next : .previous) }
            else { _ = session.go(by: delta) }
            await wait { session.entry?.url != old && session.entry?.url == session.playlist?.current }
            try? await Task.sleep(for: .milliseconds(200))
            let after = session.transform
            let kept = abs(before.scale - after.scale) < 1e-8 && before.center == after.center
            print("CARRY \(mode) before=\(SavedView(before).text) after=\(SavedView(after).text) kept=\(kept)")
            if !kept { failed = true }
        }
        if ProcessInfo.processInfo.environment["LOUPE_BENCH_SMARTZOOM"] == "1" {
            let boxes = SubjectBoxes(faces: [], people: [], objects: [
                .init(x: 0.05, y: 0.4, width: 0.1, height: 0.1), .init(x: 0.85, y: 0.4, width: 0.1, height: 0.1)], saliency: [])
            session.subjectBoxes = { _ in boxes }
            func verify(_ name: String, _ ok: Bool) { print("WORKFLOW \(name) ok=\(ok)"); failed = failed || !ok }
            func shown() -> ViewTransform { session.zoomTarget ?? session.transform }
            let profile = session.zoomRules(session.entry!.url).detector?.name
            controller.viewerView.debugPerform(.fit)
            verify("Fit preserves profile", session.smartZoom.mode == .off && session.zoomRules(session.entry!.url).detector?.name == profile)
            controller.viewerView.debugPerform(.zoomSubject)
            let firstAuto = shown()
            verify("Shift-Z directly enters Auto", session.smartZoom.mode == .frame)
            controller.viewerView.debugPerform(.zoomSubject)
            verify("repeated Shift-Z stays Auto", session.smartZoom.mode == .frame && shown() == firstAuto)
            controller.viewerView.debugPerform(.toggleStepZoom)
            verify("legacy mouse command applies Auto", session.smartZoom.mode == .frame && shown() == firstAuto)
            if let control = controller.window?.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "viewer.zoomSet" })?.view as? NSSegmentedControl {
                control.selectedSegment = 0; control.sendAction(control.action, to: control.target)
                verify("toolbar Manual enters Manual", session.smartZoom.mode == .off)
                let start = cpu()
                control.selectedSegment = 1; control.sendAction(control.action, to: control.target)
                print("WINDOW\tworkflow-control\t\((cpu() - start) * 1000)")
                verify("toolbar SmartZoom directly enters Auto", session.smartZoom.mode == .frame)
            } else { verify("toolbar workflow control exists", false) }
            controller.viewerView.debugPerform(.actual200)
            verify("ordinary preset enters Manual", session.smartZoom.mode == .off && shown().scale == 2)
            controller.saveManualZoomFolder(nil)
            let savedManual = folderSettings.ownValues(for: folder)
            verify("Manual save excludes Smart settings", Set(savedManual.keys).isDisjoint(with: Set(ZoomKeys.smartSaveKeys)))
            controller.saveSmartZoomFolder(nil)
            let savedBoth = folderSettings.ownValues(for: folder)
            verify("Smart save preserves Manual settings", ZoomKeys.manualSaveKeys.allSatisfy { savedBoth[$0] == savedManual[$0] })
            verify("saving inactive Smart stays Manual", session.smartZoom.mode == .off)
            let manual = shown()
            controller.viewerView.debugPerform(.toggleSmartZoom)
            verify("power resumes Auto", session.smartZoom.mode == .frame)
            let auto = shown()
            controller.viewerView.debugPerform(.toggleSmartZoom)
            verify("power exits without moving view", session.smartZoom.mode == .off && shown() == auto)
            verify("Manual and Smart retain selected profile", session.zoomRules(session.entry!.url).detector?.name == profile)
            controller.viewerView.debugPerform(.zoomSubject)
            session.transform = shown().withMode(.actual(4)); session.noteManualZoom()
            let old = session.entry?.url
            controller.viewerView.debugPerform(session.playlist?.index == 0 ? .next : .previous)
            await wait { session.entry?.url != old && session.entry?.url == session.playlist?.current }
            try? await Task.sleep(for: .milliseconds(100))
            let rules = session.zoomRules(session.entry!.url)
            let expected = PhotoSwitchView.subjectTransform(session.transform, boxes: boxes, rules: rules)!
            verify("manual adjustment does not teach profile size", abs(shown().scale - expected.scale) < 1e-8 && session.browse.sizes.isEmpty)
            print("WORKFLOW status=\(session.imageStatus.value(.zoom) ?? "missing")")
            _ = manual

        }
        if ProcessInfo.processInfo.environment["LOUPE_BENCH_MODEL_SWITCH"] == "1" {
            failed = await checkModels(controller, session: session, folderSettings: folderSettings, folder: folder) || failed
        }
        if ProcessInfo.processInfo.environment["LOUPE_BENCH_PANEL"] == "1" { measurePanel(controller, session: session) }
        session.close()
        exit(failed ? 1 : 0)
    }
    private static func checkModels(_ controller: ViewerWindowController, session: ViewerSession,
                                    folderSettings: FolderSettings, folder: URL) async -> Bool {
        let preferences = Settings.detectorPreferences
        let oldModel = preferences.object(forKey: DetectorModelCatalog.selectionKey)
        let oldProfile = preferences.object(forKey: ZoomKeys.lastProfileKey)
        let oldMode = preferences.object(forKey: SmartZoomState.preferenceKey)
        defer {
            preferences.set(oldModel, forKey: DetectorModelCatalog.selectionKey)
            preferences.set(oldProfile, forKey: ZoomKeys.lastProfileKey)
            preferences.set(oldMode, forKey: SmartZoomState.preferenceKey)
            Settings.shared.reload(applyingIcon: false)
        }
        func mainCPU() -> Double { var t = timespec(); clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t); return Double(t.tv_sec) + Double(t.tv_nsec) / 1e9 }
        let setup = Settings.shared.config.detectorSetup
        let entries = await Task.detached(priority: .utility) {
            DetectorModelCatalog.scan(selected: setup.model, configured: setup.model)
        }.value
        guard entries.count >= 2 else { fatalError("Two local test models are required") }
        let chosenProfile = setup.modes.last!
        let item = NSMenuItem(); item.identifier = .init("detector-mode|" + chosenProfile.name)
        controller.chooseDetectorMode(item)
        let remembered = folderSettings.ownValues(for: folder)["detector-mode"] == chosenProfile.name
            && (preferences.dictionary(forKey: ZoomKeys.lastProfileKey)?["detector-mode"] as? String) == chosenProfile.name
        print("MODEL profile-remembered ok=\(remembered)")
        controller.viewerView.debugPerform(.zoomSubject)
        guard let toolbarItem = controller.window?.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "viewer.smartZoom" }),
              let action = toolbarItem.action else { fatalError("SmartZoom panel item missing") }
        let panelCPU = mainCPU()
        NSApp.sendAction(action, to: toolbarItem.target, from: toolbarItem)
        controller.window?.contentView?.layoutSubtreeIfNeeded(); CATransaction.flush()
        print("MODEL panel-first-mainCPUms=\((mainCPU() - panelCPU) * 1000)")
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        guard let root = controller.window?.contentView,
              let picker = descendants(root).first(where: { $0.identifier?.rawValue == "smartzoom.model" }) as? NSPopUpButton else {
            fatalError("Model selector missing")
        }
        try? await Task.sleep(for: .milliseconds(150))
        for entry in [entries[0], entries[1], entries[0]] {
            guard let menu = picker.menu else { fatalError("Model menu missing") }
            menu.delegate?.menuNeedsUpdate?(menu)
            guard let index = picker.itemArray.firstIndex(where: { ($0.representedObject as? String) == entry.path }) else {
                fatalError("Catalog entry missing from model menu")
            }
            let start = ContinuousClock.now, cpuStart = mainCPU()
            print("MODEL begin \(entry.width ?? 0)x\(entry.height ?? 0)")
            picker.selectItem(at: index); picker.sendAction(picker.action, to: picker.target)
            await wait { picker.isEnabled }
            guard Settings.shared.config.detectorSetup.model == entry.path else {
                print("MODEL rejected: model preflight failed"); return true
            }
            print("MODEL loaded; waiting for photo analysis")
            await wait { session.entry.flatMap { SubjectFinder.boxes(for: $0.url, applied: session.appliesOrientation,
                setup: Settings.shared.config.detectorSetup) } != nil }
            let current = Settings.shared.config.detectorSetup
            let boxes = session.entry.flatMap { SubjectFinder.boxes(for: $0.url, applied: session.appliesOrientation, setup: current) }
            let ok = boxes?.analysisID == current.analysisID
                && session.zoomRules(session.entry!.url).detector?.name == chosenProfile.name
                && preferences.string(forKey: DetectorModelCatalog.selectionKey) == entry.path
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            print("MODEL switch \(entry.width ?? 0)x\(entry.height ?? 0) elapsed=\(ContinuousClock.now - start) mainCPUms=\((mainCPU() - cpuStart) * 1000) peakRSS=\(usage.ru_maxrss) ok=\(ok)")
            if !ok { return true }
        }
        controller.viewerView.debugPerform(.manualZoom)
        let manualView = session.zoomTarget ?? session.transform
        if let menu = picker.menu { menu.delegate?.menuNeedsUpdate?(menu) }
        let manualIndex = picker.itemArray.firstIndex { ($0.representedObject as? String) == entries[1].path }!
        picker.selectItem(at: manualIndex); picker.sendAction(picker.action, to: picker.target)
        await wait { picker.isEnabled }
        let manual = session.smartZoom.mode == .off && (session.zoomTarget ?? session.transform) == manualView
            && Settings.shared.config.detectorSetup.model == entries[1].path
        print("MODEL selection-in-Manual-keeps-view ok=\(manual)")
        let selectedBeforeFailure = Settings.shared.config.detectorSetup.model
        let broken = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mlmodelc")
        try? FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try? Data().write(to: broken.appendingPathComponent("coremldata.bin"))
        defer { try? FileManager.default.removeItem(at: broken) }
        picker.addItem(withTitle: "Invalid test model"); picker.lastItem?.representedObject = broken.path
        picker.selectItem(at: picker.numberOfItems - 1); picker.sendAction(picker.action, to: picker.target)
        await wait { picker.isEnabled }
        let retained = Settings.shared.config.detectorSetup.model == selectedBeforeFailure
            && preferences.string(forKey: DetectorModelCatalog.selectionKey) == selectedBeforeFailure
        print("MODEL failed-load-retains-selection ok=\(retained)")
        return !remembered || !retained || !manual
    }

    private static func measurePanel(_ controller: ViewerWindowController, session: ViewerSession) {
        func cpu() -> Double { var t = timespec(); clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t); return Double(t.tv_sec) + Double(t.tv_nsec) / 1e9 }
        func measured(_ label: String, _ body: () -> Void) {
            let start = cpu(); body(); controller.window?.contentView?.layoutSubtreeIfNeeded(); CATransaction.flush()
            print("WINDOW\t\(label)\t\(String(format: "%.3f", (cpu() - start) * 1000))")
        }
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let rects = (0..<40).map { i in CGRect(x: 0.1 + Double(i % 8) * 0.09, y: 0.1 + Double(i / 8) * 0.12, width: 0.05, height: 0.06) }
        let boxes = SubjectBoxes(faces: rects, people: [], objects: rects, saliency: [.init(x: 0.3, y: 0.3, width: 0.2, height: 0.2)])
        session.subjectBoxes = { _ in boxes }
        guard let item = controller.window?.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "viewer.smartZoom" }), let action = item.action else { fatalError("SmartZoom toolbar item missing") }
        measured("panel-first") { NSApp.sendAction(action, to: item.target, from: item) }
        let buttons = controller.window?.contentView.map(descendants)?.compactMap { $0 as? NSButton } ?? []
        guard let disclosure = buttons.first(where: { $0.title == "Type weights ▸" }) else { fatalError("SmartZoom panel did not become visible") }
        disclosure.performClick(nil)
        for round in 1...5 {
            measured("mode-\(round)") { controller.viewerView.debugPerform(.toggleSmartZoom) }
            measured("group-\(round)") { controller.viewerView.debugPerform(.nextTarget) }
            if let root = controller.window?.contentView {
                let sliders = descendants(root).compactMap { $0 as? NSSlider }
                if let weight = sliders.last {
                    measured("weight-\(round)") { weight.doubleValue = round.isMultiple(of: 2) ? 1 : 1.25; weight.sendAction(weight.action, to: weight.target) }
                }
            }
            measured("panel-return-\(round)") { NSApp.sendAction(action, to: item.target, from: item) }
        }
        if let root = controller.window?.contentView?.superview,
           let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/loupe-zoom-workflows-window.png"))
        }
    }

    private static func wait(_ condition: () -> Bool) async {
        for _ in 0..<5000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Photo-switch fixture did not become ready")
    }
}
