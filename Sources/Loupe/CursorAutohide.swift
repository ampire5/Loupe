import AppKit

/// Hides the cursor once the mouse has been still for `cursor-autohide` (EdgeView's "hide cursor
/// automatically"). The view reports every mouse movement and press with `activity()`; one timer is kept
/// and pushed back to the latest activity when it fires early, so a moving mouse never reschedules it.
/// Hiding is `NSCursor.setHiddenUntilMouseMoves`: the system brings the cursor back on the next move,
/// and keys, the wheel and trackpad scrolling leave it hidden.
@MainActor final class CursorAutohide {
    /// Whether the cursor may be hidden right now (over the picture and not over the thumbnail strip, window
    /// key, no button held); asked when the delay runs out.
    var canHide: () -> Bool = { false }
    private var lastActivity: CFTimeInterval = 0
    private var timer: Timer?

    private var delay: TimeInterval? {
        Settings.shared.config.cursorAutohideMilliseconds.map { Double($0) / 1000 }
    }

    /// The mouse moved or a button changed: the countdown starts over.
    func activity() {
        lastActivity = CACurrentMediaTime()
        guard timer == nil, let delay else { return }
        schedule(after: delay)
    }

    /// No hiding until the next `activity()` (window no longer key, view gone).
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func schedule(after interval: TimeInterval) {
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
    }

    private func fire() {
        timer = nil
        // The setting is re-read here, so an edit made while the mouse rests applies from the next move.
        guard let delay else { return }
        let remaining = lastActivity + delay - CACurrentMediaTime()
        if remaining > 0.01 { schedule(after: remaining); return }
        if canHide() { NSCursor.setHiddenUntilMouseMoves(true) }
    }
}
