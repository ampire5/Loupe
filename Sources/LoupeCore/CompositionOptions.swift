import Foundation

/// Composition settings are independent of detection and of image resolution.
public struct CompositionOptions: Equatable, Sendable {
    public enum Normalization: String, Sendable { case `class`, object }
    public enum PanOverflow: String, Sendable { case fit, keep }
    public enum ProtectionScope: String, Sendable { case all, selected }
    public var panOverflow = PanOverflow.fit
    public var maxZoom = 1.0
    public var margin = 0.08
    public var normalization = Normalization.class
    public var weights: [SubjectKind: Double] = [:]
    public var circleRadius = 1.0
    public var circleRadii: [SubjectKind: Double] = [:]
    /// 1 disables protection explicitly; otherwise 0...0.49 is the allowed cut on each edge.
    public var maxCrop: [SubjectKind: Double] = [:]
    public var protectionMargin = 0.0
    public var protectionMargins: [SubjectKind: Double] = [:]
    public var protectionScope = ProtectionScope.all
    public var steadyFraming = true
    public init() {}

    /// nil: another key; false: recognized but invalid. Invalid input leaves the value intact.
    public mutating func set(_ key: String, _ value: String) -> Bool? {
        switch key {
        case "circle-radius":
            guard let v = Self.share(value, in: 0.25...2) else { return false }; circleRadius = v
        case "circle-radii":
            guard let v = Self.map(value, range: 0.25...2) else { return false }; circleRadii = v
        case "max-crop":
            guard let v = Self.map(value, range: 0...0.49, allowsOff: true) else { return false }; maxCrop = v
        case "protection-margin":
            guard let v = Self.share(value, in: 0...0.5) else { return false }; protectionMargin = v
        case "protection-margins":
            guard let v = Self.map(value, range: 0...0.5) else { return false }; protectionMargins = v
        case "protection-scope":
            guard let v = ProtectionScope(rawValue: value.lowercased()) else { return false }; protectionScope = v
        case "steady-framing":
            guard ["yes", "no"].contains(value.lowercased()) else { return false }; steadyFraming = value.lowercased() == "yes"
        case "pan-overflow":
            guard let v = PanOverflow(rawValue: value.lowercased()) else { return false }; panOverflow = v
        case "max-zoom":
            guard let v = DetectorSetup.share(value), v.isFinite, (0.25...4).contains(v) else { return false }
            maxZoom = v
        case "margin":
            guard let v = DetectorSetup.share(value), v.isFinite, (0...1).contains(v) else { return false }
            margin = v
        case "weight-normalization":
            guard let v = Normalization(rawValue: value.lowercased()) else { return false }; normalization = v
        case "weights":
            var parsed: [SubjectKind: Double] = [:]
            if !value.isEmpty {
                for item in value.split(separator: ",", omittingEmptySubsequences: false) {
                    let pair = item.split(separator: ":", omittingEmptySubsequences: false)
                    guard pair.count == 2, let kind = SubjectKind(rawValue: String(pair[0])), !kind.isCombination,
                          let weight = Double(pair[1].trimmingCharacters(in: .whitespaces)), weight.isFinite,
                          (0.25...4).contains(weight) else { return false }
                    parsed[kind] = weight
                }
            }
            weights = parsed
        default: return nil
        }
        return true
    }
    public var values: [String: String] {
        ["circle-radius": "\(circleRadius * 100)%", "circle-radii": Self.text(circleRadii),
         "max-crop": Self.text(maxCrop, allowsOff: true), "protection-margin": "\(protectionMargin * 100)%",
         "protection-margins": Self.text(protectionMargins), "protection-scope": protectionScope.rawValue,
         "steady-framing": steadyFraming ? "yes" : "no",
         "pan-overflow": panOverflow.rawValue, "max-zoom": "\(maxZoom * 100)%", "margin": "\(margin * 100)%", "weight-normalization": normalization.rawValue,
         "weights": weights.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue):\($0.value)" }.joined(separator: ",")]
    }

    public var isValid: Bool {
        circleRadius.isFinite && (0.25...2).contains(circleRadius)
            && circleRadii.values.allSatisfy { $0.isFinite && (0.25...2).contains($0) }
            && maxCrop.values.allSatisfy { $0.isFinite && ((0...0.49).contains($0) || $0 == 1) }
            && protectionMargin.isFinite && (0...0.5).contains(protectionMargin)
            && protectionMargins.values.allSatisfy { $0.isFinite && (0...0.5).contains($0) }
    }

    public func radius(for kind: SubjectKind) -> Double {
        let value = circleRadii[kind] ?? circleRadius
        return value.isFinite ? min(max(value, 0.25), 2) : 1
    }

    public func cropLimit(for kind: SubjectKind) -> Double? {
        let value = maxCrop[kind] ?? (SubjectFraming.framesHead(kind) ? (maxCrop[.face] ?? 0) : nil)
        guard let value, value.isFinite, (0...0.49).contains(value) else { return nil }
        return value
    }

    public func protectionPadding(for kind: SubjectKind) -> Double {
        let value = protectionMargins[kind] ?? (SubjectFraming.framesHead(kind) ? protectionMargins[.face] : nil) ?? protectionMargin
        return value.isFinite ? min(max(value, 0), 0.5) : 0
    }

    private static func share(_ value: String, in range: ClosedRange<Double>) -> Double? {
        guard let v = DetectorSetup.share(value), v.isFinite, range.contains(v) else { return nil }; return v
    }
    private static func map(_ value: String, range: ClosedRange<Double>, allowsOff: Bool = false) -> [SubjectKind: Double]? {
        var result: [SubjectKind: Double] = [:]
        if value.isEmpty { return result }
        for entry in value.split(separator: ",", omittingEmptySubsequences: false) {
            let parts = entry.split(separator: ":", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let kind = SubjectKind(rawValue: parts[0]), !kind.isCombination, result[kind] == nil else { return nil }
            if allowsOff && parts[1].lowercased() == "off" { result[kind] = 1 }
            else if let v = share(parts[1], in: range) { result[kind] = v }
            else { return nil }
        }
        return result
    }
    public static func text(_ values: [SubjectKind: Double], allowsOff: Bool = false) -> String {
        values.sorted { $0.key.rawValue < $1.key.rawValue }.map {
            "\($0.key.rawValue):" + (allowsOff && $0.value == 1 ? "off" : "\($0.value * 100)%")
        }.joined(separator: ",")
    }
}

