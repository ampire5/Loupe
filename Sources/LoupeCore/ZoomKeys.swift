import Foundation

/// What the viewer's keep-zoom keys do (M4b spec §4.4), on the model of `ColourKeys`: `L` flips `keep-zoom-position`
/// and `K` `keep-zoom-as` for the window's folder; `⇧L` / `⇧K` save the window's value as the loupe.conf default (the window controller reuses
/// `ScalingKeys.keysToClear` to drop the folder's own entry then). Pure: the controller asks here, writes
/// `FolderSettings` / loupe.conf and shows the toast texts.
public enum ZoomKeys {
    /// The key `L` writes and `⇧L` saves.
    public static let keepKey = "keep-zoom-position"

    /// `L`: `keep-zoom-position` the other way round in `config`, as loupe.conf spells it.
    public static func toggled(_ config: Config) -> String { config.keepZoomPosition ? "no" : "yes" }

    /// `Keep zoom: on · folder` / `Keep zoom: off · folder`: both are the folder's own value.
    public static func toast(keep on: Bool) -> String { on ? "Keep zoom: on · folder" : "Keep zoom: off · folder" }

    /// `⇧L`, after loupe.conf took the value.
    public static let keepSaved = "Keep zoom saved as default"

    /// The key `K` writes and `⇧K` saves.
    public static let carryKey = "keep-zoom-as"

    /// `K`: `keep-zoom-as` the other way round in `config`.
    public static func toggledCarry(_ config: Config) -> ZoomCarry { config.keepZoomAs == .share ? .scale : .share }

    /// `Zoom keeps: share of photo · folder` / `Zoom keeps: scale · folder`.
    public static func toast(carry: ZoomCarry) -> String {
        carry == .share ? "Zoom keeps: share of photo · folder" : "Zoom keeps: scale · folder"
    }

    /// `⇧K`, after loupe.conf took the value.
    public static let carrySaved = "Zoom share / scale saved as default"
}
