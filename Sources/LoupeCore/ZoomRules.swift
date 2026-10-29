import Foundation

/// `pan-indicators`: the pills at the picture's edge that show where the visible part lies. `auto`: while the view
/// pans or zooms and shortly after; `always`: whenever the picture is larger than the window; `no`: never. The `P`
/// key cycles it for the session.
public enum PanIndicatorMode: String, CaseIterable, Sendable {
    case auto, always, no

    /// `auto` → `always` → `no` → `auto`.
    public var next: PanIndicatorMode {
        switch self {
        case .auto: return .always
        case .always: return .no
        case .no: return .auto
        }
    }
}

/// What a photo switch does with the view (M4b spec §4): `keep-zoom-position`, `default-zoom-mode` (both folder keys)
/// and `fit-upscale`, read from the effective config.
public struct ZoomRules: Equatable, Sendable {
    /// `keep-zoom-position`: a switch keeps the current zoom mode (where the view lands is `pan`'s).
    public var keep: Bool
    /// `keep-zoom-as`: what a kept free zoom keeps.
    public var carry: ZoomCarry
    /// `step-pan`: where the view lands after a step.
    public var pan: StepPan
    /// `step-zoom`: whether a step frames the next photo on its subject.
    public var stepZoom: StepZoom
    /// `subject-pull` as a share (0…1).
    public var subjectPull: Double
    /// `subject-target`: where `pan`'s subject is looked for.
    public var chain: [SubjectKind]
    /// `zoom-anchor`: where a gesture zoom is anchored.
    public var anchor: ZoomAnchor
    /// `subject-size` as a share (0.2…1): how much of the view the subject's frame takes under Zoom to Subject.
    public var subjectSize: Double
    /// `default-zoom-mode`: the mode a photo opens in when the view is not kept.
    public var defaultMode: ZoomMode
    /// `fit-upscale`: Fit magnifies a photo smaller than the window (`no`: at most 100 %).
    public var fitUpscale: Bool
    /// The custom detector's mode when it is on and its model is there (`detector`, detector.conf): its chain and size
    /// are `chain` and `subjectSize`.
    public var detector: DetectorSetup.Mode?
    public var composition = CompositionOptions()

    public init(config: Config) {
        keep = config.keepZoomPosition
        carry = config.keepZoomAs
        pan = config.stepPan
        stepZoom = config.stepZoom
        subjectPull = Double(config.subjectPull) / 100
        chain = config.subjectTarget
        anchor = config.zoomAnchor
        subjectSize = Double(config.subjectSize) / 100
        defaultMode = config.defaultZoomMode
        fitUpscale = config.fitUpscale
        if config.detector, config.detectorSetup.detects, let mode = config.detectorSetup.mode(config.detectorMode) {
            detector = mode
            chain = mode.chain
            subjectSize = mode.size
            composition = mode.composition
        }
        if let values = config.smartZoomOptions[detector?.name ?? "vision"] {
            for (key, value) in values {
                if key == "size", let v = DetectorSetup.share(value) { subjectSize = v }
                else { _ = composition.set(key, value) }
            }
        }
    }

    /// The kinds ⇧Z steps through: the custom detector's chain, else every one of Vision's.
    public var stepKinds: [SubjectKind] { detector?.chain ?? SubjectKind.vision }

    /// `fit`, `fit-width`, `fit-height`, `fill` or `<k>%` (`k` finite and above 0; `100%`, `12.5%`) → the mode, else
    /// nil. Either case, spaces around the number allowed.
    public static func parseMode(_ text: String) -> ZoomMode? {
        let token = text.trimmingCharacters(in: .whitespaces).lowercased()
        switch token {
        case "fit": return .fit
        case "fit-width": return .fitWidth
        case "fit-height": return .fitHeight
        case "fill": return .fill
        default:
            guard token.hasSuffix("%"),
                  let k = Double(token.dropLast().trimmingCharacters(in: .whitespaces)), k.isFinite, k > 0 else { return nil }
            return .actual(k / 100)
        }
    }

    /// The spelling `parseMode` reads back (`.actual(1)` is `100%`). `.free` is a transient zoom, not a mode a key can
    /// name; it prints as `fit`.
    public static func text(of mode: ZoomMode) -> String {
        switch mode {
        case .fit, .free: return "fit"
        case .fitWidth: return "fit-width"
        case .fitHeight: return "fit-height"
        case .fill: return "fill"
        case .actual(let scale): return formatNumber(scale * 100) + "%"
        }
    }
}
