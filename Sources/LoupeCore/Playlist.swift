import Foundation
import HomeScreenModel

/// The images in the current file's folder in the folder's `BrowserSort` order, the order Home's grid shows them in
/// (`FolderPlaylist`), and the position within them. The current file is always part of it, even if its extension is
/// unknown or the folder could not be listed.
public struct Playlist: Equatable, Sendable {
    public static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "heic", "heif", "avif", "jxl", "webp", "png", "gif", "tif", "tiff", "bmp",
    ]

    /// The order and the position: the grid's own sort over the same entries the grid has (`BrowserListingSource.fileEntry`).
    private var model: FolderPlaylist
    private var sourceIndex: Int?
    public var isSourceOrdered: Bool { sourceIndex != nil }
    /// `model`'s URLs, kept: the cache and the strip read them on every step.
    public private(set) var files: [URL]
    public var index: Int { sourceIndex ?? model.index }
    public var sort: BrowserSort { model.sort }
    /// Size and mtime of the files, as the folder listing reported them (empty when the playlist was
    /// built without a listing). The thumbnail cache validates against these, so it needs no `stat` per
    /// file, which is slow over SMB. Only files in `files` have an entry.
    public let stamps: [URL: FileStamp]

    /// `init(files:current:stamps:)` without stamps.
    public init(files: [URL], current: URL) {
        self.init(files: files, current: current, stamps: [:])
    }

    /// An authoritative source sequence: no extension filtering, filename sorting or folder lookup.
    public init?(ordered: [URL], current: URL) {
        var seen = Set<URL>()
        let files = ordered.filter { seen.insert($0).inserted }
        guard !files.isEmpty else { return nil }
        sourceIndex = files.firstIndex(of: current) ?? 0
        self.files = files
        stamps = [:]
        model = FolderPlaylist(folder: current.deletingLastPathComponent(), entries: [], sort: .standard, current: current)
    }

    /// Pure: filters `files` to image extensions (case-insensitive), adds `current` and `keeping` (files the
    /// filter would drop that stay anyway: opened directly) if missing and orders them by `sort` (by name: "img2"
    /// before "img10"). URLs are compared standardized so a `current` spelled differently from the listing still finds
    /// its entry. `stamps` is kept for the files that stay in the list; they give the dates and sizes the sort uses.
    public init(files: [URL], current: URL, stamps: [URL: FileStamp], keeping: [URL] = [], sort: BrowserSort = .standard) {
        let me = current.standardizedFileURL
        var images = files.map(\.quicklyStandardized)
            .filter { Self.imageExtensions.contains($0.pathExtension.lowercased()) }
        images += keeping.map(\.standardizedFileURL)
        // Drop duplicates (same file listed twice).
        var seen = Set<URL>()
        images = images.filter { seen.insert($0).inserted }
        let kept = seen.union([me])
        self.stamps = stamps.reduce(into: [:]) { result, entry in
            let url = entry.key.quicklyStandardized
            if kept.contains(url) { result[url] = entry.value }
        }
        let stamps = self.stamps
        model = FolderPlaylist(folder: me.deletingLastPathComponent(),
                               entries: images.map { BrowserListingSource.fileEntry($0, stamp: stamps[$0]) },
                               sort: sort, current: me)
        self.files = model.urls
    }

    /// Lists `current`'s folder off the caller's thread (it is often an SMB share, where listing can take a
    /// while), for `replacing(with:)` (M2.5 spec §4.5): its images, hidden ones left out (a dot name or the hidden
    /// flag). The listing also asks for size and mtime of every file (one round trip on SMB) and keeps them as
    /// `stamps`. A folder that cannot be listed is nil, so a share that drops keeps the playlist it had rather than
    /// shrinking it to one file.
    ///
    /// `current` and the files of `keeping` (the playlist being replaced) stay while they exist even where the
    /// filter would drop them — a hidden or odd-extension file opened directly stays after the user steps off it.
    /// The listing includes hidden entries, so this costs no stat; only a `current` missing from it is checked
    /// (spelled differently, or gone). The result's own position means nothing; a folder left with nothing to show
    /// is just `current`.
    public static func relist(current: URL, keeping: [URL] = []) async -> Playlist? {
        guard current.isFileURL else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let entries = list(folderOf: current) else { return nil }
            let me = current.standardizedFileURL
            let keep = Set(keeping.map(\.standardizedFileURL))
            var images: [URL] = [], odd: [URL] = [], stamps: [URL: FileStamp] = [:], listsMe = false
            for (url, stamp, hidden) in entries {
                let wanted = url == me || keep.contains(url)
                if url == me { listsMe = true }
                if hidden && !wanted { continue }
                if imageExtensions.contains(url.pathExtension.lowercased()) {
                    images.append(url)
                    if let stamp { stamps[url] = stamp }
                } else if wanted {
                    odd.append(url)
                }
            }
            // An archive's listing is all its entries: one it does not list is gone.
            if listsMe || (ArchivePath.split(me) == nil && FileManager.default.fileExists(atPath: me.path)) {
                return Playlist(files: images, current: me, stamps: stamps, keeping: odd)
            }
            return Playlist(files: images, current: images.first ?? odd.first ?? me, stamps: stamps, keeping: odd)
        }.value
    }

    /// Only the names of `current`'s folder, in one `readdir` pass that asks for no attributes: on the user's SMB share
    /// (1 735 files) that takes 0.05 s where `relist`'s listing takes ~8 s with a cold cache — any request for attributes,
    /// even `contentsOfDirectory(atPath:)`'s, costs the full time (docs/bench/2026-10-19-folder-listing.md). It is the
    /// playlist shown after an open until `relist` brings the stamps: dot names are left out, the hidden flag is not
    /// known yet, `current` always stays. Nil if the folder cannot be opened.
    public static func quickList(current: URL) async -> Playlist? {
        guard current.isFileURL else { return nil }
        return await Task.detached(priority: .userInitiated) {
            let me = current.standardizedFileURL
            let folder = me.deletingLastPathComponent()
            if ArchivePath.split(me) != nil {
                // The directory is one read: the names come with their stamps anyway.
                guard let entries = try? ArchiveReader.shared.entries(of: folder) else { return nil }
                return Playlist(files: entries.map(\.url), current: me, stamps: Dictionary(
                    entries.map { ($0.url, $0.stamp) }, uniquingKeysWith: { a, _ in a }))
            }
            guard let dir = opendir(folder.path) else { return nil }
            defer { closedir(dir) }
            var images: [URL] = []
            while let entry = readdir(dir) {
                if entry.pointee.d_type == DT_DIR { continue }
                let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                    String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
                }
                guard !name.hasPrefix("."), imageExtensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
                images.append(folder.appendingPathComponent(name, isDirectory: false))
            }
            return Playlist(files: images, current: me)
        }.value
    }

    /// Every entry of the folder (standardized) with its stamp and hidden flag; nil if it cannot be listed. The
    /// folder of an archive entry is the archive: its photos (`ArchiveReader.entries`). Blocking: callers run it off
    /// the main thread.
    private static func list(folderOf current: URL) -> [(url: URL, stamp: FileStamp?, hidden: Bool)]? {
        let folder = current.standardizedFileURL.deletingLastPathComponent()
        if ArchivePath.split(current.standardizedFileURL) != nil {
            return (try? ArchiveReader.shared.entries(of: folder))?.map { ($0.url.standardizedFileURL, $0.stamp, false) }
        }
        let keys = FileStamp.listingKeys + [.isHiddenKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: []) else { return nil }
        return contents.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return (url.standardizedFileURL, values.flatMap { FileStamp($0) }, values?.isHidden == true)
        }
    }

    /// Pure: this playlist after a re-read found `listed` (its files and stamps; its position is ignored). The
    /// current photo stays by URL; if it is gone, the file now at its old index (clamped) becomes current. Cheap
    /// (no sort: `listed` is sorted already), so it runs on the main thread against the position the user has
    /// reached while the folder was listing.
    public func replacing(with listed: Playlist) -> Playlist {
        var result = listed
        if result.isSourceOrdered {
            let identity = PhotosLocation.asset(in: current)
            if let identity, let i = result.files.firstIndex(where: { PhotosLocation.asset(in: $0) == identity }) {
                result.sourceIndex = i
            } else { result.sourceIndex = min(index, result.files.count - 1) }
            return result
        }
        if !result.model.move(to: current) {
            _ = result.model.move(by: min(index, listed.files.count - 1) - listed.index)
        }
        return result
    }

    public var current: URL { files[index] }

    /// The same files and stamps in `sort`'s order, on the same photo.
    public func sorted(_ sort: BrowserSort) -> Playlist {
        guard !isSourceOrdered else { return self }
        guard sort != self.sort else { return self }
        var result = self
        result.model.resort(sort)
        result.files = result.model.urls
        return result
    }

    /// `from`, or the first index beyond it in the direction of `step` whose file `skipping` does not refuse; nil past
    /// either end (`FolderPlaylist.index(from:step:skipping:)`).
    public func index(from: Int, step: Int, skipping: (URL) -> Bool) -> Int? {
        if isSourceOrdered {
            var i = from
            while files.indices.contains(i), skipping(files[i]) { i += step < 0 ? -1 : 1 }
            return files.indices.contains(i) ? i : nil
        }
        return model.index(from: from, step: step) { skipping($0.url) }
    }

    /// Moves by `step` entries. Returns `false` and changes nothing if that would leave the
    /// list: navigation stops at the ends rather than wrapping.
    public mutating func move(by step: Int) -> Bool {
        if let index = sourceIndex {
            let (next, overflow) = index.addingReportingOverflow(step)
            guard !overflow, files.indices.contains(next) else { return false }
            sourceIndex = next
            return true
        }
        return model.move(by: step)
    }

    /// Moves to `url` (standardized); false and nothing changed when it is not in the list.
    public mutating func move(to url: URL) -> Bool {
        if isSourceOrdered {
            guard let i = files.firstIndex(of: url) else { return false }
            sourceIndex = i
            return true
        }
        return model.move(to: url)
    }

    public mutating func moveToFirst() { _ = move(by: -index) }
    public mutating func moveToLast() { _ = move(by: files.count - 1 - index) }
}
