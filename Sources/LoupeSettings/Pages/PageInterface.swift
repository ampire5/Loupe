import LoupeCore
import SettingsKit

extension SettingsPanel {
    /// Interface (spec §5): the stats bar (I) and two pages side by side (D, spread spec 2026-10-23). The info panel (⌘I)
    /// has no keys: it remembers its size itself.
    static let interface = SettingsPage("interface", "Interface", symbol: "macwindow", sections: [
        SettingsSection("Stats Bar", rows: [
            .choice("stats-bar-position", "Position", [
                (word: "auto", title: "Automatic"), (word: "top", title: "Top"), (word: "bottom", title: "Bottom"),
            ], symbol: "rectangle.topthird.inset.filled",
                    description: "Automatic: the top in a window, the bottom in full screen. Default Automatic."),
            .toggle("stats-bar-with-toolbar", "Show with the toolbar", symbol: "menubar.rectangle",
                    description: "Off: the bar shows only when the toolbar is hidden, since the toolbar carries the "
                        + "same facts. Default on."),
            .number("stats-bar-opacity", "Glass darkness", step: 0.01, symbol: "circle.lefthalf.striped.horizontal",
                    description: "How dark the bar's glass is where the folder progress has not reached: the tint's "
                        + "opacity, 0–1, default 0.34."),
            .toggle("stats-bar-clear", "Clear glass", symbol: "drop",
                    description: "The glass without the system's frosting: with a low darkness the photo shows "
                        + "through. Default off."),
            .toggle("stats-progress", "Folder progress", symbol: "rectangle.lefthalf.filled",
                    description: "The bar's glass is darkened from the left up to the photo's place in the folder "
                        + "(N/M). Default on.",
                    nested: [
                        .number("stats-progress-opacity", "Darkness", step: 0.01,
                                description: "How much darker the passed part is: black over the bar at this "
                                    + "opacity. 0.02–0.6, default 0.15."),
                    ]),
            .toggle("stats-modified", "Modification date", symbol: "calendar",
                    description: "The file's modification date at the end of the line. Default on."),
            .toggle("stats-bar-autohide", "Hide by itself", symbol: "eye.slash",
                    description: "The bar fades out after the delay and comes back with the next photo or when "
                        + "you switch it with I. Default off.",
                    nested: [
                        .number("stats-bar-hide-delay", "Delay (ms)", step: 100,
                                description: "How long it stays after a photo came. 500–30000, default 3000."),
                    ]),
            .toggle("stats-icons", "Icons", symbol: "chart.bar.doc.horizontal",
                    description: "A small symbol in front of each field: name, place, size, weight, format, zoom, "
                        + "decode time. Default on."),
            .toggle("stats-monochrome", "Monochrome", symbol: "circle.lefthalf.filled",
                    description: "White and grey only, without the yellow of the parameters. Default off."),
            .toggle("stats-folder-name", "Folder name", symbol: "folder",
                    description: "The open folder's name in the middle of the bar. Default on."),
        ]),
        SettingsSection("Full Screen", rows: [
            .choice("fullscreen-toolbar", "Toolbar", [
                (word: "remember", title: "As you left it"), (word: "shown", title: "Shown"),
                (word: "hidden", title: "Hidden"),
            ], symbol: "menubar.rectangle",
                    description: "The viewer's toolbar when a window goes full screen. ⌥⌘T still switches it for "
                        + "the time in full screen. Default As you left it."),
        ]),
        SettingsSection("Toasts", rows: [
            .choice("toast-position", "Position", Self.toastPositions, symbol: "align.horizontal.center",
                    description: "Where the one-line answer of a key sits. Default Bottom."),
            .number("stats-toast-opacity", "Glass darkness", step: 0.01,
                    symbol: "circle.lefthalf.striped.horizontal",
                    description: "How dark the glass of the toasts is: the tint's opacity, 0–1, default 0.34."),
            .toggle("stats-toast-clear", "Clear glass", symbol: "drop",
                    description: "The glass without the system's frosting. Default off."),
            .toggle("stats-toast", "Progress toast in full screen", symbol: "gauge.with.dots.needle.33percent",
                    description: "A short glass toast with the photo's name, place in the folder and a progress bar "
                        + "when you move to another photo in full screen. It fades by itself after the message "
                        + "duration and never shows while you stay on a photo. Default on.",
                    nested: [
                        .choice("stats-toast-position", "Position", Self.toastPositions,
                                symbol: "align.horizontal.center",
                                description: "Where it sits; in the place of the key toast it steps aside. "
                                    + "Default Bottom."),
                    ]),
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
