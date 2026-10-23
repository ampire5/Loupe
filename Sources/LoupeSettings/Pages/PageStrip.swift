import LoupeCore
import SettingsKit

extension SettingsPanel {
    /// Strip (spec §5): the thumbnail strip and the stored thumbnails.
    static let strip = SettingsPage("strip", "Strip", symbol: "film", sections: [
        SettingsSection("Strip", [
            SettingsCard([
                .choice("strip-window", "In a window", [
                    (word: "beside", title: "Beside"), (word: "over", title: "Over"), (word: "hidden", title: "Hidden"),
                ], symbol: "rectangle.bottomthird.inset.filled",
                description: "Beside: a band under the photo; Over: appears with the mouse at the bottom edge and hides "
                    + "itself; Hidden: no strip. ⇧T switches Beside and Over, T hides or pins. Full screen always has it "
                    + "over. Default Beside."),
                .number("strip-height", "Height", unit: "pt", step: 4, symbol: "arrow.up.and.down",
                        description: "Thumbnail height; also by dragging the strip's top edge. 40–240 pt, default 68."),
                .slider("strip-cell-max", "Widest thumbnail", range: Config.stripCellMaxRange, marks: [
                    (value: 0.5625, title: "9:16"), (value: 0.75, title: "3:4"), (value: 1, title: "1:1"),
                    (value: 4.0 / 3, title: "4:3"), (value: 1.5, title: "3:2"),
                ], symbol: "rectangle.portrait.arrowtriangle.2.outward",
                description: "How wide a thumbnail may grow when the strip has room: 9:16 keeps every one narrow, "
                    + "3:2 lets a landscape show nearly whole. Never wider than the photo. Default 3:2."),
                .number("strip-corner-radius", "Corner radius", unit: "pt", step: 1, symbol: "app",
                        description: "0–16 pt, 0 = square corners; default 3."),
            ]),
            SettingsCard([
                .choice("strip-scroll-direction", "Scrub direction", [
                    (word: "natural", title: "Natural"), (word: "reversed", title: "Reversed"),
                ], symbol: "arrow.left.and.right",
                description: "A two-finger sideways swipe over the strip scrubs through thumbnails, sharp once you "
                    + "stop. Natural: fingers left go to the next photos, as the three-finger swipe. Default Natural."),
            ]),
            SettingsCard([
                .number("strip-hide-delay", "Hide after", unit: "ms", step: 50, symbol: "hourglass",
                        description: "How long the overlay stays after the mouse leaves it. 0–10000 ms, 0 = at once; "
                            + "default 500."),
                .number("strip-fade-in", "Fade in", unit: "ms", step: 25, symbol: "eye",
                        description: "0–2000 ms, 0 = no animation; default 150."),
                .number("strip-fade-out", "Fade out", unit: "ms", step: 25, symbol: "eye.slash",
                        description: "0–2000 ms, 0 = no animation; default 250."),
            ]),
            SettingsCard([
                .toggle("strip-jump-preview", "Preview on a jump", symbol: "forward.end",
                        description: "A jump along the strip shows the stretched thumbnail at once, then the sharp "
                            + "photo; off: the usual switch, as Show before sharp says. Default on."),
                .toggle("strip-loading-indicator", "Loading spinner", symbol: "progress.indicator",
                        description: "A spinner in the corner while only the thumbnail is on screen. Default off."),
            ]),
        ]),
        SettingsSection("Thumbnails", rows: [
            .number("thumb-size", "Thumbnail size", unit: "px", step: 64, symbol: "photo",
                    description: "Long side of a stored thumbnail; a change makes every thumbnail again. 256–1024 px, "
                        + "default 512."),
            .number("thumb-cache-size", "Thumbnail store limit", symbol: "internaldrive",
                    description: "~/Library/Caches/Loupe/Thumbs.db, ≈ 50 KB a thumbnail; the longest unseen go first. "
                        + "M or G, or bytes; 0 = in memory only until quit. Default 2G (≈ 40 000 photos)."),
        ]),
        SettingsSection("Prepare ahead", rows: [
            .choice("thumbs-ahead", "Prepare ahead", [
                (word: "folder", title: "Whole folder"), (word: "visible", title: "Cards in view"),
                (word: "off", title: "Off"),
            ], symbol: "arrow.down.circle",
            description: "Prepare thumbnails ahead: for the whole folder (default), for the cards in view, or not at "
                + "all. Background work pauses while you browse photos."),
            .number("thumbs-depth", "Prepare depth", step: 1, symbol: "arrow.down.right.and.arrow.up.left",
                    description: "How many levels of subfolders \"Prepare thumbnails of folder and subfolders\" "
                        + "goes into. 0–3, 0 = the folder itself; default 1."),
            .number("thumbs-pill-delay", "Show progress after", unit: "s", step: 0.5, symbol: "clock.badge",
                    description: "How long background work runs before its progress pill shows. 0 = at once; "
                        + "default 1."),
        ]),
    ])
}
