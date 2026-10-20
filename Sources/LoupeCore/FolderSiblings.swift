import Foundation

/// One item of a directory listing, with the properties folder navigation needs. `stamp` (size and
/// mtime, nil for directories and when the listing gave none) rides along so the playlist of the folder
/// jumped to carries it, as `Playlist.relist` does.
public struct DirectoryEntry: Equatable, Sendable {
    public let url: URL
    public let isDirectory: Bool
    public let isPackage: Bool
    public let stamp: FileStamp?

    public init(url: URL, isDirectory: Bool, isPackage: Bool, stamp: FileStamp? = nil) {
        self.url = url
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.stamp = stamp
    }
}

public enum FolderNavigationError: Error, Equatable, Sendable {
    /// The parent folder could not be listed.
    case unreadable
    /// A listing did not finish in time (a hung share); the thread doing it was written off.
    case timedOut
}

/// The subfolders of a folder's parent in Finder order, and what is next to a given one.
/// Hidden folders, packages (`.app` etc.) and plain files are not siblings.
public struct FolderSiblings: Equatable, Sendable {
    public let folders: [URL]

    /// Pure: keeps visible, non-package directories (and zip files with `archives`, `archive-folders`) and sorts
    /// them like `Playlist` sorts files.
    public init(entries: [DirectoryEntry], archives: Bool = true) {
        folders = entries
            .filter { ($0.isDirectory && !$0.isPackage) || (archives && !$0.isDirectory && ArchivePath.isArchive($0.url)) }
            .filter { !$0.url.lastPathComponent.hasPrefix(".") }
            .map { $0.url.standardizedFileURL }
            .sorted(by: Playlist.naturalLess)
    }

    /// The siblings after (`step` > 0) or before (`step` < 0) `folder`, nearest first. A `folder` that is not
    /// among them (hidden, say) counts as standing where its name sorts. Empty at either end: no wrap-around.
    public func candidates(from folder: URL, step: Int) -> [URL] {
        let me = folder.standardizedFileURL
        let place = folders.firstIndex(of: me)
        let after = place.map { $0 + 1 } ?? folders.firstIndex { Playlist.naturalLess(me, $0) } ?? folders.count
        if step > 0 { return Array(folders[after...]) }
        let before = place ?? after
        return Array(folders[..<before].reversed())
    }

    /// Lists `url`, skipping hidden items; a zip file lists its photos (`ArchiveReader.entries`). Blocking: call it
    /// off the main thread.
    public static func listEntries(_ url: URL) throws -> [DirectoryEntry] {
        if ArchivePath.isArchive(url), (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            return try ArchiveReader.shared.entries(of: url).map {
                DirectoryEntry(url: $0.url, isDirectory: false, isPackage: false, stamp: $0.stamp)
            }
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey] + FileStamp.listingKeys
        let urls = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        return urls.map { item in
            let values = try? item.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory ?? false
            let stamp = isDirectory ? nil : values.flatMap { FileStamp($0) }
            return DirectoryEntry(url: item, isDirectory: isDirectory,
                                  isPackage: values?.isPackage ?? false, stamp: stamp)
        }
    }
}

/// The folder a navigation lands in: its image files (unsorted; `Playlist` sorts them) and their stamps.
public struct FolderTarget: Equatable, Sendable {
    public let folder: URL
    public let images: [URL]
    public let stamps: [URL: FileStamp]

    /// Said in a toast once the folder is entered (a Stash gallery: its title and place in the list); nil on disk.
    public var label: String?
    /// The id of the list item it was stepped to (a Stash gallery's); nil on disk.
    public var listID: String?

    public init(folder: URL, images: [URL], stamps: [URL: FileStamp] = [:], label: String? = nil, listID: String? = nil) {
        self.folder = folder
        self.images = images
        self.stamps = stamps
        self.label = label
        self.listID = listID
    }
}

