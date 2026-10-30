import AppKit
import HomeScreenModel
import LoupeCore
import Testing
@testable import Loupe

@Suite(.serialized) @MainActor struct ViewerToolbarStatusTests {
    private func toolbar() -> ViewerToolbarController {
        ViewerToolbarController(actions: .init(back: {}, step: { _ in }, zoom: { _ in }, colour: { _ in },
            setValue: { _, _ in }, stats: {}, strip: {}, info: {}, smartZoom: {}))
    }

    private func descendants(_ view: NSView) -> [NSView] {
        // NSButton may host private text-rendering views outside its cell's clipping rect.
        [view] + (view is NSControl ? [] : view.subviews.flatMap(descendants))
    }

    private func sample() -> ImageStatus {
        var value = ImageStatus()
        value.title = "Portrait_001.jpg"
        value.folder = URL(fileURLWithPath: "/Demo/Studio session")
        value.photo = value.folder!.appendingPathComponent(value.title)
        value.index = 0; value.count = 141; value.progress = 1.0 / 141
        value.zoomDetails = .init(mode: .off, profile: "balanced", group: "Person · Face", scale: 2.75, keepingZoom: true)
        value.facts = [.init(.position, "1 / 141"), .init(.size, "2000×3000"), .init(.megapixels, "6 MP"),
            .init(.format, "JPEG"), .init(.fileSize, "1.1 MB"), .init(.zoom, "Manual · 275 %"),
            ImageStatus.exposureFact(FileFacts(exposure: 1.0 / 250, aperture: 2.8, iso: 400, focalLength: 50, exposureBias: -0.3))!]
        return value
    }

