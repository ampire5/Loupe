import Foundation
import HomeScreenModel

/// The recursive listing and controls of the File View that opened the photo.
public struct RecursivePhotoListing: Sendable {
    public let root: URL
    public let sort: BrowserSort
    let entries: [String: BrowserEntry]
    let filter: BrowserFilter

    public init(root: URL, sort: BrowserSort, entries: [String: BrowserEntry], filter: BrowserFilter) {
        self.root = root
        self.sort = sort
        self.entries = entries
        self.filter = filter
    }
}

/// Folder entry is foreground work, but its URL passes and sort must never occupy the main actor.
/// One process-wide worker serializes preparation across windows: no parallel sorts or buffers per core.
/// The 50 000-file case takes ~270 ms on M4 Max (docs/bench/2026-10-28-hot-paths.md).
public actor FolderPlaylistPreparation {
    public static let shared = FolderPlaylistPreparation()

    public func prepare(_ target: FolderTarget, sort: BrowserSort = .standard,
                        remembered: @Sendable (URL, [URL]) -> URL?) throws -> Playlist {
        try Task.checkCancellation()
        let list = FolderRequest.playlist(for: target, sort: sort, remembered: remembered)
        // Sorting is synchronous; a cancellation during it must still discard the finished buffer.
        try Task.checkCancellation()
        return list
    }

    public func prepare(_ listing: RecursivePhotoListing, current: URL) throws -> Playlist {
        try Task.checkCancellation()
        let entries = Array(listing.entries.values)
        let filtered = listing.filter.isActive ? listing.filter.apply(entries) : entries
        let list = Playlist(recursiveRoot: listing.root, entries: filtered, sort: listing.sort, current: current)
        try Task.checkCancellation()
        return list
    }
}
