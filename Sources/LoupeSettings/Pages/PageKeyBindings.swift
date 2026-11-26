import SettingsKit
import SwiftUI

extension SettingsPanel {
    /// The settings search indexes actions and inputs across both tables, including menu shortcuts and gestures.
    static let keyBindings = SettingsPage("key-bindings", "Key Bindings", symbol: "keyboard", sections: [
        SettingsSection("Keyboard", rows: [bindingTable(mouse: false)]),
        SettingsSection("Mouse & Trackpad", rows: [bindingTable(mouse: true)]),
    ])

    private static func bindingTable(mouse: Bool) -> SettingsRow {
        .custom(mouse ? "Mouse bindings" : "Keyboard bindings",
                searchTexts: { bindingSource?.searchTexts(mouse: mouse) ?? [] }) {
            if let source = bindingSource {
                KeyBindingTable(source: source, mouse: mouse, note: mouse ? "Built-in gestures are read-only" : InputBindingSource.menuNote)
            }
        }
    }
}
