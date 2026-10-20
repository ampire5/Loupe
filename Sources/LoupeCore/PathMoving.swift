import Foundation

/// A store that keeps paths and follows a rename (file browser spec §4.3): rows at or under the old path move to the new
/// one, and a file named in a folder's row takes its new name.
public protocol PathMoving: Sendable {
    func movePaths(from: URL, to: URL)
}

/// One rename, as standardized paths.
public struct PathMove: Sendable {
    public let from: String
    public let to: String

    public init(from: URL, to: URL) {
        self.from = from.standardizedFileURL.path
        self.to = to.standardizedFileURL.path
    }

    /// `path` after the move: the moved item itself or something under it; nil for anything else.
    public func moved(_ path: String) -> String? {
        if path == from { return to }
        if path.hasPrefix(from + "/") { return to + path.dropFirst(from.count) }
        return nil
    }

    /// A file name kept for `folder` after the move: the new name when it is the renamed file.
    public func renamedFile(_ name: String, in folder: String) -> String? {
        let old = URL(fileURLWithPath: from), new = URL(fileURLWithPath: to)
        guard folder == old.deletingLastPathComponent().path, name == old.lastPathComponent,
              old.deletingLastPathComponent().path == new.deletingLastPathComponent().path else { return nil }
        return new.lastPathComponent
    }
}
