import Testing
import Foundation
@testable import LoupeCore

// M3c spec §3.2: the ramp is FrameScrub's, as it is.
@Test func rampMatchesFrameScrub() {
    func share(_ delta: Double) -> Double { AutoColorSchedule.rampStrength(delta: delta, threshold: 6, full: 12) }
    #expect(share(5) == 0 && share(6) == 0)
    #expect(share(9) == 0.5)
    #expect(share(12) == 1 && share(20) == 1)
    #expect(!AutoColorSchedule.isNeeded(delta: 5.9, threshold: 6) && AutoColorSchedule.isNeeded(delta: 6, threshold: 6))
    // Threshold 0 corrects every scene.
    #expect(AutoColorSchedule.isNeeded(delta: 0, threshold: 0))
    #expect(AutoColorSchedule.rampStrength(delta: 0, threshold: 0, full: 0) == 1)
    // `full` at or below the threshold gives the whole strength to every scene that needs it.
    #expect(AutoColorSchedule.rampStrength(delta: 7, threshold: 6, full: 6) == 1)
    #expect(AutoColorSchedule.rampStrength(delta: 7, threshold: 6, full: 3) == 1)
    #expect(AutoColorSchedule.rampStrength(delta: 5, threshold: 6, full: 3) == 0)
}

@Test func filterNames() {
    #expect(AutoColorFilter(filterName: "CIToneCurve") == .curve)
    #expect(AutoColorFilter(filterName: "CIHighlightShadowAdjust") == .shadows)
    #expect(AutoColorFilter(filterName: "CIVibrance") == .vibrance)
    #expect(AutoColorFilter(filterName: "CIFaceBalance") == nil)
    #expect(AutoColorFilter.allCases == [.curve, .shadows, .vibrance])
    #expect(AutoColorMethod.allCases.map(\.rawValue) == ["apple", "apple-luma"])
}

@Test func colorSettingsFromConfig() {
    // The defaults draw the picture as it is (their strength, gain and amount only count once a key is turned on).
    let defaults = ColorSettings(config: Config())
    #expect(!defaults.autoColor && !defaults.vibrance)
    #expect(defaults.strength == 0.8 && defaults.vibranceGain == 1.5 && defaults.vibranceAmount == 0.65)
    #expect(ColorSettings.off.autoColor == false && ColorSettings.off.vibrance == false)

    var c = Config()
    c.autoColor = true
    c.autoColorMethod = .appleLuma
    c.autoColorStrength = 0.75
    c.autoColorFilters = [.curve, .vibrance]
    c.autoColorVibranceGain = 2
    c.autoColorThreshold = 4
    c.autoColorFull = 20
    c.autoColorFadeMilliseconds = 300   // the fade is the window's, not a cube parameter
    c.vibrance = true
    c.vibranceAmount = 0.8
    let s = ColorSettings(config: c)
    #expect(s.autoColor && s.method == .appleLuma && s.strength == 0.75)
    #expect(s.filters == [.curve, .vibrance] && s.vibranceGain == 2)
    #expect(s.threshold == 4 && s.full == 20)
    #expect(s.vibrance && s.vibranceAmount == 0.8)
    #expect(s != .off)
}

@Test func colorStatusCases() {
    #expect(ColorStatus.applied(method: .apple, share: 0.5, delta: 9) == .applied(method: .apple, share: 0.5, delta: 9))
    #expect(ColorStatus.applied(method: .apple, share: 0.5, delta: 9) != .applied(method: .appleLuma, share: 0.5, delta: 9))
    #expect(ColorStatus.needsNone(delta: 4) != .needsNone(delta: 5))
    #expect(ColorStatus.off != .analysing && ColorStatus.tooDark != .off)
    #expect(ColorStatus.nothingToApply(delta: 9) != .needsNone(delta: 9) && ColorStatus.noThumbnail != .analysing)
}

