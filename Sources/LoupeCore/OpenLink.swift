import Foundation

public enum OpenLink {
    /// Converts a browser link to a local file URL before sending it through the usual open pipeline.
    public static func fileURL(for url: URL) -> URL? {
        if url.isFileURL { return url }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "loupe", components.host?.lowercased() == "open",
              components.user == nil, components.password == nil, components.port == nil,
              components.path.isEmpty, components.fragment == nil,
              let items = components.queryItems, items.count == 1, items[0].name == "path",
              let path = items[0].value, path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: path.hasSuffix("/"))
    }
}
