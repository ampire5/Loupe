import Foundation

/// The enabled style is the config's `grain`; only its previous non-off choice needs separate persistence.
public enum GrainToggle {
    public static let lastStyleKey = "grain.lastEnabledStyle"

    public static func remember(_ style: GrainStyle, preferences: UserDefaults) {
        guard style != .off, preferences.string(forKey: lastStyleKey) != style.rawValue else { return }
        preferences.set(style.rawValue, forKey: lastStyleKey)
    }

    public static func toggle(_ config: inout Config, preferences: UserDefaults) {
        if config.grain != .off {
            remember(config.grain, preferences: preferences)
            config.grain = .off
        } else {
            let stored = preferences.string(forKey: lastStyleKey).flatMap(GrainStyle.init(rawValue:))
            config.grain = stored.flatMap { $0 == .off ? nil : $0 } ?? .fine
            remember(config.grain, preferences: preferences)
        }
    }

    public static func toast(_ style: GrainStyle) -> String {
        guard style != .off else { return "Grain: Off" }
        let name = style == .av1 ? "AV1" : style.rawValue.capitalized
        return "Grain: On · \(name)"
    }
}
