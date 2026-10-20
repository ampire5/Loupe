import AppKit
import LoupeCore
import SettingsKit
import UniformTypeIdentifiers

extension SettingsPanel {
    /// Advanced (spec §5): the files behind the panel.
    static let advanced = SettingsPage("advanced", "Advanced", symbol: "wrench.and.screwdriver", sections: [
        SettingsSection("Files", rows: [
            .button("Settings file", "Open", symbol: "doc.text",
                    description: "loupe.conf in your text editor: every key, with comments. Lines you add or change "
                        + "there apply when you switch back to Loupe.") { openSettingsFile() },
            .button("Key and mouse bindings", "Open", symbol: "command",
                    description: "input.conf in your text editor; made from the template (the built-in layout, "
                        + "commented out) when it is not there yet.") { openInputFile() },
            .button("Settings folder", "Reveal in Finder", symbol: "folder.badge.gearshape",
                    description: "~/.config/loupe (or $LOUPE_CONFIG_DIR): loupe.conf, input.conf, and icons/ for your "
                        + "own Dock icons.") { revealSettingsFolder() },
        ]),
    ])

    /// Writes `contents` to `url` (making its folder) unless the file is there already.
    static func makeIfMissing(_ url: URL, contents: String) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func openSettingsFile() {
        guard let url = context?.configURL else { return }
        open(url, makingItWith: ConfigText.header + "\n")
    }

    private static func openInputFile() {
        guard let url = context?.inputURL else { return }
        open(url, makingItWith: InputConfTemplate.text)
    }

    private static func revealSettingsFolder() {
        guard let url = context?.configURL else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    /// Opens `url` in the app for its type, or in the default plain-text editor when none claims `.conf`; a missing
    /// file is made first. A failure is shown as an alert.
    private static func open(_ url: URL, makingItWith contents: String) {
        do {
            try makeIfMissing(url, contents: contents)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        let workspace = NSWorkspace.shared
        guard workspace.urlForApplication(toOpen: url) == nil,
              let editor = workspace.urlForApplication(toOpen: .plainText) else {
            workspace.open(url)
            return
        }
        workspace.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }
}
