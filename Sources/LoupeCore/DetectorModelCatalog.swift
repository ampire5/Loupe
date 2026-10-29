import Foundation

/// Local compiled Core ML detectors supplied by the user. Enumeration and metadata reads run off-main.
public struct DetectorModelEntry: Equatable, Sendable {
    public var path: String
    public var name: String
    public var width: Int?
    public var height: Int?
    public var title: String {
        guard let width, let height else { return name }
        return "\(name) · \(width)×\(height)"
    }
}

public enum DetectorModelCatalog {
    public static let selectionKey = "loupe.last-detector-model"
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Loupe/Models")
    }
    public static func installed(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "mlmodelc"
            && FileManager.default.fileExists(atPath: url.appendingPathComponent("coremldata.bin").path)
    }
    public static func scan(selected: String, configured: String, directories: [URL]? = nil) -> [DetectorModelEntry] {
        var urls = [selected, configured].filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0) }
        let folders = Set(directories ?? ([directory] + urls.map { $0.deletingLastPathComponent() }))
        for folder in folders {
            let children = (try? FileManager.default.contentsOfDirectory(at: folder,
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            urls += children.filter { $0.pathExtension.lowercased() == "mlmodelc" }.sorted { $0.path < $1.path }.prefix(64)
        }
        return Set(urls.map { $0.standardizedFileURL }).filter(installed).sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url in
            var entry = DetectorModelEntry(path: url.path, name: url.deletingPathExtension().lastPathComponent)
            if let file = try? FileHandle(forReadingFrom: url.appendingPathComponent("metadata.json")) {
                defer { try? file.close() }
                if let data = try? file.read(upToCount: 1_048_576),
                   let roots = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
                   let inputs = roots.first?["inputSchema"] as? [[String: Any]],
                   let image = inputs.first(where: { ($0["type"] as? String)?.lowercased() == "image" }) {
                    entry.width = Int(String(describing: image["width"] ?? ""))
                    entry.height = Int(String(describing: image["height"] ?? ""))
                }
            }
            return entry
        }
    }
}
