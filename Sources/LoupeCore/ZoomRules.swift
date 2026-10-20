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
    /// `keep-zoom-position`: a switch keeps the current zoom mode and centre.
    public var keep: Bool
    /// `default-zoom-mode`: the mode a photo opens in when the view is not kept.
    public var defaultMode: ZoomMode
    /// `fit-upscale`: Fit magnifies a photo smaller than the window (`no`: at most 100 %).
    public var fitUpscale: Bool

    public init(config: Config) {
        keep = config.keepZoomPosition
        defaultMode = config.defaultZoomMode
        fitUpscale = config.fitUpscale
    }

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
