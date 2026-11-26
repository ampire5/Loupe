import AppKit
import Filmstrip
import LoupeCore
import LoupeRender
import Testing
@testable import Loupe

@MainActor @Suite(.serialized) struct ViewerMouseWorkflowTests {
    @Test func referenceCaptureFinishesZoomAndClearsElasticMotion() throws {
        _ = NSApplication.shared
        let reader = FileReader(threads: 1)
        let cache = ImageCache(loader: MetalPyramidLoader(), reader: reader, pool: DecodePool(), limits: CacheLimits(config: Config()))
        let thumbs = ThumbnailStore(directory: nil, reader: reader, thumbSize: 320, limitBytes: 0)
        let session = ViewerSession(cache: cache, thumbnails: thumbs, positions: FolderPositions(database: nil))
        defer { session.close() }
        let view = ViewerView(session: session, resampling: ResampleSettings(config: Config()))
        let target = ViewTransform(imageSize: .init(width: 1200, height: 1500), viewSize: .init(width: 600, height: 600), mode: .actual(1.4), center: .init(x: 0.65, y: 0.45)).clamped
        session.transform = target.withMode(.actual(0.8)).withOffset(.init(dx: 10, dy: -4))
        session.zoomTarget = target
        let captured = view.settleForFramingReference()
        #expect(session.zoomTarget == nil)
        #expect(captured == target && session.transform == target)
        _ = try FramingGeometry(captured)
        session.transform = target.withStretch(.init(factor: 1.1, anchor: .init(x: 200, y: 200)))
        let unstretched = view.settleForFramingReference()
        #expect(unstretched == target)
        #expect(view.settleForFramingReference() == target)
    }
    @Test func twoFingerPanMovesOnBothAxesFromFirstDeltaThroughMomentum() throws {
        _ = NSApplication.shared
        let reader = FileReader(threads: 1)
        let cache = ImageCache(loader: MetalPyramidLoader(), reader: reader, pool: DecodePool(), limits: CacheLimits(config: Config()))
        let thumbs = ThumbnailStore(directory: nil, reader: reader, thumbSize: 320, limitBytes: 0)
        let session = ViewerSession(cache: cache, thumbnails: thumbs, positions: FolderPositions(database: nil))
        defer { session.close() }
        let view = ViewerView(session: session, resampling: ResampleSettings(config: Config()))
        session.transform = ViewTransform(imageSize: CGSize(width: 1200, height: 1200),
                                          viewSize: CGSize(width: 600, height: 600)).withMode(.actual(1))

        func scroll(_ x: Int32, _ y: Int32, phase: CGScrollPhase?, appKitPhase: NSEvent.Phase, momentum: NSEvent.Phase = [], modifiers: CGEventFlags = []) throws {
            let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                          wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0))
            cg.flags = modifiers
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum == .began ? 1 : 0))
            let event = try #require(NSEvent(cgEvent: cg))
            try #require(event.hasPreciseScrollingDeltas)
            try #require(event.phase == appKitPhase)
            try #require(event.momentumPhase == momentum)
            let expected = session.transform.panned(by: CGVector(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY))
            view.scrollWheel(with: event)
            #expect(session.transform.center == expected.center)
        }

        try scroll(1, 2, phase: .began, appKitPhase: .began)
        try scroll(1, 8, phase: .changed, appKitPhase: .changed)
        try scroll(8, 1, phase: .changed, appKitPhase: .changed)
        try scroll(0, 0, phase: .ended, appKitPhase: .ended)
        try scroll(6, 3, phase: nil, appKitPhase: [], momentum: .began)
        // Holding Command while panning no longer reserves this swipe for tab switching.
        try scroll(60, 0, phase: .began, appKitPhase: .began, modifiers: .maskCommand)
    }

    @Test func filmstripScrollMovesTheCandidateBeforeCommittingOnePhoto() throws {
        _ = NSApplication.shared
        let reader = FileReader(threads: 1)
        let cache = ImageCache(loader: MetalPyramidLoader(), reader: reader, pool: DecodePool(), limits: CacheLimits(config: Config()))
        let thumbs = ThumbnailStore(directory: nil, reader: reader, thumbSize: 320, limitBytes: 0)
        let session = ViewerSession(cache: cache, thumbnails: thumbs, positions: FolderPositions(database: nil))
        let strip = StripController(session: session, store: thumbs)
        defer { strip.close(); session.close() }
        strip.view.frame = NSRect(x: 0, y: 0, width: 600, height: 48)
        strip.apply(Config())
        let files = (0..<60).map { URL(fileURLWithPath: "/Loupe-gesture-test/\($0).png") }
        session.openPhotos(files, current: files[30])
        strip.sessionDidChange()
        let layout = strip.view.layout

        func scroll(_ phase: CGScrollPhase) throws -> NSEvent {
            let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                          wheelCount: 2, wheel1: 0, wheel2: 120, wheel3: 0))
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            return try #require(NSEvent(cgEvent: cg))
        }
        let first = try scroll(.began), second = try scroll(.changed)
        let sign = FingerDirection.sign(invertedFromDevice: first.isDirectionInvertedFromDevice)
        let expected = try #require(layout.item(atBase: layout.centre(of: 30) - sign * (first.scrollingDeltaX + second.scrollingDeltaX)))
        try #require(expected != 30)
        strip.view.onStripScroll?(first)
        strip.view.onStripScroll?(second)
        #expect(session.playlist?.current == files[30])
        func visibleText(in view: NSView) -> [String] {
            guard !view.isHidden else { return [] }
            if let field = view as? NSTextField { return [field.stringValue] }
            return view.subviews.flatMap(visibleText)
        }
        #expect(visibleText(in: strip.view) == ["\(expected + 1) / 60"])
        strip.windowDidResignKey()
        #expect(session.playlist?.current == files[expected])
        #expect(visibleText(in: strip.view).isEmpty)
    }

    @Test func filmstripDragReversesFromThePositionOnScreen() throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        _ = NSApplication.shared
        let thumbs = ThumbnailStore(directory: nil, reader: FileReader(threads: 1), thumbSize: 320, limitBytes: 0)
        let session = ViewerSession(cache: ImageCache(loader: MetalPyramidLoader()), thumbnails: thumbs,
                                    positions: FolderPositions(database: nil))
        let strip = StripController(session: session, store: thumbs)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { strip.close(); session.close(); window.close() }
        strip.view.frame = NSRect(x: 0, y: 0, width: 600, height: strip.bandHeight)
        window.contentView?.addSubview(strip.view)
        window.orderBack(nil)
        try #require(window.isVisible)
        var config = Config()
        config.stripWindow = .over
        strip.apply(config)

        let files = (0..<60).map { URL(fileURLWithPath: "/Loupe-reverse-test/\($0).png") }
        session.openPhotos(files, current: files[30])
        strip.sessionDidChange()
        let pitch = strip.view.layout.centre(of: 31) - strip.view.layout.centre(of: 30)
        strip.view.onDrag?(-pitch * 0.55)
        try #require(session.playlist?.current == files[31])
        strip.view.onDragEnd?()

        // Reverse across the boundary while the strip is still just past it. A restart from the snap's
        // destination would keep 31 selected with the same amount of pointer travel.
        strip.view.onDrag?(pitch * 0.15)
        strip.view.onDragEnd?()
        #expect(session.playlist?.current == files[30])
    }

    @Test func filmstripHoverRestartsTheDetailsDwellWhenThePointerMoves() async throws {
        let hover = StripHover()
        var titles: [Int] = [], details: [Int] = []
        hover.onRest = { [weak hover] in if let file = hover?.restedFile { titles.append(file) } }
        hover.onDetail = { details.append($0) }
        defer { hover.drop() }
        #expect(hover.set(3))
        let deadline = ContinuousClock.now + .seconds(2)
        while titles.isEmpty, .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(titles == [3])
        try #require(details.isEmpty)

        #expect(hover.set(4))
        while details.isEmpty, .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(titles == [3, 4])
        #expect(details == [4])
    }

    @Test func filmstripCaptionKeepsTheTitleInPlaceWhenDetailsArriveNearAnEdge() throws {
        _ = NSApplication.shared
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 180))
        let caption = StripCaption()
        root.addSubview(caption)
        let title = "6 / 48 · Dunes.jpg"
        let detail = "1/250 · f/2.8 · ISO 400 · 24 MP"

        func fields(in view: NSView) -> [NSTextField] {
            guard !view.isHidden else { return [] }
            if let field = view as? NSTextField { return [field] }
            return view.subviews.flatMap(fields)
        }

        caption.show(title: title, centre: 40, above: 80, within: root.bounds)
        let titleField = try #require(fields(in: caption).first)
        let frame = root.convert(titleField.bounds, from: titleField)
        caption.show(title: title, detail: detail, centre: 40, above: 80, within: root.bounds)
        #expect(fields(in: caption).map(\.stringValue) == [title, detail])
        #expect(root.convert(titleField.bounds, from: titleField) == frame)

        let tools = NSRect(x: 236, y: 84, width: 108, height: 32)
        caption.show(title: title, detail: detail, centre: 310, above: 80, within: root.bounds, avoiding: tools)
        #expect(caption.frame.maxX <= tools.minX)
    }

    @Test func filmstripToolsLeaveTheThumbnailsClear() throws {
        _ = NSApplication.shared
        let thumbs = ThumbnailStore(directory: nil, reader: FileReader(threads: 1), thumbSize: 320, limitBytes: 0)
        let session = ViewerSession(cache: ImageCache(loader: MetalPyramidLoader()), thumbnails: thumbs,
                                    positions: FolderPositions(database: nil))
        let strip = StripController(session: session, store: thumbs)
        defer { strip.close(); session.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 460))
        root.addSubview(strip.view)
        NSLayoutConstraint.activate([
            strip.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            strip.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            strip.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        strip.attach(to: root)
        var config = Config()
        config.stripWindow = .over
        config.stripHeight = 192
        config.stripFadeInMilliseconds = 0
        strip.apply(config)
        let files = (0..<10).map { URL(fileURLWithPath: "/Loupe-tools-test/\($0).png") }
        session.openPhotos(files, current: files[5])
        strip.sessionDidChange()
        root.layoutSubtreeIfNeeded()

        let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 360, y: 4),
                                                   modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                   context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        strip.mouseMoved(with: event)
        root.layoutSubtreeIfNeeded()
        strip.mouseMoved(with: event)
        root.layoutSubtreeIfNeeded()
        let capsule = try #require(root.subviews.compactMap { $0 as? FilmstripToolsView }.first)
        try #require(capsule.alphaValue == 1)
        #expect(strip.view.frame.height == 204)
        #expect(capsule.frame.minY >= strip.view.frame.maxY)
        #expect(root.bounds.contains(capsule.frame))

        let gap = try #require(NSEvent.mouseEvent(with: .mouseMoved,
                                                   location: NSPoint(x: capsule.frame.midX, y: capsule.frame.minY - 1),
                                                   modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                   context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        strip.mouseMoved(with: gap)
        #expect(capsule.alphaValue == 1)

        root.setFrameSize(NSSize(width: 340, height: 224))
        root.layoutSubtreeIfNeeded()
        #expect(strip.view.frame.height < 204)
        #expect(root.bounds.contains(capsule.frame))
        #expect(capsule.frame.minY >= strip.view.frame.maxY)
        root.setFrameSize(NSSize(width: 720, height: 460))
        root.layoutSubtreeIfNeeded()
        #expect(strip.view.frame.height == 204)
    }

    @Test func filmstripFlingAtEitherEndKeepsTheEndFrameAndReverses() throws {
        _ = NSApplication.shared
        let thumbs = ThumbnailStore(directory: nil, reader: FileReader(threads: 1), thumbSize: 320, limitBytes: 0)
        let session = ViewerSession(cache: ImageCache(loader: MetalPyramidLoader()), thumbnails: thumbs,
                                    positions: FolderPositions(database: nil))
        let strip = StripController(session: session, store: thumbs)
        defer { strip.close(); session.close() }
        strip.view.frame = NSRect(x: 0, y: 0, width: 600, height: strip.bandHeight)
        strip.apply(Config())

        func swipe(_ phase: CGScrollPhase, towardNext pixels: Int32) throws {
            let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                          wheel1: 0, wheel2: pixels, wheel3: 0))
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            let event = try #require(NSEvent(cgEvent: cg))
            if FingerDirection.sign(invertedFromDevice: event.isDirectionInvertedFromDevice) > 0 {
                cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -Int64(pixels))
            }
            strip.view.onStripScroll?(try #require(NSEvent(cgEvent: cg)))
        }

        let files = (0..<100).map { URL(fileURLWithPath: "/Loupe-end-test/\($0).png") }
        let centre = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 300, y: 40),
                                                    modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                    context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        var underCentre: Int?
        strip.view.onHover = { underCentre = $0 }
        for (edge, direction, neighbour) in [(0, Int32(-1), 1), (99, Int32(1), 98)] {
            session.openPhotos(files, current: files[edge])
            strip.sessionDidChange()
            try swipe(.began, towardNext: 5000 * direction)
            strip.view.mouseMoved(with: centre)
            #expect(underCentre == edge)
            try swipe(.changed, towardNext: -85 * direction)
            strip.windowDidResignKey()
            #expect(session.playlist?.current == files[neighbour])
        }
    }

    @Test func manualPresetsAndThumbWheelDoNotDisableSmartZoom() {
        _ = NSApplication.shared
        let reader = FileReader(threads: 1)
        let cache = ImageCache(loader: MetalPyramidLoader(), reader: reader, pool: DecodePool(), limits: CacheLimits(config: Config()))
        let thumbs = ThumbnailStore(directory: nil, reader: reader, thumbSize: 320, limitBytes: 0)
        let session = ViewerSession(cache: cache, thumbnails: thumbs, positions: FolderPositions(database: nil))
        defer { session.close() }
        let view = ViewerView(session: session, resampling: ResampleSettings(config: Config()))
        view.onZoomKey = { action in
            if action == .manualZoom || action == .fit { session.smartZoom.select(.off) }
            return true
        }
        let photo = URL(fileURLWithPath: "/Demo/photo.png")
        for mode in [SmartZoomMode.frame, .pan] {
            session.smartZoom.select(mode)
            session.transform = ViewTransform(imageSize: CGSize(width: 1000, height: 1500), viewSize: CGSize(width: 1200, height: 800))
            for action in [KeyAction.fit, .actual100, .zoomIn, .zoomOut, .toggleFitActual, .fitWidth, .fitHeight, .fill] {
                let request = SmartZoomRequest(photo: photo, revision: session.smartZoomRevision)
                let item = NSMenuItem(); item.representedObject = action.rawValue
                view.performKeyAction(item)
                #expect(session.smartZoom.mode == mode)
                #expect(!request.matches(photo: photo, revision: session.smartZoomRevision, enabled: true))
            }
            view.thumbWheelZoom(delta: 12, stepsPerRevolution: 360, began: true, ended: false, at: 1)
            #expect(session.smartZoom.mode == mode)
            let manual = NSMenuItem(); manual.representedObject = KeyAction.manualZoom.rawValue
            view.performKeyAction(manual)
            #expect(session.smartZoom.mode == .off)
            #expect(session.smartZoom.lastEnabled == mode)
        }
    }
    @Test func thumbWheelEndDiscardsTheHeldStop() {
        _ = NSApplication.shared
        let reader = FileReader(threads: 1)
        let cache = ImageCache(loader: MetalPyramidLoader(), reader: reader, pool: DecodePool(), limits: CacheLimits(config: Config()))
        let thumbs = ThumbnailStore(directory: nil, reader: reader, thumbSize: 320, limitBytes: 0)
        let session = ViewerSession(cache: cache, thumbnails: thumbs, positions: FolderPositions(database: nil))
        defer { session.close() }
        let view = ViewerView(session: session, resampling: ResampleSettings(config: Config()))
        view.zoomStopMode = .fixed
        session.transform = ViewTransform(imageSize: CGSize(width: 1200, height: 1200),
                                          viewSize: CGSize(width: 600, height: 600)).withMode(.actual(0.9))
        let inward = Settings.shared.config.thumbZoomInvert ? 1 : -1
        view.thumbWheelZoom(delta: 36 * inward, stepsPerRevolution: 360, began: true, ended: false, at: 1)
        #expect(session.transform.scale == 1)
        view.thumbWheelZoom(delta: 0, stepsPerRevolution: 360, began: false, ended: true, at: 1.1)
        #expect(session.transform.scale == 1)
        // A phase-less follow-up must be able to leave the stop even without a new began event.
        view.thumbWheelZoom(delta: inward, stepsPerRevolution: 360, began: false, ended: false, at: 1.2)
        #expect(session.transform.scale > 1)
    }

    @Test func rightVerticalDragZoomsWhileSmartZoomRemainsEnabled() throws {
        _ = NSApplication.shared
        let reader = FileReader(threads: 1)
        let cache = ImageCache(loader: MetalPyramidLoader(), reader: reader, pool: DecodePool(), limits: CacheLimits(config: Config()))
        let thumbs = ThumbnailStore(directory: nil, reader: reader, thumbSize: 320, limitBytes: 0)
        let session = ViewerSession(cache: cache, thumbnails: thumbs, positions: FolderPositions(database: nil))
        defer { session.close() }
        let view = ViewerView(session: session, resampling: ResampleSettings(config: Config()))
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 600)
        session.smartZoom.select(.frame)
        session.transform = ViewTransform(imageSize: CGSize(width: 1200, height: 1200), viewSize: CGSize(width: 600, height: 600))
        let buttons = MouseButtons.shared
        buttons.cancelAll()
        let oldState = buttons.pressedButtons
        let oldTarget = buttons.target
        let oldBrowser = buttons.browser
        buttons.pressedButtons = { 2 }
        buttons.target = { nil }; buttons.browser = { nil }
        defer { buttons.cancelAll(); buttons.pressedButtons = oldState; buttons.target = oldTarget; buttons.browser = oldBrowser }
        func event(_ type: NSEvent.EventType, y: CGFloat, at time: TimeInterval) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: 300, y: y), modifierFlags: [],
                timestamp: time, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let start = session.transform.scale
        let revision = session.smartZoomRevision
        var rightClicks = 0
        view.onRightClick = { _ in rightClicks += 1 }
        view.rightMouseDown(with: try event(.rightMouseDown, y: 300, at: 0))
        #expect(rightClicks == 0)
        view.rightMouseUp(with: try event(.rightMouseUp, y: 300, at: 0.05))
        #expect(rightClicks == 1)
        view.rightMouseDown(with: try event(.rightMouseDown, y: 300, at: 0.06))
        #expect(session.smartZoomRevision == revision)
        view.rightMouseDragged(with: try event(.rightMouseDragged, y: 320, at: 0.1))
        #expect(session.transform.scale != start)
        #expect(session.smartZoomRevision > revision)
        #expect(session.smartZoom.mode == .frame)
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line,
            wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0))
        _ = buttons.wheel(try #require(NSEvent(cgEvent: cg)))
        let horizontal = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line,
            wheelCount: 2, wheel1: 0, wheel2: 1, wheel3: 0))
        #expect(buttons.wheel(try #require(NSEvent(cgEvent: horizontal))))
        let afterWheel = session.transform.scale
        view.rightMouseDragged(with: try event(.rightMouseDragged, y: 340, at: 0.2))
        #expect(session.transform.scale != afterWheel)
        view.rightMouseUp(with: try event(.rightMouseUp, y: 340, at: 0.3))
        #expect(rightClicks == 1)
    }

    @Test func rightModifierAndColourWheelDoNotCancelPendingSmartZoom() throws {
        _ = NSApplication.shared
        let reader = FileReader(threads: 1)
        let cache = ImageCache(loader: MetalPyramidLoader(), reader: reader, pool: DecodePool(), limits: CacheLimits(config: Config()))
        let thumbs = ThumbnailStore(directory: nil, reader: reader, thumbSize: 320, limitBytes: 0)
        let session = ViewerSession(cache: cache, thumbnails: thumbs, positions: FolderPositions(database: nil))
        defer { session.close() }
        let view = ViewerView(session: session, resampling: ResampleSettings(config: Config()))
        session.smartZoom.select(.frame)
        let buttons = MouseButtons.shared
        buttons.cancelAll()
        let oldState = buttons.pressedButtons
        let oldTarget = buttons.target
        let oldBrowser = buttons.browser
        buttons.pressedButtons = { 2 }
        buttons.target = { view }; buttons.browser = { nil }
        defer { buttons.cancelAll(); buttons.pressedButtons = oldState; buttons.target = oldTarget; buttons.browser = oldBrowser }
        let revision = session.smartZoomRevision
        let down = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        view.rightMouseDown(with: down)
        #expect(session.smartZoomRevision == revision)
        buttons.press(.panel, at: 0.01)
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0))
        let wheel = try #require(NSEvent(cgEvent: cg))
        view.scrollWheel(with: wheel)
        #expect(session.smartZoomRevision == revision)
        #expect(session.smartZoom.mode == .frame)
        buttons.release(.panel, at: 0.1)
        buttons.pressedButtons = { 0 } // The RMB-up event was lost over a different view.
        buttons.move(dx: 0, dy: 0)
        #expect(!buttons.rightZoomSuppressed)
    }

}
