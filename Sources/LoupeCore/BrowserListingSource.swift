import Foundation
import HomeScreenModel
import UniformTypeIdentifiers

/// What the file browser lists (file browser spec §4.2): folders (not packages), zips with `archive-folders`, and the
/// photos Loupe opens; hidden names left out. A local folder is listed with dates, sizes and packages in one pass.
/// A share has a names-only pass first because its full listing can take seconds. Inside a zip the one directory
/// read has everything, and its photos are read-only. Blocking calls: run them off the main thread.
public enum BrowserListingSource {
    /// How many names make a part on a slow share (each part is shown as it comes).
    public static let partSize = 300

    /// A part goes out only this long after the last one: a fast disk lists in one go, a slow share shows as it comes.
    public static let partInterval: Duration = .milliseconds(150)

    /// Names only: kinds from `d_type` (an unknown one by the extension), no dates or sizes. Every `partEvery` names,
    /// at most every `partAfter`, `part` gets all the names so far; false from it stops the listing
    /// (`CancellationError`): a folder left gives the share back at the next part rather than at the end.
    /// `stat`: each photo's date and size too (one `fstatat` each, nothing for folders, other files and symlinks; a
    /// local volume's folder card): `LoupeBench thumbs --covers` on 2000-file folders, see docs/bench/folder-cards.md.
    public static func names(_ folder: URL, archives: Bool, stat: Bool = false, partEvery: Int = partSize,
                             partAfter: Duration = partInterval,
                             part: ([BrowserEntry]) -> Bool = { _ in true }) throws -> [BrowserEntry] {
        if ArchivePath.resolveArchive(folder) { return try archiveEntries(folder) }
        return try directoryNames(folder, archives: archives, stat: stat, partEvery: partEvery, partAfter: partAfter, part: part)
    }

