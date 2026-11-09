import AppKit
import LoupeCore
import LoupeRender
import Testing
@testable import Loupe

@MainActor @Suite(.serialized) struct ViewerMouseWorkflowTests {
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
        strip.windowDidResignKey()
        #expect(session.playlist?.current == files[expected])
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
            view.thumbWheelZoom(delta: 12, stepsPerRevolution: 360, began: true, at: 1)
            #expect(session.smartZoom.mode == mode)
            let manual = NSMenuItem(); manual.representedObject = KeyAction.manualZoom.rawValue
            view.performKeyAction(manual)
            #expect(session.smartZoom.mode == .off)
            #expect(session.smartZoom.lastEnabled == mode)
        }
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
        view.rightMouseDown(with: try event(.rightMouseDown, y: 300, at: 0))
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