@Test func configAutoColorKeys() throws {
    // Spec §2.4: verbatim keys, defaults and ranges.
    let keys = ["auto-color", "auto-color-method", "auto-color-strength", "auto-color-filters",
                "auto-color-vibrance-gain", "auto-color-threshold", "auto-color-full", "auto-color-fade",
                "vibrance", "vibrance-amount"]
    let c = Config()
    #expect(!c.autoColor && c.autoColorMethod == .apple && c.autoColorStrength == 0.8)
    #expect(c.autoColorFilters == [.curve, .shadows, .vibrance] && c.autoColorVibranceGain == 1.5)
    #expect(c.autoColorThreshold == 6 && c.autoColorFull == 12 && c.autoColorFadeMilliseconds == 150)
    #expect(!c.vibrance && c.vibranceAmount == 0.65)
    let defaults = ["no", "apple", "0.8", "curve,shadows,vibrance", "1.5", "6", "12", "150", "no", "0.65"]
    #expect(keys.map { c.text(forKey: $0) } == defaults)

    let (p, w) = Config.parse("""
        auto-color=yes
        auto-color-method=Apple-Luma
        auto-color-strength=0.5
        auto-color-filters = Vibrance, curve
        auto-color-vibrance-gain=4
        auto-color-threshold=0
        auto-color-full=255
        auto-color-fade=0
        vibrance=yes
        vibrance-amount=1
        """)
    #expect(w.isEmpty)
    #expect(p.autoColor && p.autoColorMethod == .appleLuma && p.autoColorStrength == 0.5)
    #expect(p.autoColorFilters == [.curve, .vibrance] && p.autoColorVibranceGain == 4)
    #expect(p.autoColorThreshold == 0 && p.autoColorFull == 255 && p.autoColorFadeMilliseconds == 0)
    #expect(p.vibrance && p.vibranceAmount == 1)
    // Written back in the canonical order, and read again as the same config.
    #expect(p.text(forKey: "auto-color-filters") == "curve,vibrance")
    let text = keys.map { "\($0)=\(p.text(forKey: $0) ?? "")" }.joined(separator: "\n")
    #expect(Config.parse(text) == (p, []))

    // Edges of the ranges.
    for good in ["auto-color-strength=0", "auto-color-strength=1", "auto-color-vibrance-gain=0",
                 "auto-color-threshold=255", "auto-color-fade=2000", "vibrance-amount=0", "auto-color-filters=shadows"] {
        #expect(Config.parse(good).1.isEmpty, "\(good)")
    }
    // A bad value is the usual warning and leaves the default.
    for bad in ["auto-color=maybe", "auto-color-method=oil", "auto-color-strength=1.5", "auto-color-strength=-0.1",
                "auto-color-filters=", "auto-color-filters=curve,red", "auto-color-filters=none",
                "auto-color-vibrance-gain=4.5", "auto-color-threshold=256", "auto-color-threshold=-1",
                "auto-color-full=300", "auto-color-fade=3000", "auto-color-fade=-1", "auto-color-fade=1.5",
                "vibrance=maybe", "vibrance-amount=-1", "vibrance-amount=1.01", "vibrance-amount=nan"] {
        let (parsed, warnings) = Config.parse(bad)
        #expect(parsed == Config() && warnings.count == 1, "\(bad)")
        var set = Config()
        #expect(set.set(String(bad.split(separator: "=", omittingEmptySubsequences: false)[0]),
                        String(bad.split(separator: "=", omittingEmptySubsequences: false)[1])) == .badValue, "\(bad)")
        #expect(set == Config(), "\(bad)")
    }

    // Right after `exif-orientation`, in this order.
    let exif = try #require(Config.keys.firstIndex(of: "exif-orientation"))
    #expect(Array(Config.keys[(exif + 1)...(exif + 10)]) == keys)
    #expect(Config.keys[exif + 11] == "strip-window")

    // The five folder keys, and `applying` takes them (and no others of these).
    let folder = ["auto-color", "auto-color-method", "auto-color-strength", "vibrance", "vibrance-amount"]
    #expect(folder.allSatisfy(Config.folderKeys.contains))
    let (applied, rejected) = Config().applying(["auto-color": "yes", "auto-color-method": "apple-luma",
                                                 "auto-color-strength": "0.4", "vibrance": "yes", "vibrance-amount": "0.2"])
    #expect(rejected.isEmpty)
    #expect(applied.autoColor && applied.autoColorMethod == .appleLuma && applied.autoColorStrength == 0.4)
    #expect(applied.vibrance && applied.vibranceAmount == 0.2)
    let (global, globalRejected) = Config().applying(["auto-color-filters": "curve", "auto-color-fade": "0",
                                                      "auto-color-vibrance-gain": "2", "auto-color-threshold": "1",
                                                      "auto-color-full": "2"])
    #expect(global == Config() && globalRejected.count == 5)
}
