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
    func lookUpProvisional(_ dir: URL, _ files: [URL], location: ThumbnailLocation, fresh: Bool = false) {
        // The folder's rows are read once per visit (its names come in parts on a share): a later part maps its names
        // to them in memory and asks only ids not checked yet whether they have a thumbnail.
        let old = folders[dir].flatMap { $0.provisional && $0.location == location && !fresh ? $0 : nil }
        var catalog = old?.catalog ?? [:], checked = old?.checked ?? [:]
        if old?.catalog == nil {
            guard let rows = perform("lookup", { db -> [String: CatalogRow] in
                self.provisionalLookups += 1
                return try db.catalogRows(in: location, names: nil)
            }) else { return }
            catalog = rows
            checked = [:]
        }
        let unchecked = files.compactMap { catalog[$0.lastPathComponent]?.id }.filter { checked[$0] == nil }
        if !unchecked.isEmpty {
            guard let have = perform("lookup", { try $0.hasThumbnail(unchecked) }) else { return }
            for id in unchecked { checked[id] = have.contains(id) }
        }
        // What an earlier part served goes; this part's rows replace it.
        if let previous = folders[dir], previous.provisional {
            for file in previous.listing {
                ids[file.url] = nil
                stored.remove(file.url)
                provisional.remove(file.url)
            }
        }
        var listing: [ListedFile] = []
        for url in files {
            guard let row = catalog[url.lastPathComponent] else { continue }
            listing.append(ListedFile(url: url, stamp: row.stamp))
            ids[url] = row.id
            provisional.insert(url)
            if checked[row.id] == true { stored.insert(url) } else { stored.remove(url) }
        }
        var folder = Folder(listing: listing, location: location, partial: true, provisional: true)
        folder.catalog = catalog
        folder.checked = checked
        folder.asked = files
        folders[dir] = folder
        for url in missed where stored.contains(url) {
            missed.remove(url)
            onThumbnail?(url)
        }
    }

    /// Where Home's folder on screen is, as its covers resolved it (`shownFolderPlace`): its photos' folder needs no
    /// second resolve. `folder` is the folder itself; its files' folder key is the same URL as theirs. A key the mount
    /// table gave (`shareLocated`) is replaced by it, so a share path through a symlink ends on the resolved key
    /// whatever came first, and a provisional folder open under the other key is looked up again under this one. A
    /// folder already synced under the mount table's key keeps it for the session: syncing it again under the
    /// resolved one would leave the first rows behind as a second folder in the catalog.
    public func knowLocation(of folder: URL, _ location: ThumbnailLocation) {
        let dir = folder.appendingPathComponent("_").deletingLastPathComponent()
        guard locations[dir] == nil || shareLocated.contains(dir) else { return }
        if let open = folders[dir], !open.provisional { return }
        shareLocated.remove(dir)
        let before = locations[dir]
        locations[dir] = location
        guard let before, before.volume != location.volume || before.folder != location.folder,
              let open = folders[dir], open.location.map({ $0.volume == before.volume && $0.folder == before.folder }) == true
        else { return }
        for file in open.listing {
            ids[file.url] = nil
            stored.remove(file.url)
        }
        folders[dir]?.location = location
        lookUpProvisional(dir, open.asked, location: location, fresh: true)
    }

    /// `url`'s location on a share from the mount table (`getfsstat` with `MNT_NOWAIT`, which asks no file system):
    /// the share's key and the folder under its mount point, as `ThumbnailLocation.resolve` would give without its
    /// `realpath` and `statfs` on the share. Nil off a share or with no mount point above it. The path is taken as
    /// written: one through a symlink inside the share gets the link's folder, not the real one `resolve` gives; Home's
    /// resolved place replaces it once known, unless the folder was synced under it already (`knowLocation`).
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
