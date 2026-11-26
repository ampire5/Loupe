import AppKit
import Filmstrip
import Testing
import LoupeCore
import LoupeRender
@testable import Loupe

@Suite(.serialized) @MainActor struct SlotStatsLayoutTests {
    @Test(arguments: [1, 2])
    func statsKeepTheFilenameFolderNoticeAndZoomAtNarrowWidths(rows: Int) throws {
        _ = NSApplication.shared
        var config = Config()
        config.statsBarRows = rows
        config.statsIcons = false
        let bar = StatsBar(frame: NSRect(x: 0, y: 0, width: 420, height: StatsBar.height(rows: rows)))
        bar.apply(config)
        var status = ImageStatus()
        status.title = "Photograph from a studio session with a very long filename.jpg"
        status.note = "Loading folder…"
        status.facts = [.init(.position, "1 / 10"), .init(.size, "3840×2160"),
                        .init(.zoom, "SmartZoom · Auto · Vision · Person · Fit 40 %")]
        status.compactZoom = "Fit 40 %"
        status.decodeMilliseconds = 120
        bar.update(status)

        for width: CGFloat in [420, 680, 1200, 420] {
            bar.setFrameSize(.init(width: width, height: bar.frame.height))
            bar.layoutSubtreeIfNeeded()
            let labels = bar.subviews.flatMap { [$0] + $0.subviews }.compactMap { $0 as? NSTextField }
                .filter { !$0.isHiddenOrHasHiddenAncestor && $0.frame.width > 0 }
            #expect(labels.contains { $0.stringValue == status.title }, "Filename at \(width) pt")
            #expect(labels.contains { $0.stringValue == status.note }, "Folder notice at \(width) pt")
            #expect(labels.contains { $0.stringValue.contains("Fit 40 %") }, "Zoom at \(width) pt")
        }
    }

    @Test(arguments: [1, 2])
    func upscaleStatsKeepFolderAndZoomAndShowAvailableDetails(rows: Int) throws {
        _ = NSApplication.shared
        var config = Config()
        try #require(config.set("stats-bar-rows", String(rows)) == .ok)
        config.statsIcons = false
        let bar = StatsBar(frame: NSRect(x: 0, y: 0, width: 1200, height: StatsBar.height(rows: rows)))
        bar.apply(config)
        var status = ImageStatus()
        status.title = "Photo.jpg"
        status.folder = URL(fileURLWithPath: "/Photos/Album")
        status.facts = [.init(.position, "1 / 10"), .init(.size, "3840×2160"), .init(.zoom, "Manual · Fit 40 %")]
        status.compactZoom = "Fit 40 %"
        status.decodeMilliseconds = 120
        status.upscale = .init(indicator: "Upscale 2×", size: .init(width: 7680, height: 4320), milliseconds: 530)
        func visibleLabels(in view: NSView) -> [NSTextField] {
            view.subviews.filter { !$0.isHidden }.flatMap { child in
                if let label = child as? NSTextField { return label.stringValue.isEmpty ? [] : [label] }
                return visibleLabels(in: child)
            }
        }
        bar.update(status)
        bar.layoutSubtreeIfNeeded()
        var labels = visibleLabels(in: bar)
        #expect(labels.contains { $0.stringValue.contains("Album") })
        #expect(labels.contains { $0.stringValue == "Fit 40 % · Upscale 2×" })
        #expect(labels.contains { $0.stringValue == "3840×2160 → 7680×4320" })
        #expect(labels.contains { $0.stringValue == "Decode 120 ms · Upscale 530 ms" })
        for label in labels {
            #expect(bar.bounds.contains(bar.convert(label.frame, from: label.superview)))
            #expect(label.frame.width >= label.attributedStringValue.size().width)
        }

        bar.setFrameSize(.init(width: 420, height: bar.frame.height))
        bar.layoutSubtreeIfNeeded()
        labels = visibleLabels(in: bar)
        #expect(labels.contains { $0.stringValue.contains("Album") })
        #expect(labels.contains { $0.stringValue == "Fit 40 % · Upscale 2×" })
        #expect(labels.contains { $0.stringValue.contains("Photo.jpg") })

        bar.setFrameSize(.init(width: 1200, height: bar.frame.height))
        status.upscale = .init(indicator: "Original")
        bar.update(status)
        bar.layoutSubtreeIfNeeded()
        labels = visibleLabels(in: bar)
        #expect(labels.contains { $0.stringValue == "3840×2160" })
        #expect(labels.contains { $0.stringValue == "Decode 120 ms" })
        #expect(labels.contains { $0.stringValue == "Fit 40 % · Original" })
    }

