import Foundation

/// Where a photo lives, in terms that survive a re-mount: the volume, the folder inside it, the file name.
/// The thumbnail database keys files by this triple instead of by path, so a share that comes back as
/// `/Volumes/L$-1` (the old mount point still being held) keeps its thumbnails.
public struct ThumbnailLocation: Hashable, Sendable {
    /// `net:<share address>` for network volumes (the address as `statfs` reports it, never the mount
    /// point), `uuid:<volume UUID>` for local ones, `mnt:<mount point>` for a local volume without a UUID.
    public let volume: String
    /// Folder relative to the volume root, starting with `/` (`/` for the root itself).
    public let folder: String
    public let name: String

    public init(volume: String, folder: String, name: String) {
        self.volume = volume
        self.folder = folder
        self.name = name
    }

    /// The pure part of `resolve`: everything it learns from the system is passed in.
    static func make(path: String, mountPoint: String, mountFrom: String,
                     isLocal: Bool, volumeUUID: String?) -> ThumbnailLocation {
        let parent = (path as NSString).deletingLastPathComponent
        return ThumbnailLocation(volume: volumeKey(mountPoint: mountPoint, mountFrom: mountFrom,
                                                   isLocal: isLocal, volumeUUID: volumeUUID),
                                 folder: relative(parent, to: mountPoint),
                                 name: (path as NSString).lastPathComponent)
    }

    /// `volume` for a mounted file system (also how a clean-up finds where a stored volume is mounted now).
    static func volumeKey(mountPoint: String, mountFrom: String, isLocal: Bool, volumeUUID: String?) -> String {
        if !isLocal { return "net:" + mountFrom }
        if let volumeUUID { return "uuid:" + volumeUUID }
        return "mnt:" + mountPoint
    }

    /// `path` below `mountPoint`, starting with `/`. A path that is not below it (firmlinked `/Users/…` on
    /// the Data volume mounted at `/System/Volumes/Data`) is already volume-relative and stays as is.
    private static func relative(_ path: String, to mountPoint: String) -> String {
        if mountPoint == "/" { return path.isEmpty ? "/" : path }
        if path == mountPoint { return "/" }
        if path.hasPrefix(mountPoint + "/") { return String(path.dropFirst(mountPoint.count)) }
        return path.isEmpty ? "/" : path
    }

    /// Asks the system which volume holds `url`'s folder. Nil when the folder cannot be examined (gone, or
    /// the share is unreachable): the caller then simply has no thumbnail to look up or store. On a share, the mount
    /// table answers alone (`onShare`): `realpath` and `statfs` there ask the share for each component of the path,
    /// up to seconds each on a cold one, and the catalog's thumbnails and listings waited for it
    /// (docs/bench/2026-10-26-stored-listings.md).
    public static func resolve(_ url: URL) -> ThumbnailLocation? {
        if let shared = onShare(url) { return shared }
        // statfs follows symlinks, but the path must be the real one to be comparable with the mount point.
        guard let real = realPath(url.deletingLastPathComponent().path) else { return nil }
        var fs = statfs()
        guard statfs(real, &fs) == 0 else { return nil }
        let mountPoint = string(from: &fs.f_mntonname)
        let mountFrom = string(from: &fs.f_mntfromname)
        let isLocal = fs.f_flags & UInt32(MNT_LOCAL) != 0
        let uuid = isLocal
            ? (try? URL(fileURLWithPath: mountPoint).resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
            : nil
        return make(path: real + "/" + url.lastPathComponent, mountPoint: mountPoint,
                    mountFrom: mountFrom, isLocal: isLocal, volumeUUID: uuid)
    }

    /// The location of `url` when it is on a share, from the mount table (`getfsstat` with `MNT_NOWAIT`: no file system
    /// asked): the path as written, under the longest mount point holding it. Nil on a local volume (whose key needs
    /// `statfs`: a firmlinked `/Users/…` is on the Data volume) or when none matches.
    public static func onShare(_ url: URL) -> ThumbnailLocation? {
        onShare(path: url.standardizedFileURL.path, mounts: ThumbnailStore.mounts())
    }

    static func onShare(path: String, mounts: [ThumbnailStore.Mount]) -> ThumbnailLocation? {
        guard let mount = ThumbnailStore.mount(of: path, in: mounts), !mount.local else { return nil }
        return make(path: path, mountPoint: mount.point, mountFrom: mount.from, isLocal: false, volumeUUID: nil)
    }

    private static func realPath(_ path: String) -> String? {
        guard let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    /// A fixed-size C char array (as in `statfs`) as a Swift string.
    static func string<T>(from tuple: inout T) -> String {
        withUnsafePointer(to: &tuple) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
        }
    }
}
