import AppKit
import Foundation
import Photos
import UniformTypeIdentifiers

public struct PhotosCollection: Sendable {
    public let id: String
    public let title: String
    public let isFolder: Bool
    public init(id: String, title: String, isFolder: Bool) { self.id = id; self.title = title; self.isFolder = isFolder }
}

public protocol PhotosChangeObservation: AnyObject, Sendable {}

/// Injectable library boundary: UI checks use synthetic albums without requesting a person's library access.
public protocol PhotosLibraryAccess: Sendable {
    func authorize() async throws
    func collections(in folder: String?) async throws -> [PhotosCollection]
    func assets(in album: String) async throws -> [PhotosAsset]
    func cover(in album: String) async throws -> URL?
    func thumbnail(_ url: URL, pixels: Int) async throws -> CGImage?
    func aspects(_ urls: [URL]) async throws -> [URL: Double]
    func observeChanges(_ changed: @escaping @Sendable () -> Void) -> any PhotosChangeObservation
}

public extension PhotosLibraryAccess {
    func aspects(_ urls: [URL]) async throws -> [URL: Double] { [:] }
}

public struct PhotosAsset: Sendable {
    public let id: String
    public let modified: Date
    public let created: Date?
    public let width: Int
    public let height: Int
    /// The source resource's original filename, including its actual extension. It is display metadata, not a path.
    public let filename: String

    public init(id: String, modified: Date, created: Date?, width: Int, height: Int, filename: String = "Photo") {
        self.id = id
        self.modified = modified
        self.created = created
        self.width = width
        self.height = height
        self.filename = filename.isEmpty ? "Photo" : filename.replacingOccurrences(of: "/", with: "∕")
    }

    public func url(in album: String) -> URL {
        PhotosLocation.assetURL(album: album, asset: id, revision: String(modified.timeIntervalSinceReferenceDate), filename: filename)
    }
}

public enum PhotosLibraryError: LocalizedError {
    case permission, missing, unavailable, busy
    public var errorDescription: String? {
        switch self {
        case .permission: "Allow Loupe to access Photos in System Settings → Privacy & Security → Photos, then try again."
        case .missing: "This album or photo is no longer available in Photos."
        case .unavailable: "The photo is not available locally. Open it to download it from iCloud."
        case .busy: "Photos is busy. Try again."
        }
    }
}

/// The only PhotoKit boundary. Metadata fetches are serial utility work; image requests are asynchronous,
/// cancellable and bounded independently of album size. No Photos database or library path is read directly.
public final class PhotosLibrary: PhotosLibraryAccess, @unchecked Sendable {
    public static let shared = PhotosLibrary()
    private let queue = DispatchQueue(label: "local.loupe.photos", qos: .utility)
    private let manager = PHCachingImageManager()
    private var assetNames = PhotosAssetNames()
    private var namedFetch: PHFetchResult<PHAsset>?
    private let selectedQueue = DispatchQueue(label: "local.loupe.photos.selected", qos: .userInitiated)
    // One selected-image request and one thumbnail request at a time. Full-image prefetch is disabled for Photos;
    // thumbnails use no network. Serial background work leaves cores for input and the existing renderer.
    // First-release bounds and the outstanding real-library validation are recorded in the bench document.
    private let current = PhotosRequestBudget()
    private let thumbs = PhotosRequestBudget()

    public static let nameCacheURL = URL.cachesDirectory.appendingPathComponent("local.loupe/Photos/names-v1.json")

    public init(nameCacheURL: URL? = PhotosLibrary.nameCacheURL) {
        assetNames = PhotosAssetNames(file: nameCacheURL)
    }

