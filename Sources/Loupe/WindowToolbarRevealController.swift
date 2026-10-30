import AppKit

/// Event-driven reveal for a windowed native toolbar. Full screen stays under
/// AppKit's native autohiding policy. No polling or recurring idle work.
@MainActor final class WindowToolbarRevealController {
    private let hideDelay: TimeInterval
    private let pointerLocation: @MainActor (NSWindow) -> NSPoint
    init(hideDelay: TimeInterval, pointerLocation: @escaping @MainActor (NSWindow) -> NSPoint = { $0.mouseLocationOutsideOfEventStream }) {
        self.hideDelay = hideDelay
        self.pointerLocation = pointerLocation
    }

    var onVisibilityChange: (() -> Void)?
    private weak var window: NSWindow?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var hideWork: DispatchWorkItem?
    private var menusOpen = 0

    deinit { MainActor.assumeIsolated { stop() } }

    func setEnabled(_ enabled: Bool, for window: NSWindow) {
        if !enabled { stop(); return }
        guard self.window !== window || monitor == nil else { return }
        stop()
        self.window = window
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseEntered, .mouseExited,
            .leftMouseUp, .rightMouseUp, .otherMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.window === self?.window { self?.evaluate() }
            }
            return event
        }
        observe(NSMenu.didBeginTrackingNotification, object: nil) { owner in
            owner.menusOpen += 1; owner.cancelHide()
        }
        observe(NSMenu.didEndTrackingNotification, object: nil) { owner in
            owner.menusOpen = max(0, owner.menusOpen - 1); owner.evaluate()
        }
        observe(NSWindow.didResignKeyNotification, object: window) { $0.setVisible(false) }
        observe(NSWindow.didBecomeKeyNotification, object: window) { $0.evaluate() }
        observe(NSWindow.willCloseNotification, object: window) { $0.stop() }
        evaluate()
    }

    private func observe(_ name: Notification.Name, object: AnyObject?, action: @escaping @MainActor (WindowToolbarRevealController) -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        })
    }

    private func stop() {
        cancelHide()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        window = nil
        menusOpen = 0
    }

    private func cancelHide() { hideWork?.cancel(); hideWork = nil }

    private func evaluate() {
        guard let window, let container = window.contentView, let toolbar = window.toolbar,
              menusOpen == 0 else { return }
        let point = container.convert(pointerLocation(window), from: nil)
        let layoutTop = container.convert(NSPoint(x: 0, y: window.contentLayoutRect.maxY), from: nil).y
        // Eight points below native chrome is a geometry affordance, not a
        // processing interval; the larger shown chrome supplies hysteresis.
        let inside = window.isKeyWindow && container.bounds.contains(point)
            && point.y >= layoutTop - 8
        if inside { cancelHide(); setVisible(true); return }
        guard NSEvent.pressedMouseButtons == 0, hideWork == nil, toolbar.isVisible else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hideWork = nil
                guard self.menusOpen == 0, self.window?.isKeyWindow == true else { return }
                self.setVisible(false)
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hideDelay, execute: work)
    }

    private func setVisible(_ visible: Bool) {
        guard let toolbar = window?.toolbar, toolbar.isVisible != visible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            toolbar.isVisible = visible
        }
        onVisibilityChange?()
    }
}
