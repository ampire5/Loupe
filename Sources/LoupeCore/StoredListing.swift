import Foundation
import HomeScreenModel

/// A folder's last complete listing as the catalog keeps it (`ThumbnailDatabase.putListing`): its folders, zips and
/// photos by name, with the dates, sizes and photo counts the listing had, each one renamed and trashed as a listed one
/// (`BrowserListingSource`). Shown the next time the folder opens, before
/// the share answers, and replaced by the share's listing when it comes. Names only, not paths: the same share mounted
/// elsewhere finds its folders' listings under the folder as it is opened then.
public enum StoredListing {
    private struct Row: Codable {
        var n: String
        /// `d` folder, `a` zip, `f` photo.
        var k: String
        var s: Int64?
        var t: Double?
        var c: Int?
    }

    /// The entries a folder's listing holds (folders, zips, photos); nil when none can be encoded.
    public static func encode(_ entries: [BrowserEntry]) -> Data? {
        let rows = entries.compactMap { e -> Row? in
            let kind: String
            switch e.kind {
            case .folder: kind = "d"
            case .archive: kind = "a"
            case .file: kind = "f"
            case .place, .collection: return nil
            }
            return Row(n: e.name, k: kind, s: e.size, t: e.date?.timeIntervalSinceReferenceDate, c: e.count)
        }
        return try? JSONEncoder().encode(rows)
    }

    /// The entries of `data` in `folder`; nil when it does not decode.
    public static func decode(_ data: Data, in folder: URL) -> [BrowserEntry]? {
        guard let rows = try? JSONDecoder().decode([Row].self, from: data) else { return nil }
        return rows.compactMap { r in
            let kind: BrowserEntry.Kind
            switch r.k {
            case "d": kind = .folder
            case "a": kind = .archive
            case "f": kind = .file
            default: return nil
            }
            return BrowserEntry(url: folder.appendingPathComponent(r.n, isDirectory: kind == .folder), name: r.n,
                                kind: kind, date: r.t.map(Date.init(timeIntervalSinceReferenceDate:)), size: r.s,
                                count: r.c, canRename: true, canTrash: true)
        }
    }
}
