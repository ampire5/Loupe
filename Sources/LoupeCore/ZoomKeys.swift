import Foundation

/// What the viewer's keep-zoom keys do (M4b spec §4.4), on the model of `ColourKeys`: `L` flips `keep-zoom-position`
/// and `K` `keep-zoom-as` for the window's folder; `⇧L` / `⇧K` save the window's value as the loupe.conf default (the window controller reuses
/// `ScalingKeys.keysToClear` to drop the folder's own entry then). Pure: the controller asks here, writes
/// `FolderSettings` / loupe.conf and shows the toast texts.
public enum ZoomKeys {
    /// The zoom keys and the zoom menu choose for the tab (owner, 2026-10-28): its values go over the folder's, for
    /// whatever folder it shows, until the tab closes; `⌥L` (`rememberZoom`) writes them for the folder at once.
    public static func layered(folder: [String: String], tab: [String: String]) -> [String: String] {
        folder.merging(tab) { $1 }
    }

    public static func profileSelection(_ name: String?) -> [String: String] {
        var values = ["detector": name == nil ? "no" : "yes"]
        if let name { values["detector-mode"] = name }
        return values
    }
    public static func recalledProfile(_ values: [String: String]?, setup: DetectorSetup) -> [String: String] {
        guard let values else { return [:] }
        if values["detector"] == "no" { return profileSelection(nil) }
        guard values["detector"] == "yes", let name = values["detector-mode"],
              setup.modes.contains(where: { $0.name == name }) else { return [:] }
        return profileSelection(name)
    }
    public static let lastProfileKey = "loupe.last-detector-profile"

    public static let manualSaveKeys = ["keep-zoom-position", "keep-zoom-as", "default-zoom-mode", "step-pan", "zoom-anchor"]
    public static let smartSaveKeys = ["smart-zoom", "smart-zoom-options", "detector", "detector-mode", "subject-target"]
    public static func saveKeys(for mode: SmartZoomMode) -> [String] { mode == .off ? manualSaveKeys : smartSaveKeys }

    /// `⌥⇧G`: framing while browsing (`step-zoom`) for the tab.
    public static let stepZoomKey = "step-zoom"

    public static func toggledStepZoom(_ config: Config) -> StepZoom { config.stepZoom == .subject ? .keep : .subject }

    public static func toast(stepZoom: StepZoom) -> String {
        stepZoom == .subject ? "After a step: frame the subject · tab" : "After a step: the zoom as kept · tab"
    }

    /// `⌥L`, after the folder took the tab's zoom choices.
    public static let remembered = "Zoom remembered for this folder"

    /// The key `L` writes and `⇧L` saves.
    public static let keepKey = "keep-zoom-position"

    /// `L`: `keep-zoom-position` the other way round in `config`, as loupe.conf spells it.
    public static func toggled(_ config: Config) -> String { config.keepZoomPosition ? "no" : "yes" }

    /// `Manual zoom: keep on · tab` / `Manual zoom: keep off · tab`: the tab's own value, until it closes or ⌥L remembers it.
    public static func toast(keep on: Bool) -> String { on ? "Manual zoom: keep on · tab" : "Manual zoom: keep off · tab" }

    /// `⇧L`, after loupe.conf took the value.
    public static let keepSaved = "Keep zoom saved as default"

    /// The key `K` writes and `⇧K` saves.
    public static let carryKey = "keep-zoom-as"

    /// `K`: the next `keep-zoom-as` after the one in `config`: share → scale → screen → share.
    public static func toggledCarry(_ config: Config) -> ZoomCarry {
        switch config.keepZoomAs {
        case .share: .scale
        case .scale: .screen
        case .screen: .share
        }
    }

    /// `Manual zoom keeps: share of photo · folder`, `… scale · folder`, `… share of screen · folder`.
    public static func toast(carry: ZoomCarry) -> String {
        switch carry {
        case .share: "Manual zoom keeps: share of photo · tab"
        case .scale: "Manual zoom keeps: scale · tab"
        case .screen: "Manual zoom keeps: share of screen · tab"
        }
    }

    /// `⇧K`, after loupe.conf took the value.
    public static let carrySaved = "Zoom share / scale saved as default"

    /// The keys `⌥K` and `⌥Z` write (and save with `⇧`).
    public static let panKey = "step-pan"
    public static let anchorKey = "zoom-anchor"

    /// `⌥K`: the next `step-pan`: subject → keep → center → subject.
    public static func toggledPan(_ config: Config) -> StepPan {
        switch config.stepPan {
        case .subject: .keep
        case .keep: .center
        case .center: .subject
        }
    }

    /// `⌥Z`: the next `zoom-anchor`: pointer → center → subject → pointer.
    public static func toggledAnchor(_ config: Config) -> ZoomAnchor {
        switch config.zoomAnchor {
        case .pointer: .center
        case .center: .subject
        case .subject: .pointer
        }
    }

