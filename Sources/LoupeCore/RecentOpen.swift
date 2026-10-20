import Foundation

/// What a click on a Recent card opens (Home spec §2.3).
public enum RecentOpen {
    public enum Plan: Equatable, Sendable {
        /// Through Stash: it maps the path and mounts the share, and folder steps follow `list`.
        case gallery(id: String, list: RecentGalleryList?)
        /// The photo last viewed, in its folder.
        case file(URL)
        /// The folder, at the photo it remembers or its first: the remembered one is gone.
        case folder(URL)
        /// Neither can be reached; the toast names it.
        case notAvailable(name: String)
    }

    /// A Stash gallery always goes through Stash; else the remembered photo when it is there, the folder when only it
    /// is, and "not available" when the folder is gone (a share not mounted, a folder deleted).
    public static func plan(_ e: RecentEntry, folderExists: Bool, fileExists: Bool) -> Plan {
        if let gallery = e.gallery { return .gallery(id: gallery.id, list: gallery.list) }
        guard folderExists else { return .notAvailable(name: e.displayTitle) }
        if let file = e.file, fileExists { return .file(e.url.appendingPathComponent(file)) }
        return .folder(e.url)
    }
}
