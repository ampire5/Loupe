import Foundation

/// What a folder cover is built from.
public enum CoverSource: Equatable, Sendable {
    case photos([String])
    case subfolders([String])
    case empty
}

/// Picks the photos shown on a folder cover. Pure: works on names only.
public enum CoverSampling {
    /// A name with one of the viewer's image extensions. Archive entry names (with "/") work too. Hidden files,
    /// AppleDouble `._*` files and `__MACOSX/` entries are not photos (same rules as the folder and archive listings).
    public static func isPhoto(_ name: String) -> Bool {
        let last = name.split(separator: "/").last.map(String.init) ?? ""
        guard !last.hasPrefix("."), !name.hasPrefix("__MACOSX/"), !name.contains("/__MACOSX/") else { return false }
        return Playlist.imageExtensions.contains((last as NSString).pathExtension.lowercased())
    }

    /// `count` names spread evenly over `names` (`round(i*(n-1)/(count-1))`). Does not filter by extension (`plan`
    /// does). A `lastViewed` that is in `names` goes first; if it is not already in the spread, it replaces the
    /// spread point nearest to it, so the folder's ends stay. Absent `lastViewed` is ignored.
    public static func pick(_ names: [String], count: Int = 4, lastViewed: String?) -> [String] {
        guard count > 0, !names.isEmpty else { return [] }
        var spread: [Int] = []
        if names.count <= count {
            spread = Array(names.indices)
        } else if count == 1 {
            spread = [0]
        } else {
            for i in 0..<count {
                let index = Int((Double(i) * Double(names.count - 1) / Double(count - 1)).rounded())
                if !spread.contains(index) { spread.append(index) }
            }
        }
        guard let last = lastViewed, let at = names.firstIndex(of: last) else { return spread.map { names[$0] } }
        if let existing = spread.firstIndex(of: at) {
            spread.remove(at: existing)
        } else if spread.count >= count, let nearest = spread.indices.min(by: { abs(spread[$0] - at) < abs(spread[$1] - at) }) {
            spread.remove(at: nearest)
        }
        return [last] + spread.map { names[$0] }
    }

    /// Photos of the folder if it has any, else its first 4 subfolders, else nothing. `directories` must be
    /// pre-sorted; `names` are filtered here, and a `lastViewed` that is not one of the photos is ignored.
    public static func plan(names: [String], directories: [String], lastViewed: String?) -> CoverSource {
        let photos = names.filter(isPhoto)
        if !photos.isEmpty { return .photos(pick(photos, lastViewed: lastViewed)) }
        if !directories.isEmpty { return .subfolders(Array(directories.prefix(4))) }
        return .empty
    }
}
