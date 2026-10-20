import LogiHIDPP
import SettingsKit

extension SettingsPanel {
    /// The `haptic-*` patterns as loupe.conf spells them: none, every pattern, then every pattern at the strong strength.
    static let hapticChoices: [(word: String, title: String)] = {
        let plain = HapticPattern.all.map { (word: $0.configName, title: $0.name.prefix(1).uppercased() + $0.name.dropFirst()) }
        return [(word: "none", title: "None")] + plain + plain.map { (word: $0.word + " strong", title: $0.title + ", strong") }
    }()

    /// Mouse & Trackpad (spec §5): button timing, the wheel, the MX Master's haptics and buttons. The bindings
    /// themselves are in input.conf (Key Bindings).
    static let mouse = SettingsPage("mouse", "Mouse & Trackpad", symbol: "computermouse", sections: [
        SettingsSection("Buttons", rows: [
            .number("mouse-long-press", "Long press", unit: "ms", step: 50, symbol: "button.programmable",
                    description: "A press held this long is a long one. A button bound with + wheel or + movement (the "
                        + "panel, forward) does its long action on release, if not turned or moved. 150–2000 ms, "
                        + "default 400."),
            .number("mouse-move-step", "Movement step", unit: "pt", step: 2, symbol: "arrow.up.and.down.circle",
                    description: "One step of a held button + moving the mouse up or down (the panel + movement: "
                        + "vibrance strength). 4–200 pt, default 20."),
        ]),
        SettingsSection("Wheel", rows: [
            .choice("wheel-direction", "Wheel direction", [
                (word: "content", title: "As content scrolls"), (word: "device", title: "As the wheel turns"),
            ], symbol: "scroll",
            description: "Content: the notch that scrolls a page down shows the next photo, after LinearMouse, Mac "
                + "Mouse Fix and natural scrolling, as in every app; Device: by the wheel's physical turn. Default "
                + "As content scrolls."),
        ]),
        SettingsSection("Haptics", rows: [
            .toggle("mouse-haptics", "MX Master haptics", symbol: "waveform",
                    description: "The MX Master 4's vibration, through the Bolt receiver, without Logi Options+. "
                        + "A pattern per event, or None. Default on.",
                    nested: [
                        .choice("haptic-zoom-stop", "Zoom stop", hapticChoices,
                                description: "Right-button zoom reaches a stop (on a pinch the trackpad clicks "
                                    + "itself). Default Subtle collision."),
                        .choice("haptic-limit", "Limit", hapticChoices,
                                description: "Right-button zoom at its limit; auto colour or vibrance strength at 0 "
                                    + "or 1. Default Sharp collision."),
                        .choice("haptic-step", "Adjustment step", hapticChoices,
                                description: "A step of the panel + wheel or forward + wheel. Default Whisper "
                                    + "collision."),
                        .choice("haptic-toggle", "Switch", hapticChoices,
                                description: "A switch by a key or button (auto colour, vibrance, the bar, the info "
                                    + "panel…), not by a menu item. Default Sharp state change."),
                        .choice("haptic-long-armed", "Long press armed", hapticChoices,
                                description: "A button with + wheel or + movement held past Long press: let go now "
                                    + "for its long action. Default Damp state change."),
                        .choice("haptic-detent", "Detent", hapticChoices,
                                description: "The 0.25 / 0.50 / 0.75 marks while adjusting auto colour or vibrance "
                                    + "strength, in place of the step. Default Damp collision."),
                        .choice("haptic-end", "First or last photo", hapticChoices,
                                description: "Stepping hit the folder's first or last photo (wheel, keys, button), "
                                    + "once per stop. Default Sharp collision, strong."),
                        .number("haptic-strength", "Strength", step: 5,
                                description: "The mouse's normal vibration strength. 0–100, or keep (default): "
                                    + "never written."),
                        .number("haptic-strong-strength", "Strong strength", step: 5,
                                description: "For the patterns marked strong. 0–100, default 80."),
                    ]),
        ]),
        SettingsSection("MX Master", rows: [
            .number("mx-panel-force", "Panel force", step: 5, symbol: "hand.point.down",
                    description: "How hard the haptic panel must be pressed: 0 the lightest the mouse takes, 100 the "
                        + "stiffest, default the factory value; keep (default) leaves it alone."),
            .choice("mx-side-buttons", "Side buttons", [
                (word: "watch", title: "Watch"), (word: "take", title: "Take"), (word: "system", title: "System"),
            ], symbol: "arrow.left.arrow.right.circle",
            description: "Back and forward. Watch: heard through the mouse, still the system's (Mac Mouse Fix keeps "
                + "them; over a Loupe window only); Take: Loupe's while in front; System: the system's events. A "
                + "press that moved 8 pt or more does not count. Default Watch."),
            .toggle("thumb-wheel-zoom", "Thumb wheel zooms", symbol: "dial.medium",
                    description: "The thumb wheel with no button held zooms smoothly at the pointer: right in, left "
                        + "out. A button bound with + thumb wheel still takes it. Off: the system's horizontal "
                        + "scrolling. Default on.",
                    nested: [
                        .number("thumb-zoom-speed", "Speed", unit: "×", step: 0.25,
                                description: "Doublings per turn of the wheel: 2 makes one turn ×4. 0.25–8, default 2."),
                        .choice("thumb-zoom-stops", "Zoom stops", [
                            (word: "tick", title: "Tick"), (word: "halt", title: "Halt"),
                        ], description: "Tick: the zoom goes through a stop and the mouse ticks (Zoom stop haptic); "
                            + "Halt: one turn halts on each stop, as a pinch, the next turn goes on. Default Tick."),
                        .toggle("thumb-zoom-invert", "Invert",
                                description: "Left zooms in, right out. Default off."),
                    ]),
        ]),
    ])
}
