import Foundation

// Before a folder's stamps (a share's names-only listing, seconds ahead of the one with dates and sizes): what the
// catalog has of its files is served at once, read only. The catalog's stamps stand in for the listing's until the
// real ones come; then only the files that changed are forgotten (`open`), and the caller asks for them again.

extension ThumbnailStore {
    /// The request's files without a stamp, by folder, of the folders with no stamped file in it.
    static func unstamped(_ files: [URL], _ stamps: [URL: FileStamp],
                          except listings: [URL: [ListedFile]]) -> [URL: [URL]] {
        var result: [URL: [URL]] = [:]
        for url in files where stamps[url] == nil {
            let dir = url.deletingLastPathComponent()
            guard listings[dir] == nil else { continue }
            result[dir, default: []].append(url)
        }
        return result
    }

    /// The folders of a window's names-only files opened from the catalog (`lookUpProvisional`), each located first
    /// (a share's from the mount table, no I/O). One open with stamps (another window's, the walk's) stays as it is.
    /// `current` gives the window's provisional folders after the awaits (nil: it closed).
    func openProvisional(_ unstamped: [URL: [URL]], current: (isolated ThumbnailStore) -> Set<URL>?) async {
        guard wantsDisk else { return }
        for (dir, files) in unstamped where folders[dir]?.provisional ?? true {
            guard let location = await location(of: dir, sample: files[0]) else { continue }
            guard current(self)?.contains(dir) == true, folders[dir]?.provisional ?? true else { continue }
            lookUpProvisional(dir, files, location: location)
        }
    }

    /// The catalog's rows of `files` (one read-only query, `ThumbnailDatabase.catalogRows`): their ids and stored
    /// thumbnails serve their cells; the folder is partial and provisional (no sync writes or deletes, no access
    /// written, nothing made). Cells asked for before and now stored are told about (`onThumbnail`).
    func lookUpProvisional(_ dir: URL, _ files: [URL], location: ThumbnailLocation) {
        let names = Set(files.map(\.lastPathComponent))
        guard let (rows, have) = perform("lookup", { db -> ([String: (id: Int64, stamp: FileStamp)], Set<Int64>) in
            let rows = try db.catalogRows(in: location, names: names)
            return (rows, try db.hasThumbnail(rows.values.map(\.id)))
        }) else { return }
        // A lookup before (fewer names so far): what it served goes, these rows replace it.
        if let old = folders[dir], old.provisional {
            for file in old.listing {
                ids[file.url] = nil
                stored.remove(file.url)
                provisional.remove(file.url)
            }
        }
        var listing: [ListedFile] = []
        for url in files {
            guard let row = rows[url.lastPathComponent] else { continue }
            listing.append(ListedFile(url: url, stamp: row.stamp))
            ids[url] = row.id
            provisional.insert(url)
            if have.contains(row.id) { stored.insert(url) } else { stored.remove(url) }
        }
        folders[dir] = Folder(listing: listing, location: location, partial: true, provisional: true)
        for url in missed where stored.contains(url) {
            missed.remove(url)
            onThumbnail?(url)
        }
    }

    /// Where Home's folder on screen is, as its covers resolved it (`shownFolderPlace`): its photos' folder needs no
    /// second resolve. `folder` is the folder itself; its files' folder key is the same URL as theirs.
    public func knowLocation(of folder: URL, _ location: ThumbnailLocation) {
        let dir = folder.appendingPathComponent("_").deletingLastPathComponent()
        if locations[dir] == nil { locations[dir] = location }
    }

    /// `url`'s location on a share from the mount table (`getfsstat` with `MNT_NOWAIT`, which asks no file system):
    /// the share's key and the folder under its mount point, as `ThumbnailLocation.resolve` would give without its
    /// `realpath` and `statfs` on the share. Nil off a share or with no mount point above it.
    @Sendable public static func shareLocation(_ url: URL) -> ThumbnailLocation? {
        shareLocation(of: url.standardizedFileURL.path, in: mounts())
    }

    /// `shareLocation`'s pure part: the location of `path` among `mounts`, when its mount is a share.
    static func shareLocation(of path: String, in mounts: [Mount]) -> ThumbnailLocation? {
        guard let mount = mount(of: path, in: mounts), !mount.local else { return nil }
        return ThumbnailLocation.make(path: path, mountPoint: mount.point, mountFrom: mount.from, isLocal: false,
                                      volumeUUID: nil)
    }
}
