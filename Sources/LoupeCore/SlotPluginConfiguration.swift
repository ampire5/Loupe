import Foundation
import SlotModel

public struct SlotPluginConfiguration: Equatable, Sendable {
    public let name: String
    public let url: URL
    public let slotID: SlotTabID
    public let origin: SlotPluginOrigin

    /// "Name | HTTPS URL". The name produces a stable ID for saved slot assignments.
    public init?(line: String) {
        guard let separator = line.firstIndex(of: "|") else { return nil }
        let title = line[..<separator].trimmingCharacters(in: .whitespaces)
        let address = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        let slug = title.lowercased().split { !$0.isASCII || (!$0.isLetter && !$0.isNumber) }.joined(separator: "-")
        guard !slug.isEmpty, let url = URL(string: address), let origin = SlotPluginOrigin(url) else { return nil }
        self.name = title
        self.url = url
        self.origin = origin
        self.slotID = SlotTabID(rawValue: "plugin:" + slug)
    }

    static func isPluginSlot(_ id: SlotTabID) -> Bool {
        guard id.rawValue.hasPrefix("plugin:") else { return false }
        let slug = id.rawValue.dropFirst("plugin:".count)
        return !slug.isEmpty && slug.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }
}

/// HTTPS scheme, canonical host and effective port. URL credentials never form part of a trusted location.
public struct SlotPluginOrigin: Equatable, Sendable {
    public let host: String
    public let port: Int

    public init?(_ url: URL) {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host(), !host.isEmpty else { return nil }
        let port = url.port ?? 443
        guard (1...65535).contains(port) else { return nil }
        self.host = host.lowercased()
        self.port = port
    }
}
