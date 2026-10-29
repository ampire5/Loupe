import Foundation
import HomeScreenModel

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
}