    @Test func statusKeepsGraphicalControlsOutsideTheInformationSurface() throws {
        _ = NSApplication.shared
        let controller = toolbar()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1100, height: 400),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.autorecalculatesKeyViewLoop = true
        defer { window.close() }
        window.titleVisibility = .hidden
        controller.attach(to: window)
        window.toolbar = controller.nsToolbar
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        let item = try #require(controller.nsToolbar.items.first { $0.itemIdentifier.rawValue == "viewer.status" })
        let view = try #require(item.view)
        #expect(view.frame.height == 46)
        let labels = descendants(view).compactMap { ($0 as? NSButton)?.accessibilityLabel() }
        #expect(labels.contains("SmartZoom profile"))
        #expect(labels.contains("Subject group"))
        let identifiers = Set(controller.nsToolbar.items.map { $0.itemIdentifier.rawValue })
        for duplicate in ["viewer.info"] {
            #expect(!identifiers.contains(duplicate))
        }
        for restored in ["viewer.navigation", "viewer.zoom", "viewer.zoomModes", "viewer.smartZoom", "viewer.keepZoom", "viewer.zoomSet"] {
            #expect(identifiers.contains(restored))
            #expect(controller.nsToolbar.items.firstIndex { $0.itemIdentifier.rawValue == restored }! < controller.nsToolbar.items.firstIndex { $0.itemIdentifier.rawValue == "viewer.status" }!)
        }

    }

    @Test func graphicalPresetsAndKeepZoomReflectCurrentState() throws {
        let controller = toolbar()
        controller.updateStatus(sample(), zoomMode: .fit)
        let presets = try #require(controller.toolbar(controller.nsToolbar, itemForItemIdentifier: .init("viewer.zoomModes"), willBeInsertedIntoToolbar: true) as? NSToolbarItemGroup)
        let keep = try #require(controller.toolbar(controller.nsToolbar, itemForItemIdentifier: .init("viewer.keepZoom"), willBeInsertedIntoToolbar: true) as? NSToolbarItemGroup)
        #expect(presets.selectedIndex == 0)
        #expect(presets.subitems.allSatisfy { $0.image != nil })
        #expect(keep.isSelected(at: 0))
        let workflow = try #require(controller.toolbar(controller.nsToolbar, itemForItemIdentifier: .init("viewer.zoomSet"), willBeInsertedIntoToolbar: true) as? NSToolbarItemGroup)
        #expect(workflow.selectedIndex == 0)
        var smart = sample(); smart.zoomDetails?.mode = .frame
        controller.updateStatus(smart)
        #expect(workflow.selectedIndex == 1)
        controller.updateStatus(sample(), zoomMode: .actual(1))
        #expect(presets.selectedIndex == 1)
        controller.updateStatus(ImageStatus())
        #expect(!keep.isEnabled && !keep.isSelected(at: 0))
    }

    @Test func narrowLayoutKeepsCaptureProfileAndGroupInsideTheSurface() {
        let view = ViewerToolbarStatusView()
        var value = sample()
        value.facts.removeAll { $0.kind == .exposure }
        value.facts.append(ImageStatus.exposureFact(FileFacts(exposure: 1.0 / 8000, aperture: 22, iso: 102400, focalLength: 1200, exposureBias: 3))!)
        value.title = String(repeating: "Long neutral photo name ", count: 20)
        value.zoomDetails?.profile = String(repeating: "Profile ", count: 20)
        value.zoomDetails?.group = String(repeating: "Subject group ", count: 20)
        view.update(value)
        let allocatedWidth = view.widthAnchor.constraint(equalToConstant: 280)
        allocatedWidth.isActive = true
        defer { allocatedWidth.isActive = false }
        for width: CGFloat in [140, 180, 220, 240, 270, 280, 320, 400, 430, 549, 550, 640, 800, 1024, 1800] {
            allocatedWidth.constant = width
            view.frame = NSRect(x: 0, y: 0, width: width, height: 46)
            view.layoutSubtreeIfNeeded()
            view.layout()
            #expect(view.frame.height == 46)
            #expect(view.bounds.width == width)
            #expect(!view.profileButton.isHidden && !view.groupButton.isHidden)
            for control in descendants(view) where (control is NSButton || control is NSTextField) && !control.isHiddenOrHasHiddenAncestor {
                let rect = view.convert(control.bounds, from: control)
                #expect(rect.minX >= -0.5 && rect.maxX <= width + 0.5, "width \(width): \(control) at \(rect)")
                #expect(rect.width > 0)
                #expect(rect.minY >= -0.5 && rect.maxY <= 46.5)
            }
            let exposure = value.facts.first { $0.kind == .exposure }!.parts
            if width == 1800 {
                #expect(view.metadataButton.frame.width <= 320)
                #expect(view.groupButton.frame.maxX <= view.preferredWidth)
                #expect(view.groupButton.frame.width <= 450)
                #expect(view.zoomButton.frame.minY == view.profileButton.frame.minY)
                #expect(view.groupButton.frame.minX == view.profileButton.frame.minX)
                #expect(view.groupButton.frame.width > view.profileButton.frame.width)
                for label in descendants(view).compactMap({ $0 as? NSTextField }) where !label.isHiddenOrHasHiddenAncestor && exposure.contains(where: { $0.text == label.stringValue }) {
                    #expect(label.frame.width >= label.cell!.cellSize.width)
                }
            }
            let shown = descendants(view).compactMap { ($0 as? NSTextField).flatMap { $0.isHiddenOrHasHiddenAncestor ? nil : $0.stringValue } }
            for part in exposure { #expect(shown.contains(part.text)) }
        }
        for button in [view.metadataButton, view.zoomButton, view.modeButton, view.profileButton, view.groupButton] {
            #expect(button.alignment == .left)
        }
        #expect(view.profileButton.title == value.zoomDetails?.profile)
        #expect(view.profileButton.toolTip?.contains(value.zoomDetails!.profile) == true)
    }

    @Test func preferredWidthGrowsForRealTextWithoutStretchingToTheWindow() {
        let view = ViewerToolbarStatusView()
        var value = sample()
        view.update(value)
        let short = view.preferredWidth
        value.title = "Studio_Portrait_Session_2026_Selected_Photograph_001.jpg"
        value.folder = URL(fileURLWithPath: "/Demo/Portrait session — selected photographs for review")
        value.zoomDetails?.group = "Person · Full body · Standing · Front view"
        view.update(value)
        #expect(view.preferredWidth > short)
        #expect(view.preferredWidth < 1500)
        view.frame = NSRect(x: 0, y: 0, width: view.preferredWidth, height: 46)
        view.layout()
        #expect(view.groupButton.frame.width >= view.groupButton.cell!.cellSize.width)
        let names = [value.title, value.folder!.lastPathComponent]
        for label in descendants(view).compactMap({ $0 as? NSTextField }) where names.contains(label.stringValue) {
            #expect(label.frame.width >= label.cell!.cellSize.width)
        }
    }

    @Test func exposureReturnsAfterMissingMetadataInCollapsedLayout() {
        let view = ViewerToolbarStatusView()
        var value = sample()
        value.facts.removeAll { $0.kind == .exposure }
        view.update(value)
        view.frame = NSRect(x: 0, y: 0, width: 140, height: 46); view.layout()
        view.update(sample())
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 46); view.layout()
        let labels = descendants(view).compactMap { $0 as? NSTextField }.filter { !$0.isHiddenOrHasHiddenAncestor && $0.frame.width > 0 }
        for part in sample().facts.first(where: { $0.kind == .exposure })!.parts {
            #expect(labels.contains { $0.stringValue == part.text })
        }
        var loading = sample()
        loading.facts = []; loading.pending = [.exposure]
        view.update(loading)
        // A new surface must distinguish header loading from confirmed absent EXIF.
        let fresh = ViewerToolbarStatusView(); fresh.update(loading)
        let loadingLabels = descendants(fresh).compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(loadingLabels.contains("Reading EXIF…"))
    }

    @Test func pendingExifIsHeldButAnAbsentExifReplacesIt() {
        let view = ViewerToolbarStatusView()
        var value = sample()
        view.update(value)
        value.pending = [.exposure]
        value.facts.removeAll { $0.kind == .exposure }
        value.title = "Next photo.jpg"
        view.update(value)
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 46); view.layout()
        var labels = descendants(view).compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(labels.contains("1/250"))
        value.pending = []
        view.update(value); view.layout()
        labels = descendants(view).compactMap { ($0 as? NSTextField).flatMap { $0.isHiddenOrHasHiddenAncestor ? nil : $0.stringValue } }
        #expect(labels.contains("No EXIF"))
        #expect(!labels.contains("1/250"))
    }

    @Test func menusReadCurrentChoicesOnlyWhenOpenedAndRouteActions() {
        let view = ViewerToolbarStatusView()
        var reads = 0, version = 0
        var received: [ViewerStatusAction] = []
        view.onAction = { received.append($0) }
        view.choices = { reads += 1; return .init(profiles: version == 0 ? ["balanced"] : ["scene"]) }
        let count = descendants(view).count
        for _ in 0..<100 { view.update(sample()) }
        #expect(reads == 0 && descendants(view).count == count)
        let menu = view.makeMenu(for: "profile")
        menu.performActionForItem(at: 0)
        #expect(reads == 1 && received == [.profile("balanced")])
        version = 1
        #expect(view.makeMenu(for: "profile").items.first?.title == "scene")
        #expect(reads == 2)
        view.metadataButton.performClick(nil)
        #expect(received.last == .info)
    }

    @Test func numericInputsRejectNonfiniteFractionalAndOutOfRangeValues() {
        let zoom = ViewerStatusPopover(kind: .zoom)
        zoom.update(index: 0, count: 141, zoom: sample().zoomDetails)
        let position = ViewerStatusPopover(kind: .position)
        position.update(index: 0, count: 141, zoom: nil)
        var actions: [ViewerStatusAction] = []
        zoom.onAction = { actions.append($0) }; position.onAction = { actions.append($0) }
        for invalid in ["nan", "inf", "-1", "0", "6401", "word"] { #expect(!zoom.applyValue(invalid)) }
        for invalid in ["nan", "inf", "-1", "0", "142", "1.5", "1e30"] { #expect(!position.applyValue(invalid)) }
        #expect(actions.isEmpty)
        #expect(zoom.applyValue("275,5"))
        #expect(position.applyValue("42"))
        #expect(actions == [.zoomPercent(275.5), .position(41)])
        position.update(index: 0, count: nil, zoom: nil)
        #expect(!position.applyValue("1"))
    }

    @Test func emptySessionClearsPriorZoomAndExif() {
        let view = ViewerToolbarStatusView()
        view.update(sample())
        view.update(ImageStatus())
        #expect(view.profileButton.title == "—" && view.groupButton.title == "—")
        #expect(!view.zoomButton.isEnabled && !view.positionButton.isEnabled)
    }

    @Test func nativeToolbarKeepsStatusVisibleAtMinimumWindowWidth() async throws {
        let controller = toolbar()
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1100, height: 300),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.autorecalculatesKeyViewLoop = true
        defer { window.close() }
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.titleVisibility = .hidden
        controller.attach(to: window)
        window.toolbar = controller.nsToolbar
        controller.updateStatus(sample())
        window.orderFront(nil)
        for width: CGFloat in [3000, 2400, 1800, 1024, 800, 640, 400, 320] {
            window.setContentSize(NSSize(width: width, height: 300))
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            let item = try #require(controller.nsToolbar.items.first { $0.itemIdentifier.rawValue == "viewer.status" })
            let view = try #require(item.view as? ViewerToolbarStatusView)
            if ProcessInfo.processInfo.environment["LOUPE_STATUS_LAYOUT"] == "1" {
                print("STATUS_LAYOUT width=\(width) status=\(view.frame) fitting=\(view.fittingSize) intrinsic=\(view.intrinsicContentSize) min=\(item.minSize) max=\(item.maxSize) visible=\(controller.nsToolbar.visibleItems?.map { $0.itemIdentifier.rawValue } ?? [])")
            }
            #expect(view.frame.height == 46)
            #expect(view.frame.width <= width)
            #expect(view.frame.width <= view.preferredWidth + 1)
            #expect(controller.nsToolbar.visibleItems?.contains { $0 === item } == true, "Window width \(width)")
            #expect(view.window === window, "Window width \(width)")
            if width == 1800 {
                #expect(controller.nsToolbar.visibleItems?.contains { $0.itemIdentifier.rawValue == "viewer.vibrance" } == true,
                    "Status must compress before the Vibrance slider disappears at this width")
            }
            if width >= 400 {
                #expect(controller.nsToolbar.visibleItems?.contains { $0.itemIdentifier.rawValue == "viewer.back" } == true)
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOUPE_STATUS_BENCH"] == "1"))
    func nativeWindowBenchAndSnapshot() async throws {
        _ = NSApplication.shared
        var initial = sample()
        let start = ThreadCPU.milliseconds()
        let controller = toolbar()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1280, height: 420),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.autorecalculatesKeyViewLoop = true
        defer { window.close() }
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.titleVisibility = .hidden
        controller.attach(to: window)
        window.toolbar = controller.nsToolbar
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor(calibratedWhite: 0.17, alpha: 1).cgColor
        controller.updateStatus(initial)
        window.makeKeyAndOrderFront(nil)
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        print(String(format: "STATUS_BENCH open mainCPUms=%.3f", ThreadCPU.milliseconds() - start))
        let view = try #require(controller.nsToolbar.items.first { $0.itemIdentifier.rawValue == "viewer.status" }?.view as? ViewerToolbarStatusView)
        view.choices = { .init(profiles: ["Vision", "balanced", "portrait"], groups: []) }
        if ProcessInfo.processInfo.environment["LOUPE_STATUS_PROFILE"] == "1" {
            try String(getpid()).write(toFile: "/tmp/loupe-status-profile.pid", atomically: true, encoding: .utf8)
            print("STATUS_PROFILE pid=\(getpid())")
            fflush(stdout)
            try await Task.sleep(for: .seconds(2))
        }
        for round in 1...10 {
            let updateStart = ThreadCPU.milliseconds()
            for index in 0..<100 {
                initial.index = index
                initial.title = "Portrait_\(index).jpg"
                initial.facts[0] = .init(.position, "\(index + 1) / 141")
                controller.updateStatus(initial)
                view.layoutSubtreeIfNeeded()
            }
            let updates = (ThreadCPU.milliseconds() - updateStart) / 100
            let resizeStart = ThreadCPU.milliseconds()
            for width: CGFloat in [320, 400, 640, 800, 1024, 1800, 1280] {
                window.setContentSize(NSSize(width: width, height: 420))
                window.contentView?.superview?.layoutSubtreeIfNeeded()
            }
            let resizes = (ThreadCPU.milliseconds() - resizeStart) / 7
            try await Task.sleep(for: .milliseconds(100))
            let menuStart = ThreadCPU.milliseconds()
            _ = view.makeMenu(for: "profile")
            let menuCPU = ThreadCPU.milliseconds() - menuStart
            let popupStart = ThreadCPU.milliseconds()
            NSApp.sendAction(view.zoomButton.action!, to: view.zoomButton.target, from: view.zoomButton)
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(60))
            let popupCPU = ThreadCPU.milliseconds() - popupStart
            view.dismissPopover()
            try await Task.sleep(for: .milliseconds(250))
            print(String(format: "STATUS_BENCH round=%d update=%.3f resize=%.3f menu=%.3f popup=%.3f", round, updates, resizes, menuCPU, popupCPU))
        }
        var preview = sample()
        preview.title = "Studio_Portrait_Session_2026_001.jpg"
        preview.folder = URL(fileURLWithPath: "/Demo/Portrait session — selected photographs")
        preview.zoomDetails?.group = "Person · Full body · Standing"
        controller.updateStatus(preview)
        for width in [3000, 2400, 1800, 1280, 640, 320] {
            window.setContentSize(NSSize(width: width, height: 420))
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            if width == 3000, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/loupe-status-detail.png"))
            }
            if let frame = window.contentView?.superview {
                let rect = NSRect(x: 0, y: frame.bounds.maxY - 100, width: frame.bounds.width, height: 100)
                if let bitmap = frame.bitmapImageRepForCachingDisplay(in: rect) {
                    frame.cacheDisplay(in: rect, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/loupe-status-native-\(width).png"))
                }
            }
        }
    }
}
