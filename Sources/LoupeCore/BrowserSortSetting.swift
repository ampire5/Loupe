import Foundation
import HomeScreenModel

/// `browser-sort` in a folder's settings (file browser spec §4.2): the browser's order for the folder and the ones under
/// it, which the strip and the steps follow too.
extension BrowserSort {
    public static let settingKey = "browser-sort"

    /// The folder's sort, inherited from its ancestors; none set, or text that is not a sort, is by name.
    public static func forFolder(_ folder: URL, settings: FolderSettings?) -> BrowserSort {
        settings?.values(for: folder)[settingKey].flatMap(BrowserSort.init(text:)) ?? .standard
    }
}

extension Playlist {
    /// The playlist in `sort` order, on the same photo. Date and size come from `stamps`: files without one (the
    /// names-only listing) keep Finder order after those that have one. Equal values go by name, ascending.
    public func sorted(_ sort: BrowserSort) -> Playlist {
        guard sort != .standard else { return self }
        let value: (URL) -> Double? = { url in
            guard let stamp = stamps[url] else { return nil }
            switch sort.key {
            case .name: return nil
            case .date: return stamp.modified.timeIntervalSinceReferenceDate
            case .size: return Double(stamp.size)
            }
        }
        let ordered: [URL]
        if sort.key == .name {
            ordered = files.reversed()   // `files` is in Finder order already
        } else {
            ordered = files.sorted { a, b in
                switch (value(a), value(b)) {
                case let (x?, y?) where x != y: return sort.ascending ? x < y : x > y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return Playlist.naturalLess(a, b)
                }
            }
        }
        return reordered(ordered)
    }
}
