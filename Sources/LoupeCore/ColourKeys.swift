import Foundation

/// What the viewer's colour keys do to the values (M3c spec §2.1), on the model of `ScalingKeys`: `C` flips
/// `auto-color` and `V` flips `vibrance`, both for the window's folder; `⇧C` / `⇧V` save the window's values as
/// loupe.conf defaults (the window controller reuses `ScalingKeys.keysToClear` to drop the folder's own entries then).
/// Pure: the controller asks here, writes `FolderSettings` / loupe.conf and shows the toast texts.
public enum ColourKeys {
    /// The keys `⇧C` saves.
    public static let autoKeys = ["auto-color", "auto-color-method", "auto-color-strength"]
    /// The keys `⇧V` saves.
    public static let vibranceKeys = ["vibrance", "vibrance-amount"]

    /// `C` / `V`: `key` (`auto-color` or `vibrance`) the other way round in `config`, as loupe.conf spells it.
    public static func toggled(_ config: Config, key: String) -> String {
        (config.text(forKey: key) == "yes") ? "no" : "yes"
    }

    /// `Auto colour: on · folder` / `Auto colour: off`: `on` is a folder value, `off` too, but the text only says so for on.
    public static func toast(autoColor on: Bool) -> String { on ? "Auto colour: on · folder" : "Auto colour: off" }
    /// `Vibrance: on · folder` / `Vibrance: off`.
    public static func toast(vibrance on: Bool) -> String { on ? "Vibrance: on · folder" : "Vibrance: off" }
    /// The Colour menu's Method radio: `Method: apple-luma · folder`.
    public static func toast(method: AutoColorMethod) -> String { "Method: \(method.rawValue) · folder" }

    /// `⇧C` / `⇧V`, after loupe.conf took the values.
    public static let autoColorSaved = "Auto colour saved as default"
    public static let vibranceSaved = "Vibrance saved as default"
    /// Colour › Reset Folder Colour.
    public static let folderReset = "Folder colour reset"

    /// The Colour menu's Method radios, in menu order.
    public static let menuMethods: [(method: AutoColorMethod, title: String)] = [
        (.apple, "Apple"), (.appleLuma, "Apple, Luminance Only"),
    ]
}
