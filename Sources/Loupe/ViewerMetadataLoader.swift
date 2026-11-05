import Foundation
import LoupeCore

/// One viewer inspector's selection and read lifetime. Presentation/hold/diagnostics belong to its controller.
/// Cancellation is checked after every suspension: even A → B → A must reject the first A's late result.
@MainActor final class ViewerMetadataLoader {
    typealias Stamp = (size: Int?, modified: Date?)
    typealias StatReader = @Sendable (URL) async -> Stamp
    typealias Reader = @Sendable (URL, Stamp) async -> PhotoMetadata

    private(set) var url: URL?
    private(set) var size: Int?
    private(set) var metadata: PhotoMetadata?
    private(set) var isPending = false
    /// false: file size changed; true: metadata/pending changed and presentation must refresh.
    var onChange: ((Bool) -> Void)?

    private let stamp: StatReader
    private let read: Reader
    private let pendingDelay: Duration
    private let pendingSleep: @Sendable (Duration) async throws -> Void
    private var readTask: Task<Void, Never>?
    private var pendingTask: Task<Void, Never>?
    /// Shared across windows and created only when a viewer panel first asks for metadata.
    private static let cache = PhotoMetadataCache()

    init(pendingDelay: Duration = .seconds(1), stamp: @escaping StatReader, read: @escaping Reader,
         pendingSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.pendingDelay = pendingDelay
        self.pendingSleep = pendingSleep
        self.stamp = stamp
        self.read = read
    }

    convenience init(thumbnails: ThumbnailStore) {
        self.init(stamp: { url in
            await Task.detached(priority: .utility) { Self.fileStamp(url) }.value
        }, read: { url, stamp in
            let version = stamp.size.flatMap { size in stamp.modified.map { FileStamp(modified: $0, size: size) } }
            if let version, let stored = await thumbnails.photoMetadata(for: url, stamp: version) { return stored }
            let result = await Self.cache.metadata(for: url, size: stamp.size ?? -1, modified: stamp.modified)
            if let version, result.modified == version.modified {
                await thumbnails.keepPhotoMetadata(result, for: url, stamp: version)
            }
            return result
        })
    }

    deinit { readTask?.cancel(); pendingTask?.cancel() }

    func select(_ url: URL?) {
        guard url != self.url else { return }
        stop()
        self.url = url
        guard let url, url.isFileURL else { return }
        let stamp = self.stamp, read = self.read
        readTask = Task { [weak self] in
            let version = await stamp(url)
            guard !Task.isCancelled, self?.url == url else { return }
            self?.size = version.size
            self?.onChange?(false)
            guard !Task.isCancelled, self?.url == url else { return }
            let result = await read(url, version)
            guard !Task.isCancelled, let self, self.url == url else { return }
            self.pendingTask?.cancel()
            self.pendingTask = nil
            self.readTask = nil
            self.metadata = result
            self.isPending = false
            self.onChange?(true)
        }
        let delay = pendingDelay, sleep = pendingSleep
        pendingTask = Task { [weak self] in
            try? await sleep(delay)
            guard !Task.isCancelled, let self, self.url == url, self.metadata == nil else { return }
            self.pendingTask = nil
            self.isPending = true
            self.onChange?(true)
        }
    }

    /// Stop publishing immediately; a synchronous filesystem/cache read may still finish off the main actor.
    func stop() {
        readTask?.cancel()
        pendingTask?.cancel()
        readTask = nil
        pendingTask = nil
        url = nil
        size = nil
        metadata = nil
        isPending = false
    }

    nonisolated private static func fileStamp(_ url: URL) -> Stamp {
        if ArchivePath.split(url) != nil {
            let stamp = try? ArchiveReader.shared.stamp(url)
            return (stamp?.size, stamp?.modified)
        }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return (values?.fileSize, values?.contentModificationDate)
    }
}
