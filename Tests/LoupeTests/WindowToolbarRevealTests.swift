import AppKit
import Testing
@testable import Loupe

@MainActor private final class RevealTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@MainActor @Suite(.serialized) struct WindowToolbarRevealTests {
    @Test func windowedToolbarRevealsHidesAndStopsWhenDisabled() async {
        _ = NSApplication.shared
        let window = RevealTestWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.autorecalculatesKeyViewLoop = true
        let toolbar = NSToolbar(identifier: UUID().uuidString)
        window.toolbar = toolbar
        var point = NSPoint(x: 200, y: 200)
        let reveal = WindowToolbarRevealController(hideDelay: 0, pointerLocation: { _ in point })
        defer { reveal.setEnabled(false, for: window); window.close() }
        reveal.setEnabled(true, for: window)
        for _ in 0..<100 {
            if !toolbar.isVisible { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(!toolbar.isVisible)
        point.y = window.contentView!.bounds.maxY - 1
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        #expect(toolbar.isVisible)
        point.y = 200
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        reveal.setEnabled(false, for: window)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(toolbar.isVisible) // A cancelled hide cannot hide a subsequently pinned toolbar.
    }
}
