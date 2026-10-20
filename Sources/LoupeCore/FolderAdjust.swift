import Foundation

/// The `add <key> <step>` action (M4c spec §2.3): a step on a numeric folder key, rounded to the step and held to the
/// key's range, and the toast that answers it. Pure: the window controller reads the current value, asks here, writes
/// `FolderSettings` and shows the toast and the haptic.
public enum FolderAdjust {
    /// The keys `add` takes and their ranges (the same as `Config.set` accepts).
    public static let ranges: [String: ClosedRange<Double>] = [
        "auto-color-strength": 0...1, "vibrance-amount": 0...1,
    ]

    /// The value of `key` in `config` and whether its feature (`auto-color`, `vibrance`) is on there, for the toast's
    /// ` (off)`; nil for a key `add` does not take.
    public static func current(_ key: String, in config: Config) -> (value: Double, enabled: Bool)? {
        switch key {
        case "auto-color-strength": (config.autoColorStrength, config.autoColor)
        case "vibrance-amount": (config.vibranceAmount, config.vibrance)
        default: nil
        }
    }

    /// `value` moved by `step * n` (`n` is the number of wheel / move steps, negative for down), rounded to a multiple of
    /// `|step|` (so `0.65`, not `0.6500001`) and clamped to the range of `key`. `hitLimit`: the move went past the range
    /// (including a push against the bound the value already sits on).
    public static func stepped(_ value: Double, step: Double, times n: Int, key: String) -> (value: Double, hitLimit: Bool) {
        let range = ranges[key] ?? 0...1
        let unit = abs(step)
        guard unit > 0 else { return (min(max(value, range.lowerBound), range.upperBound), false) }
        let raw = value + step * Double(n)
        // Round to a multiple of the step, then to 6 places to shed the multiplication's noise.
        let snapped = ((raw / unit).rounded() * unit * 1e6).rounded() / 1e6
        let eps = 1e-9
        let hit = raw < range.lowerBound - eps || raw > range.upperBound + eps
            || snapped < range.lowerBound - eps || snapped > range.upperBound + eps
        return (min(max(snapped, range.lowerBound), range.upperBound), hit)
    }

    /// The detents of an `add` step, as fractions of the key's range (M4c spec §11): the value moving onto or across
    /// one plays `haptic-detent` in place of `haptic-step`.
    public static let detents = [0.25, 0.5, 0.75]

    /// The value went onto or across a detent: one lies after `from` (exclusive) up to `to` (inclusive), going either way,
    /// so 0.45 → 0.50 and 0.70 → 0.80 count, 0.50 → 0.55 does not. Bounds are no detents: a push at one is `hitLimit`,
    /// which wins over this.
    public static func crossesDetent(from: Double, to: Double, key: String) -> Bool {
        let range = ranges[key] ?? 0...1
        let width = range.upperBound - range.lowerBound
        let eps = 1e-9
        return detents.contains { f in
            let d = range.lowerBound + f * width
            return from < to ? (d > from + eps && d <= to + eps) : (d < from - eps && d >= to - eps)
        }
    }

    /// Two decimals: `0.65`, `1.00`.
    public static func text(_ v: Double) -> String { String(format: "%.2f", v) }

    /// `Auto colour strength 0.65 · folder` / `Vibrance amount 0.40 · folder`, with ` (off)` when the feature is off in
    /// the folder (the strength still changed).
    public static func toast(key: String, value: Double, enabled: Bool) -> String {
        let name: String
        switch key {
        case "auto-color-strength": name = "Auto colour strength"
        case "vibrance-amount": name = "Vibrance amount"
        default: name = key
        }
        return "\(name) \(text(value)) · folder" + (enabled ? "" : " (off)")
    }
}
