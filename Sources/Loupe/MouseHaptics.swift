import Foundation
import LoupeCore
import LogiHIDPP

/// Plays a haptic pattern on the mouse by its LogiHIDPP `HapticPattern`, at `strength` (0…100) or, nil, the mouse's normal
/// strength. The app's player is `LogiMouse` (`AppDelegate`); without one (a secondary launch) nothing vibrates.
@MainActor protocol HapticPlaying: AnyObject {
    func play(_ pattern: HapticPattern, strength: UInt8?)
}

/// The mouse's haptic answers (M4c spec §5, §11): which pattern each event plays comes from loupe.conf
/// (`haptic-zoom-stop`, `haptic-limit`, `haptic-step`, `haptic-detent`, `haptic-long-armed`, `haptic-toggle`,
/// `haptic-end`), read at each call so a reload applies at once; `none` or `mouse-haptics=no` plays nothing. A value that ends in `strong` plays at `haptic-strong-strength`, the rest at
/// the mouse's normal strength (`haptic-strength`, set by `AppDelegate`). Only events a mouse or a key started call
/// these: a trackpad gesture keeps its own trackpad tick. The package itself stays silent in the background and with
/// haptics off in the mouse, and a newer pattern replaces one not yet sent, so fast steps do not queue up.
@MainActor final class MouseHaptics {
    static let shared = MouseHaptics()

    /// Set once a `LogiMouse` exists; nil plays nothing.
    var player: HapticPlaying?

    private init() {}

    /// A right-button zoom (the drag or its coast) or a `zoom-step` (the gesture button + wheel) lands on a zoom stop.
    func zoomStop() { play(Settings.shared.config.hapticZoomStop, "zoom stop") }

    /// A right-button zoom or a `zoom-step` gets to a zoom limit, or an `add` step pushes past the end of the key's
    /// range.
    func limit() { play(Settings.shared.config.hapticLimit, "limit") }

    /// An `add` step inside the key's range.
    func step() { play(Settings.shared.config.hapticStep, "step") }

    /// An `add` step lands on or crosses a detent (25 / 50 / 75 % of the key's range): in place of `step`.
    func detent() { play(Settings.shared.config.hapticDetent, "detent") }

    /// A held button whose long press fires on release (built in: the panel, forward) reaches the long-press deadline:
    /// releasing now counts as a long press.
    func longArmed() { play(Settings.shared.config.hapticLongArmed, "long armed") }

    /// A `toggle-*` / `cycle-*` action done from a key or a mouse button.
    func toggle() { play(Settings.shared.config.hapticToggle, "toggle") }

    /// A previous / next step by the wheel, a key or a mouse button stopped at an end of the folder (`EndBump` decides
    /// when).
    func end() { play(Settings.shared.config.hapticEnd, "end") }

    private func play(_ choice: HapticChoice?, _ event: String) {
        let config = Settings.shared.config
        guard config.mouseHaptics, let choice, let player else { return }
        DebugLog.log("haptic \(event) \(HapticChoice.text(choice))")
        player.play(choice.pattern, strength: choice.strong ? UInt8(config.hapticStrongStrength) : nil)   // 0…100
    }
}
