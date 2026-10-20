import SettingsKit

extension SettingsPanel {
    /// Strip (spec §5): the thumbnail strip and the stored thumbnails.
    static let strip = SettingsPage("strip", "Strip", symbol: "film", sections: [
        SettingsSection("Strip", [
            SettingsCard([
                .choice("strip-window", "In a window", [
                    (word: "overlay", title: "Overlay"), (word: "bar", title: "Bar"), (word: "off", title: "Off"),
                ], symbol: "rectangle.bottomthird.inset.filled",
                description: "Overlay: appears with the mouse at the bottom edge and hides itself; Bar: a fixed band "
                    + "under the photo; Off: no strip. Full screen always has the overlay; T pins it. Default Overlay."),
                .number("strip-height", "Height", unit: "pt", step: 4, symbol: "arrow.up.and.down",
                        description: "Thumbnail height; also by dragging the strip's top edge. 40–240 pt, default 64."),
                .choice("strip-aspect", "Thumbnail shape", [
                    (word: "native", title: "Photo's proportions"), (word: "crop", title: "3:2, cropped"),
                ], symbol: "aspectratio",
                description: "Each thumbnail as wide as its photo's proportions, or all 3:2 with the photo cropped "
                    + "to the centre. Default Photo's proportions."),
                .number("strip-corner-radius", "Corner radius", unit: "pt", step: 1, symbol: "app",
                        description: "Grows with a magnified thumbnail. 0–16 pt, 0 = square corners; default 4."),
            ]),
            SettingsCard([
                .number("strip-magnify", "Magnification", unit: "×", step: 0.5, symbol: "magnifyingglass.circle",
                        description: "The thumbnail under the cursor grows, as in the Dock. 1–4, 1 = none; default 2.",
                        nested: [
                            .number("strip-magnify-reach", "Reach", step: 0.5,
                                    description: "Thumbnails on each side over which it fades out, fractions too; "
                                        + "0 = only the one under the cursor grows. 0–6, default 2."),
                            .number("strip-magnify-limit", "Height limit", unit: "%", step: 5,
                                    description: "A magnified thumbnail is at most this share of the window's height, "
                                        + "so a tall strip stops short of ×4. 5–100 %, default 15."),
                        ], off: ["1"]),
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
    ])
}
