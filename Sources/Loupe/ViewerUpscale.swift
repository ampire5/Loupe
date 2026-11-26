import Foundation
import LoupeCore
import LoupeRender

enum UpscaleLookahead {
    // The depth bounds playlist work, independent of the cache's measured byte limits.
    static let depths = 0...8

    static func urls(in files: [URL], from index: Int, direction: Int, depth: Int) -> [URL] {
        guard depth > 0, files.indices.contains(index) else { return [] }
        let step = direction < 0 ? -1 : 1
        return (1...min(depth, depths.upperBound)).compactMap {
            let next = index + $0 * step
            return files.indices.contains(next) ? files[next] : nil
        }
    }
}

private extension NeuralUpscaleModel {
    var savedIdentity: String { "loupe-v1-\(revision)-\(margin)-\(compute.rawValue)" }
}

extension Notification.Name {
    static let savedUpscaleChanged = Notification.Name("local.loupe.savedUpscaleChanged")
}

private struct UpscaleKey: Hashable, Sendable {
    let url: URL
    let modified: Date?
    let size: Int?
    let unidentifiedSource: UUID?
    let model: NeuralUpscaleModel
}

private enum UpscaleCacheKey: Hashable {
    case inferred(UpscaleKey)
    case saved(SavedUpscale)
}

/// One process-wide scheduler for foreground, explicit batch, and speculative lookahead work.
@MainActor private final class UpscaleService {
    static let shared = UpscaleService()

