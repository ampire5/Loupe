import Foundation
import HomeScreenModel
import UniformTypeIdentifiers

/// What the file browser lists (file browser spec §4.2): folders (not packages), zips with `archive-folders`, and the
/// photos Loupe opens; hidden names left out. A folder is listed twice: names only first (one `readdir`, ~0.05 s on
/// the user's share), then with dates, sizes and packages (seconds on a cold share). Inside a zip the one directory
/// read has everything, and its photos are read-only. Blocking calls: run them off the main thread.
public enum BrowserListingSource {
    /// How many names make a part on a slow share (each part is shown as it comes).
    public static let partSize = 300

    /// A part goes out only this long after the last one: a fast disk lists in one go, a slow share shows as it comes.
    public static let partInterval: Duration = .milliseconds(150)

    /// Names only: kinds from `d_type` (an unknown one by the extension), no dates or sizes. Every `partEvery` names,
    /// at most every `partAfter`, `part` gets all the names so far; false from it stops the listing
    /// (`CancellationError`): a folder left gives the share back at the next part rather than at the end.
    public static func names(_ folder: URL, archives: Bool, partEvery: Int = partSize, partAfter: Duration = partInterval,
                             part: ([BrowserEntry]) -> Bool = { _ in true }) throws -> [BrowserEntry] {
        var last = ContinuousClock.now
        if ArchivePath.isArchive(folder) { return try archiveEntries(folder) }
        guard let dir = opendir(folder.path) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { closedir(dir) }
        var entries: [BrowserEntry] = []
        while let item = readdir(dir) {
            let name = withUnsafeBytes(of: item.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(item.pointee.d_namlen)), as: UTF8.self)
            }
            guard !name.hasPrefix(".") else { continue }
            let ext = (name as NSString).pathExtension.lowercased()
            let type = item.pointee.d_type
            let isDirectory = type == DT_DIR || (type == DT_UNKNOWN && ext.isEmpty)
            let url = folder.appendingPathComponent(name, isDirectory: isDirectory)
            if let entry = entry(url, isDirectory: isDirectory, isPackage: isDirectory && isPackageExtension(ext),
                                 stamp: nil, modified: nil, archives: archives) {
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
        if ArchivePath.isArchive(folder) { return try archiveEntries(folder) }
        return try FolderSiblings.listEntries(folder).compactMap {
            entry($0.url, isDirectory: $0.isDirectory, isPackage: $0.isPackage, stamp: $0.stamp, modified: $0.modified,
                  archives: archives)
        }
    }

    /// The names, then the full listing (one listing inside a zip), off the caller's thread; stopping the iteration
    /// stops the listing between the two.
    public static func listings(_ folder: URL, archives: Bool, partEvery: Int = partSize,
                                partAfter: Duration = partInterval) -> AsyncThrowingStream<BrowserListing, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    if ArchivePath.isArchive(folder) {
                        continuation.yield(BrowserListing(entries: try archiveEntries(folder), complete: true))
                    } else {
                        let all = try names(folder, archives: archives, partEvery: partEvery, partAfter: partAfter) { soFar in
                            guard !Task.isCancelled else { return false }
                            continuation.yield(BrowserListing(entries: soFar, complete: false, more: true))
                            return true
                        }
                        continuation.yield(BrowserListing(entries: all, complete: false))
                        try Task.checkCancellation()
                        continuation.yield(BrowserListing(entries: try full(folder, archives: archives), complete: true))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The top level: the home folder, the volumes, the pinned folders, in that order; one that does not answer within
    /// a second (a share that hangs) or is gone is dimmed.
    public static func places(pins: [URL], home: URL, volumes: [URL]) async -> [BrowserEntry] {
        let all = [home] + volumes + pins
        let reachable = await HomeGrid.availability(of: all.map(\.path), timeout: .seconds(1))
        return all.map { url in
            BrowserEntry(url: url, name: url.path == "/" ? FileManager.default.displayName(atPath: "/") : url.lastPathComponent,
                         kind: .place, isDimmed: reachable[url.path] != .some(true))
        }
    }

    /// The mounted volumes Finder shows, without the hidden system ones.
    public static func volumes() -> [URL] {
        (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [])
            .filter { !$0.path.hasPrefix("/System/Volumes") }
    }

    /// Up from `folder`: its parent; from a volume's root (`/`, `/Volumes/X`) the places.
    public static func parent(of folder: URL) -> BrowserLocation {
        let path = folder.standardizedFileURL.path
        if path == "/" || folder.standardizedFileURL.deletingLastPathComponent().path == "/Volumes" { return .places }
        return .folder(folder.standardizedFileURL.deletingLastPathComponent())
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
        if ArchivePath.isArchive(url) {
            guard archives else { return nil }
            return BrowserEntry(url: url, name: name, kind: .archive, date: stamp?.modified, size: stamp.map { Int64($0.size) },
                                canRename: true, canTrash: true)
        }
        guard Playlist.imageExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        return BrowserEntry(url: url, name: name, kind: .file, date: stamp?.modified, size: stamp.map { Int64($0.size) },
                            canRename: true, canTrash: true)
    }

    /// A zip's photos, by their inner paths; the archive's date for each, its own size.
    private static func archiveEntries(_ archive: URL) throws -> [BrowserEntry] {
        try ArchiveReader.shared.entries(of: archive).map { item in
            BrowserEntry(url: item.url, name: ArchivePath.split(item.url)?.entry ?? item.url.lastPathComponent, kind: .file,
                         date: item.stamp.modified, size: Int64(item.stamp.size))
        }
    }
}
