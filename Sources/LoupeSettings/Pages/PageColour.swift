import SettingsKit

extension SettingsPanel {
    /// Colour (spec §5): Apple's auto colour and the manual vibrance. Both are folder keys (`c`, `v`), so their
    /// rows stay usable while loupe.conf has them off: a folder may have them on.
    static let colour = SettingsPage("colour", "Colour", symbol: "camera.filters", sections: [
        SettingsSection("Auto Colour", rows: [
            .toggle("auto-color", "Auto colour", symbol: "wand.and.stars",
                    description: "Apple's automatic enhancement, as Enhance in Photos, worked out from the strip "
                        + "thumbnail. C switches it for the folder, ⇧C saves it here; the rows below apply wherever it "
                        + "is on. Default off.",
                    nested: [
                        .choice("auto-color-method", "Method", [
                            (word: "apple", title: "Apple"), (word: "apple-luma", title: "Luminance only"),
                        ], description: "Apple: its curve, shadows and vibrance as they are. Luminance only: curve "
                            + "and shadows on brightness alone, hues and saturation kept (better on dark saturated "
                            + "photos, where Apple turns skin orange). Default Apple."),
                        .number("auto-color-strength", "Strength", step: 0.05,
                                description: "Blend with the original in linear light. 0–1, default 0.8."),
                        .flags("auto-color-filters", "Parts", [
                            (word: "curve", title: "Curve"), (word: "shadows", title: "Shadows"),
                            (word: "vibrance", title: "Vibrance"),
                        ], description: "Which parts of Apple's correction apply, at least one. Default all three."),
                        .number("auto-color-vibrance-gain", "Vibrance gain", unit: "×", step: 0.1,
                                description: "Multiplies the vibrance Apple picked (the result stays at most 1). "
                                    + "0–4, default 1.5."),
                        .number("auto-color-threshold", "Threshold", step: 1,
                                description: "Δ, how much Apple's full correction changes the photo (0–255): below "
                                    + "it the photo is left alone; 0 corrects everything. Default 6."),
                        .number("auto-color-full", "Full strength from", step: 1,
                                description: "From the threshold up to this Δ the strength grows linearly to full. "
                                    + "0–255, default 12."),
                        .number("auto-color-fade", "Fade", unit: "ms", step: 50,
                                description: "How smoothly a new correction of the same photo comes in. 0–2000 ms, "
                                    + "0 = at once; default 150."),
                    ], off: []),
        ]),
        SettingsSection("Vibrance", rows: [
            .toggle("vibrance", "Vibrance", symbol: "drop.halffull",
                    description: "Manual vibrance, over auto colour or alone. V switches it for the folder, ⇧V saves "
                        + "it here. Default off.",
                    nested: [
                        .number("vibrance-amount", "Amount", step: 0.05,
                                description: "0–1, default 0.65."),
                    ], off: []),
        ]),
    ])
}
