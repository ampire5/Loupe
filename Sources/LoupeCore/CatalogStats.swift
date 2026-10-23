import Foundation

/// What the thumbnail catalog holds (Settings › Catalog): folders, files and thumbnails by volume, and the size of the
/// two databases on disk. Read through connections of its own that only read, off the main thread: the catalog's own
/// connections go on serving the windows.
public struct CatalogStats: Equatable, Sendable {
    public struct Volume: Equatable, Sendable {
        /// `ThumbnailLocation.volume`: `net:<share>`, `uuid:<volume UUID>` or `mnt:<mount point>`.
        public var key: String
        public var folders = 0
        public var files = 0
        public var thumbnails = 0
        public var thumbnailBytes = 0
    }

    /// The most files first.
    public var volumes: [Volume]
    public var total: Volume
    /// `Catalog.db` and `Thumbs.db` with their `-wal` and `-shm`.
    public var diskBytes: Int

    /// Nil when there is no catalog in `directory` (or it cannot be read).
    public static func read(directory: URL) -> CatalogStats? {
        let catalogPath = directory.appendingPathComponent("Catalog.db").path
        let thumbsPath = directory.appendingPathComponent("Thumbs.db").path
        let fm = FileManager.default
        guard fm.fileExists(atPath: catalogPath) else { return nil }
        let pragmas = ["query_only=1", "busy_timeout=2000"]
        do {
            var byKey: [Int64: Volume] = [:]
            var volumeOfFile: [Int64: Int64] = [:]
            let catalog = try SQLiteConnection(path: catalogPath, pragmas: pragmas)
            defer { catalog.close() }
            try catalog.query("SELECT id, key FROM volumes", []) { r in byKey[r.int(0)] = Volume(key: r.text(1)) }
            try catalog.query("SELECT volume, COUNT(*) FROM folders GROUP BY volume", []) { r in byKey[r.int(0)]?.folders = Int(r.int(1)) }
            try catalog.query("SELECT f.id, d.volume FROM files f JOIN folders d ON f.folder = d.id", []) { r in
                volumeOfFile[r.int(0)] = r.int(1)
                byKey[r.int(1)]?.files += 1
            }
            if fm.fileExists(atPath: thumbsPath) {
                let thumbs = try SQLiteConnection(path: thumbsPath, pragmas: pragmas)
                defer { thumbs.close() }
                // A thumbnail of a file the catalog no longer has (another catalog's) belongs to no volume.
                try thumbs.query("SELECT file_id, length(jpeg) FROM thumbs", []) { r in
                    guard let volume = volumeOfFile[r.int(0)] else { return }
                    byKey[volume]?.thumbnails += 1
                    byKey[volume]?.thumbnailBytes += Int(r.int(1))
                }
            }
            let volumes = byKey.values.filter { $0.files > 0 || $0.folders > 0 }
                .sorted { $0.files != $1.files ? $0.files > $1.files : $0.key < $1.key }
            var total = Volume(key: "")
            for v in volumes {
                total.folders += v.folders
                total.files += v.files
                total.thumbnails += v.thumbnails
                total.thumbnailBytes += v.thumbnailBytes
            }
            var disk = 0
            for path in [catalogPath, thumbsPath] {
                for suffix in ["", "-wal", "-shm"] {
                    disk += ((try? fm.attributesOfItem(atPath: path + suffix))?[.size] as? Int) ?? 0
                }
            }
            return CatalogStats(volumes: volumes, total: total, diskBytes: disk)
        } catch {
            return nil
        }
    }

    /// A volume as people name it: `L$ · pc` for a share, the disk's name for a local volume that is mounted
    /// (`localNames`: volume UUID → name), else `Local disk`; the mount point's name for one without a UUID.
    public static func title(forVolume key: String, localNames: [String: String]) -> String {
        if key.hasPrefix("net:") {
            let address = key.dropFirst(4).replacingOccurrences(of: "//", with: "")
            let parts = address.split(separator: "/", maxSplits: 1).map(String.init)
            let host = parts.first.map { $0.split(separator: "@").last.map(String.init) ?? $0 } ?? ""
            let share = parts.count > 1 ? (parts[1].removingPercentEncoding ?? parts[1]) : ""
            return share.isEmpty ? host : "\(share) · \(host)"
        }
        if key.hasPrefix("uuid:") { return localNames[String(key.dropFirst(5))] ?? "Local disk" }
        if key.hasPrefix("mnt:") { return (String(key.dropFirst(4)) as NSString).lastPathComponent }
        return key
    }

    /// Whether `title(forVolume:localNames:)` needs the local volumes' names: only `uuid:` volumes use them.
    public static func needsLocalNames(_ stats: CatalogStats) -> Bool {
        stats.volumes.contains { $0.key.hasPrefix("uuid:") }
    }

    /// The volumes worth asking for a UUID and a name: the local ones (a share would answer over the network).
    public static func localVolumes(_ volumes: [(url: URL, isLocal: Bool)]) -> [URL] {
        volumes.filter(\.isLocal).map(\.url)
    }

    /// Mounted local volumes by UUID, for `title(forVolume:localNames:)`. Network volumes are never asked for their
    /// UUID or name: `volumeIsLocal` comes with the mount list (the mount's flags), the rest are server round trips.
    public static func mountedLocalNames() -> [String: String] {
        let fm = FileManager.default
        let mounted = fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsLocalKey], options: []) ?? []
        let records = mounted.map { url in
            (url: url, isLocal: (try? url.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal ?? false)
        }
        let keys: Set<URLResourceKey> = [.volumeUUIDStringKey, .volumeNameKey]
        var names: [String: String] = [:]
        for url in localVolumes(records) {
            guard let values = try? url.resourceValues(forKeys: keys), let uuid = values.volumeUUIDString else { continue }
            names[uuid] = values.volumeName ?? url.lastPathComponent
        }
        return names
    }
}
