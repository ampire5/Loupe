import SettingsKit

extension SettingsPanel {
    /// Zoom & Pan (spec §5): zoom, right-button zoom, pan and inertia, pan indicators.
    static let zoomPan = SettingsPage("zoom-pan", "Zoom & Pan", symbol: "plus.magnifyingglass", sections: [
        SettingsSection("Zoom", [
            SettingsCard([
                .text("zoom-stops", "Zoom stops", placeholder: "fit-width,fit-height,100%", symbol: "scope",
                      description: "Where pinch and right-button zoom pause: fit-width, fit-height and percentages, "
                        + "comma-separated; none for no stops. Default fit-width,fit-height,100%."),
                .toggle("zoom-stop-haptics", "Haptic click at a stop", symbol: "hand.tap",
                        description: "A light trackpad click when the zoom reaches a stop. Default on."),
            ]),
            SettingsCard([
                .choice("default-zoom-mode", "Default zoom", [
                    (word: "fit", title: "Fit"), (word: "fit-width", title: "Fit width"),
                    (word: "fit-height", title: "Fit height"), (word: "fill", title: "Fill"),
                    (word: "50%", title: "50 %"), (word: "100%", title: "100 %"), (word: "200%", title: "200 %"),
                ], symbol: "arrow.up.left.and.down.right.magnifyingglass",
                description: "How a photo opens when its zoom is not kept: at launch, from Finder, with Keep zoom off. "
                    + "Any percentage in loupe.conf works too. Default Fit."),
                .toggle("keep-zoom-position", "Keep zoom and position", symbol: "lock",
                        description: "The next photo keeps the zoom and place; off: it opens in Default zoom, centred. "
                            + "L switches it for the folder. Default on."),
                .toggle("fit-upscale", "Upscale small photos in Fit", symbol: "arrow.up.left.and.arrow.down.right",
                        description: "Off: a photo smaller than the window shows at 100 %, centred. Also Zoom › Upscale "
                            + "Small Images in Fit. Default on."),
            ]),
            SettingsCard([
                .number("zoom-animation", "Zoom animation", unit: "ms", step: 10, symbol: "timer",
                        description: "Zoom changes by keys, menu and double click ease around the point that stays. "
                            + "0–1000 ms, 0 = instant; default 150."),
                .toggle("zoom-rubber-band", "Rubber band at the zoom limits",
                        symbol: "arrow.up.and.down.and.arrow.left.and.right",
                        description: "Pinch and right-button zoom go past the limits (up to ×1.25) with resistance and "
                            + "spring back. Default on."),
            ]),
        ]),
        SettingsSection("Right-Button Zoom", rows: [
            .number("rmb-zoom-speed", "Speed", unit: "×", step: 0.25, symbol: "speedometer",
                    description: "Drag up or down with the right button: 1 doubles in 200 pt, 1.5 in ~133 pt, 3 in "
                        + "~67 pt. 0.25–5, default 1.5."),
            .toggle("rmb-zoom-inertia", "Inertia", symbol: "wind",
                    description: "Let go while moving and the zoom coasts for ~2 s, up to the next stop or limit; a "
                        + "click, wheel, key or photo switch stops it. Default off."),
            .toggle("rmb-zoom-invert", "Invert", symbol: "arrow.up.arrow.down",
                    description: "Drag down to zoom in (the inertia follows). Default off."),
        ]),
        SettingsSection("Pan & Inertia", rows: [
            .toggle("drag-inertia", "Inertia after a drag", symbol: "hand.draw",
                    description: "A photo thrown with the left button keeps sliding. Default on.",
                    nested: [
                        .number("inertia-deceleration", "Deceleration", step: 0.001,
                                description: "Speed kept per millisecond: 0.99 short, 0.998 as in iOS (default), "
                                    + "0.999 long. 0.99–0.999."),
                    ]),
            .toggle("rubber-band", "Rubber band at the edges", symbol: "rectangle.dashed",
                    description: "Past the edge the photo stretches with resistance and springs back; inertia "
                        + "overshoots by at most a third of the window. Default on."),
        ]),
        SettingsSection("Pan Indicators", rows: [
            .choice("pan-indicators", "Pan indicators", [
                (word: "auto", title: "Auto"), (word: "always", title: "Always"), (word: "no", title: "Off"),
            ], symbol: "rectangle.inset.filled",
            description: "Bars at the window's edges when the photo is larger than the window. Auto: while panning "
                + "and zooming. P cycles them, ⇧P saves. Default Auto.",
            nested: [
                .number("pan-indicators-hide", "Hide after", unit: "ms", step: 50,
                        description: "Auto: how long the bars stay after the last move. 0–5000 ms, default 400."),
                .number("pan-indicators-fade", "Fade", unit: "ms", step: 50,
                        description: "Auto: how long they take to fade. 0–2000 ms, default 250."),
                .toggle("pan-indicators-on-switch", "Show on photo switch",
                        description: "Also when switching photos with a kept zoom; off: only when panning or zooming "
                            + "the same photo. Default off."),
            ], off: ["no"]),
        ]),
    ])
}
