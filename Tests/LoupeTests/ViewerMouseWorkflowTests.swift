import AppKit
import LoupeCore
import LoupeRender
import Testing
@testable import Loupe

@MainActor @Suite(.serialized) struct ViewerMouseWorkflowTests {
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
            view.thumbWheelZoom(delta: 12, stepsPerRevolution: 360, began: true)
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
        view.rightMouseDragged(with: try event(.rightMouseDragged, y: 400, at: 0.1))
        #expect(session.transform.scale != start)
        #expect(session.smartZoomRevision > revision)
        #expect(session.smartZoom.mode == .frame)
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line,
            wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0))
        _ = buttons.wheel(try #require(NSEvent(cgEvent: cg)))
        let afterWheel = session.transform.scale
        view.rightMouseDragged(with: try event(.rightMouseDragged, y: 500, at: 0.2))
        #expect(session.transform.scale == afterWheel)
        view.rightMouseUp(with: try event(.rightMouseUp, y: 500, at: 0.3))
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
