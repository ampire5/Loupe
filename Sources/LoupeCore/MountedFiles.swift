import Foundation

/// Answers "Clean Up Thumbnails"' question for each catalog row: is this file still there? Only for volumes
/// mounted now: a share that is not mounted answers nil, so its rows stay (a disconnected share is not
/// deleted photos, spec §3.3). Each folder is listed once, not `stat`ed per file, which over SMB is the
/// difference between one round trip and thousands. A file counts as gone only when the system says its
/// folder does not exist: any other failure (a share that dropped but is still in the mount table) keeps it.
/// Blocking: run it off any actor that has other work.
final class MountedFiles {
    /// Volume key (as `ThumbnailLocation.volume`) → where that volume is mounted now.
    private let mountPoints: [String: String]
    /// Folder path → its file names; nil when the folder exists but cannot be listed (cannot tell).
    private var listings: [String: Set<String>?] = [:]

    init() {
        var points: [String: String] = [:]
        var list: UnsafeMutablePointer<statfs>?
        // MNT_NOWAIT: the kernel's cached table, without asking a hung server for fresh statistics.
        let count = getmntinfo(&list, MNT_NOWAIT)
        for i in 0..<Int(max(0, count)) {
            guard var fs = list?[i] else { continue }
            let mountPoint = ThumbnailLocation.string(from: &fs.f_mntonname)
            let isLocal = fs.f_flags & UInt32(MNT_LOCAL) != 0
            let uuid = isLocal
                ? (try? URL(fileURLWithPath: mountPoint).resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
                : nil
            let key = ThumbnailLocation.volumeKey(mountPoint: mountPoint, mountFrom: ThumbnailLocation.string(from: &fs.f_mntfromname),
                                                  isLocal: isLocal, volumeUUID: uuid)
            // The first mount of a volume wins, as `statfs` would report for a path on it.
            if points[key] == nil { points[key] = mountPoint }
        }
        mountPoints = points
    }

    /// Mount point → whether it can be listed now. A share that dropped stays in the mount table, and
    /// everything on it fails to list; one that fails at its root is not trusted about any folder.
    private var reachable: [String: Bool] = [:]

    /// True / false for a file on a mounted volume, nil when its volume is not mounted or not reachable, or
    /// its folder cannot be examined. `ThumbnailLocation.folder` is relative to the mount point, except on
    /// the Data volume, where it is the firmlinked absolute path; the mount point plus it is a real path in
    /// both cases.
    func isPresent(_ location: ThumbnailLocation) -> Bool? {
        guard let mountPoint = mountPoints[location.volume] else { return nil }
        if reachable[mountPoint] == nil {
            reachable[mountPoint] = (try? FileManager.default.contentsOfDirectory(atPath: mountPoint)) != nil
        }
        guard reachable[mountPoint] == true else { return nil }
        let folder = mountPoint == "/" ? location.folder
            : location.folder == "/" ? mountPoint : mountPoint + location.folder
        if listings[folder] == nil { listings[folder] = .some(Self.names(in: folder)) }
        guard let names = listings[folder] ?? nil else { return nil }
        return names.contains(location.name)
    }

    /// The folder's file names; empty only when the folder is certainly gone (`ENOENT`, `ENOTDIR`), nil when
    /// it cannot be listed for any other reason (permissions, a share timing out: `EIO`, `ETIMEDOUT`, …).
    static func names(in folder: String) -> Set<String>? {
        // A zip's rows are its entries (Stash spec §2.4): listing the file as a folder would fail with ENOTDIR and
        // count them as gone.
        let url = URL(fileURLWithPath: folder)
        if ArchivePath.isArchive(url), (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            guard let entries = try? ArchiveReader.shared.entries(of: url) else { return nil }
            return Set(entries.map(\.url.lastPathComponent))
        }
        if let names = try? FileManager.default.contentsOfDirectory(atPath: folder) { return Set(names) }
        var st = stat()
        if lstat(folder, &st) == 0 { return nil }   // there, but not listable
        return errno == ENOENT || errno == ENOTDIR ? [] : nil
    }
}
