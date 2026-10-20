import AppKit
import LoupeCore

/// The main menu's ⌘ shortcuts (not the Edit menu's, Hide or Quit), read from the menu so what is shown is what it
/// does, the Stash item only while it shows; then the browser's tab chords no item carries (`BrowserTabKeys`). The `?`
/// sheet and the Key Bindings table list them.
@MainActor enum MenuShortcuts {
    static func rows() -> [(input: String, title: String)] {
        let skipped: Set<String> = ["Edit"]
        let standard: Set<Selector> = [#selector(NSApplication.hide(_:)), #selector(NSApplication.terminate(_:))]
        var rows: [(input: String, title: String)] = []
        for top in NSApp.mainMenu?.items ?? [] where !skipped.contains(top.title) {
            for item in top.submenu?.items ?? [] where !item.isHidden && !item.keyEquivalent.isEmpty {
                let flags = item.keyEquivalentModifierMask
                guard flags.contains(.command), !(item.action.map(standard.contains) ?? false) else { continue }
                let key = MenuShortcut.text(key: item.keyEquivalent, command: true, shift: flags.contains(.shift),
                                            option: flags.contains(.option), control: flags.contains(.control))
                let title = item.action == #selector(ViewerWindowController.goBack(_:))
                    ? "Back to Recent or Stash" : item.title.replacingOccurrences(of: "…", with: "")
                rows.append((key, title))
            }
        }
        return rows + BrowserTabKeys.rows
    }
}
