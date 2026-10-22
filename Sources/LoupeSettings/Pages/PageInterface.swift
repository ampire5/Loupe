import LoupeCore
import SettingsKit

extension SettingsPanel {
    /// Interface (spec §5): the stats bar (I) and two pages side by side (D, spread spec 2026-10-23). The info panel (⌘I)
    /// has no keys: it remembers its size itself.
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
        SettingsSection("Two Pages", rows: [
            .toggle("spread", "Two pages", symbol: "book.pages",
                    description: "Photos in pairs side by side, as a book or a magazine spread: scans, comics, two "
                        + "portraits. Both pages share one height and zoom and pan as one picture; arrows and the wheel "
                        + "step by pairs. A window taller than wide shows one page. D switches it for the folder (its "
                        + "toast says why a page stays alone), ⇧D saves. Default off."),
            .toggle("spread-shift", "Shift pages (first page alone)", symbol: "book.closed",
                    description: "The first page stands alone, as a cover, and the pairs start from the second: 1, "
                        + "2–3, 4–5…; off: 1–2, 3–4… ⌥D switches it for the folder, when the pairs come out one page "
                        + "off. Default off."),
            .choice("spread-direction", "Reading order", [
                (word: "ltr", title: "Left to right"), (word: "rtl", title: "Right to left"),
            ], symbol: "text.alignright",
            description: "Which side a pair's first page is on. Right to left reads as manga. Also View › Right to "
                + "Left, for the folder. Default Left to right."),
            .choice("spread-landscape", "Landscape pages", [
                (word: "alone", title: "Alone"), (word: "pair", title: "In pairs"),
            ], symbol: "rectangle.ratio.4.to.3",
            description: "Alone: a page clearly wider than tall (over Wide page from, 1.15 : 1 by default, so "
                + "square and near-square scans still pair) shows by itself, and the pairs count again after it; a "
                + "magazine's double page stays whole. In pairs: it pairs like any other page, as for a folder of "
                + "landscape photos. Also View › Landscape Pages Alone, for the folder. Default Alone."),
            .slider("spread-wide-ratio", "Wide page from", range: Config.spreadWideRatioRange,
                    marks: wideRatioMarks, symbol: "rectangle.ratio.16.to.9",
                    description: "Pages wider than this stand alone when Landscape Pages Alone is on. Lower it for "
                        + "scans that come out wide with their margins, raise it to pair 5:4 and 4:3 pages. For the "
                        + "folder, as the other two-page keys. 1.00–2.00 : 1, default 1.15 : 1."),
        ]),
    ])

    /// `spread-wide-ratio`'s slider names its value in steps of 0.05 (`1.15 : 1`).
    static let wideRatioMarks: [(value: Double, title: String)] = (0...20).map { step in
        let value = 1 + Double(step) / 20
        return (value: value, title: String(format: "%.2f : 1", value))
    }
}