    @Test func slotsAreInFrontOfFloatingFilmstripChrome() throws {
        _ = NSApplication.shared
        let thumbnails = ThumbnailStore(directory: nil, reader: FileReader(threads: 1), thumbSize: 320, limitBytes: 0)
        let controller = ViewerWindowController(cache: ImageCache(loader: MetalPyramidLoader()), thumbnails: thumbnails,
            thumbnailsReady: nil, positions: FolderPositions(database: nil), folderSettings: FolderSettings(database: nil), recent: nil)
        defer { controller.window?.close() }
        let root = try #require(controller.window?.contentView)
        let slots = try #require(root.subviews.firstIndex { $0 is SlotOverlayArea })
        let strip = try #require(root.subviews.firstIndex { $0 is FilmstripView })
        #expect(slots > strip)
    }

    @Test func floatingFilmstripKeepsItsStateOverSlotControls() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: StripController.pinnedKey)
        defaults.set(false, forKey: StripController.pinnedKey)
        defer { defaults.set(previous, forKey: StripController.pinnedKey) }

        let thumbnails = ThumbnailStore(directory: nil, reader: FileReader(threads: 1), thumbSize: 320, limitBytes: 0)
        let session = ViewerSession(cache: ImageCache(loader: MetalPyramidLoader()), thumbnails: thumbnails,
                                    positions: FolderPositions(database: nil))
        let strip = StripController(session: session, store: thumbnails)
        defer { strip.close(); session.close() }
        var config = Config()
        config.stripWindow = .over
        config.stripHideDelayMilliseconds = 30
        strip.apply(config)
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        root.addSubview(strip.view)
        strip.attach(to: root)
        let area = SlotOverlayArea(frame: root.bounds)
        root.addSubview(area)
        let slot = NSView(frame: CGRect(x: 0, y: 0, width: 210, height: root.bounds.height))
        let control = NSButton(frame: CGRect(x: 12, y: 12, width: 100, height: 26))
        slot.addSubview(control)
        area.addSubview(slot)
        strip.slotOverlayArea = area

        func move(x: CGFloat, y: CGFloat) throws {
            let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: CGPoint(x: x, y: y), modifierFlags: [],
                                                       timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                                                       clickCount: 0, pressure: 0))
            strip.mouseMoved(with: event)
        }
        try move(x: 30, y: 20)
        #expect(!strip.isShown)
        try move(x: 400, y: 25)
        #expect(!strip.isShown)
        try move(x: 400, y: 20)
        #expect(strip.isShown)
        try move(x: 30, y: 150)
        try await Task.sleep(for: .milliseconds(100))
        #expect(strip.isShown)
        try move(x: 400, y: 200)
        let deadline = ContinuousClock.now + .seconds(2)
        while strip.isShown, .now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!strip.isShown)
    }

    @Test func floatingFilmstripRearmsItsPlaybackEdgeAfterAnExplicitHide() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: StripController.pinnedKey)
        defaults.set(false, forKey: StripController.pinnedKey)
        defer { defaults.set(previous, forKey: StripController.pinnedKey) }

        let thumbnails = ThumbnailStore(directory: nil, reader: FileReader(threads: 1), thumbSize: 320, limitBytes: 0)
        let session = ViewerSession(cache: ImageCache(loader: MetalPyramidLoader()), thumbnails: thumbnails,
                                    positions: FolderPositions(database: nil))
        let strip = StripController(session: session, store: thumbnails)
        defer { strip.close(); session.close() }
        var config = Config()
        config.stripWindow = .over
        config.stripHideDelayMilliseconds = 30
        config.stripFadeInMilliseconds = 0
        config.stripFadeOutMilliseconds = 0
        strip.apply(config)
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        strip.view.frame = CGRect(x: 0, y: 42, width: 640, height: strip.bandHeight)
        root.addSubview(strip.view)
        strip.attach(to: root)
        strip.setPlaybackClearance(42)

        func move(_ y: CGFloat) throws {
            let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: CGPoint(x: 320, y: y),
                                                       modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                       context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            strip.mouseMoved(with: event)
        }

        try move(41)
        #expect(!strip.isShown)
        try move(67)
        #expect(!strip.isShown)
        try move(62)
        try #require(strip.isShown)
        strip.setStripVisibility(false)
        #expect(!strip.isShown)
        try move(63)
        #expect(!strip.isShown)
        try move(68)
        #expect(!strip.isShown)
        try move(62)
        #expect(strip.isShown)

        try move(-70)
        try await Task.sleep(for: .milliseconds(80))
        try #require(strip.isShown)
        try move(-101)
        let deadline = ContinuousClock.now + .seconds(1)
        while strip.isShown, .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!strip.isShown)
    }

    @Test func floatingFilmstripFitsItsRevealZoneToVisibleThumbnailHeight() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: StripController.pinnedKey)
        defaults.set(false, forKey: StripController.pinnedKey)
        defer { defaults.set(previous, forKey: StripController.pinnedKey) }

        let thumbnails = ThumbnailStore(directory: nil, reader: FileReader(threads: 1), thumbSize: 320, limitBytes: 0)
        let session = ViewerSession(cache: ImageCache(loader: MetalPyramidLoader()), thumbnails: thumbnails,
                                    positions: FolderPositions(database: nil))
        let strip = StripController(session: session, store: thumbnails)
        defer { strip.close(); session.close() }
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        root.addSubview(strip.view)
        strip.attach(to: root)
        var config = Config()
        config.stripWindow = .over
        config.stripFadeInMilliseconds = 0
        config.stripFadeOutMilliseconds = 0

        func move(_ y: CGFloat) throws {
            let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: CGPoint(x: 150, y: y),
                                                       modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                       context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            strip.mouseMoved(with: event)
        }

        for (height, width, edge) in [(40, 640, 20), (105, 640, 24), (200, 640, 44), (200, 300, 23)] {
            root.setFrameSize(CGSize(width: width, height: 480))
            config.stripHeight = height
            strip.apply(config)
            try move(CGFloat(edge + 1))
            #expect(!strip.isShown, "height \(height), window width \(width)")
            try move(CGFloat(edge))
            #expect(strip.isShown, "height \(height), window width \(width)")
            strip.setStripVisibility(false)
        }
    }

    @Test func floatingFilmstripReversesAnExitTogetherWithItsCapsule() async throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: StripController.pinnedKey)
        defaults.set(false, forKey: StripController.pinnedKey)
        defer { defaults.set(previous, forKey: StripController.pinnedKey) }

        let thumbnails = ThumbnailStore(directory: nil, reader: FileReader(threads: 1), thumbSize: 320, limitBytes: 0)
        let session = ViewerSession(cache: ImageCache(loader: MetalPyramidLoader()), thumbnails: thumbnails,
                                    positions: FolderPositions(database: nil))
        let strip = StripController(session: session, store: thumbnails)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 480), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { strip.close(); session.close(); window.close() }
        let root = try #require(window.contentView)
        strip.view.frame = CGRect(x: 0, y: 0, width: 640, height: strip.bandHeight)
        root.addSubview(strip.view)
        NSLayoutConstraint.activate([
            strip.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            strip.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            strip.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        strip.attach(to: root)
        window.orderBack(nil)
        var config = Config()
        config.stripWindow = .over
        config.stripHideDelayMilliseconds = 0
        config.stripFadeOutMilliseconds = 500
        strip.apply(config)
        root.layoutSubtreeIfNeeded()
        try #require(strip.view.frame.contains(CGPoint(x: 320, y: 64)))

        func move(_ y: CGFloat) throws {
            let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: CGPoint(x: 320, y: y),
                                                       modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                       context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            strip.mouseMoved(with: event)
        }
        func slide(_ view: NSView) -> CABasicAnimation? {
            let group = view.layer?.animation(forKey: StripVisibilityMotion.key) as? CAAnimationGroup
            return group?.animations?.compactMap { $0 as? CABasicAnimation }
                .first { $0.keyPath == "transform.translation.y" }
        }

        let capsule = try #require(root.subviews.compactMap { $0 as? FilmstripToolsView }.first)
        try move(4)
        try #require(strip.isShown)
        #expect(slide(strip.view)?.fromValue as? Double == -16)
        #expect(slide(capsule)?.fromValue as? Double == -16)
        try await Task.sleep(for: .milliseconds(300))
        try move(300)
        let deadline = ContinuousClock.now + .seconds(1)
        while strip.isShown, .now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(!strip.isShown && !strip.view.isHidden)
        try #require(slide(strip.view) != nil)
        #expect(slide(capsule)?.toValue as? Double == -16)
        try await Task.sleep(for: .milliseconds(70))
        let before = StripVisibilityMotion.state(of: strip.view, enteringFromEdge: false)
        let toolsBefore = StripVisibilityMotion.state(of: capsule, enteringFromEdge: false)
        try #require(before.y < 0 && before.y > -16)
        #expect(before.opacity > 0 && before.opacity < 1)
        #expect(abs(before.y - toolsBefore.y) < 2)
        try move(64)
        #expect(strip.isShown)
        let start = try #require(slide(strip.view)?.fromValue as? Double)
        #expect(abs(start - before.y) < 2)
        try await Task.sleep(for: .milliseconds(500))
        #expect(!strip.view.isHidden)
    }

    @Test func slotsStayBelowVisibleStatsAndReclaimTheTopWhenHidden() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let keys = ["viewerToolbar", "statsMode", "fullScreenStatus", "fullScreen"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(false, forKey: "viewerToolbar")
        defaults.set("compact", forKey: "statsMode")
        let thumbnails = ThumbnailStore(directory: nil, reader: FileReader(threads: 1), thumbSize: 320, limitBytes: 0)
        let controller = ViewerWindowController(cache: ImageCache(loader: MetalPyramidLoader()), thumbnails: thumbnails,
            thumbnailsReady: nil, positions: FolderPositions(database: nil), folderSettings: FolderSettings(database: nil), recent: nil)
        defer { controller.window?.close() }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let bar = try #require(root.subviews.compactMap { $0 as? StatsBar }.first)
        let area = try #require(root.subviews.compactMap { $0 as? SlotOverlayArea }.first)
        let photo = try #require(root.subviews.compactMap { $0 as? ViewerView }.first)
        for fullScreen in [false, true] {
            if fullScreen {
                defaults.set(true, forKey: "fullScreenStatus")
                NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
            }
            for rows in [1, 2] {
                var config = Config(); #expect(config.set("stats-bar-rows", String(rows)) == .ok)
                bar.apply(config)
                root.needsLayout = true; root.layoutSubtreeIfNeeded()
                #expect(!bar.isHidden)
                #expect(area.frame.maxY <= bar.frame.minY + 0.5)
                #expect(abs(area.frame.maxY - bar.frame.minY) < 0.5)
                #expect(photo.frame.maxY > bar.frame.minY) // Only panels move below floating stats.
            }
            controller.toggleStatsBar(nil)
            root.layoutSubtreeIfNeeded()
            #expect(bar.isHidden)
            #expect(abs(area.frame.maxY - photo.frame.maxY) < 0.5)
            controller.toggleStatsBar(nil)
            root.layoutSubtreeIfNeeded()
            #expect(!bar.isHidden)
            #expect(abs(area.frame.maxY - bar.frame.minY) < 0.5)
        }
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
    }
}
