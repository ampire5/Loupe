import LoupeCore
import SettingsKit

extension SettingsPanel {
    /// What a step through the folder waits for (`wheel-step`, `key-step`).
    private static let stepWaits: [(word: String, title: String)] = [
        (word: "thumb", title: "Thumbnail"), (word: "coarse", title: "Coarse"), (word: "sharp", title: "Sharp"),
        (word: "any", title: "Nothing"),
    ]

    /// Performance (spec §5): the photo cache and how fast stepping goes.
    static let performance = performancePage(on: .current)

    /// The page with the defaults it names taken from `profile` (tests stand in other Macs); a discrete card adds
    /// the graphics memory Loupe sets for it.
    static func performancePage(on profile: MachineProfile) -> SettingsPage {
        let cacheMemoryHere = Config.memoryText(HardwareAdvice.defaultCacheMemory(profile))
        let jxlThreadsHere = String(Machine.jxlThreadsCurrent(performanceCores: profile.performanceCores))
        let jxlThreadsOtherHere = HardwareAdvice.defaultJXLThreadsOther(profile)
        let graphics = HardwareAdvice.graphicsMemory(profile)
        let cacheMemoryDescription = graphics == nil
            ? "The ceiling over all of the above; the photos on screen may briefly pass it. M or G, or bytes; "
                + "default a fifth of this Mac's memory, 1–4G (" + cacheMemoryHere + " here)."
            : "System memory for photos kept decoded and ready and for compressed files; graphics memory is "
                + "Loupe's (" + GraphicsMemoryView.bytes(graphics ?? 0) + " here, below). M or G, or bytes; "
                + "default a fifth of this Mac's memory (" + cacheMemoryHere + " here)."
        return SettingsPage("performance", "Performance", symbol: "gauge.with.dots.needle.67percent",
                                          sections: [
        SettingsSection("Cache", [
            SettingsCard([
                .choice("cache-full", "Full resolution", [
                    (word: "0", title: "Current photo only"), (word: "1", title: "+ the next one"),
                    (word: "2", title: "+ the previous one too"),
                ], symbol: "photo.stack",
                description: "Neighbours kept at full resolution, for an instant step at 100 %: the next in the "
                    + "direction you browse, and the previous (≈ +0.85 GB at 147 MP). Default + the next one."),
                .number("cache-previews", "Previews", unit: "photos", step: 5, symbol: "square.grid.3x2",
                        description: "Photos kept at least as a screen-size preview, the current one included "
                            + "(EdgeView's Image Cache Count), ≈ 48–100 MB each. 1–200, default 20."),
                .choice("cache-far-previews", "Far previews", [
                    (word: "coarse", title: "Coarser"), (word: "full", title: "Full quality"),
                ], symbol: "square.3.layers.3d",
                description: "Previews beyond ±3 photos: a level coarser, a quarter of the memory; or all at screen "
                    + "quality. Default Coarser."),
                .number("cache-files", "Compressed files", unit: "files", step: 1, symbol: "doc.zipper",
                        description: "Neighbours kept in memory as their files (no re-read over SMB), ~12 MB each; the "
                            + "current photo's always. 0–50, default 24."),
                .number("cache-memory", "Memory limit", symbol: "memorychip", description: cacheMemoryDescription),
            ] + graphicsRows(profile) + [
                .number("cache-idle-trim", "Trim idle windows after", unit: "min", step: 5, symbol: "moon.zzz",
                        description: "A window or tab not active for this many minutes lets go of everything but "
                            + "its current photo; those on screen are never trimmed. 0–1440 min, 0 = never; "
                            + "default 30."),
                .choice("cache-idle-keep", "Idle window keeps", [
                    (word: "full", title: "Full photo"), (word: "preview", title: "Preview"),
                ], symbol: "tray.full",
                description: "What a trimmed window or tab keeps of its current photo: as it is, up to full "
                    + "resolution (back without a read or decode), or down to the screen-size preview. Default Full "
                    + "photo."),
            ]),
            SettingsCard([
                .choice("show-blurry", "Show before sharp", [
                    (word: "no", title: "Never"), (word: "fit", title: "In Fit"), (word: "always", title: "Always"),
                ], symbol: "circle.dashed",
                description: "Never: only sharp for the scale, the previous photo stays until then; In Fit: a softer "
                    + "far preview at once at Fit and smaller; Always: what is there at once, then sharpened. "
                    + "Default Never."),
            ]),
        ]),
        SettingsSection("Catalog", rows: [
            .custom("Catalog", searchTexts: { ["Catalog", "Thumbnails", "Folders", "Photos", "Database", "Disk"] }) {
                CatalogStatsView(directory: context?.catalogDirectory, clear: context?.clearThumbnails)
            },
        ]),
        SettingsSection("JPEG XL", rows: [
            .toggle("jxl-dc-preview", "1:8 picture first", symbol: "square.grid.4x3.fill",
                    description: "A JPEG XL photo shows its built-in 1:8 picture at once (≈ 15 ms at 147 MP), and "
                        + "far previews and thumbnails come from it; off: every picture is a full decode, made "
                        + "smaller. Default on."),
            .number("jxl-threads-current", "Threads, current photo", unit: "threads", step: 1, symbol: "cpu",
                    description: "libjxl threads decoding the photo on screen. 1–16, default one per performance "
                        + "core (" + jxlThreadsHere + " here)."),
            .number("jxl-threads-other", "Threads, neighbours", unit: "threads", step: 1, symbol: "cpu.fill",
                    description: "libjxl threads for neighbours and thumbnails, so they leave the current photo "
                        + "room. 1–16, default a quarter of the cores, 1 or 2 (" + String(jxlThreadsOtherHere)
                        + " here)."),
        ]),
        SettingsSection("Navigation", rows: [
            .choice("wheel-step", "Wheel step waits for", stepWaits, symbol: "dial.low",
                    description: "A fast wheel slows down instead of skipping photos, until each shows at this "
                        + "quality (at most 1 s; notches meanwhile are dropped). Nothing: a step per display frame, "
                        + "photos not ready are skipped. Default Thumbnail."),
            .choice("key-step", "Key step waits for", stepWaits, symbol: "arrow.right.square",
                    description: "The same for the stepping keys (← →, space, ⌫, Page Up / Down), held too. Default "
                        + "Thumbnail."),
        ]),
    ])
    }

    /// The graphics memory row of a discrete card; none on unified memory.
    private static func graphicsRows(_ profile: MachineProfile) -> [SettingsRow] {
        guard HardwareAdvice.graphicsMemory(profile) != nil else { return [] }
        return [.custom("Graphics memory", searchTexts: { ["Graphics memory", "GPU", "VRAM", "Video memory"] }) {
            GraphicsMemoryView(profile: profile)
        }]
    }
}