/// Finds the next or previous sibling folder that has images. Every listing runs on a background queue with a
/// timeout, so a hung SMB share costs one abandoned thread and an error, never the caller. The parent's
/// listing and the folders found empty or unreadable are remembered for the session.
public actor FolderNavigator {
    public typealias Lister = @Sendable (URL) throws -> [DirectoryEntry]

    private let timeout: Duration
    private let list: Lister
    /// Each parent's listing, unfiltered: `archive-folders` filters it per call.
    private var siblingsByParent: [URL: [DirectoryEntry]] = [:]
    private var skippedFolders: Set<URL> = []

    public init(timeout: Duration = .seconds(10), list: @escaping Lister = { try FolderSiblings.listEntries($0) }) {
        self.timeout = timeout
        self.list = list
    }

    /// The nearest folder in direction `step` that has images, or nil at the end of the siblings.
    /// A candidate that cannot be listed (or hangs) is skipped; the parent failing throws `.unreadable`, a hang `.timedOut`.
    /// `archives`: zip files count as folders (`archive-folders`).
    public func neighbour(of folder: URL, step: Int, archives: Bool = true) async throws -> FolderTarget? {
        let folder = folder.standardizedFileURL
        let parent = folder.deletingLastPathComponent()
        let entries: [DirectoryEntry]
        if let cached = siblingsByParent[parent] {
            entries = cached
        } else {
            do {
                entries = try await listed(parent)
            } catch FolderNavigationError.timedOut {
                throw FolderNavigationError.timedOut
            } catch {
                throw FolderNavigationError.unreadable
            }
            siblingsByParent[parent] = entries
        }
        let siblings = FolderSiblings(entries: entries, archives: archives)
        for candidate in siblings.candidates(from: folder, step: step) where !skippedFolders.contains(candidate) {
            let entries: [DirectoryEntry]
            do {
                entries = try await listed(candidate)
            } catch {
                // Unreadable or hung: skip this folder and try the next (remembered, so a hung one costs one
                // timeout per session, not one per key press).
                skippedFolders.insert(candidate)
                continue
            }
            if let target = Self.target(candidate, entries) {
                return target
            }
            skippedFolders.insert(candidate)
        }
        return nil
    }

    /// One folder or archive as a target (an open from Finder or Stash): its photos, or nil when it has none. Fails
    /// as a listing does (`.timedOut` for a hang).
    public func contents(of folder: URL) async throws -> FolderTarget? {
        let folder = folder.standardizedFileURL
        return Self.target(folder, try await listed(folder))
    }

    private static func target(_ folder: URL, _ entries: [DirectoryEntry]) -> FolderTarget? {
        let imageEntries = entries
            .filter { !$0.isDirectory && Playlist.imageExtensions.contains($0.url.pathExtension.lowercased()) }
        guard !imageEntries.isEmpty else { return nil }
        var stamps: [URL: FileStamp] = [:]
        for entry in imageEntries { stamps[entry.url.standardizedFileURL] = entry.stamp }
        return FolderTarget(folder: folder, images: imageEntries.map(\.url), stamps: stamps)
    }

    /// Forgets the remembered sibling lists and empty folders, so changes on disk show up.
    public func invalidate() {
        siblingsByParent = [:]
        skippedFolders = []
    }

    private func listed(_ url: URL) async throws -> [DirectoryEntry] {
        try await BlockingCall.run(timeout: timeout) { [list] in try list(url) }
    }
}

/// Runs blocking work on a global queue and gives up waiting after `timeout`; the work itself cannot be
/// cancelled, so a hung call keeps its thread but no longer holds anyone up.
enum BlockingCall {
    /// Calls `completion` exactly once: with the work's result, or `.timedOut` once `timeout` has passed
    /// first. The work and the timer both run on GCD, so neither needs a Swift-concurrency pool thread
    /// (those may all be busy); only the caller's resumption after `run` does.
    static func start<T: Sendable>(
        timeout: Duration,
        _ work: @escaping @Sendable () throws -> T,
        completion: @escaping @Sendable (Result<T, Error>) -> Void
    ) {
        let once = Once(completion)
        DispatchQueue.global(qos: .userInitiated).async {
            once.finish(Result { try work() })
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout.seconds) {
            once.finish(.failure(FolderNavigationError.timedOut))
        }
    }

    static func run<T: Sendable>(timeout: Duration, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            start(timeout: timeout, work) { continuation.resume(with: $0) }
        }
    }

    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var completion: (@Sendable (Result<T, Error>) -> Void)?

        init(_ completion: @escaping @Sendable (Result<T, Error>) -> Void) { self.completion = completion }

        func finish(_ result: Result<T, Error>) {
            let taken = lock.withLock { () -> (@Sendable (Result<T, Error>) -> Void)? in
                defer { completion = nil }
                return completion
            }
            taken?(result)
        }
    }
}

extension Duration {
    var seconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
