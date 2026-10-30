import Foundation

/// Stable source identities, never paths into the Photos library or an export directory.
public enum PhotosLocation {
    public static let root = "photos"
    /// A source-owned collection, distinct from PhotoKit's opaque album identifiers.
    public static let library = "@library"
    public static func collection(_ id: String) -> String { "photos:" + id }
    public static func owns(_ source: String) -> Bool { source == root || source.hasPrefix("photos:") }
    public static func collectionID(_ source: String) -> String? {
        source.hasPrefix("photos:") ? String(source.dropFirst(7)) : nil
    }

    public static func assetURL(album: String, asset: String, revision: String, filename: String = "Photo") -> URL {
        var c = URLComponents()
        c.scheme = "loupe-photos"
        c.host = "asset"
        func component(_ text: String) -> String {
            Data(text.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "=", with: "")
        }
        let name = filename.isEmpty ? "Photo" : filename.replacingOccurrences(of: "/", with: "∕")
        c.path = "/" + component(album) + "/" + component(asset) + "/" + name
        c.queryItems = [URLQueryItem(name: "album", value: album), URLQueryItem(name: "asset", value: asset),
                        URLQueryItem(name: "revision", value: revision)]
        return c.url!
    }

    private static func value(_ name: String, in url: URL) -> String? {
        guard url.scheme == "loupe-photos", url.host == "asset" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
    public static func asset(in url: URL) -> String? { value("asset", in: url) }
    public static func album(in url: URL) -> String? { value("album", in: url) }
}
