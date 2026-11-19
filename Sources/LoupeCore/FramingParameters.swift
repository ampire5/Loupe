import Foundation

public enum FramingParameters {
    public static let keys = ["size", "chain", "weights", "weight-normalization", "max-zoom", "margin", "circle-radius",
        "circle-radii", "max-crop", "protection-margin", "protection-margins", "protection-scope", "pan-overflow", "steady-framing"]
    public static func neighbors(profile: FramingProfile, references: [FramingReference], step: Double) -> [FramingProfile] {
        var result: [FramingProfile] = []
        func edit(_ body: (inout FramingProfile) -> Void) { var p = profile; body(&p); if p.isValid && p != profile { result.append(p) } }
        let observed = Set(references.flatMap { $0.instances.filter { $0.score >= 0.2 }.map(\.kind) })
        let context = references.first?.evidence.framing ?? DetectorFraming()
        for d in [-step, step] {
            edit { $0.size = min(1, max(0.2, $0.size + d)) }
            edit { $0.composition.margin = min(1, max(0, $0.composition.margin + d)) }
            edit { $0.composition.maxZoom = min(4, max(0.25, $0.composition.maxZoom + d * 4)) }
            edit { $0.composition.circleRadius = min(2, max(0.25, $0.composition.circleRadius + d)) }
            edit { $0.composition.protectionMargin = min(0.5, max(0, $0.composition.protectionMargin + d)) }
            for kind in observed.sorted(by: { $0.rawValue < $1.rawValue }) {
                edit { $0.composition.weights[kind] = min(4, max(0.25, ($0.composition.weights[kind] ?? 1) + d * 4)) }
                edit { $0.composition.circleRadii[kind] = min(2, max(0.25, $0.composition.radius(for: kind) + d)) }
                edit { $0.composition.protectionMargins[kind] = min(0.5, max(0, $0.composition.protectionPadding(for: kind, framing: context) + d)) }
                edit { $0.composition.maxCrop[kind] = min(0.49, max(0, ($0.composition.cropLimit(for: kind, framing: context) ?? 0) + d)) }
            }
        }
        for kind in observed.sorted(by: { $0.rawValue < $1.rawValue }) {
            edit { $0.composition.maxCrop[kind] = 1 }
            edit { $0.composition.maxCrop.removeValue(forKey: kind) }
        }
        edit { $0.composition.normalization = $0.composition.normalization == .class ? .object : .class }
        edit { $0.composition.protectionScope = $0.composition.protectionScope == .all ? .selected : .all }
        if references.contains(where: { $0.behavior == .pan }) {
            edit { $0.composition.panOverflow = $0.composition.panOverflow == .fit ? .keep : .fit }
        }
        for i in 1..<max(1, profile.chain.count) { edit { $0.chain.swapAt(i - 1, i) } }
        return result
    }
}