    public func authorize() async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        guard status == .authorized || status == .limited else { throw PhotosLibraryError.permission }
    }

    private func checkAuthorization() throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { throw PhotosLibraryError.permission }
    }

    private func metadata<T: Sendable>(on lane: DispatchQueue? = nil, _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await cancellableMetadata(on: lane) { _ in try body() }
    }

    private func cancellableMetadata<T: Sendable>(on lane: DispatchQueue? = nil,
        _ body: @escaping @Sendable (@escaping @Sendable () -> Bool) throws -> T) async throws -> T {
        let request = PhotosImageRequest<T>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                request.attach(continuation)
                (lane ?? queue).async {
                    guard !request.isFinished else { return }
                    do { request.finish(.success(try body { request.isFinished })) }
                    catch { request.finish(.failure(error)) }
                }
            }
        } onCancel: { request.cancel() }
    }

    public func collections(in folder: String?) async throws -> [PhotosCollection] {
        try await metadata { [self] in
            try checkAuthorization()
            let result: PHFetchResult<PHCollection>
            if let folder {
                guard let list = PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [folder], options: nil).firstObject
                else { throw PhotosLibraryError.missing }
                result = PHCollection.fetchCollections(in: list, options: nil)
            } else { result = PHCollectionList.fetchTopLevelUserCollections(with: nil) }
            var values: [PhotosCollection] = []
            result.enumerateObjects { item, _, _ in
                if let album = item as? PHAssetCollection, album.assetCollectionType != .album { return }
                values.append(PhotosCollection(id: item.localIdentifier, title: item.localizedTitle ?? "Untitled Album",
                                               isFolder: item is PHCollectionList))
            }
            return values
        }
    }

    public func assets(in album: String) async throws -> [PhotosAsset] {
        try await assets(in: album, firstOnly: false)
    }

    public func cover(in album: String) async throws -> URL? {
        try await assets(in: album, firstOnly: true).first?.url(in: album)
    }

    private func assets(in album: String, firstOnly: Bool) async throws -> [PhotosAsset] {
        try await cancellableMetadata { [self] cancelled in
            try checkAuthorization()
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
            if firstOnly { options.fetchLimit = 1 }
            let result: PHFetchResult<PHAsset>
            if album == PhotosLocation.library {
                // Fetch the library itself: unioning albums omits every image not assigned to an album.
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
                result = PHAsset.fetchAssets(with: .image, options: options)
            } else {
                guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [album], options: nil).firstObject
                else { throw PhotosLibraryError.missing }
                result = PHAsset.fetchAssets(in: collection, options: options)
            }
            var values: [PhotosAsset] = []
            var byID: [String: PHAsset] = [:]
            values.reserveCapacity(result.count)
            byID.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, stop in
                if cancelled() { stop.pointee = true; return }
                autoreleasepool {
                    byID[asset.localIdentifier] = asset
                    values.append(PhotosAsset(id: asset.localIdentifier, modified: asset.modificationDate ?? asset.creationDate ?? .distantPast,
                                              created: asset.creationDate, width: asset.pixelWidth, height: asset.pixelHeight))
                }
            }
            if cancelled() { throw CancellationError() }
            // Covers must not evict a collection's reusable names with a one-record snapshot.
            if firstOnly {
                return values.map { value in
                    PhotosAsset(id: value.id, modified: value.modified, created: value.created,
                                width: value.width, height: value.height,
                                filename: byID[value.id].map { Self.filename(of: $0) } ?? "Photo")
                }
            }
            let named = try assetNames.resolve(values, isLibrary: album == PhotosLocation.library, isCancelled: cancelled) { value in
                autoreleasepool { byID[value.id].map { Self.filename(of: $0) } ?? "Photo" }
            }
            namedFetch = result
            return named
        }
    }

    /// Resource descriptors are metadata only: no image download or private KVC filename lookup is needed.
    private static func filename(of asset: PHAsset) -> String {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .photo })
            ?? resources.first(where: { $0.type == .fullSizePhoto })
            ?? resources.first(where: { $0.type == .alternatePhoto }) else { return "Photo" }
        let name: String?
        if #available(macOS 27, *) { name = resource.filename }
        else { name = resource.originalFilename }
        if let name, !name.isEmpty { return name }
        return resource.contentType.preferredFilenameExtension.map { "Photo." + $0 } ?? "Photo"
    }

    public func aspects(_ urls: [URL]) async throws -> [URL: Double] {
        try await metadata { [self] in
            try checkAuthorization()
            var result: [URL: Double] = [:]
            // Bound each PhotoKit fetch and temporary object lifetime even for a very large album.
            for start in stride(from: 0, to: urls.count, by: 256) {
                autoreleasepool {
                    let batch = Array(urls[start..<min(start + 256, urls.count)])
                    let byID = Dictionary(batch.compactMap { url in PhotosLocation.asset(in: url).map { ($0, url) } },
                                          uniquingKeysWith: { a, _ in a })
                    PHAsset.fetchAssets(withLocalIdentifiers: Array(byID.keys), options: nil).enumerateObjects { asset, _, _ in
                        if let url = byID[asset.localIdentifier], asset.pixelHeight > 0 {
                            result[url] = Double(asset.pixelWidth) / Double(asset.pixelHeight)
                        }
                    }
                }
            }
            return result
        }
    }

    private func asset(_ url: URL, selected: Bool = false) async throws -> PHAsset {
        guard let id = PhotosLocation.asset(in: url) else { throw PhotosLibraryError.missing }
        return try await metadata(on: selected ? selectedQueue : nil) { [self] in
            try checkAuthorization()
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
            else { throw PhotosLibraryError.missing }
            return asset
        }
    }

    public func stamp(_ url: URL) async throws -> FileStamp {
        let asset = try await asset(url)
        // Byte size is unknown until PhotoKit supplies a rendition. Stamps must stay identical before and after
        // the read; only the asset revision is authoritative, not the encoded length of a particular rendition.
        return FileStamp(modified: asset.modificationDate ?? asset.creationDate ?? .distantPast, size: 0)
    }

    public func read(_ url: URL, priority: ReadPriority) async throws -> FileBytes {
        return try await current.run(rank: priority.value) { [self] in
            guard priority.isCurrent else { throw CancellationError() }
            let asset = try await asset(url, selected: true)
            guard priority.isCurrent else { throw CancellationError() }
            let options = PHImageRequestOptions()
            options.version = .current
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.progressHandler = { progress, _, stop, _ in
                priority.progress = progress
                if !priority.isCurrent { stop.pointee = true }
            }
            let request = PhotosImageRequest<Data>()
            if options.isNetworkAccessAllowed {
                priority.observeMoves { [weak request] in
                    if !priority.isCurrent { request?.cancel() }
                }
                if !priority.isCurrent { request.cancel() }
            }
            defer { priority.observeMoves {} }
            let manager = self.manager
            let data: Data = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    request.attach(continuation)
                    guard !request.isFinished else { return }
                    let id = manager.requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                        if let error = info?[PHImageErrorKey] as? Error { request.finish(.failure(error)) }
                        else if (info?[PHImageCancelledKey] as? Bool) == true { request.cancel() }
                        else if let data { request.finish(.success(data)) }
                        else { request.finish(.failure(PhotosLibraryError.unavailable)) }
                    }
                    request.onCancel { manager.cancelImageRequest(id) }
                }
            } onCancel: { request.cancel() }
            try Task.checkCancellation()
            return FileBytes(data: data, stamp: FileStamp(modified: asset.modificationDate ?? asset.creationDate ?? .distantPast, size: 0))
        }
    }

    public func thumbnail(_ url: URL, pixels: Int) async throws -> CGImage? {
        try await thumbs.run(rank: 0) { [self] in
            let asset = try await asset(url)
            let options = PHImageRequestOptions()
            options.version = .current
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false
            let request = PhotosImageRequest<CGImage?>()
            let manager = self.manager
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    request.attach(continuation)
                    queue.async {
                        guard !request.isFinished else { return }
                        let side = max(1, pixels)
                        let id = manager.requestImage(for: asset, targetSize: CGSize(width: side, height: side),
                                                      contentMode: .aspectFit, options: options) { image, info in
                            if (info?[PHImageCancelledKey] as? Bool) == true { request.cancel(); return }
                            if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                            if let error = info?[PHImageErrorKey] as? Error { request.finish(.failure(error)); return }
                            request.finish(.success(image?.cgImage(forProposedRect: nil, context: nil, hints: nil)))
                        }
                        request.onCancel { manager.cancelImageRequest(id) }
                    }
                }
            } onCancel: { request.cancel() }
        }
    }

    /// Own this token only while a browser or viewer needs updates; there is no polling or idle timer.
    public func observeChanges(_ changed: @escaping @Sendable () -> Void) -> any PhotosChangeObservation {
        PhotosLibraryObservation { [weak self] change in
            if let self {
                self.queue.async {
                    guard let fetch = self.namedFetch, let details = change.changeDetails(for: fetch) else { return }
                    if details.hasIncrementalChanges {
                        self.assetNames.invalidate(Set((details.changedObjects + details.removedObjects).map(\.localIdentifier)))
                    } else { self.assetNames.clear() }
                    self.namedFetch = details.fetchResultAfterChanges
                }
            }
            changed()
        }
    }
}

