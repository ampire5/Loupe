import CoreGraphics
import Darwin
import Foundation
import ImageIO
import os

/// Session-scoped identities keep temporary search results out of the file browser and its history.
public enum WebImageLocation {
    public static func url(for original: URL, thumbnail: URL? = nil, in search: UUID) -> URL {
        var components = URLComponents()
        components.scheme = "loupe-web-image"
        components.host = search.uuidString.lowercased()
        components.path = "/" + (original.lastPathComponent.isEmpty ? "Image" : original.lastPathComponent)
        components.queryItems = [.init(name: "original", value: original.absoluteString)]
        if let thumbnail { components.queryItems?.append(.init(name: "thumbnail", value: thumbnail.absoluteString)) }
        return components.url!
    }

    public static func original(in url: URL) -> URL? {
        resource("original", in: url)
    }

    public static func thumbnail(in url: URL) -> URL? { resource("thumbnail", in: url) }

    public static func owns(_ url: URL) -> Bool { url.scheme == "loupe-web-image" }

    private static func resource(_ key: String, in url: URL) -> URL? {
        guard owns(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let original = components.queryItems?.first(where: { $0.name == key })?.value
        else { return nil }
        return SearXNGClient.httpURL(original)
    }
}

public struct WebImageReader: FileReading {
    private let fallback: any FileReading

    public init(fallback: any FileReading) { self.fallback = fallback }

    public func read(_ url: URL, priority: ReadPriority) async throws -> FileBytes {
        guard let original = WebImageLocation.original(in: url) else { return try await fallback.read(url, priority: priority) }
        return try await WebImageFiles.shared.read(original, priority: priority)
    }

    public func readPrefix(_ url: URL, priority: ReadPriority, isEnough: @escaping @Sendable (Data) -> Bool) async throws -> FileBytes {
        guard WebImageLocation.original(in: url) != nil else {
            return try await fallback.readPrefix(url, priority: priority, isEnough: isEnough)
        }
        return try await read(url, priority: priority)
    }

    public func stamp(_ url: URL, priority: Int) async throws -> FileStamp {
        guard let original = WebImageLocation.original(in: url) else { return try await fallback.stamp(url, priority: priority) }
        return await WebImageFiles.shared.stamp(original)
    }

