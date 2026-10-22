import Foundation

/// What a folder cover is built from.
public enum CoverSource: Equatable, Sendable {
    case photos([String])
    case subfolders([String])
    case empty
}

/// Picks the photos shown on a folder cover. Pure: works on names only.
public enum CoverSampling {
    /// A name with one of the viewer's image extensions. Archive entry names (with "/") work too.
    public static func isPhoto(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), name[dot...].firstIndex(of: "/") == nil else { return false }
        return Playlist.imageExtensions.contains(name[name.index(after: dot)...].lowercased())
    }

    /// `count` names spread evenly over `names` (`round(i*(n-1)/(count-1))`), the last viewed one first.
    public static func pick(_ names: [String], count: Int = 4, lastViewed: String?) -> [String] {
        guard count > 0, !names.isEmpty else { return [] }
        var spread: [String] = []
        if names.count <= count {
            spread = names
        } else if count == 1 {
            spread = [names[0]]
        } else {
            var seen = Set<Int>()
            for i in 0..<count {
                let index = Int((Double(i) * Double(names.count - 1) / Double(count - 1)).rounded())
                if seen.insert(index).inserted { spread.append(names[index]) }
            }
        }
        guard let last = lastViewed, names.contains(last) else { return spread }
        return Array(([last] + spread.filter { $0 != last }).prefix(count))
    }

    /// Photos of the folder if it has any, else its first subfolders, else nothing.
    public static func plan(names: [String], directories: [String], lastViewed: String?) -> CoverSource {
        let photos = names.filter(isPhoto)
        if !photos.isEmpty { return .photos(pick(photos, lastViewed: lastViewed)) }
        if !directories.isEmpty { return .subfolders(Array(directories.prefix(4))) }
        return .empty
    }
}