public final class PhotosLibraryObservation: NSObject, PHPhotoLibraryChangeObserver, PhotosChangeObservation, @unchecked Sendable {
    private let changed: @Sendable (PHChange) -> Void
    init(_ changed: @escaping @Sendable (PHChange) -> Void) {
        self.changed = changed
        super.init()
        PHPhotoLibrary.shared().register(self)
    }
    public func photoLibraryDidChange(_ changeInstance: PHChange) { changed(changeInstance) }
    deinit { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
}

/// One active request; a bounded, priority-ordered wait list. Cancellation removes queued requests immediately.
private actor PhotosRequestBudget {
    private struct Waiter { let id: UUID; let rank: Int; let continuation: CheckedContinuation<Void, Error> }
    private var running = false
    private var waiting: [Waiter] = []

    private func acquire(rank: Int) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                if !running { running = true; continuation.resume(); return }
                guard waiting.count < 128 else { continuation.resume(throwing: PhotosLibraryError.busy); return }
                waiting.append(Waiter(id: id, rank: rank, continuation: continuation))
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        guard let i = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: i).continuation.resume(throwing: CancellationError())
    }
    private func release() {
        guard !waiting.isEmpty else { running = false; return }
        let i = waiting.indices.min { waiting[$0].rank < waiting[$1].rank }!
        waiting.remove(at: i).continuation.resume()
    }
    func run<T: Sendable>(rank: Int, _ work: @Sendable () async throws -> T) async throws -> T {
        try await acquire(rank: rank)
        defer { release() }
        try Task.checkCancellation()
        return try await work()
    }
}