    public func stamp(_ url: URL, priority: ReadPriority, started: @escaping @Sendable () -> Void) async throws -> FileStamp {
        guard WebImageLocation.original(in: url) != nil else {
            return try await fallback.stamp(url, priority: priority, started: started)
        }
        started()
        return try await stamp(url, priority: priority.value)
    }
}

public actor WebImageFiles {
    public static let shared = WebImageFiles(limit: 64 * 1024 * 1024, capacity: 4)
    private static let previews = WebImageFiles(limit: 2 * 1024 * 1024, capacity: 24)

    public nonisolated static func preview(_ url: URL, priority: ReadPriority = ReadPriority(0)) async throws -> CGImage? {
        try await previews.decodePreview(url, priority: priority)
    }

    private func decodePreview(_ url: URL, priority: ReadPriority) async throws -> CGImage? {
        try Task.checkCancellation()
        if let picture = cached[url]?.preview {
            touch(url)
            return picture
        }
        let bytes = try await read(url, priority: priority)
        try Task.checkCancellation()
        // Another caller may already have decoded the same response while this one was suspended.
        if let picture = cached[url]?.preview { return picture }
        guard let source = CGImageSourceCreateWithData(bytes.data as CFData, nil) else { return nil }
        let picture = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
        cached[url]?.preview = picture
        return picture
    }

    private static let queueCapacity = 64
    private let session: URLSession
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Loupe-WebImages-" + UUID().uuidString)
    private let limit: Int
    private let capacity: Int
    private var cached: [URL: (file: URL, stamp: FileStamp, preview: CGImage?)] = [:]
    private var recent: [URL] = []
    private var active = 0
    private var closed = false
    private var waiters: [UUID: (priority: ReadPriority, ready: CheckedContinuation<Void, any Error>)] = [:]
    private var order: [UUID] = []
    private struct OriginalPreload {
        let id: UUID
        let task: Task<Void, Never>
        var wanted = true
        var readers: [UUID: CheckedContinuation<FileBytes, any Error>] = [:]
    }
    private var originalPreloads: [URL: OriginalPreload] = [:]

    private init(limit: Int, capacity: Int) {
        self.limit = limit
        self.capacity = capacity
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 90
        session = URLSession(configuration: config)
    }

    func stamp(_ url: URL) -> FileStamp { cached[url]?.stamp ?? .init(modified: .distantPast, size: 0) }

    func read(_ url: URL, priority: ReadPriority) async throws -> FileBytes {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        if let bytes = try existing(url) { return bytes }
        if let loading = originalPreloads[url], !loading.task.isCancelled {
            do { return try await joinOriginalPreload(url, id: loading.id) }
            catch { try Task.checkCancellation() }
        }
        try await acquire(priority)
        defer { release() }
        try Task.checkCancellation()
        if let bytes = try existing(url) { return bytes }
        return try await download(url, retainingCount: capacity)
    }

    /// Speculation uses its own slots, starting only when no on-screen download is in progress.
    /// On-screen reads can join one of those transfers or start in the regular pool immediately.
    public func preloadOriginal(_ url: URL, retainingCount: Int, concurrency: Int) async {
        let concurrency = WebImagesPreferences.boundedOriginalPrefetchConcurrency(concurrency)
        guard !Task.isCancelled, !closed, active == 0, cached[url] == nil, originalPreloads[url] == nil,
              originalPreloads.count < concurrency, originalPreloads.values.allSatisfy({ $0.readers.isEmpty })
        else { return }
        let maxOriginals = 1 + 2 * WebImagesPreferences.originalPrefetchDepthRange.upperBound
        let retainingCount = min(maxOriginals, max(capacity, retainingCount))
        let id = UUID()
        let task = Task(priority: .utility) {
            let result: Result<FileBytes, any Error>
            do {
                try Task.checkCancellation()
                result = .success(try await download(url, retainingCount: retainingCount))
            } catch {
                result = .failure(error)
            }
            let readers = originalPreloads.removeValue(forKey: url)?.readers.values
            readers?.forEach { $0.resume(with: result) }
        }
        originalPreloads[url] = OriginalPreload(id: id, task: task)
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.endOriginalPreload(url, id: id) }
        }
    }

    private func joinOriginalPreload(_ url: URL, id: UUID) async throws -> FileBytes {
        let reader = UUID()
        let bytes = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (ready: CheckedContinuation<FileBytes, any Error>) in
                guard !Task.isCancelled, originalPreloads[url]?.id == id, originalPreloads[url]?.task.isCancelled == false else {
                    ready.resume(throwing: CancellationError())
                    return
                }
                guard (originalPreloads[url]?.readers.count ?? 0) < Self.queueCapacity else {
                    ready.resume(throwing: FileError.busy)
                    return
                }
                originalPreloads[url]?.readers[reader] = ready
            }
        } onCancel: {
            Task { await self.cancelOriginalReader(reader, url: url, id: id) }
        }
        try Task.checkCancellation()
        return bytes
    }

    private func endOriginalPreload(_ url: URL, id: UUID) {
        guard originalPreloads[url]?.id == id else { return }
        originalPreloads[url]?.wanted = false
        cancelUnusedOriginalPreload(url)
    }

    private func cancelOriginalReader(_ reader: UUID, url: URL, id: UUID) {
        guard originalPreloads[url]?.id == id else { return }
        originalPreloads[url]?.readers.removeValue(forKey: reader)?.resume(throwing: CancellationError())
        cancelUnusedOriginalPreload(url)
    }

    private func cancelUnusedOriginalPreload(_ url: URL) {
        if let loading = originalPreloads[url], !loading.wanted, loading.readers.isEmpty { loading.task.cancel() }
    }

    private func download(_ url: URL, retainingCount: Int) async throws -> FileBytes {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        let limiter = DownloadLimit(bytes: limit)
        let temporary: URL
        let response: URLResponse
        do { (temporary, response) = try await session.download(for: request, delegate: limiter) }
        catch {
            try Task.checkCancellation()
            if limiter.exceededLimit { throw FileError.invalidSize(limit) }
            throw FileError.transport(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FileError.downloadFailed((response as? HTTPURLResponse)?.statusCode)
        }
        let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= limit else { throw FileError.invalidSize(limit) }
        if let bytes = try existing(url) { return bytes }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent(UUID().uuidString)
        try manager.moveItem(at: temporary, to: file)
        let stamp = FileStamp(modified: .distantPast, size: size)
        cached[url] = (file, stamp, nil)
        recent.append(url)
        // A bounded temporary working set. The decoder can retain its own mapped bytes independently.
        while recent.count > retainingCount {
            if let old = cached.removeValue(forKey: recent.removeFirst()) {
                try? manager.removeItem(at: old.file)
            }
        }
        return FileBytes(data: try Data(contentsOf: file, options: .mappedIfSafe), stamp: stamp)
    }

    /// Stage on the destination volume, then publish with an exclusive rename.
    public func save(_ url: URL, bytes: Data?, to folder: URL) throws -> URL {
        guard let data = try bytes ?? existing(url)?.data else { throw FileError.originalUnavailable }
        return try Self.save(data, named: url.lastPathComponent, to: folder)
    }

    nonisolated static func save(_ data: Data, named name: String, to folder: URL) throws -> URL {
        let manager = FileManager.default
        guard folder.isFileURL, (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw FileError.missingDestination
        }
        let leaf = (name as NSString).lastPathComponent.replacingOccurrences(of: ":", with: "_")
        let safeName = ["", ".", "..", "/"].contains(leaf) ? "Image" : leaf
        let ext = (safeName as NSString).pathExtension
        let stem = (safeName as NSString).deletingPathExtension
        let staged = folder.appendingPathComponent(".loupe-" + UUID().uuidString)
        defer { try? manager.removeItem(at: staged) }
        try data.write(to: staged, options: [.withoutOverwriting])
        for index in 1...10_000 {
            let numbered = index == 1 ? safeName : "\(stem) \(index)" + (ext.isEmpty ? "" : "." + ext)
            let destination = folder.appendingPathComponent(numbered)
            let result = staged.withUnsafeFileSystemRepresentation { source in
                destination.withUnsafeFileSystemRepresentation { target in renamex_np(source, target, UInt32(RENAME_EXCL)) }
            }
            if result == 0 { return destination }
            let code = errno
            if code != EEXIST {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: destination.path])
            }
        }
        throw FileError.nameUnavailable
    }

    public nonisolated static func clearTemporaryFiles() async {
        async let originals: Void = shared.close()
        async let thumbnails: Void = previews.close()
        _ = await (originals, thumbnails)
    }

    private func close() {
        closed = true
        originalPreloads.values.forEach { $0.task.cancel() }
        session.invalidateAndCancel()
        for waiter in waiters.values { waiter.ready.resume(throwing: CancellationError()) }
        waiters.removeAll()
        order.removeAll()
        cached.removeAll()
        recent.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }

    private func existing(_ url: URL) throws -> FileBytes? {
        guard let (file, stamp, _) = cached[url] else { return nil }
        do {
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            touch(url)
            return FileBytes(data: data, stamp: stamp)
        } catch {
            cached.removeValue(forKey: url)
            recent.removeAll { $0 == url }
            try? FileManager.default.removeItem(at: file)
            return nil
        }
    }

    private func touch(_ url: URL) {
        recent.removeAll { $0 == url }
        recent.append(url)
    }

    private func canStart(_ priority: ReadPriority) -> Bool {
        // Only an idle pool starts speculative work, leaving the second slot open for a visible request.
        active < 2 && (!priority.isBackground || active == 0)
    }

    private func acquire(_ priority: ReadPriority) async throws {
        guard !closed else { throw CancellationError() }
        if canStart(priority) { active += 1; return }
        guard order.count < Self.queueCapacity else { throw FileError.busy }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { ready in
                waiters[id] = (priority, ready)
                order.append(id)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        order.removeAll { $0 == id }
        waiters.removeValue(forKey: id)?.ready.resume(throwing: CancellationError())
    }

    private func release() {
        active -= 1
        let eligible = order.indices.filter { index in
            waiters[order[index]].map { canStart($0.priority) } ?? false
        }
        if let next = eligible.min(by: {
            (waiters[order[$0]]?.priority.value ?? Int.max) < (waiters[order[$1]]?.priority.value ?? Int.max)
        }), let waiter = waiters.removeValue(forKey: order.remove(at: next)) {
            active += 1
            waiter.ready.resume()
        }
    }

    enum FileError: LocalizedError, Equatable {
        case downloadFailed(Int?), invalidSize(Int), transport(String), missingDestination, nameUnavailable, busy, originalUnavailable

        var errorDescription: String? {
            switch self {
            case .transport(let message): message
            case .downloadFailed(let code): code.map { "Image download returned HTTP \($0)." } ?? "Image download failed."
            case .invalidSize(let limit): "The image download was empty or exceeded \(limit / (1024 * 1024)) MB."
            case .missingDestination: "Choose an accessible save folder in Web Images settings."
            case .nameUnavailable: "Could not find an unused filename."
            case .busy: "Image downloads are busy. Try again."
            case .originalUnavailable: "The original is no longer cached. Reopen the result and try again."
            }
        }
    }
}

private final class DownloadLimit: NSObject, URLSessionDownloadDelegate {
    private let bytes: Int64
    private let exceeded = OSAllocatedUnfairLock(initialState: false)
    var exceededLimit: Bool { exceeded.withLock { $0 } }

    init(bytes: Int) { self.bytes = Int64(bytes) }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > bytes || totalBytesExpectedToWrite > bytes {
            exceeded.withLock { $0 = true }
            downloadTask.cancel()
        }
    }
}
