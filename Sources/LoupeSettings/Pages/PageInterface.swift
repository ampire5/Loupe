import LoupeCore
import SettingsKit

extension SettingsPanel {
    /// The viewer's stats bar, information panel text, full-screen chrome, toasts and two-page spread.
    static let interface = SettingsPage("interface", "Interface", symbol: "macwindow", sections: [
        SettingsSection("Stats Bar", rows: [
            .toggle("stats-bar-with-toolbar", "Show alongside toolbar", symbol: "menubar.rectangle",
                    description: "Show the stats bar alongside the toolbar in a window. Press I to toggle the stats "
                        + "bar or ⌥⌘T to toggle the toolbar. Default off."),
            .number("stats-bar-opacity", "Background opacity", step: 0.01, symbol: "circle.lefthalf.striped.horizontal",
                    description: "Higher values make the text easier to read over bright photos. 0.3–1, default 0.7."),
            .choice("stats-bar-rows", "Rows", [(word: "2", title: "Two"), (word: "1", title: "One")],
                    symbol: "rectangle.split.1x2",
                    description: "Two: the facts in the first row, the file's name and the folder's in the second. One: "
                        + "everything in one row, the file's name and the folder's in the middle, between the facts and "
                        + "the date. Default One."),
            .toggle("stats-progress", "Folder progress", symbol: "rectangle.lefthalf.filled",
                    description: "The strip is lightened from the left up to the photo's place in the folder "
                        + "(N/M). Default on.",
                    nested: [
                        .number("stats-progress-opacity", "Brightness", step: 0.01,
                                description: "How much lighter the passed part is: white over the strip at this "
                                    + "opacity. 0.02–0.6, default 0.15."),
                    ]),
            .toggle("stats-modified", "Modification date", symbol: "calendar",
                    description: "Show when the file was last modified. Default on."),
            .toggle("stats-bar-autohide", "Hide after a delay", symbol: "eye.circle",
                    description: "The stats bar returns when you change photos or show it with I. Default off.",
                    nested: [
                        .number("stats-bar-hide-delay", "Delay (ms)", step: 100,
                                description: "How long the stats bar stays visible after you change photos. "
                                    + "500–30000 ms, default 3000 ms."),
                    ]),
            .toggle("stats-icons", "Icons", symbol: "chart.bar.doc.horizontal",
                    description: "A small symbol in front of each fact: place, size, weight, format, zoom, date, "
                        + "decode time. Default on."),
            .toggle("stats-monochrome", "Monochrome", symbol: "swatchpalette",
                    description: "White and grey only, without the yellow of the parameters. Default off."),
            .toggle("stats-folder-name", "Folder name", symbol: "folder",
                    description: "The open folder's name at the right end of the bar. Default on."),
        ]),
        SettingsSection("Information Panel", rows: [
            .number("info-panel-font-size", "Text size (⌘I)", unit: "pt", step: 1, symbol: "textformat.size",
                    description: "Text size in the photo viewer’s information panel. 8–40 pt, default 12."),
        ]),
        SettingsSection("Full Screen", rows: [
            .choice("fullscreen-toolbar", "Toolbar", [
                (word: "remember", title: "As you left it"), (word: "shown", title: "Shown"),
                (word: "hidden", title: "Hidden"),
            ], symbol: "arrow.up.backward.and.arrow.down.forward",
                    description: "The viewer's toolbar when a window goes full screen. ⌥⌘T still switches it for "
                        + "the time in full screen. Default As you left it."),
            .choice("fullscreen-tabs", "Tabs", [
                (word: "shown", title: "Always visible"), (word: "auto", title: "Auto-hide with toolbar"),
            ], symbol: "rectangle.topthird.inset.filled",
                    description: "Always visible keeps the upper toolbar and tab bar expanded while tabs are shown, "
                        + "so they stay in place for switching. Auto-hide reveals both together at the screen edge. "
                        + "B temporarily switches pinning. Default Auto-hide with toolbar."),
        ]),
        SettingsSection("Toasts", rows: [
            .choice("toast-position", "Position", Self.toastPositions, symbol: "align.horizontal.center",
                    description: "Where shortcut feedback appears in the viewer. Default Bottom."),
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

    /// The six places of a toast.
    static let toastPositions: [(word: String, title: String)] = [
        (word: "top-left", title: "Top left"), (word: "top", title: "Top"), (word: "top-right", title: "Top right"),
        (word: "bottom-left", title: "Bottom left"), (word: "bottom", title: "Bottom"),
        (word: "bottom-right", title: "Bottom right"),
    ]

    /// `spread-wide-ratio`'s slider names its value in steps of 0.05 (`1.15 : 1`).
    static let wideRatioMarks: [(value: Double, title: String)] = (0...20).map { step in
        let value = 1 + Double(step) / 20
        return (value: value, title: String(format: "%.2f : 1", value))
    }
}
