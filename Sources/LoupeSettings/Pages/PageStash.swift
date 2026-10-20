import AppKit
import LoupeCore
import SettingsKit
import StashKit

extension SettingsPanel {
    /// Stash (Stash spec §3.2): the server whose WebUI Loupe shows, its key, the path rules, and a check.
    static let stash = SettingsPage("stash", "Stash", symbol: "books.vertical", sections: [
        SettingsSection("Library", rows: [
            .text("stash-url", "Address", placeholder: "http://localhost:9999", symbol: "network",
                  description: "The Stash server. Set: File › Stash Library (⇧⌘L) shows its pages in the window, a "
                    + "launch without a photo opens it, a click on a gallery opens the gallery here. Empty (default): "
                    + "no Stash."),
            .text("stash-api-key", "API key", symbol: "key",
                  description: "Stash's API key (Settings › Security in Stash) when Stash has a login; else empty."),
            .text("stash-path-map", "Path rules", placeholder: "S:\\=/Volumes/S$;\\\\nas\\share=/Volumes/share",
                  symbol: "arrow.triangle.branch",
                  description: "Where Stash's paths are on this Mac, as stashPrefix=localPrefix separated by ';', "
                    + "tried first. Without a rule a drive letter goes to the PC's mounted X$ share, a \\\\server\\share "
                    + "path to that share; a share that is not mounted is mounted when a gallery needs it."),
            .choice("stash-title", "Untitled galleries", [
                (word: "tidy", title: "Tidy file name"), (word: "file", title: "File name"),
            ], symbol: "textformat",
            description: "What the message on opening or stepping to a gallery calls one with no title in Stash: its "
                + "file or folder name, or that name without .zip and with spaces for underscores. Default Tidy."),
            .button("Connection", "Check", symbol: "checkmark.seal",
                    description: "Asks Stash for its version and shows where its first gallery is on this Mac.") {
                checkStash()
            },
        ]),
    ])

    /// The Check button: Stash's version and the first gallery's path, mapped as an open would map it.
    private static func checkStash() {
        guard let url = context?.configURL else { return }
        let config = Config.parse((try? String(contentsOf: url, encoding: .utf8)) ?? "").0
        guard let base = config.stashURL else {
            alert("No Stash address", "Set the address first.")
            return
        }
        let client = StashClient(baseURL: base, apiKey: config.stashAPIKey)
        let rules = config.stashPathMap
        Task { @MainActor in
            do {
                let version = try await client.version()
                var lines = ["Stash \(version)"]
                if let path = try await client.firstGalleryPath() {
                    let map = StashPathMap(mounts: SMBMount.current(), rules: StashPathRule.parse(rules))
                    let place: String
                    switch map.resolve(path) {
                    case .local(let local): place = local.path
                    case .needsMount(let smb): place = "share not mounted (\(smb.absoluteString))"
                    case .unmapped: place = "not mapped"
                    }
                    lines.append("First gallery: \(path) → \(place)")
                } else {
                    lines.append("No galleries with a path")
                }
                alert("Stash answers", lines.joined(separator: "\n"))
            } catch {
                alert("Stash does not answer", error.localizedDescription)
            }
        }
    }

    private static func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