    static func directoryNames(_ folder: URL, archives: Bool, stat: Bool = false, partEvery: Int = partSize,
                               partAfter: Duration = partInterval, part: ([BrowserEntry]) -> Bool) throws -> [BrowserEntry] {
        try Task.checkCancellation()
        var last = ContinuousClock.now
        guard let dir = opendir(folder.path) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { closedir(dir) }
        var entries: [BrowserEntry] = []
        var untilCancellationCheck = partSize
        while let item = readdir(dir) {
            untilCancellationCheck -= 1
            if untilCancellationCheck == 0 {
                try Task.checkCancellation()
                untilCancellationCheck = partSize
            }
            let name = withUnsafeBytes(of: item.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(item.pointee.d_namlen)), as: UTF8.self)
            }
            guard !name.hasPrefix(".") else { continue }
            let ext = (name as NSString).pathExtension.lowercased()
            var type = Int32(item.pointee.d_type)
            if type == DT_UNKNOWN, ext == "zip" {
                var info = Darwin.stat()
                if fstatat(dirfd(dir), name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                    if info.st_mode & S_IFMT == S_IFDIR { type = DT_DIR }
                    if info.st_mode & S_IFMT == S_IFREG { type = DT_REG }
                }
            }
            let isDirectory = type == DT_DIR || (type == DT_UNKNOWN && ext.isEmpty)
            let url = folder.appendingPathComponent(name, isDirectory: isDirectory)
            if ext == "zip", type == DT_DIR || type == DT_REG {
                ArchivePath.noteDirectoryType(url, isDirectory: isDirectory)
            }
            var stamp: FileStamp?
            // A symlink is not followed: one into a share that hangs would hold the local listing.
            if stat, !isDirectory, type != DT_LNK, Playlist.mediaExtensions.contains(ext) {
                var st = Darwin.stat()
                if fstatat(dirfd(dir), name, &st, AT_SYMLINK_NOFOLLOW) == 0, st.st_mode & S_IFMT == S_IFREG {
                    stamp = FileStamp(st)
                }
            }
            if let entry = entry(url, isDirectory: isDirectory, isPackage: isDirectory && isPackageExtension(ext),
                                 stamp: stamp, modified: nil, archives: archives) {
                entries.append(entry)
                if entries.count % max(1, partEvery) == 0, ContinuousClock.now - last >= partAfter {
                    last = ContinuousClock.now
                    if !part(entries) { throw CancellationError() }
                }
            }
        }
        return entries
    }

    /// With dates, sizes and packages (`FolderSiblings.listEntries`). A folder's date is its own modification date, as
    /// Finder's Date Modified (from the same listing, no further reads); it has no size.
    public static func full(_ folder: URL, archives: Bool) throws -> [BrowserEntry] {
        if ArchivePath.resolveArchive(folder) { return try archiveEntries(folder) }
        return try fullDirectory(folder, archives: archives)
    }

    private static func fullDirectory(_ folder: URL, archives: Bool) throws -> [BrowserEntry] {
        let entries = try FolderSiblings.directoryEntries(folder).compactMap {
            entry($0.url, isDirectory: $0.isDirectory, isPackage: $0.isPackage, stamp: $0.stamp, modified: $0.modified,
                  archives: archives)
        }
        return markSavedUpscales(entries)
    }

    /// Read at most one copy directory per source folder or archive's parent, with no per-photo disk reads.
    package static func markSavedUpscales(_ entries: [BrowserEntry]) -> [BrowserEntry] {
        var copies: [URL: Set<String>] = [:]
        return entries.map { entry in
            guard entry.isFile, let date = entry.date, let size = entry.size else { return entry }
            let folder = SavedUpscale.directory(for: entry.url)
            let names: Set<String>
            if let known = copies[folder] {
                names = known
            } else {
                names = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                copies[folder] = names
            }
            guard !names.isEmpty else { return entry }
            let copy = SavedUpscale(source: entry.url, stamp: FileStamp(modified: date, size: Int(size)))
            guard names.contains(copy.file.lastPathComponent) else { return entry }
            var marked = entry
            marked.badge = SavedUpscale.badge
            marked.subtitle = SavedUpscale.badge
            return marked
        }
    }

    /// A complete listing off the caller's thread. On a share, send the names while the stamps are still pending.
    public static func listings(_ folder: URL, archives: Bool, partEvery: Int = partSize,
                                partAfter: Duration = partInterval,
                                isLocal: @escaping @Sendable (URL) -> Bool = FileReader.volumeIsLocal)
        -> AsyncThrowingStream<BrowserListing, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try Task.checkCancellation()
                    if ArchivePath.resolveArchive(folder) {
                        let entries = try archiveEntries(folder)
                        try Task.checkCancellation()
                        continuation.yield(BrowserListing(entries: entries, complete: true))
                    } else {
                        // The mount table keeps a known share out of the resource-value call. Confirm the actual
                        // volume for local-looking paths, which may reach a share through a symlink.
                        let localMount = ThumbnailStore.mount(of: folder.path, in: ThumbnailStore.mounts())?.local == true
                        let local = localMount && isLocal(folder)
                        try Task.checkCancellation()
                        if !local {
                            let all = try directoryNames(folder, archives: archives, partEvery: partEvery, partAfter: partAfter) { soFar in
                                guard !Task.isCancelled else { return false }
                                continuation.yield(BrowserListing(entries: soFar, complete: false, more: true))
                                return true
                            }
                            continuation.yield(BrowserListing(entries: all, complete: false))
                        }
                        try Task.checkCancellation()
                        let entries = try fullDirectory(folder, archives: archives)
                        try Task.checkCancellation()
                        continuation.yield(BrowserListing(entries: entries, complete: true))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The top level: the home folder, the volumes, then pinned folders. Only a negative check dims a place.
    /// A check still in flight or skipped at the batch deadline leaves its place available for navigation.
    public static func places(pins: [URL], home: URL, volumes: [URL]) async -> [BrowserEntry] {
        let all = [home] + volumes + pins
        let reachable = await HomeGrid.availability(of: all.map(\.path), timeout: .seconds(1))
        return all.map { url in
            BrowserEntry(url: url, name: url.path == "/" ? FileManager.default.displayName(atPath: "/") : url.lastPathComponent,
                         kind: .place, isDimmed: reachable[url.path] == .some(false))
        }
    }

    /// The mounted volumes Finder shows, without the hidden system ones.
    public static func volumes() -> [URL] {
        (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [])
            .filter { !$0.path.hasPrefix("/System/Volumes") }
    }

    /// Up from `folder`: its parent; from a volume's root (`/`, `/Volumes/X`, a share mounted elsewhere, as
    /// ~/Volumes/X) the places, so the path starts at the volume as Finder's does.
    public static func parent(of folder: URL, volumeRoots: @autoclosure () -> Set<String> = mountPoints()) -> BrowserLocation {
        let path = folder.standardizedFileURL.path
        if path == "/" || folder.standardizedFileURL.deletingLastPathComponent().path == "/Volumes" { return .places }
        if volumeRoots().contains(path) { return .places }
        return .folder(folder.standardizedFileURL.deletingLastPathComponent())
    }

    /// The mounted volumes' roots (one `getfsstat`, no read of the volumes themselves).
    public static func mountPoints() -> Set<String> {
        Set((FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? [])
            .map(\.standardizedFileURL.path))
    }

    /// A folder whose extension names a package type (`.app`, `.bundle`, `.icon`): known from the type registry, no disk
    /// read, so the names-only pass hides what the full listing hides.
    private static func isPackageExtension(_ ext: String) -> Bool {
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext, conformingTo: .directory) else { return false }
        return type.conforms(to: .package)
    }

    private static func entry(_ url: URL, isDirectory: Bool, isPackage: Bool, stamp: FileStamp?, modified: Date?,
                              archives: Bool) -> BrowserEntry? {
        let name = url.lastPathComponent
        guard !name.hasPrefix(".") else { return nil }
        if isDirectory {
            guard !isPackage else { return nil }
            return BrowserEntry(url: url, name: name, kind: .folder, date: modified, canRename: true, canTrash: true)
        }
        if ArchivePath.hasZipExtension(url) {
            guard archives else { return nil }
            return BrowserEntry(url: url, name: name, kind: .archive, date: stamp?.modified, size: stamp.map { Int64($0.size) },
                                canRename: true, canTrash: true)
        }
        guard Playlist.mediaExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        return fileEntry(url, stamp: stamp)
    }

    /// A photo's card: inside a zip named by its inner path (read-only), its date and size from its stamp. The viewer's
    /// playlist is made of the same entries (`Playlist`), so its steps follow the grid's order exactly.
    public static func fileEntry(_ url: URL, stamp: FileStamp?) -> BrowserEntry {
        let inner = ArchivePath.split(url)?.entry
        return BrowserEntry(url: url, name: inner ?? url.lastPathComponent, kind: .file, date: stamp?.modified,
                            size: stamp.map { Int64($0.size) }, canRename: inner == nil, canTrash: inner == nil)
    }

    /// A zip's photos, by their inner paths; the archive's date for each, its own size.
    private static func archiveEntries(_ archive: URL) throws -> [BrowserEntry] {
        let entries = try ArchiveReader.shared.entries(of: archive).map { fileEntry($0.url, stamp: $0.stamp) }
        return markSavedUpscales(entries)
    }
}
