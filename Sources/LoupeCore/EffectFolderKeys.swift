/// Effect settings use the same per-folder inheritance and explicit default saving as colour/scaling.
public enum DisplayEffect: Sendable { case deband, grain }

public enum EffectFolderKeys {
    public static func keys(_ effect: DisplayEffect) -> [String] {
        switch effect {
        case .deband: return ["deband", "deband-strength", "deband-threshold", "deband-radius", "deband-iterations", "deband-texture-protection"]
        case .grain: return ["grain", "grain-stage", "grain-amount", "grain-size"]
        }
    }

    public static func modeKey(_ effect: DisplayEffect) -> String {
        switch effect { case .deband: "deband"; case .grain: "grain" }
    }

    public static func toggled(_ effect: DisplayEffect, config: Config, remembered: String?) -> String {
        switch effect {
        case .deband:
            guard config.deband == .off else { return "off" }
            let mode = remembered.flatMap(DebandMode.init(rawValue:))
            return mode.flatMap { $0 == .off ? nil : $0 }?.rawValue ?? "window"
        case .grain:
            guard config.grain == .off else { return "off" }
            let style = remembered.flatMap(GrainStyle.init(rawValue:))
            return style.flatMap { $0 == .off ? nil : $0 }?.rawValue ?? "fine"
        }
    }
}
