import Foundation

/// A value-only edit; validation and file transformation can run off the UI thread.
public struct DetectorProfileDraft: Equatable, Sendable {
    public var name: String
    public var chain: [SubjectKind]
    public var size = 0.6
    public var composition = CompositionOptions()
    public init(name: String, chain: [SubjectKind]) { self.name = name; self.chain = chain }
    public enum Invalid: String, Error, LocalizedError {
        case name = "Use a profile name without brackets, comments or line breaks."
        case exists = "A profile with this name already exists."
        case missing = "This profile no longer exists."
        case empty = "Add at least one priority rule."
        case category = "A rule uses a category not provided by the configured detector."
        case duplicate = "The same group appears more than once."
        case range = "Size, weights or framing limits are outside the supported range."
        public var errorDescription: String? { rawValue }
    }
    public var normalizedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    public func writing(in text: String, creating: Bool) throws -> String {
        let name = normalizedName
        guard !name.isEmpty, name.count <= 64, name != "classes", name != "vision",
              !name.contains(where: { "[]#=\r\n".contains($0) }), !self.name.contains(where: { $0.isNewline }) else { throw Invalid.name }
        let setup = DetectorSetup.parse(text).0
        let exists = setup.modes.contains { $0.name == name }
        if creating && exists { throw Invalid.exists }
        if !creating && !exists { throw Invalid.missing }
        guard !chain.isEmpty else { throw Invalid.empty }
        let known = Set(setup.kinds + SubjectKind.vision)
        guard chain.allSatisfy({ $0.parts.allSatisfy(known.contains) }) else { throw Invalid.category }
        var seen = Set<String>()
        for group in chain {
            guard seen.insert(group.parts.map(\.rawValue).sorted().joined(separator: "+")).inserted else { throw Invalid.duplicate }
        }
        guard size.isFinite, (0.2...1).contains(size), composition.maxZoom.isFinite, (0.25...4).contains(composition.maxZoom),
              composition.margin.isFinite, (0...1).contains(composition.margin),
              composition.weights.allSatisfy({ !$0.key.isCombination && known.contains($0.key) && $0.value.isFinite && (0.25...4).contains($0.value) }) else { throw Invalid.range }
        var values = composition.values
        values["size"] = "\(size * 100)%"
        values["chain"] = chain.map(\.rawValue).joined(separator: ", ")
        if !creating {
            guard let edited = DetectorSetup.settingValues(values, of: name, in: text) else { throw Invalid.missing }
            return edited
        }
        return text + (text.hasSuffix("\n\n") ? "" : text.hasSuffix("\n") ? "\n" : "\n\n")
            + "[\(name)]\n" + values.keys.sorted().map { "\($0) = \(values[$0]!)\n" }.joined()
    }
}
