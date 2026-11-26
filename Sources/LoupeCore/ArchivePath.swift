import Foundation

/// Paths through a zip archive (Stash spec §2.4). An entry is one path component under the archive, its inner path
/// with "∕" (U+2215 DIVISION SLASH) for "/": `/Volumes/A$/G.zip/caps∕0001.jpg`. So a photo's folder
/// (`deletingLastPathComponent`) is the archive itself, and every key made of a folder and a file name works as for a
/// folder. UI callers use the last known filesystem type for ambiguous paths without doing I/O.
public enum ArchivePath {
    public static let separator: Character = "\u{2215}"

    // NSCache synchronizes its lookups and writes.
    private nonisolated(unsafe) static let kinds: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 1024
        return cache
    }()

    static func hasZipExtension(_ url: URL) -> Bool { url.pathExtension.lowercased() == "zip" }

    private static func key(_ url: URL) -> NSString {
        let path = url.path
        // Foundation can return /private/var or /private/tmp from a listing of /var or /tmp.
        if path.hasPrefix("/private/var/") || path.hasPrefix("/private/tmp/") || path.hasPrefix("/private/etc/") {
            return String(path.dropFirst("/private".count)) as NSString
        }
        return path as NSString
    }

    public static func isArchive(_ url: URL) -> Bool {
        hasZipExtension(url) && (kinds.object(forKey: key(url))?.boolValue ?? true)
    }

    /// A type already obtained from a directory listing or an open request.
    public static func noteDirectoryType(_ url: URL, isDirectory: Bool) {
        guard hasZipExtension(url) else { return }
        kinds.setObject(NSNumber(value: !isDirectory), forKey: key(url))
    }

    /// Refresh the type before listing a .zip path. Blocking: call off the main thread.
    static func resolveArchive(_ url: URL) -> Bool {
        guard hasZipExtension(url) else { return false }
        let key = key(url)
        var info = stat()
        guard stat(url.path, &info) == 0 else { return kinds.object(forKey: key)?.boolValue ?? true }
        let isArchive = info.st_mode & S_IFMT == S_IFREG
        kinds.setObject(NSNumber(value: isArchive), forKey: key)
        return isArchive
    }

    /// Resolve an entry whose parent's type hasn't been seen yet. Blocking on a cache miss for .zip parents.
    public static func isArchiveEntryOnDisk(_ url: URL) -> Bool {
        guard !url.hasDirectoryPath else { return false }
        let parent = url.deletingLastPathComponent()
        guard hasZipExtension(parent), !url.lastPathComponent.isEmpty else { return false }
        return kinds.object(forKey: key(parent))?.boolValue ?? resolveArchive(parent)
    }

    /// The archive and the entry's inner path (with "/"), when the parent is an archive.
    public static func split(_ url: URL) -> (archive: URL, entry: String)? {
        guard !url.hasDirectoryPath else { return nil }
        let parent = url.deletingLastPathComponent()
        guard isArchive(parent), !url.lastPathComponent.isEmpty else { return nil }
        return (parent, url.lastPathComponent.replacingOccurrences(of: String(separator), with: "/"))
    }

    /// File › Copy Path: the file's path; an archive entry (which has none) is the archive's path and its inner path.
    public static func copyText(_ url: URL) -> String {
        guard let (archive, entry) = split(url) else { return url.path }
        return archive.path + "/" + entry
    }

    /// The entry's URL; nil for an inner path that already has a "∕" (it would not come back the same).
    public static func url(archive: URL, entry: String) -> URL? {
        guard !entry.contains(separator), !entry.isEmpty else { return nil }
        return archive.appendingPathComponent(entry.replacingOccurrences(of: "/", with: String(separator)),
                                              isDirectory: false)
    }

    /// The name a photo goes by in a title, the stats line or a label: an entry's own file name (`0001.jpg`, never
    /// its inner path with "∕"), else the file name.
    public static func shortName(_ url: URL) -> String {
        guard let (_, entry) = split(url) else { return url.lastPathComponent }
        return (entry as NSString).lastPathComponent
    }

    /// `G.zip › caps/0001.jpg` for an entry, the file name otherwise.
    public static func displayName(_ url: URL) -> String {
        guard let (archive, entry) = split(url) else { return url.lastPathComponent }
        return "\(archive.lastPathComponent) › \(entry)"
    }
}
