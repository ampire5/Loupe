import Foundation
import HomeScreenModel

public enum FolderStripError: Error { case busy }

/// One demand-driven disk listing at a time across all windows. A timed-out syscall keeps its
/// place until it actually returns: rapid cancellation cannot accumulate stuck worker threads.
private final class FolderStripDiskIO: @unchecked Sendable {
    static let shared = FolderStripDiskIO()
    private let lock = NSLock()
    private var running = false
    private func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return false }; running = true; return true
    }
    private func release() { lock.lock(); running = false; lock.unlock() }
    func list(_ url: URL) async throws -> [DirectoryEntry] {
        try Task.checkCancellation()
        guard take() else { throw FolderStripError.busy }
        return try await BlockingCall.run(timeout: .seconds(10)) { [self] in
            defer { release() }
            // One stat listing, like Home's final order; symbolic directory links cannot form an unbounded walk.
            return try FolderSiblings.listEntries(url).filter { !$0.isSymbolicLink }

        }
    }
}

public actor FolderStripListing: FolderStripSource {
    public typealias Lister = @Sendable (URL) async throws -> [DirectoryEntry]
    private let list: Lister
    private let archives: Bool
    private let sort: @Sendable (URL) async -> BrowserSort
    // A single last listing: no cache proportional to all folders visited or all descendants.
    private var last: (url: URL, entries: [DirectoryEntry])?
    public init(archives: Bool = true, sort: @escaping @Sendable (URL) async -> BrowserSort = { _ in .standard },
                list: @escaping Lister = { try await FolderStripListing.diskEntries($0) }) {
        self.archives = archives; self.sort = sort; self.list = list
    }
    public static func diskEntries(_ url: URL) async throws -> [DirectoryEntry] {
        try await FolderStripDiskIO.shared.list(url)
    }
    private func entries(_ url: URL) async throws -> [DirectoryEntry] {
        try Task.checkCancellation()
        if let last, last.url == url { return last.entries }
        let entries = try await list(url)
        try Task.checkCancellation()
        last = (url, entries)
        return entries
    }
    public func rows(around id: FolderStripID) async throws -> [FolderStripEntry] {
        guard case .folder(let folder) = id else { return [] }
        let parent = folder.standardizedFileURL.deletingLastPathComponent()
        let siblings = FolderSiblings(entries: try await entries(parent), archives: archives, sort: await sort(parent))
        return siblings.folders.map { FolderStripEntry(id: .folder($0), title: $0.lastPathComponent) }
    }
    public func children(of id: FolderStripID) async throws -> [FolderStripEntry] {
        guard case .folder(let folder) = id, !ArchivePath.isArchive(folder) else { return [] }
        let children = FolderSiblings(entries: try await entries(folder), archives: archives, sort: await sort(folder))
        return children.folders.map { FolderStripEntry(id: .folder($0), parent: id, title: $0.lastPathComponent, depth: 1) }
    }
    public func target(for id: FolderStripID) async throws -> FolderTarget? {
        guard case .folder(let folder) = id else { return nil }
        // Iterative DFS, no recursive stack. Only the current path's siblings are held.
        var pending = [folder.standardizedFileURL], visited = Set<URL>()
        while let next = pending.popLast() {
            try Task.checkCancellation()
            guard visited.insert(next).inserted else { continue }
            let values: [DirectoryEntry]
            do { values = try await entries(next) }
            catch is CancellationError { throw CancellationError() }
            catch FolderStripError.busy { throw FolderStripError.busy }
            catch { if next == folder.standardizedFileURL { throw error }; continue }
            let images = values.filter { !$0.isDirectory && Playlist.imageExtensions.contains($0.url.pathExtension.lowercased()) }
            if !images.isEmpty {
                let ordered = (await sort(next)).order(images.map {
                    BrowserEntry(url: $0.url, name: $0.url.lastPathComponent, kind: .file,
                                 date: $0.modified, size: $0.stamp.map { Int64($0.size) })
                })
                let stamps = Dictionary(images.compactMap { item in item.stamp.map { (item.url, $0) } }, uniquingKeysWith: { first, _ in first })
                return FolderTarget(folder: next, images: ordered.map(\.url), stamps: stamps)
            }
            let children = FolderSiblings(entries: values, archives: archives, sort: await sort(next)).folders
            pending.append(contentsOf: children.reversed().filter { !visited.contains($0) })
        }
        return nil
    }
}