    public static func toast(pan: StepPan) -> String {
        switch pan {
        case .subject: "After a step: the subject · tab"
        case .keep: "Manual pan: the same place · tab"
        case .center: "Manual pan: the centre · tab"
        }
    }

    public static func toast(anchor: ZoomAnchor) -> String {
        switch anchor {
        case .pointer: "Zoom towards: the pointer · tab"
        case .center: "Zoom towards: the centre · tab"
        case .subject: "Zoom towards: the subject · tab"
        }
    }

    public static let panSaved = "After a step saved as default"
    public static let targetKey = "subject-target"

    /// `⌥G`: the next of `SmartZoomMenu.targets` after the folder's chain (a chain that is none of them: the first).
    public static func toggledTarget(_ config: Config) -> String {
        let targets = SmartZoomMenu.targets.map(\.value)
        let now = config.text(forKey: targetKey) ?? ""
        guard let i = targets.firstIndex(of: now) else { return targets[0] }
        return targets[(i + 1) % targets.count]
    }

    public static func toast(target: String) -> String {
        let title = SmartZoomMenu.targets.first { $0.value == target }?.title.lowercased() ?? target
        return "Zoom to: \(title) · tab"
    }
    public static let anchorSaved = "Zoom towards saved as default"

    /// The custom detector's keys (`⌥C`, `⌥G` under it): the tab's, like the zoom keys.
    public static let detectorKey = "detector", detectorModeKey = "detector-mode"

    /// `⌥C`: the custom detector off when on, else on; nil without a model and modes (detector.conf), so the key says so.
    public static func toggledDetector(_ config: Config) -> Bool? {
        guard config.detectorSetup.detects, !config.detectorSetup.modes.isEmpty else { return nil }
        return !config.detector
    }

    /// `⌥G` under the custom detector: the mode after the tab's, round.
    public static func nextDetectorMode(_ config: Config) -> String? {
        config.detectorSetup.next(after: config.detectorMode)?.name
    }

    /// `M`: the mode the custom detector turns on in (the folder's, else detector.conf's `mode`), or the next one while
    /// it is on; nil when it cannot frame (no model, classes or modes).
    public static func modeAfterM(_ config: Config) -> String? {
        guard toggledDetector(config) != nil else { return nil }
        return ZoomRules(config: config).detector != nil ? nextDetectorMode(config) : config.detectorSetup.mode(config.detectorMode)?.name
    }

    public static func toast(detector on: Bool, mode: String?) -> String {
        on ? "Detector: \(mode ?? "on") · folder" : "Detector: off · folder"
    }
}

/// The zoom block's set (smart zoom spec §3.3): the classic modes (Fit, 100 %, Fit Width, Fit Height, Fill) or smart
/// zoom (Subject, Screen share, Fill on the subject). `g` switches it; in the smart set the number keys 1 and 2 are the
/// smart modes (3 is Fill on the subject in both, 0 Fit in both).
public enum ZoomSet: String, Sendable {
    case classic, smart

    public var toggled: ZoomSet { self == .classic ? .smart : .classic }

    /// What a key or mouse button's action does in `set`.
    public static func remap(_ action: KeyAction, in set: ZoomSet) -> KeyAction {
        action
    }
}

/// The zoom menu's smart zoom groups (spec §3.2): each a key of loupe.conf and its values with their titles, the folder's
/// value ticked. `subject-target` is not among them: a list, edited in the Settings window.
public enum SmartZoomMenu {
    public struct Group: Sendable {
        public let title: String
        public let key: String
        public let choices: [(title: String, value: String)]
    }

    /// Where Zoom to Subject and `step-pan=subject` look first: `subject-target`'s chains, each falling back to the next.
    public static let targets: [(title: String, value: String)] = [
        ("A Face", "face,person,object,saliency"), ("A Person", "person,object,saliency"),
        ("An Object", "object,saliency"), ("Where the Eye Goes", "saliency"),
    ]

    public static let groups: [Group] = [
        Group(title: "SmartZoom — Vision Targets", key: "subject-target", choices: targets),
        Group(title: "Manual Zoom — Carry", key: "keep-zoom-as",
              choices: [("Share of the Photo", "share"), ("Scale", "scale"), ("Share of the Screen", "screen")]),
        Group(title: "SmartZoom", key: "smart-zoom",
              choices: [("Manual", "off"), ("Pan only", "pan"), ("Auto framing", "frame")]),
        Group(title: "Gesture Zoom Towards", key: "zoom-anchor",
              choices: [("The Pointer", "pointer"), ("The Centre", "center"), ("The Subject", "subject")]),
        Group(title: "Subject Analysis Scheduling", key: "subject-analysis",
              choices: [("Ahead While SmartZoom Is On", "ahead"), ("Current Photo", "on-demand"), ("SmartZoom Requests Only", "off")]),
    ]
}
