import Foundation

/// One step through a list of folders kept elsewhere (a Stash gallery list): the item, with its title, its path as
/// the list writes it, its place in the list and its id there (a Stash gallery's), or the list's end.
public enum ListStep: Equatable, Sendable {
    case item(title: String, path: String, index: Int, count: Int, id: String? = nil)
    case end
}

/// Folder steps through a list instead of the folder's siblings on disk (Stash spec §2.3): `next(index, step)` gives
/// the list's item after (or before) `index`, `resolve` maps its path to this Mac, `contents` lists it. An item that
/// cannot be resolved or has no photos is skipped (`onSkip("Skipped <title>: <reason>")`) and the step goes on, at
/// most `skipLimit` times in a row; the list's end calls `onEnd`. Either way the step gives nil, the photo on screen
/// stays, and `position` stays where it was: it moves only to an item that was found. A cancelled step stops at the
/// next item. The target found carries `"<title> · <n> / <N>"` as its label and the item's id as its `listID`.
public actor ListFolderNavigator {
    public static let skipLimit = 10
    /// The list index of the folder on screen.
    public private(set) var position: Int
    private let next: @Sendable (Int, Int) async throws -> ListStep
    private let resolve: @Sendable (String) async -> Result<URL, Error>
    private let contents: @Sendable (URL) async throws -> FolderTarget?
    private let onEnd: @Sendable () -> Void
    private let onSkip: @Sendable (String) -> Void

    public init(start: Int, next: @escaping @Sendable (Int, Int) async throws -> ListStep,
                resolve: @escaping @Sendable (String) async -> Result<URL, Error>,
                contents: @escaping @Sendable (URL) async throws -> FolderTarget?,
                onEnd: @escaping @Sendable () -> Void,
                onSkip: @escaping @Sendable (String) -> Void) {
        position = start
        self.next = next
        self.resolve = resolve
        self.contents = contents
        self.onEnd = onEnd
        self.onSkip = onSkip
    }

    /// `"<title> · <n> / <N>"`, or `"<title> · <n>"` while the list's length is not known.
    public static func label(title: String, index: Int, count: Int?) -> String {
        "\(title) · \(index + 1)" + (count.map { " / \($0)" } ?? "")
    }

    /// `folder` is the one on screen (unused: the list knows where it is).
    public func neighbour(of folder: URL, step: Int) async throws -> FolderTarget? {
        var at = position, skipped = 0
        while true {
            try Task.checkCancellation()
            if skipped == Self.skipLimit {
                onSkip("Stopped: \(Self.skipLimit) galleries in a row could not be opened")
                return nil
            }
            guard case .item(let title, let path, let index, let count, let id) = try await next(at, step) else {
                onEnd()
                return nil
            }
            at = index
            skipped += 1
            let url: URL
            switch await resolve(path) {
            case .success(let u): url = u
            case .failure(let error):
                onSkip("Skipped \(title): \(error.localizedDescription)")
                continue
            }
            let target: FolderTarget?
            do {
                target = try await contents(url)
            } catch {
                onSkip("Skipped \(title): \(error.localizedDescription)")
                continue
            }
            guard var found = target else {
                onSkip("Skipped \(title): no photos")
                continue
            }
            found.label = Self.label(title: title, index: index, count: count)
            found.listID = id
            position = index
            return found
        }
    }
}
