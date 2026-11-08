import LoupeCore
import SettingsKit

extension SettingsPanel {
    /// The resampling filters, as loupe.conf spells them (`UpscaleFilter.cycle` order).
    private static let filters: [(word: String, title: String)] = [
        (word: "lanczos3", title: "Lanczos-3"), (word: "lanczos2", title: "Lanczos-2"),
        (word: "mitchell", title: "Mitchell"), (word: "catmull-rom", title: "Catmull-Rom"),
        (word: "bilinear", title: "Bilinear"),
    ]
    /// The two magnifying-only filters.
    private static let upscaleOnly: [(word: String, title: String)] = [
        (word: "metalfx", title: "MetalFX"), (word: "ewa-lanczos", title: "EWA Lanczos"),
    ]

    /// Quality (spec §5): scaling and transparency.
    static let quality = SettingsPage("quality", "Quality", symbol: "camera.aperture", sections: [
        SettingsSection("Scaling", [
            SettingsCard([
                .choice("upscale", "Upscale filter", filters + upscaleOnly, symbol: "arrow.down.left.and.arrow.up.right",
                        description: "Zooming in past 100 %, in linear light. Lanczos-3 is the sharpest, with a faint "
                            + "halo; MetalFX and EWA Lanczos cost more GPU. S cycles it for the folder. Default MetalFX "
                            + "(Lanczos-3 on a GPU without it)."),
                .choice("upscale-high", "Strong upscale filter", filters + upscaleOnly,
                        symbol: "arrow.down.left.and.arrow.up.right.square",
                        description: "Takes over from Strong upscale from: at ×3 and more a softer kernel often looks "
                            + "better. Default MetalFX (Lanczos-3 on a GPU without it)."),
                .number("upscale-high-from", "Strong upscale from", unit: "%", step: 50, symbol: "arrow.up.to.line",
                        description: "Magnification of the drawn level. 100–6400 %, 0 = never (Upscale everywhere); "
                            + "default 200."),
                .choice("downscale", "Downscale filter", filters, symbol: "minus.magnifyingglass",
                        description: "Fit of large photos and zoom below 100 %. Lanczos-3 removes moiré and jaggies; "
                            + "Bilinear is the cheapest. Default Lanczos-3."),
                .toggle("lanczos-antiring", "Lanczos anti-ringing", symbol: "circle.dotted",
                        description: "Lanczos upscaling stays within its four nearest pixels: less halo, slightly "
                            + "softer; +0.2–0.3 ms GPU per 6K frame. A toggles it for the folder. Default off."),
            ]),
            SettingsCard([
                .number("pixel-art", "Square pixels from", unit: "%", step: 100, symbol: "square.grid.3x3",
                        description: "Zoom from which pixels are drawn as squares, without smoothing (at full "
                            + "resolution only). 100–6400 %, 0 = never; default 800."),
                .choice("pyramid-filter", "Pyramid filter", [
                    (word: "lanczos3", title: "Lanczos-3"), (word: "box", title: "Box"),
                ], symbol: "square.stack.3d.down.right",
                description: "Builds the reduced copies behind Fit of large photos (Box: a 2×2 average); applies to "
                    + "photos opened after the change. Default Lanczos-3."),
                .toggle("exif-orientation", "EXIF orientation", symbol: "rotate.right",
                        description: "Photos, previews and the strip as shot (portraits upright); off: as stored in "
                            + "the file. Default on."),
            ]),
        ]),
        SettingsSection("Debanding", rows: [
            .choice("deband", "Filter", [("off", "Off"), ("single", "Four samples"), ("double", "Two passes"),
                                        ("adaptive", "Adaptive"), ("reference", "Reference (libplacebo)"), ("window", "Adaptive window")],
                    symbol: "line.3.horizontal.decrease.circle",
                    description: "Smooths colour bands before scaling. Single and Double use fixed sampling; Adaptive "
                        + "protects texture, Reference uses stochastic sampling, and Window averages a wider area. "
                        + "Strong filtering can remove fine detail. N toggles it for this folder; Shift-N saves the current mode and parameters as defaults. Default off."),
            .number("deband-strength", "Strength", step: 0.1, symbol: "dial.low.fill",
                    description: "Blend with the original photo, 0–1. Higher values remove more banding and may soften detail. "
                        + "0 bypasses the filter. Default 0.5."),
            .number("deband-threshold", "Threshold", step: 0.5, symbol: "line.3.horizontal.decrease",
                    description: "Allowed colour difference in 8-bit levels, 0.1–32. Applies to Adaptive, Reference and Window; "
                        + "Single and Double derive it from Strength. Default 9."),
            .number("deband-radius", "Radius", unit: "px", step: 1, symbol: "circle.dashed.inset.filled",
                    description: "Sampling radius in input pixels before scaling, 1–64. Applies to Adaptive, Reference and Window; "
                        + "Single and Double derive it from Strength. Default 24."),
            .number("deband-iterations", "Iterations", step: 1, symbol: "repeat.circle",
                    description: "Reference sampling iterations, 1–4. More iterations may smooth more detail and cost more GPU. "
                        + "Other filters use fixed sampling. Default 1."),
            .number("deband-texture-protection", "Texture protection", step: 0.1, symbol: "shield.lefthalf.filled",
                    description: "Protects texture in Adaptive and Window, 0–1. Higher values preserve more fine detail. "
                        + "Single, Double and Reference do not use this control. Default 1."),
        ]),
        SettingsSection("Grain", rows: [
            .choice("grain", "Pattern", [("off", "Off"), ("white", "White"), ("fine", "Fine"), ("soft", "Soft"),
                                        ("av1", "AV1"), ("particles", "Particles")], symbol: "aqi.low",
                    description: "Uniform monochrome grain after colour correction. White is uncorrelated; Fine and Soft "
                        + "have increasing softness, AV1 has correlated texture, Particles has a film-like pattern. "
                        + "J toggles the last pattern for this folder; Shift-J saves the current pattern and parameters as defaults. The application stage is preserved. "
                        + "Stable while viewing, without animation. Default off."),
            .choice("grain-stage", "Apply", [("before", "Before upscale"), ("after", "After upscale")],
                    symbol: "square.2.layers.3d.bottom.filled",
                    description: "Before upscale: grain follows the photo and is scaled independently. After upscale: "
                        + "grain uses fixed screen pixels. MetalFX never processes grain in either mode. Default before upscale."),
            .number("grain-amount", "Strength", step: 0.1, symbol: "aqi.medium",
                    description: "Approximate grain strength in 8-bit colour levels, 0–3. Default 0.65."),
            .number("grain-size", "Size", unit: "px", step: 0.25, symbol: "aqi.high",
                    description: "0.5–4; default 1. Before upscale: original photo pixels. After upscale: physical screen pixels."),
        ]),
        SettingsSection("Transparency", rows: [
            .choice("transparency", "Behind transparent pixels", [
                (word: "checker", title: "Checkerboard"), (word: "background", title: "Background colour"),
                (word: "black", title: "Black"), (word: "white", title: "White"),
            ], symbol: "checkerboard.rectangle",
            description: "PNG, TIFF, HEIC, WebP and JPEG XL with alpha; around the picture it is always "
                + "Background. Default Checkerboard."),
            .number("checker-size", "Checker size", unit: "pt", step: 1, symbol: "square.grid.2x2",
                    description: "A cell's side on screen, whatever the zoom; the cells move with the picture. "
                        + "2–64 pt, default 8."),
            .color("checker-colors", "Checker colours", count: 2, names: [
                "light": hex(CheckerColors.light.first) + "," + hex(CheckerColors.light.second),
                "dark": hex(CheckerColors.dark.first) + "," + hex(CheckerColors.dark.second),
            ], symbol: "paintpalette",
            description: "light (#FFFFFF / #CCCCCC, default), dark (#333333 / #262626) or two colours "
                + "#RRGGBB,#RRGGBB without a space."),
        ]),
    ])
}
