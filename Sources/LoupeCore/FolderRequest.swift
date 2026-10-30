import Foundation
import HomeScreenModel

/// The bookkeeping of one "go to the next / previous folder" request, so what the viewer does with it is
/// tested without AppKit: at most one request is pending (a second key press is ignored), any other navigation
/// cancels it, and its result is applied only if it is still the pending request and the photo on screen is
/// the one it started from.
public struct FolderRequest: Sendable {
    public struct Token: Equatable, Sendable { fileprivate let id: Int }

    /// What the viewer does with a finished request.
    public enum Outcome: Equatable, Sendable {
        /// Stale (cancelled, superseded or the photo changed): touch nothing.
        case drop
        /// There is no folder in that direction: remove "Loading folder…", nothing else changes.
        case stay
        /// Show this playlist.
        case enter(Playlist)
        /// Keep the current folder and show this line.
        case fail(String)
    }

    public static let loadingText = "Loading folder…"

    private var nextID = 0
    private var pending: (token: Token, origin: URL)?

    public init() {}

    public var isPending: Bool { pending != nil }

    /// Starts a request from the photo `origin`; nil (ignore the key) while another is pending.
    public mutating func begin(from origin: URL) -> Token? {
        guard pending == nil else { return nil }
        nextID += 1
        let token = Token(id: nextID)
        pending = (token, origin.standardizedFileURL)
        return token
    }

    /// Any other navigation (photo, first / last, open): the pending request no longer applies.
    public mutating func cancel() { pending = nil }

    /// Decides what to do with `result` of the request `token`, given the photo now on screen. `remembered`
    /// maps a folder and its files to the file to land on (`FolderPositions.recall`). Clears the request when
    /// it is the pending one.
    public mutating func finish(_ token: Token, result: Result<FolderTarget?, Error>, current: URL?,
                                sort: (URL) -> BrowserSort = { _ in .standard },
                                remembered: (URL, [URL]) -> URL?) -> Outcome {
        guard let pending, pending.token == token else { return .drop }
        guard current?.standardizedFileURL == pending.origin else { self.pending = nil; return .drop }
        return finish(token, prepared: result.map { target in
            target.map { Self.playlist(for: $0, sort: sort($0.folder), remembered: remembered) }
        }, current: current)
    }

    /// Commits an already prepared result. Only constant-size request bookkeeping belongs on the main actor;
    /// the playlist is made by `FolderPlaylistPreparation` before this final stale-result check.
    public mutating func finish(_ token: Token, prepared result: Result<Playlist?, Error>, current: URL?) -> Outcome {
        guard let pending, pending.token == token else { return .drop }
        self.pending = nil
        guard current?.standardizedFileURL == pending.origin else { return .drop }
        switch result {
        case .success(nil): return .stay
        case .success(let list?): return .enter(list)
        case .failure(let error): return .fail(Self.errorText(error, origin: pending.origin))
        }
    }

    /// The target's playlist in `sort` order (`browser-sort`), on the remembered photo if it is still there, else on
    /// the first.
    public static func playlist(for target: FolderTarget, sort: BrowserSort = .standard,
                                remembered: (URL, [URL]) -> URL?) -> Playlist {
        // Built once, in `sort`'s order; the remembered photo is moved to, not built again (that sorted by name,
        // owner, 2026-10-28).
        var list = Playlist(files: target.images, current: target.images[0], stamps: target.stamps, sort: sort)
        list.moveToFirst()
        if let file = remembered(target.folder, list.files), !list.move(to: file) {
            list = Playlist(files: list.files, current: file, stamps: list.stamps, sort: sort)
        }
        return list
    }

    /// The line for a failed request; it names the parent folder whose listing failed.
    public static func errorText(_ error: Error, origin: URL) -> String {
        listErrorText(error, name: origin.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent)
    }

    /// The line for a folder or archive named `name` that could not be listed.
    public static func listErrorText(_ error: Error, name: String) -> String {
        switch error as? FolderNavigationError {
        case .timedOut?: return "Can't list “\(name)”: not responding"
        default: return "Can't list “\(name)”"
        }
    }
}
