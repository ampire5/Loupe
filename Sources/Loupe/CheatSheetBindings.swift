import LoupeCore
import SettingsKit

@MainActor
extension CheatSheetView.Sheet {
    /// An action input.conf left without a key is not listed.
    static func bindings(inputMap: InputMap) -> Self {
        func keys(_ group: KeyGroup) -> [(keys: String, title: String)] {
            KeyAction.allCases.map { inputMap.keys.label($0) }.filter { $0.group == group && !$0.keys.isEmpty }
                .map { ($0.keys, $0.title) }
        }
        let buttons = inputMap.mouseLabels()
        let mouse = buttons.isEmpty ? [] : [Section(title: "Mouse", rows: buttons.map { ($0.input, $0.title) })]
        let steps = inputMap.keys.stepLabels()
        let custom = steps.isEmpty ? [] : [Section(title: "input.conf", rows: steps.map { ($0.keys, $0.title) })]
        let stash = Settings.shared.config.stashURL == nil ? [] : [Section(title: "Stash", rows: stashRows)]
        return Self(columns: [
            [Section(title: "Navigation", rows: keys(.navigation)), Section(title: "Colour", rows: keys(.colour)),
             Section(title: "View", rows: keys(.view))] + custom,
            // input.conf's tab and window keys under the menu's.
            [Section(title: "Zoom", rows: keys(.zoom)), Section(title: "Scaling", rows: keys(.scaling)),
             Section(title: "Window", rows: menuRows() + keys(.tabs))] + stash,
            mouse + [Section(title: "Mouse & Trackpad", rows: KeyMap.gestures.map { ($0.input, $0.title) })],
        ])
    }

    private static func menuRows() -> [(keys: String, title: String)] {
        MenuShortcuts.rows().map { ($0.input, $0.title) }
    }

    /// What Stash's page and its galleries answer to (StashKitUI's `StashLibraryView`, `BackButton`).
    private static let stashRows: [(keys: String, title: String)] = [
        ("‹ Recent  ‹ Stash", "Over what Home opened: back there (⌘[)"),
        ("⌘[  ⌘]  ⌘←  ⌘→", "In Stash: back / forward a page"),
        ("Mouse back / forward", "In Stash: back / forward a page"),
        ("⌘R", "In Stash: reload the page"),
        ("Click a gallery", "Open it here; folder steps follow Stash's list"),
    ]
}
