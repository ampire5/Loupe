import AppKit

/// The viewer's toolbar in full screen, hidden over the photo and brought by the pointer, as the Zen sidebar does
/// (~/.claude/guides/hideable-sidebars-and-glass.md): the pointer touching the screen's top edge shows it at once; it
/// hides 150 ms after the pointer has left it, which may overshoot it by 100 pt. It stays while a menu is open (a
/// toolbar item's, or the menu bar's that slid in above it). After a show or a hide the edge stays quiet until the
/// pointer has left it, so a pointer resting there does not flicker it.
///
/// Mouse moves are watched only between `start` and `stop` (full screen over a photo with `⌥⌘T` on).
@MainActor final class FullScreenToolbar {
    /// How far below the toolbar the pointer may go before the hide starts.
    static let overshoot: CGFloat = 100
    /// How long after the pointer left the toolbar it hides.
    static let hideDelay: TimeInterval = 0.15
    /// How close to the screen's top the pointer must be to bring the toolbar.
    static let edge: CGFloat = 2

    private let window: () -> NSWindow?
    private var monitor: Any?
    private var menuObservers: [NSObjectProtocol] = []
    private var menusOpen = 0
    private var hideWork: DispatchWorkItem?
    /// Set by a show or a hide on the edge; cleared when the pointer leaves the edge.
    private var edgeQuiet = false

    init(window: @escaping () -> NSWindow?) { self.window = window }

    var isWatching: Bool { monitor != nil }

    func start() {
        guard monitor == nil else { return }
        edgeQuiet = isOnEdge(NSEvent.mouseLocation)   // a ⌥⌘T or a return from Home with the pointer up there
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged,
                                                              .otherMouseDragged]) { [weak self] event in
            self?.moved()
            return event
        }
        let center = NotificationCenter.default
        for (name, delta) in [(NSMenu.didBeginTrackingNotification, 1), (NSMenu.didEndTrackingNotification, -1)] {
            menuObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.menusOpen = max(0, self.menusOpen + delta)
                    self.moved()
                }
            })
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        menuObservers.forEach(NotificationCenter.default.removeObserver)
        menuObservers = []
        menusOpen = 0
        hideWork?.cancel()
        hideWork = nil
    }

    private func isOnEdge(_ point: CGPoint) -> Bool {
        guard let screen = window()?.screen else { return false }
        return point.y >= screen.frame.maxY - Self.edge
    }

    private func moved() {
        guard let window = window(), let toolbar = window.toolbar, let screen = window.screen else { return }
        let point = NSEvent.mouseLocation
        let onEdge = point.y >= screen.frame.maxY - Self.edge
        guard toolbar.isVisible else {
            if !onEdge { edgeQuiet = false } else if !edgeQuiet, window.isKeyWindow {
                toolbar.isVisible = true
                edgeQuiet = true
            }
            return
        }
        if !onEdge { edgeQuiet = false }
        // The toolbar's band: from the screen's top (the menu bar slides in above it) to its bottom, and the overshoot.
        let toolbarBottom = window.convertPoint(toScreen: CGPoint(x: 0, y: window.contentLayoutRect.maxY)).y
        let keeps = menusOpen > 0 || point.y >= toolbarBottom - Self.overshoot
        if keeps {
            hideWork?.cancel()
            hideWork = nil
            return
        }
        guard hideWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hideWork = nil
            guard self.isWatching, self.menusOpen == 0 else { return }
            window.toolbar?.isVisible = false
            self.edgeQuiet = self.isOnEdge(NSEvent.mouseLocation)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideDelay, execute: work)
    }
}
