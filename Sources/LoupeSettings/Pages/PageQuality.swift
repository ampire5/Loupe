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
                .toggle("lanczos-antiring", "Anti-ringing", symbol: "circle.dotted",
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
