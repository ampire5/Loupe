import Foundation
import HomeScreenModel

/// What a folder card says about its folder, from one directory listing: how many photos and subfolders, how big, the
/// span of the photos' dates and a twelve-bin histogram of them. Pure: the listing is read elsewhere (the cover queue).
public struct FolderSummary: Equatable, Sendable {
    /// Bins of `histogram`.
    public static let histogramBins = 12

    /// Photos directly in the folder (a zip's: its photo entries).
    public var photos: Int
    /// Direct subfolders (not hidden, not packages: the same rule as a cover's names).
    public var folders: Int
    /// Bytes of the photos (a zip's: the archive's size); nil when the listing gave no sizes (a share).
    public var bytes: Int64?
    /// The earliest and latest photo date (modification time); nil without dated photos.
    public var first: Date?
    public var last: Date?
    /// `histogramBins` values, each bin's share of the dated photos scaled to 255 (sum about 255, rounding allowed), the
    /// bins spanning `first`...`last` evenly. All photos on one date: bin 0 is 255. Empty without dated photos and for
    /// an archive.
    public var histogram: [UInt8]
    /// The folder's own modification time when the summary was made: it changes when files come or go, so a stored
    /// summary is fresh while it matches.
    public var folderModified: Date?
    /// Whether the dates and sizes come from a listing with stat (false: names only, on a share).
    public var datesKnown: Bool

    public init(photos: Int, folders: Int, bytes: Int64? = nil, first: Date? = nil, last: Date? = nil,
                histogram: [UInt8] = [], folderModified: Date? = nil, datesKnown: Bool = false) {
        self.photos = photos
        self.folders = folders
        self.bytes = bytes
        self.first = first
        self.last = last
        self.histogram = histogram
        self.folderModified = folderModified
        self.datesKnown = datesKnown
    }

    /// From a listing with stat (a local volume, or an open folder's full listing).
    public static func of(entries: [DirectoryEntry], folderModified: Date? = nil) -> FolderSummary {
        var folders = 0
        var photos = 0
        var bytes: Int64 = 0
        var dates: [Date] = []
        for entry in entries {
            guard !entry.url.lastPathComponent.hasPrefix(".") else { continue }
            if entry.isDirectory {
                if !entry.isPackage { folders += 1 }
                continue
            }
            guard Playlist.imageExtensions.contains(entry.url.pathExtension.lowercased()) else { continue }
            photos += 1
            if let stamp = entry.stamp { bytes += Int64(stamp.size) }
            if let date = entry.modified { dates.append(date) }
        }
        return dated(photos: photos, folders: folders, bytes: bytes, dates: dates, folderModified: folderModified)
    }

    private static func dated(photos: Int, folders: Int, bytes: Int64, dates: [Date],
                              folderModified: Date?) -> FolderSummary {
        let span = (dates.min(), dates.max())
        return FolderSummary(photos: photos, folders: folders, bytes: bytes, first: span.0, last: span.1,
                             histogram: histogram(of: dates), folderModified: folderModified, datesKnown: true)
    }

    /// From a listing as the browser has it (`BrowserListingSource.full`, the open folder's, which has stat on a share
    /// too; or `names` with stat, a local card's): its photos with their dates and sizes, its subfolders (packages are
    /// already left out); zips are not photos. Names, not URLs: a URL's parts cost microseconds each, which thousands
    /// of entries feel.
    public static func of(listing entries: [BrowserEntry], folderModified: Date?) -> FolderSummary {
        var folders = 0
        var photos = 0
        var bytes: Int64?
        var dates: [Date] = []
        for entry in entries where !entry.name.hasPrefix(".") {
            switch entry.kind {
            case .folder:
                folders += 1
            case .file:
                photos += 1
                if let size = entry.size { bytes = (bytes ?? 0) + size }
                if let date = entry.date { dates.append(date) }
            case .archive, .collection, .place:
                break
            }
        }
        var summary = dated(photos: photos, folders: folders, bytes: bytes ?? 0, dates: dates,
                            folderModified: folderModified)
        // Photos without a date or size (a listing that could not stat them): not known, rather than nothing.
        summary.bytes = photos == 0 ? 0 : bytes
        summary.datesKnown = !dates.isEmpty || photos == 0
        return summary
    }

    /// From a names-only listing (a share): counts only, no dates, no size.
    public static func of(names: CoverNames, folderModified: Date?) -> FolderSummary {
        FolderSummary(photos: names.files.count, folders: names.folders.count, folderModified: folderModified)
    }

    /// A zip: its photo count, the archive's size and date, no histogram.
    public static func ofArchive(photos: Int, bytes: Int64, modified: Date) -> FolderSummary {
        FolderSummary(photos: photos, folders: 0, bytes: bytes, first: modified, last: modified,
                      folderModified: modified, datesKnown: true)
    }

    /// The photos in the known summaries of the subfolders, and whether some are unknown (nil).
    public func inside(_ subfolders: [FolderSummary?]) -> (photos: Int, incomplete: Bool) {
        (subfolders.reduce(0) { $0 + ($1?.photos ?? 0) }, subfolders.contains { $0 == nil })
    }

    private static func histogram(of dates: [Date]) -> [UInt8] {
        guard let first = dates.min(), let last = dates.max() else { return [] }
        var counts = [Int](repeating: 0, count: histogramBins)
        let span = last.timeIntervalSince(first)
        for date in dates {
            let bin = span > 0 ? min(histogramBins - 1, Int(date.timeIntervalSince(first) / span * Double(histogramBins))) : 0
            counts[bin] += 1
        }
        return counts.map { UInt8((Double($0) * 255 / Double(dates.count)).rounded()) }
    }
}