    // M4 Max, 36 GB: 4K → 8K used ~560 MiB peak in serial Core ML + PNG bench. A 4K → 8K
    // BGRA8 texture pyramid retains ~204 MiB with aprons. Allow that result and two such
    // results in the retained tier while we measure browsing with other viewer caches active.
    private let cacheLimit = 512 * 1024 * 1024
    private let resultLimit = 256 * 1024 * 1024
    private var pressureLimit: Int?
    private var cache = UpscaleResultCache<UpscaleCacheKey, NeuralUpscaleWorker.Result>()
    private lazy var worker = NeuralUpscaleWorker()
    private lazy var lookupWorker = NeuralUpscaleWorker()
    private var secondWorker: NeuralUpscaleWorker?
    private let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)

    private struct Request {
        enum Kind { case foreground, lookahead, batch }

        let cancellation: UpscaleCancellation
        let kind: Kind
        let work: (NeuralUpscaleWorker) async -> Void
        let discarded: () -> Void
    }

    private struct Running {
        let request: Request
        let task: Task<Void, Never>
    }

    private var pendingForeground: Request?
    private var pendingAhead: [Request] = []
    private var running: [Int: Running] = [:]
    private var pendingLookup: Request?
    private var runningLookup: Running?
    private var savingPreviews: [UpscaleKey: UpscaleCancellation] = [:]
    private var batch: Batch?

    private final class Batch {
        let urls: [URL]
        let cache: ImageCache<MetalPyramidLoader>
        let model: NeuralUpscaleModel
        let scale: Int
        let feedback: (String) -> Void
        var index = 0
        var saved = 0
        var skipped = 0
        var firstError: String?
        var folders: Set<String> = []
        var cancelled = false

        init(urls: [URL], cache: ImageCache<MetalPyramidLoader>, model: NeuralUpscaleModel, scale: Int,
             feedback: @escaping (String) -> Void) {
            self.urls = urls
            self.cache = cache
            self.model = model
            self.scale = scale
            self.feedback = feedback
        }
    }

    // Mac16,6, M4 Max with 10 performance cores and 36 GiB: two saving workers improved 1080p/4K aggregate
    // throughput without a material change in the main-actor timer. Three raised peak RSS and per-photo latency.
    // Keep one worker on unmeasured hardware classes and for lookahead backed only by the in-memory LRU.
    private let measuredBackgroundWorkers: Int = {
        #if arch(arm64)
        var model = [CChar](repeating: 0, count: 64)
        var size = model.count
        guard sysctlbyname("hw.model", &model, &size, nil, 0) == 0,
              String(decoding: model.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self) == "Mac16,6"
        else { return 1 }
        var cores: Int32 = 0
        size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.perflevel0.physicalcpu", &cores, &size, nil, 0) == 0, cores >= 10,
              ProcessInfo.processInfo.physicalMemory >= 36 * 1024 * 1024 * 1024 else { return 1 }
        return 2
        #else
        return 1
        #endif
    }()

    func lookaheadWorkers(autoSave: Bool, scale: Int, compute: NeuralUpscaleModel.Compute) -> Int {
        autoSave && scale == 2 && compute == .cpuAndGPU ? measuredBackgroundWorkers : 1
    }

    private init() {
        pressure.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.trimForPressure() }
        }
        pressure.resume()
    }

    private func trimForPressure() {
        let event = pressure.data
        if event.contains(.critical) { pressureLimit = resultLimit / 4 }
        else if event.contains(.warning) { pressureLimit = cacheLimit / 2 }
        else { pressureLimit = nil }
        cache.trim(to: pressureLimit ?? cacheLimit)
        if pressureLimit != nil {
            cancelBackground(includingSaves: true)
            secondWorker = nil
        }
        runNext()
    }

    func result(_ key: UpscaleKey) -> NeuralUpscaleWorker.Result? {
        if let inferred = cache.value(for: .inferred(key)) { return inferred }
        guard let modified = key.modified, let size = key.size, SavedUpscale.supports(key.url) else { return nil }
        let copy = SavedUpscale(source: key.url, stamp: .init(modified: modified, size: size))
        guard let saved = savedResult(copy), saved.savedModel == key.model.savedIdentity else { return nil }
        return saved
    }

    func previewWhileSaving(_ key: UpscaleKey) -> NeuralUpscaleWorker.Result? {
        guard savingPreviews[key] != nil else { return nil }
        return cache.value(for: .inferred(key))
    }

    func savedResult(_ copy: SavedUpscale) -> NeuralUpscaleWorker.Result? { cache.value(for: .saved(copy)) }

    func isRunningAhead(_ cancellation: UpscaleCancellation) -> Bool {
        running.values.contains { $0.request.kind == .lookahead && $0.request.cancellation === cancellation }
    }

    func cancel(_ cancellation: UpscaleCancellation) {
        // Once rendered, let the bounded worker finish committing the requested copy.
        guard !savingPreviews.values.contains(where: { $0 === cancellation }) else { return }
        cancellation.cancel()
        if pendingForeground?.cancellation === cancellation { pendingForeground = nil }
        if pendingLookup?.cancellation === cancellation { pendingLookup = nil }
        if runningLookup?.request.cancellation === cancellation { runningLookup?.task.cancel() }
        pendingAhead.removeAll { $0.cancellation === cancellation }
        running.values.first { $0.request.cancellation === cancellation }?.task.cancel()
    }

    func prepare(_ key: UpscaleKey, source: TiledImage, saving: NeuralUpscaleWorker.SaveRequest?,
                 cancellation: UpscaleCancellation,
                 completion: @escaping (Result<NeuralUpscaleWorker.Result, Error>) -> Void) {
        enqueue(cancellation, discarded: { completion(.failure(CancellationError())) }) { worker in
            do {
                let made = try await self.make(key, source: source, saving: saving, cancellation: cancellation,
                                               worker: worker)
                completion(.success(made))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func load(_ copy: SavedUpscale, size: PixelSize, cancellation: UpscaleCancellation,
              completion: @escaping (NeuralUpscaleWorker.Result?, Bool) -> Void) {
        let previous = pendingLookup
        pendingLookup = Request(cancellation: cancellation, kind: .foreground, work: { worker in
            let promoted = await worker.isPromoted(copy)
            guard !promoted, !Task.isCancelled else {
                completion(nil, promoted)
                return
            }
            let key = UpscaleCacheKey.saved(copy)
            if let cached = self.cache.value(for: key) {
                completion(cached, false)
                return
            }
            let limit = min(self.resultLimit, self.pressureLimit ?? self.resultLimit)
            let result = try? await worker.stored(copy, originalSize: size, limit: limit)
            if let result, !Task.isCancelled {
                let budget = self.pressureLimit ?? self.cacheLimit
                guard result.image.byteCount <= budget else {
                    completion(nil, false)
                    return
                }
                self.cache.insert(result, key: key, bytes: result.image.byteCount, limit: budget)
            }
            completion(result, false)
        }, discarded: { completion(nil, false) })
        previous?.cancellation.cancel()
        previous?.discarded()
        runLookup()
    }

    /// A saved result can be opened without interrupting inference for another photo.
    private func runLookup() {
        guard runningLookup == nil, let request = pendingLookup else { return }
        pendingLookup = nil
        let task = Task(priority: .utility) {
            await request.work(lookupWorker)
            runningLookup = nil
            runLookup()
        }
        runningLookup = Running(request: request, task: task)
    }

    func prepareAhead(_ url: URL, cache sourceCache: ImageCache<MetalPyramidLoader>,
                      model: NeuralUpscaleModel, scale: Int, autoSave: Bool,
                      budget: Int, keeping current: UpscaleCacheKey?, cancellation: UpscaleCancellation,
                      completion: @escaping (Int) -> Void) {
        enqueue(cancellation, ahead: true, discarded: { completion(0) }) { worker in
            do {
                let bytes = try await self.prepareAhead(url, cache: sourceCache, model: model, scale: scale,
                                                        autoSave: autoSave, budget: budget, keeping: current,
                                                        cancellation: cancellation, worker: worker)
                completion(bytes)
            } catch {
                completion(0)
            }
        }
    }

    private func prepareAhead(_ url: URL, cache sourceCache: ImageCache<MetalPyramidLoader>,
                              model: NeuralUpscaleModel, scale: Int, autoSave: Bool,
                              budget: Int, keeping current: UpscaleCacheKey?, cancellation: UpscaleCancellation,
                              worker: NeuralUpscaleWorker) async throws -> Int {
        guard pressureLimit == nil, budget > 0, PlaybackMedia.candidate(url) == nil,
              !WebImageLocation.owns(url) else { return 0 }
        let stamp = try await sourceCache.upscaleStamp(url)
        let key = UpscaleKey(url: url, modified: stamp.modified, size: stamp.size, unidentifiedSource: nil, model: model)
        if let cached = result(key), !autoSave || cached.savedCopy != nil || cached.saveError != nil {
            return cached.image.byteCount
        }
        let copy = SavedUpscale(source: url, stamp: stamp)
        if SavedUpscale.supports(url) {
            if await worker.isPromoted(copy) { return 0 }
            if await worker.hasStored(copy) { return 0 }
        }
        let limit = min(resultLimit, budget)
        let (source, orientation) = try await sourceCache.upscaleSource(url, stamp: stamp, factor: scale, limit: limit)
        let size = source.grid.imageSize
        guard let bytes = UpscaleGeometry.residentBytes(PixelSize(width: size.width * scale, height: size.height * scale)),
              bytes <= limit else { return 0 }
        let saving = autoSave && SavedUpscale.supports(url)
            ? NeuralUpscaleWorker.SaveRequest(copy: copy, orientation: orientation, model: model.savedIdentity) : nil
        return try await make(key, source: source, saving: saving, cancellation: cancellation,
                              worker: worker, keeping: current).image.byteCount
    }

    private func make(_ key: UpscaleKey, source: TiledImage, saving: NeuralUpscaleWorker.SaveRequest?,
                      cancellation: UpscaleCancellation, worker: NeuralUpscaleWorker,
                      keeping current: UpscaleCacheKey? = nil,
                      onBatchSave: ((SavedUpscale) -> Void)? = nil) async throws -> NeuralUpscaleWorker.Result {
        let isBatch = onBatchSave != nil
        try Task.checkCancellation()
        if !isBatch, let cached = result(key),
           saving == nil || cached.savedCopy == saving?.copy || cached.saveError != nil {
            return cached
        }
        defer {
            if savingPreviews[key] === cancellation { savingPreviews[key] = nil }
        }
        let made: NeuralUpscaleWorker.Result
        if let saving, let stored = try? await worker.stored(saving.copy, originalSize: source.grid.imageSize,
                                                            limit: resultLimit, matching: saving.model) {
            made = stored
        } else {
            made = try await worker.process(source, model: key.model, limit: min(resultLimit, pressureLimit ?? resultLimit),
                                            cancellation: cancellation, saving: saving) { preview in
                guard !isBatch, !Task.isCancelled, let saving else { return }
                let budget = self.pressureLimit ?? self.cacheLimit
                guard preview.image.byteCount <= budget else { return }
                self.savingPreviews[key] = cancellation
                if let current { _ = self.cache.value(for: current) }
                self.cache.insert(preview, key: .inferred(key), bytes: preview.image.byteCount, limit: budget)
                for viewer in UpscaleCatalog.shared.viewers.allObjects {
                    viewer.upscalePreviewReady(for: saving.copy.source)
                }
            }
            if let copy = made.savedCopy {
                await Settings.shared.thumbnails?.discardUpscaledCell(copy)
                if let onBatchSave { onBatchSave(copy) }
                else { NotificationCenter.default.post(name: .savedUpscaleChanged, object: copy.source) }
            }
        }
        // Batch results are on disk. Keep the viewer's in-memory results in its existing LRU.
        if isBatch {
            if made.savedCopy == nil { try Task.checkCancellation() }
            return made
        }
        try Task.checkCancellation()
        let limit = pressureLimit ?? cacheLimit
        guard made.image.byteCount <= limit else { throw NeuralUpscaleError.tooLarge }
        if let current { _ = cache.value(for: current) }
        let cacheKey = made.savedCopy.map(UpscaleCacheKey.saved) ?? .inferred(key)
        if made.savedCopy != nil { cache.removeValue(for: .inferred(key)) }
        cache.insert(made, key: cacheKey, bytes: made.image.byteCount, limit: limit)
        return made
    }

    func lookaheadBudget(keeping currentBytes: Int) -> Int {
        guard pressureLimit == nil else { return 0 }
        return max(0, cacheLimit - currentBytes)
    }

    var batchIsRunning: Bool { batch != nil }

    func startBatch(_ urls: [URL], cache: ImageCache<MetalPyramidLoader>, model: NeuralUpscaleModel, scale: Int,
                    feedback: @escaping (String) -> Void) {
        batch = Batch(urls: urls, cache: cache, model: model, scale: scale, feedback: feedback)
        feedback("Batch Upscale · \(urls.count) \(urls.count == 1 ? "image" : "images") queued")
        runNext()
    }

    func cancelBatch() {
        guard let batch else { return }
        batch.cancelled = true
        if let active = running.values.first(where: { $0.request.kind == .batch }) {
            active.request.cancellation.cancel()
            active.task.cancel()
        } else {
            finishBatch(batch)
            runNext()
        }
    }

    private func batchRequest(_ batch: Batch) -> Request {
        let url = batch.urls[batch.index]
        let cancellation = UpscaleCancellation()
        return Request(cancellation: cancellation, kind: .batch, work: { worker in
            do {
                if try await self.prepareBatchItem(url, batch: batch, cancellation: cancellation, worker: worker) {
                    batch.saved += 1
                } else {
                    batch.skipped += 1
                }
                batch.index += 1
            } catch {
                // Foreground inference or memory pressure interrupted this item. Keep its place in the batch.
                guard !Task.isCancelled else { return }
                if batch.firstError == nil { batch.firstError = "\(ArchivePath.shortName(url)) — \(error.localizedDescription)" }
                batch.index += 1
            }
        }, discarded: {})
    }

    private func prepareBatchItem(_ url: URL, batch: Batch, cancellation: UpscaleCancellation,
                                  worker: NeuralUpscaleWorker) async throws -> Bool {
        try Task.checkCancellation()
        let stamp = try await batch.cache.upscaleStamp(url)
        let copy = SavedUpscale(source: url, stamp: stamp)
        if await worker.isPromoted(copy) { return false }
        if await worker.hasStored(copy) { return false }
        let (source, orientation) = try await batch.cache.upscaleSource(url, stamp: stamp, factor: batch.scale, limit: resultLimit)
        let key = UpscaleKey(url: url, modified: stamp.modified, size: stamp.size, unidentifiedSource: nil, model: batch.model)
        let save = NeuralUpscaleWorker.SaveRequest(copy: copy, orientation: orientation, model: batch.model.savedIdentity)
        let result = try await make(key, source: source, saving: save, cancellation: cancellation, worker: worker,
                                    onBatchSave: { saved in
            batch.folders.insert(saved.source.deletingLastPathComponent().standardizedFileURL.path)
        })
        guard result.savedCopy != nil else { throw BatchSaveError(details: result.saveError) }
        return true
    }

    private struct BatchSaveError: LocalizedError {
        let details: String?
        var errorDescription: String? { details ?? "The upscale could not be saved." }
    }

    private func finishBatch(_ batch: Batch) {
        self.batch = nil
        if !batch.folders.isEmpty {
            NotificationCenter.default.post(name: .fileViewListingChanged, object: batch.folders)
        }
        let heading = batch.cancelled ? "Batch Upscale cancelled" : "Batch Upscale finished"
        var lines = ["\(heading) · \(batch.saved) saved · \(batch.skipped) skipped"]
        if let error = batch.firstError {
            lines.append("\(batch.index - batch.saved - batch.skipped) failed · \(error)")
        }
        batch.feedback(lines.joined(separator: "\n"))
    }

    private func enqueue(_ cancellation: UpscaleCancellation, ahead: Bool = false,
                         discarded: @escaping () -> Void, _ work: @escaping (NeuralUpscaleWorker) async -> Void) {
        let request = Request(cancellation: cancellation, kind: ahead ? .lookahead : .foreground,
                              work: work, discarded: discarded)
        if ahead {
            guard pendingForeground == nil, pendingAhead.count < measuredBackgroundWorkers else {
                discarded()
                return
            }
            pendingAhead.append(request)
        } else {
            let old = pendingForeground
            pendingForeground = request
            cancelBackground()
            old?.cancellation.cancel()
            old?.discarded()
        }
        runNext()
    }

    private func cancelBackground(includingSaves: Bool = false) {
        let discarded = pendingAhead
        pendingAhead.removeAll()
        for item in running.values where item.request.kind != .foreground {
            if !includingSaves, item.request.kind == .lookahead,
               savingPreviews.values.contains(where: { $0 === item.request.cancellation }) { continue }
            item.request.cancellation.cancel()
            item.task.cancel()
        }
        for item in discarded {
            item.cancellation.cancel()
            item.discarded()
        }
    }

    private func runNext() {
        if let batch, (batch.cancelled || batch.index == batch.urls.count),
           !running.values.contains(where: { $0.request.kind == .batch }) {
            finishBatch(batch)
        }
        if let next = pendingForeground {
            guard running.isEmpty else { return }
            pendingForeground = nil
            start(next, in: 0)
            return
        }
        if let batch, pressureLimit == nil {
            if running.isEmpty { start(batchRequest(batch), in: 0) }
            return
        }
        guard running.values.allSatisfy({ $0.request.kind == .lookahead }) else { return }
        for slot in 0..<measuredBackgroundWorkers where running[slot] == nil && !pendingAhead.isEmpty {
            start(pendingAhead.removeFirst(), in: slot)
        }
    }

    private func start(_ request: Request, in slot: Int) {
        let worker: NeuralUpscaleWorker
        if slot == 0 {
            worker = self.worker
        } else if let secondWorker {
            worker = secondWorker
        } else {
            worker = NeuralUpscaleWorker()
            secondWorker = worker
        }
        let task = Task(priority: .utility) {
            await request.work(worker)
            running[slot] = nil
            runNext()
        }
        running[slot] = Running(request: request, task: task)
    }
}

/// The model directory and parameter overrides are shared; each viewer can select its own model.
@MainActor private final class UpscaleCatalog {
    typealias Scale = NeuralUpscaleModel.Scale
    private struct Classification: Sendable {
        let model: NeuralUpscaleModel
        let scale: Scale
    }

    static let shared = UpscaleCatalog()
    private static let folderKey = "loupe.upscale-models-directory"
    private static let modelKey = "loupe.upscale-model"
    private static let scaleKey = "loupe.upscale-scale"
    private static let overridesKey = "loupe.upscale-model-overrides"

    private let preferences = UserDefaults.standard
    private var search: Task<Void, Never>?
    private var classifications: [URL: Classification] = [:]
    let viewers = NSHashTable<ViewerUpscale>.weakObjects()
    private(set) var models: [NeuralUpscaleModel] = []

    var scanning: Bool { search != nil }
    var directory: URL {
        preferences.string(forKey: Self.folderKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? NeuralUpscaleModel.defaultDirectory
    }
    var lastScale: Scale? {
        if let scale = Scale(rawValue: preferences.integer(forKey: Self.scaleKey)) { return scale }
        guard let legacyPath = preferences.string(forKey: Self.modelKey) else { return nil }
        return models.first { $0.url.path == legacyPath }.flatMap { classifications[$0.url]?.scale }
    }

    func setScale(_ scale: Scale) { preferences.set(scale.rawValue, forKey: Self.scaleKey) }

    func lastSelection(for scale: Scale) -> String? {
        preferences.string(forKey: "\(Self.modelKey)-\(scale.rawValue)") ?? preferences.string(forKey: Self.modelKey)
    }

    func select(_ url: URL, for scale: Scale) {
        preferences.set(url.path, forKey: "\(Self.modelKey)-\(scale.rawValue)")
    }

    func models(for scale: Scale) -> [NeuralUpscaleModel] {
        models.filter { classifications[$0.url]?.scale == scale }
    }

    var firstAvailableScale: Scale? { Scale.allCases.first { !models(for: $0).isEmpty } }

    func setDirectory(_ directory: URL) {
        guard directory.standardizedFileURL != self.directory.standardizedFileURL else { reload(); return }
        preferences.set(directory.standardizedFileURL.path, forKey: Self.folderKey)
        models = []
        classifications = [:]
        reload()
        notify()
    }

    func setParameters(_ model: NeuralUpscaleModel, margin: Int, compute: NeuralUpscaleModel.Compute) {
        guard let index = models.firstIndex(of: model), (0...1023).contains(margin),
              model.margin != margin || model.compute != compute else { return }
        var overrides = self.overrides
        overrides[model.url.path] = ["margin": String(margin), "compute": compute.rawValue]
        preferences.set(overrides, forKey: Self.overridesKey)
        models[index].margin = margin
        models[index].compute = compute
        notify()
    }

    private var overrides: [String: [String: String]] {
        preferences.dictionary(forKey: Self.overridesKey) as? [String: [String: String]] ?? [:]
    }

    func reload() {
        guard search == nil else { return }
        let directory = directory
        let previous = classifications
        search = Task {
            let entries = await Task.detached(priority: .utility) {
                var entries: [Classification] = []
                for model in NeuralUpscaleModel.scan(directory) {
                    let cached = previous[model.url]
                    if let cached, cached.model.revision == model.revision {
                        entries.append(cached)
                    } else if let scale = try? await model.nativeScale() {
                        entries.append(Classification(model: model, scale: scale))
                    }
                }
                return entries
            }.value
            search = nil
            guard directory == self.directory else { reload(); return }
            classifications = Dictionary(uniqueKeysWithValues: entries.map { ($0.model.url, $0) })
            let overrides = self.overrides
            models = entries.map { entry in
                var item = entry.model
                guard let values = overrides[item.url.path] else { return item }
                if let margin = values["margin"].flatMap(Int.init) { item.margin = margin }
                if let compute = values["compute"].flatMap(NeuralUpscaleModel.Compute.init(rawValue:)) { item.compute = compute }
                return item
            }
            notify()
        }
    }

    func loadIfNeeded() async {
        if models.isEmpty { reload() }
        await search?.value
    }

    private func notify() { viewers.allObjects.forEach { $0.catalogChanged() } }
}

@MainActor final class ViewerUpscale {
    typealias Scale = NeuralUpscaleModel.Scale
    private let catalog = UpscaleCatalog.shared
    private var dwell: Task<Void, Never>?
    private var cancellation: UpscaleCancellation?
    private var sourceWithoutStamp: (ObjectIdentifier, UUID)?
    private var requested: UpscaleKey?
    private weak var resultImage: TiledImage?
    private var resultScale: Int?
    private var resultMilliseconds: Int?
    private var reason: String?
    private var storedScope: SavedUpscale?
    private var storedPromoted = false
    private var storedWork: UpscaleCancellation?
    private struct StoredResult {
        weak var image: TiledImage?
        let copy: SavedUpscale
        let model: String?
        let scale: Int
        let milliseconds: Int?
        init?(_ result: NeuralUpscaleWorker.Result) {
            guard let copy = result.savedCopy else { return nil }
            image = result.image
            self.copy = copy
            model = result.savedModel
            scale = result.scale
            milliseconds = result.upscaleMilliseconds
        }
    }

    private var storedResult: StoredResult?
    private var rebuildStoredForCurrentPhoto = false
    private var currentURL: URL?
    private var lookaheadNotBefore = ContinuousClock.now
    private var adoptedWork: UpscaleCancellation?
    private var aheadURLs: [URL] = []
    private var aheadIndex = 0
    private var aheadDwell: Task<Void, Never>?
    private var aheadBytes = 0
    private var aheadWork: [URL: UpscaleCancellation] = [:]

    var storedImage: TiledImage? { storedResult?.image }
    var storedCopy: SavedUpscale? { storedResult?.copy }

    private static let lookaheadKey = "loupe.upscale-lookahead"
    private static let autoSaveKey = "loupe.upscale-auto-save"
    private static var batchSetup: Task<Void, Never>?
    static let enabledDefaultKey = "loupe.upscale-enabled-by-default"

    var lookaheadDepth: Int {
        min(max(0, UserDefaults.standard.integer(forKey: Self.lookaheadKey)), UpscaleLookahead.depths.upperBound)
    }
    var autoSave: Bool { UserDefaults.standard.object(forKey: Self.autoSaveKey) as? Bool ?? true }

    func setLookaheadDepth(_ value: Int) {
        guard UpscaleLookahead.depths.contains(value), value != lookaheadDepth else { return }
        UserDefaults.standard.set(value, forKey: Self.lookaheadKey)
        for viewer in catalog.viewers.allObjects {
            viewer.resetLookahead()
            viewer.onCatalogChange?()
            viewer.onChange?()
        }
    }

    func setAutoSave(_ enabled: Bool) {
        guard autoSave != enabled else { return }
        UserDefaults.standard.set(enabled, forKey: Self.autoSaveKey)
        for viewer in catalog.viewers.allObjects {
            viewer.cancelAdoptedWork()
            viewer.resetLookahead()
            viewer.resetRequest()
            viewer.onCatalogChange?()
            viewer.onChange?()
        }
    }

    private var waitingForPixels = false
    private(set) var isEnabled = UserDefaults.standard.bool(forKey: ViewerUpscale.enabledDefaultKey)
    private(set) var showsOriginal = false
    private(set) var selected: NeuralUpscaleModel?
    private var chosenScale: Scale?
    private var preferredPaths: [Scale: String] = [:]
    var scale: Scale { chosenScale ?? .double }
    var models: [NeuralUpscaleModel] { catalog.models(for: scale) }
    var scanning: Bool { catalog.scanning }
    var directory: URL { catalog.directory }
    var onChange: (() -> Void)?
    var onCatalogChange: (() -> Void)?
    var onStoredChange: (() -> Void)?
    var onComparisonChange: (() -> Void)?

    func saveModeAsDefault() {
        UserDefaults.standard.set(isEnabled, forKey: Self.enabledDefaultKey)
    }

    func setShowsOriginal(_ show: Bool) {
        guard show != showsOriginal else { return }
        showsOriginal = show
        onComparisonChange?()
        onChange?()
    }

    var status: String? {
        if showsOriginal { return "Original" }
        if let reason, isEnabled { return reason }
        if storedPromoted, isEnabled { return "Upscale replaced the original" }
        if let storedResult, storedImage != nil, !isEnabled || !rebuildStoredForCurrentPhoto {
            return "Saved upscale · \(storedResult.scale)×"
        }
        guard isEnabled else { return nil }
        if resultImage != nil, let resultScale, let selected { return "\(selected.name) \(resultScale)×" }
        if adoptedWork != nil, let selected { return "\(selected.name) · Finishing lookahead…" }
        if requested != nil || waitingForPixels, let selected { return "\(selected.name) · Processing…" }
        if let storedResult { return "Saved upscale · \(storedResult.scale)×" }
        if scanning { return "Looking for upscale models…" }
        if selected == nil { return "Add a \(scale.title) model in the Neural Upscale slot" }
        return nil
    }

    func imageStatus(displaying image: TiledImage?, orientation: ImageOrientation) -> ImageStatus.Upscale? {
        if let image {
            let usesResult = image === resultImage
            if let factor = usesResult ? resultScale : storedResult?.scale {
                let timing = usesResult ? resultMilliseconds : storedResult?.milliseconds
                return .init(indicator: "Upscale \(factor)×", size: orientation.orientedSize(image.grid.imageSize),
                             milliseconds: isEnabled ? timing : nil, detail: status)
            }
        }
        if showsOriginal {
            return .init(indicator: "Original", milliseconds: isEnabled ? resultMilliseconds ?? storedResult?.milliseconds : nil)
        }
        guard isEnabled else { return nil }
        if adoptedWork != nil || waitingForPixels || (requested != nil && resultImage == nil && reason == nil) {
            return .init(indicator: "Upscaling…", detail: status)
        }
        if scanning { return .init(indicator: "Upscale…", detail: status) }
        if reason != nil || selected == nil { return .init(indicator: "Upscale unavailable", detail: status) }
        return .init(indicator: "Upscale on", detail: status)
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if !enabled {
            cancelAdoptedWork()
            rebuildStoredForCurrentPhoto = false
            resetLookahead()
            resetRequest()
        } else if selected == nil {
            reload()
        }
        onChange?()
    }

    init() {
        catalog.viewers.add(self)
        updateSelection()
        if isEnabled && selected == nil { reload() }
    }

    func setDirectory(_ directory: URL) { catalog.setDirectory(directory) }
    func reload() { catalog.reload() }

    static var batchIsRunning: Bool { batchSetup != nil || UpscaleService.shared.batchIsRunning }

    static func cancelBatch() {
        batchSetup?.cancel()
        UpscaleService.shared.cancelBatch()
    }

    func startBatch(_ urls: [URL], cache: ImageCache<MetalPyramidLoader>, feedback: @escaping (String) -> Void) {
        guard !urls.isEmpty else { return }
        guard !Self.batchIsRunning else {
            feedback("A batch upscale is already in progress")
            return
        }
        if let selected {
            UpscaleService.shared.startBatch(urls, cache: cache, model: selected, scale: scale.rawValue, feedback: feedback)
            return
        }
        feedback("Finding upscale models…")
        Self.batchSetup = Task {
            await catalog.loadIfNeeded()
            Self.batchSetup = nil
            guard !Task.isCancelled else {
                feedback("Batch Upscale cancelled")
                return
            }
            updateSelection()
            guard let selected else {
                feedback("Choose a Core ML model in the Neural Upscale slot")
                return
            }
            UpscaleService.shared.startBatch(urls, cache: cache, model: selected, scale: scale.rawValue, feedback: feedback)
        }
    }

    func setScale(_ scale: Scale) {
        guard chosenScale != scale else { return }
        cancelAdoptedWork()
        rebuildStoredForCurrentPhoto = isEnabled && storedScope != nil
        chosenScale = scale
        catalog.setScale(scale)
        catalogChanged()
    }

    func select(_ url: URL) {
        guard let item = models.first(where: { $0.url == url }), selected != item else { return }
        preferredPaths[scale] = url.path
        catalog.select(url, for: scale)
        selected = item
        cancelAdoptedWork()
        resetLookahead()
        rebuildStoredForCurrentPhoto = isEnabled && storedScope != nil
        resetRequest()
        onChange?()
        onCatalogChange?()
    }

    func setParameters(margin: Int, compute: NeuralUpscaleModel.Compute) {
        guard let selected, (0...1023).contains(margin),
              selected.margin != margin || selected.compute != compute else { return }
        rebuildStoredForCurrentPhoto = isEnabled && storedScope != nil
        catalog.setParameters(selected, margin: margin, compute: compute)
    }

    fileprivate func upscalePreviewReady(for url: URL) {
        if currentURL?.standardizedFileURL == url { onChange?() }
    }

    fileprivate func catalogChanged() {
        updateSelection()
        onCatalogChange?()
        if isEnabled { onChange?() }
    }

    private func updateSelection() {
        if chosenScale == nil { chosenScale = catalog.lastScale ?? catalog.firstAvailableScale }
        let preferred = preferredPaths[scale] ?? catalog.lastSelection(for: scale)
        let available = models
        let next = available.first { $0.url.path == preferred } ?? available.first
        if preferredPaths[scale] == nil { preferredPaths[scale] = next?.url.path }
        if selected != next {
            selected = next
            cancelAdoptedWork()
            resetLookahead()
            resetRequest()
        }
    }

    private func updateCurrent(_ url: URL?, mayAdopt: Bool) {
        if url != currentURL {
            cancelAdoptedWork()
            currentURL = url
            if showsOriginal {
                showsOriginal = false
                onComparisonChange?()
            }
            lookaheadNotBefore = .now + ViewerSession.dwellDelay
            if mayAdopt, let url, let token = aheadWork.removeValue(forKey: url) {
                if UpscaleService.shared.isRunningAhead(token) { adoptedWork = token }
                else { UpscaleService.shared.cancel(token) }
            }
            resetStored()
            resetRequest()
        } else if !mayAdopt {
            cancelAdoptedWork()
        }
    }

    private func cancelAdoptedWork() {
        if let adoptedWork { UpscaleService.shared.cancel(adoptedWork) }
        adoptedWork = nil
    }

    func update(entry: CacheEntryView<TiledImage>?, current: URL?,
                scale: Double, visible: Bool, active: Bool, excluded: Bool) -> TiledImage? {
        updateCurrent(current, mayAdopt: isEnabled && active && visible && !excluded)
        let enhanced = updateResult(entry: entry, current: current, scale: scale, visible: visible,
                                    active: active, excluded: excluded)
        return showsOriginal ? nil : enhanced
    }

    private func updateResult(entry: CacheEntryView<TiledImage>?, current: URL?, scale: Double,
                              visible: Bool, active: Bool, excluded: Bool) -> TiledImage? {
        let usable = visible && !excluded && entry?.url == current && entry?.pyramidIsSeeded == false
        if adoptedWork == nil, usable, let entry, let stamp = entry.sourceStamp, let info = entry.info, SavedUpscale.supports(entry.url) {
            let copy = SavedUpscale(source: entry.url, stamp: stamp)
            if active { updateStored(copy, size: info.pixelSize) }
            else if storedScope != copy || storedWork != nil { resetStored() }
        } else if adoptedWork == nil {
            resetStored()
        }
        guard isEnabled, visible, !storedPromoted, scale > 1 || autoSave || lookaheadDepth > 0, let selected, let entry, entry.url == current,
              let source = entry.pyramid, !entry.pyramidIsSeeded else {
            if requested != nil || waitingForPixels { resetRequest() }
            return storedImage
        }
        if excluded || source.hasAlpha {
            let message = excluded ? "Upscale is available for single photos" : "Upscale requires an opaque photo"
            if reason != message {
                resetRequest()
                reason = message
            }
            return nil
        }
        let stamp = entry.sourceStamp
        let identity = ObjectIdentifier(source)
        if stamp == nil, sourceWithoutStamp?.0 != identity { sourceWithoutStamp = (identity, UUID()) }
        let key = UpscaleKey(url: entry.url, modified: stamp?.modified, size: stamp?.size,
                             unidentifiedSource: stamp == nil ? sourceWithoutStamp?.1 : nil, model: selected)
        if let preview = UpscaleService.shared.previewWhileSaving(key) {
            resultImage = preview.image
            resultScale = preview.scale
            resultMilliseconds = preview.upscaleMilliseconds
            return preview.image
        }
        guard adoptedWork == nil else { return storedImage }
        if requested == key {
            if let resultImage { return resultImage }
            if reason != nil || (active && cancellation != nil) { return storedImage }
        }
        resetRequest()
        if let storedResult, let storedImage,
           !rebuildStoredForCurrentPhoto || storedResult.model == selected.savedIdentity {
            rebuildStoredForCurrentPhoto = false
            requested = key
            resultImage = storedImage
            resultScale = storedResult.scale
            resultMilliseconds = storedResult.milliseconds
            return storedImage
        }
        let saving: NeuralUpscaleWorker.SaveRequest?
        if autoSave, let storedScope, let info = entry.info {
            saving = .init(copy: storedScope, orientation: info.orientation, model: selected.savedIdentity)
        } else {
            saving = nil
        }
        if let hit = UpscaleService.shared.result(key),
           saving == nil || hit.savedCopy == saving?.copy || hit.saveError != nil {
            requested = key
            accept(hit)
            return hit.image
        }
        guard active, storedWork == nil else { return storedImage }
        guard source.finestResidentLevel == 0 else {
            waitingForPixels = true
            return storedImage
        }
        requested = key
        let token = UpscaleCancellation()
        cancellation = token
        dwell = Task { [weak self] in
            try? await Task.sleep(for: ViewerSession.dwellDelay)
            guard let self, !Task.isCancelled, cancellation === token else { return }
            dwell = nil
            UpscaleService.shared.prepare(key, source: source, saving: saving, cancellation: token) { [weak self] outcome in
                guard let self, cancellation === token else { return }
                cancellation = nil
                switch outcome {
                case .success(let made): accept(made)
                case .failure(is CancellationError): requested = nil
                case .failure(let error): reason = error.localizedDescription
                }
                onChange?()
            }
        }
        return storedImage
    }

    private func accept(_ result: NeuralUpscaleWorker.Result) {
        resultImage = result.image
        resultScale = result.scale
        resultMilliseconds = result.upscaleMilliseconds
        if let copy = result.savedCopy, copy == storedScope {
            rebuildStoredForCurrentPhoto = false
            storedResult = StoredResult(result)
            onStoredChange?()
        }
        if let error = result.saveError { reason = "Could not save upscale · \(error)" }
    }

    private func updateStored(_ copy: SavedUpscale, size: PixelSize) {
        guard storedScope != copy || (storedResult != nil && storedImage == nil) else { return }
        resetStored()
        resetRequest()
        storedScope = copy
        if let cached = UpscaleService.shared.savedResult(copy) {
            storedResult = StoredResult(cached)
            onStoredChange?()
            return
        }
        let token = UpscaleCancellation()
        storedWork = token
        UpscaleService.shared.load(copy, size: size, cancellation: token) { [weak self] result, promoted in
            guard let self, storedWork === token else { return }
            storedWork = nil
            storedPromoted = promoted
            storedResult = result.flatMap(StoredResult.init)
            onStoredChange?()
            onChange?()
        }
    }

    private func resetStored() {
        if let storedWork { UpscaleService.shared.cancel(storedWork) }
        storedWork = nil
        storedScope = nil
        rebuildStoredForCurrentPhoto = false
        storedPromoted = false
        if storedResult != nil {
            storedResult = nil
            onStoredChange?()
        }
    }

    func updateLookahead(_ urls: [URL], cache: ImageCache<MetalPyramidLoader>, eligible: Bool) {
        guard eligible, isEnabled, let selected else {
            resetLookahead()
            return
        }
        if urls != aheadURLs {
            aheadDwell?.cancel()
            aheadDwell = nil
            for url in aheadWork.keys.filter({ !urls.contains($0) }) {
                if let token = aheadWork.removeValue(forKey: url) { UpscaleService.shared.cancel(token) }
            }
            aheadURLs = urls
            aheadIndex = 0
            aheadBytes = 0
        }
        guard cancellation == nil, adoptedWork == nil, !waitingForPixels, storedWork == nil,
              resultImage != nil || storedImage != nil || reason != nil || storedPromoted,
              aheadDwell == nil, aheadURLs.indices.contains(aheadIndex) else { return }

        let remaining = ContinuousClock.now.duration(to: lookaheadNotBefore)
        if remaining > .zero {
            aheadDwell = Task { [weak self] in
                try? await Task.sleep(for: remaining)
                guard let self, !Task.isCancelled else { return }
                aheadDwell = nil
                updateLookahead(aheadURLs, cache: cache, eligible: true)
            }
            return
        }
        let service = UpscaleService.shared
        let parallelism = service.lookaheadWorkers(autoSave: autoSave, scale: scale.rawValue, compute: selected.compute)
        let currentBytes = resultImage?.byteCount ?? storedImage?.byteCount ?? 0
        let capacity = service.lookaheadBudget(keeping: currentBytes)
        // Persistent copies let a split batch finish even when its textures exceed the retained LRU budget.
        let budget = autoSave ? capacity : capacity - aheadBytes
        guard budget > 0 else { return }
        let keeping = resultImage === storedImage
            ? storedCopy.map(UpscaleCacheKey.saved) : requested.map(UpscaleCacheKey.inferred)
        while aheadWork.count < parallelism, aheadURLs.indices.contains(aheadIndex) {
            let url = aheadURLs[aheadIndex]
            aheadIndex += 1
            guard aheadWork[url] == nil else { continue }
            let token = UpscaleCancellation()
            aheadWork[url] = token
            service.prepareAhead(url, cache: cache, model: selected, scale: scale.rawValue,
                                 autoSave: autoSave, budget: budget, keeping: keeping, cancellation: token) { [weak self] bytes in
                guard let self else { return }
                if adoptedWork === token {
                    adoptedWork = nil
                    onChange?()
                    return
                }
                guard aheadWork[url] === token else { return }
                aheadWork[url] = nil
                aheadBytes += bytes
                updateLookahead(aheadURLs, cache: cache, eligible: true)
            }
        }
    }

    private func resetLookahead() {
        aheadDwell?.cancel()
        aheadDwell = nil
        for token in aheadWork.values { UpscaleService.shared.cancel(token) }
        aheadWork.removeAll()
        aheadURLs = []
        aheadIndex = 0
        aheadBytes = 0
    }

    func close() {
        catalog.viewers.remove(self)
        cancelAdoptedWork()
        resetLookahead()
        resetStored()
        resetRequest()
    }

    private func resetRequest() {
        dwell?.cancel()
        dwell = nil
        if let cancellation { UpscaleService.shared.cancel(cancellation) }
        cancellation = nil
        requested = nil
        resultImage = nil
        resultScale = nil
        resultMilliseconds = nil
        reason = nil
        waitingForPixels = false
    }
}
