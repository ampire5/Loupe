import Foundation

/// Resource descriptors only; image data is never exported. All calls, including lazy disk I/O, run on
/// PhotosLibrary's serial utility queue. Membership and revisions are always queried from PhotoKit.
struct PhotosAssetNames {
    private struct Name: Codable, Equatable { let modified: Date; let filename: String }
    private struct Snapshot: Codable { let version: Int; let names: [String: Name]; let albumNames: [String: Name]? }
    private var previous: [String: Name] = [:]
    private var albumNames: [String: Name] = [:]
    private let file: URL?
    private var loaded = false
    // Corrupt/foreign cache files cannot cause an unbounded allocation. An optional cache exceeding this
    // conservative safety bound is ignored; this is not a tuned library-size or throughput limit.
    private static let maximumDiskBytes = 64 * 1024 * 1024

    init(file: URL? = nil) { self.file = file }

    private mutating func load() {
        guard !loaded else { return }
        loaded = true
        guard let file,
              let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= Self.maximumDiskBytes,
              let data = try? Data(contentsOf: file),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data), snapshot.version == 1 else { return }
        previous = snapshot.names
        albumNames = snapshot.albumNames ?? [:]
    }

    private func save() {
        guard let file, let data = try? JSONEncoder().encode(Snapshot(version: 1, names: previous, albumNames: albumNames)),
              data.count <= Self.maximumDiskBytes else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { /* Optional cache: a failed write must not prevent Photos access. */ }
    }

    mutating func resolve(_ assets: [PhotosAsset], isLibrary: Bool = true, isCancelled: () -> Bool = { false },
                          filename: (PhotosAsset) -> String) throws -> [PhotosAsset] {
        load()
        var named: [PhotosAsset] = []
        var next: [String: Name] = [:]
        named.reserveCapacity(assets.count)
        next.reserveCapacity(assets.count)
        for asset in assets {
            if isCancelled() { throw CancellationError() }
            let cached = albumNames[asset.id].flatMap { $0.modified == asset.modified ? $0.filename : nil }
                ?? previous[asset.id].flatMap { $0.modified == asset.modified ? $0.filename : nil }
            let name = cached ?? filename(asset)
            named.append(PhotosAsset(id: asset.id, modified: asset.modified, created: asset.created,
                                     width: asset.width, height: asset.height, filename: name))
            next[asset.id] = Name(modified: asset.modified, filename: name)
        }
        if isCancelled() { throw CancellationError() }
        if isLibrary {
            if next != previous || !albumNames.isEmpty { previous = next; albumNames = [:]; save() }
        } else if next != albumNames { albumNames = next; save() }
        return named
    }

    mutating func invalidate(_ ids: Set<String>) {
        load()
        var changed = false
        for id in ids {
            let primary = previous.removeValue(forKey: id) != nil
            let album = albumNames.removeValue(forKey: id) != nil
            changed = primary || album || changed
        }
        if changed { save() }
    }

    mutating func clear() { loaded = true; previous = [:]; albumNames = [:]; save() }
}
