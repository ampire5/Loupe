import Foundation

/// What the viewer's scaling keys do to the values (folder settings spec §4): `S` cycles the filter of the frame's
/// current mode and `A` flips `lanczos-antiring`, both for the window's folder; `⇧S` / `⇧A` save them as loupe.conf
/// defaults. Pure: the window controller asks here, then writes `FolderSettings` / loupe.conf and shows the toast
/// texts (spec §5).
public enum ScalingKeys {
    /// The keys `⇧S` saves: the filters, not `lanczos-antiring` (that is `⇧A`'s).
    public static let filterKeys = [ResampleKey.downscale, .upscale, .upscaleHigh].map(\.rawValue)
    /// The key `A` flips and `⇧A` saves.
    public static let antiringKey = "lanczos-antiring"

    /// `S`: the filter after `key`'s value in `config`, in its cycle, as the key and the text to record.
    public static func cycle(_ config: Config, key: ResampleKey) -> (key: String, value: String) {
        let next: String
        switch key {
        case .downscale: next = config.downscale.next().text
        case .upscale: next = config.upscale.next().text
        case .upscaleHigh: next = config.upscaleHigh.next().text
        }
        return (key.rawValue, next)
    }

    /// `A`: `lanczos-antiring` the other way round, as loupe.conf spells it.
    public static func toggledAntiring(_ config: Config) -> String {
        config.lanczosAntiring ? "no" : "yes"
    }

    /// `⇧S`: which of `keys` the window's folder records (its own or inherited), sorted; empty means nothing to save.
    public static func keysToSave(folderValues: [String: String], among keys: [String]) -> [String] {
        keys.filter { folderValues[$0] != nil }.sorted()
    }

    /// `⇧S` / `⇧A`, after `saved` (key → text) went into loupe.conf: which of the window folder's `own` entries to drop
    /// so that the window still draws the same (spec §4). Without its own entry the folder would take the nearest
    /// ancestor's (`inheritedWithoutOwn`, the ancestors' merged values) or else loupe.conf's, now the saved value; the
    /// entry goes only if that is the saved value. An ancestor value `Config.applying` refuses does not draw, so it
    /// counts as absent. Values are compared as `Config` reads them (`lanczos` is `lanczos3`). Sorted.
    public static func keysToClear(saved: [String: String], own: [String: String],
                                   inheritedWithoutOwn: [String: String]) -> [String] {
        saved.keys.filter { key in
            guard own[key] != nil, let value = canonical(key, saved[key]) else { return false }
            return (canonical(key, inheritedWithoutOwn[key]) ?? value) == value
        }.sorted()
    }

    /// Whether a Reset Folder Scaling / Reset Folder Colour item has anything to do: the folder's `own` entries hold one of
    /// the `keys` it clears (`Config.scalingFolderKeys` / `Config.colorFolderKeys`), not just any entry.
    public static func canReset(own: [String: String], keys: [String]) -> Bool {
        keys.contains { own[$0] != nil }
    }

    /// `value` in loupe.conf's spelling for `key`; nil when missing or refused.
    private static func canonical(_ key: String, _ value: String?) -> String? {
        guard let value else { return nil }
        var config = Config()
        return config.set(key, value) == .ok ? config.text(forKey: key) : nil
    }

    // MARK: Scaling menu (spec §6)

    /// The values the Scaling menu's section or submenu of `key` offers, as loupe.conf spells them and in menu order: the filters'
    /// cycles, `upscale-high-from` `0, 200, 300, 400, 600`, `pixel-art` `0, 400, 800, 1600`, `pyramid-filter`
    /// `lanczos3, box`. A `current` loupe.conf value outside the list (`upscale-high-from=250`) goes first. Empty for
    /// a key the menu has no choices for.
    public static func menuChoices(for key: String, current: String) -> [String] {
        let choices: [String]
        switch key {
        case ResampleKey.downscale.rawValue: choices = DownscaleFilter.cycle.map(\.text)
        case ResampleKey.upscale.rawValue, ResampleKey.upscaleHigh.rawValue: choices = UpscaleFilter.cycle.map(\.text)
        case "upscale-high-from": choices = ["0", "200", "300", "400", "600"]
        case "pixel-art": choices = ["0", "400", "800", "1600"]
        case "pyramid-filter": choices = ["lanczos3", "box"]
        default: return []
        }
        return choices.contains(current) ? choices : [current] + choices
    }

    /// The menu title of `value` in `key`'s submenu: the config text, except the percent keys (`Off`, `800 %`).
    public static func menuTitle(key: String, value: String) -> String {
        guard key == "upscale-high-from" || key == "pixel-art" else { return value }
        return value == "0" ? "Off" : "\(value) %"
    }

    /// `upscale-high: ewa-lanczos · this folder`.
    public static func toast(key: String, setForFolder value: String) -> String {
        "\(key): \(value) · this folder"
    }

    /// `S` on a nearest-neighbour frame, which no filter key affects: `nearest · pixel-art 800 %`.
    public static func toast(pixelArtPercent: Int) -> String {
        "nearest · pixel-art \(pixelArtPercent) %"
    }

    /// `Saved as default: downscale, upscale-high`, the keys in the order given (`keysToSave` sorts them).
    public static func toast(savedAsDefault keys: [String]) -> String {
        "Saved as default: " + keys.joined(separator: ", ")
    }

    /// `⇧S` while no filter of the window comes from a folder.
    public static let nothingToSave = "Nothing to save: no folder filters"
    /// `⇧S` / `⇧A` when loupe.conf could not be written (the folder keeps its values then).
    public static let couldNotSave = "Could not save loupe.conf"
}
