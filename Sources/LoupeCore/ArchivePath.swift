import Foundation

/// Paths through a zip archive (Stash spec §2.4). An entry is one path component under the archive, its inner path
/// with "∕" (U+2215 DIVISION SLASH) for "/": `/Volumes/A$/G.zip/caps∕0001.jpg`. So a photo's folder
/// (`deletingLastPathComponent`) is the archive itself, and every key made of a folder and a file name works as for a
/// folder. Pure: nothing here touches the disk; an archive is a path whose extension is `zip`.
public enum ArchivePath {
    public static let separator: Character = "\u{2215}"

    public static func isArchive(_ url: URL) -> Bool { url.pathExtension.lowercased() == "zip" }

    /// The archive and the entry's inner path (with "/"), when the parent is an archive.
    public static func split(_ url: URL) -> (archive: URL, entry: String)? {
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
