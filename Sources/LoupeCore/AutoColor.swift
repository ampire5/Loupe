import Foundation

/// The parts of Apple's automatic adjustments that can be turned off one by one (`auto-color-filters`).
public enum AutoColorFilter: String, CaseIterable, Sendable {
    case curve, shadows, vibrance

    /// The part a Core Image filter of Apple's analysis stands for; nil for the others (face balance, red-eye).
    public init?(filterName: String) {
        switch filterName {
        case "CIToneCurve": self = .curve
        case "CIHighlightShadowAdjust": self = .shadows
        case "CIVibrance": self = .vibrance
        default: return nil
        }
    }
}

/// `auto-color-method`: how Apple's analysis is applied.
public enum AutoColorMethod: String, CaseIterable, Sendable {
    /// Apple's chain as it is.
    case apple
    /// The tone curve and shadows of Apple's chain on luminance only: a pixel keeps its own chroma, and Apple's vibrance
    /// is left out.
    case appleLuma = "apple-luma"
}

/// Which scenes get the automatic correction and how much of it (`auto-color-threshold`, `auto-color-full`); ported
/// from FrameScrub as it is, without its re-analysis interval (Loupe has no video).
public enum AutoColorSchedule {
    /// Whether a photo gets the automatic correction: it changes the picture by at least `threshold`
    /// (`auto-color-threshold`, mean difference 0...255); 0 corrects every photo.
    public static func isNeeded(delta: Double, threshold: Double) -> Bool {
        threshold <= 0 || delta >= threshold
    }

    /// The share of `auto-color-strength` a photo gets: 0 at the threshold, growing in a line to the whole strength
    /// at `full` (`auto-color-full`), so photos that barely need it are barely touched. `full` at or below the
    /// threshold gives the whole strength to every photo that needs it.
    public static func rampStrength(delta: Double, threshold: Double, full: Double) -> Double {
        guard isNeeded(delta: delta, threshold: threshold) else { return 0 }
        guard full > threshold else { return 1 }
        return min(1, max(0, (delta - threshold) / (full - threshold)))
    }
}

/// The colour keys of a window as one value: what the cube builder and the window's corrector are given.
/// `auto-color-fade` is not here, it is the window's own transition.
public struct ColorSettings: Equatable, Sendable {
    public var autoColor: Bool
    public var method: AutoColorMethod
    public var strength: Double
    public var filters: Set<AutoColorFilter>
    public var vibranceGain: Double
    public var threshold: Double
    public var full: Double
    public var vibrance: Bool
    public var vibranceAmount: Double

    /// Everything off: the picture is drawn as it is.
    public static let off = ColorSettings(autoColor: false, method: .apple, strength: 1,
                                          filters: Set(AutoColorFilter.allCases), vibranceGain: 1,
                                          threshold: 6, full: 12, vibrance: false, vibranceAmount: 0.5)

    public init(autoColor: Bool, method: AutoColorMethod, strength: Double, filters: Set<AutoColorFilter>,
                vibranceGain: Double, threshold: Double, full: Double, vibrance: Bool, vibranceAmount: Double) {
        self.autoColor = autoColor
        self.method = method
        self.strength = strength
        self.filters = filters
        self.vibranceGain = vibranceGain
        self.threshold = threshold
        self.full = full
        self.vibrance = vibrance
        self.vibranceAmount = vibranceAmount
    }

    public init(config: Config) {
        self.init(autoColor: config.autoColor, method: config.autoColorMethod, strength: config.autoColorStrength,
                  filters: config.autoColorFilters, vibranceGain: config.autoColorVibranceGain,
                  threshold: config.autoColorThreshold, full: config.autoColorFull, vibrance: config.vibrance,
                  vibranceAmount: config.vibranceAmount)
    }
}

/// What the stats line says about a photo's colour (M3c spec §2.3).
public enum ColorStatus: Equatable, Sendable {
    /// Auto colour is off.
    case off
    /// On, and the photo's analysis is not there yet.
    case analysing
    /// The photo is nearly black: Apple's analysis of it would stretch the tones wildly, so it is left alone.
    case tooDark
    /// Below `auto-color-threshold`: Δ, and the photo is not touched.
    case needsNone(delta: Double)
    /// Corrected with `share` of the strength after the ramp; Δ is what the full correction would change.
    case applied(method: AutoColorMethod, share: Double, delta: Double)
    /// Needed (Δ) with a share above 0, but no cube carries it: the chosen steps leave nothing (`apple-luma` with only
    /// Apple's vibrance, say) or the photo's colour space cannot take a cube (no linearized variant).
    case nothingToApply(delta: Double)
    /// On, and the thumbnail store cannot make the photo's thumbnail, the analysis's only source: not analysed.
    case noThumbnail
}
