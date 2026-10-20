import SettingsKit

extension SettingsPanel {
    /// Interface (spec §5): the stats bar (I). The info panel (⌘I) has no keys: it remembers its size itself.
    static let interface = SettingsPage("interface", "Interface", symbol: "macwindow", sections: [
        SettingsSection("Stats Bar", rows: [
            .toggle("stats-progress", "Folder progress", symbol: "rectangle.lefthalf.filled",
                    description: "The bar's background fills from the left up to the photo's place in the folder "
                        + "(N/M). Default on.",
                    nested: [
                        .number("stats-progress-opacity", "Brightness", step: 0.01,
                                description: "How much lighter the filled part is: white over the bar at this "
                                    + "opacity. 0.02–0.6, default 0.15."),
                    ]),
            .toggle("stats-folder-name", "Folder name", symbol: "folder",
                    description: "The folder's name in the middle of the bar, larger. Default on."),
        ]),
    ])
}
