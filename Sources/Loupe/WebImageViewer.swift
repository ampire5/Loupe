import CoreGraphics
import Foundation
import LoupeCore

/// Owns one viewer's position and pending advance. The underlying query survives a trip back to Home.
@MainActor final class WebImageViewer {
    typealias PreviewLoader = @Sendable (URL, ReadPriority) async throws -> CGImage?
    typealias OriginalLoader = @Sendable (URL, Int, Int) async -> Void

    let search: WebImageSearch
    private let loadPreview: PreviewLoader
    private let loadOriginal: OriginalLoader
    private(set) var files: [URL] = []
    private(set) var current: URL?
    private(set) var preview: CGImage?
    private var previewTask: Task<Void, Never>?
    private var prewarmTask: Task<Void, Never>?
    private var warmingOriginals: [URL: Task<Void, Never>] = [:]
    private var originalPlan: [URL] = []
    private var originalConcurrency = 1
    private var pendingOriginals: ArraySlice<URL> = []
    private var pageTask: Task<Void, Never>?
    private var pendingAdvance: URL?
    private var lastPrefetch: URL?
    var result: WebImageResult? { current.flatMap { url in indices[url].map { search.results[$0] } } }
    private var indices: [URL: Int] = [:]

    init(search: WebImageSearch, loadPreview: @escaping PreviewLoader = WebImageFiles.preview,
         loadOriginal: @escaping OriginalLoader = {
             await WebImageFiles.shared.preloadOriginal($0, retainingCount: $1, concurrency: $2)
         }) {
        self.search = search
        self.loadPreview = loadPreview
        self.loadOriginal = loadOriginal
        appendFiles()
    }

    func identity(for result: WebImageResult) -> URL {
        WebImageLocation.url(for: result.originalURL, thumbnail: result.thumbnailURL, in: search.id)
    }

    func appendFiles() {
        let count = files.count
        for index in count..<search.results.count {
            let url = identity(for: search.results[index])
            files.append(url)
            indices[url] = index
        }
    }

    func show(_ url: URL, previewChanged: @escaping () -> Void) {
        guard current != url else { return }
        cancelAdvance()
        stopOriginalPrefetch(keeping: WebImageLocation.original(in: url))
        current = url
        preview = nil
        previewTask?.cancel()
        prewarmTask?.cancel()
        previewTask = nil
        prewarmTask = nil
        guard let index = indices[url] else { return }
        let thumbnail = search.results[index].thumbnailURL
        if let thumbnail {
            previewTask = Task(priority: .userInitiated) { [weak self, loadPreview] in
                let picture = try? await loadPreview(thumbnail, ReadPriority(0))
                guard !Task.isCancelled, let self, current == url else { return }
                preview = picture
                previewChanged()
            }
        }

        let adjacent = neighbors(of: index).compactMap(\.thumbnailURL)
        guard !adjacent.isEmpty else { return }
        let currentPreview = previewTask
        prewarmTask = Task(priority: .utility) { [loadPreview] in
            await currentPreview?.value
            let priority = ReadPriority(ReadPriority.background, isBackground: true)
            var requested = Set<URL>()
            if let thumbnail { requested.insert(thumbnail) }
            for neighbor in adjacent where requested.insert(neighbor).inserted {
                guard !Task.isCancelled else { return }
                _ = try? await loadPreview(neighbor, priority)
            }
        }
    }

    func updateOriginalPrefetch(enabled: Bool, currentReady: Bool, depth: Int = 1, concurrency: Int = 1) {
        guard enabled else {
            stopOriginalPrefetch()
            return
        }
        guard currentReady, let current, let index = indices[current] else { return }
        let depth = WebImagesPreferences.boundedOriginalPrefetchDepth(depth)
        let concurrency = WebImagesPreferences.boundedOriginalPrefetchConcurrency(concurrency)
        let plan = neighbors(of: index, depth: depth).map(\.originalURL)
        guard plan != originalPlan || concurrency != originalConcurrency else { return }
        originalPlan = plan
        originalConcurrency = concurrency

        // Keep a transfer for the selected original even when the settings shrink the background plan.
        let selected = search.results[index].originalURL
        let selectedInFlight = warmingOriginals[selected] != nil
        let warmSlots = concurrency - (selectedInFlight ? 1 : 0)
        var keep = Set(plan.lazy.filter { self.warmingOriginals[$0] != nil }.prefix(warmSlots))
        if selectedInFlight { keep.insert(selected) }
        cancelOriginalTransfers(except: keep)
        pendingOriginals = plan.filter { warmingOriginals[$0] == nil }[...]
        fillOriginalPrefetchSlots()
    }

    private func neighbors(of index: Int, depth: Int = 1) -> [WebImageResult] {
        (1...depth).flatMap { [index + $0, index - $0] }
            .compactMap { search.results.indices.contains($0) ? search.results[$0] : nil }
    }

    private func fillOriginalPrefetchSlots() {
        let retainingCount = originalPlan.count + 1
        let concurrency = originalConcurrency
        while warmingOriginals.count < concurrency, let url = pendingOriginals.popFirst() {
            warmingOriginals[url] = Task(priority: .utility) { [weak self, loadOriginal] in
                await loadOriginal(url, retainingCount, concurrency)
                guard !Task.isCancelled, let self else { return }
                warmingOriginals[url] = nil
                fillOriginalPrefetchSlots()
            }
        }
    }

    private func stopOriginalPrefetch(keeping selected: URL? = nil) {
        originalPlan = []
        pendingOriginals = []
        cancelOriginalTransfers(except: selected.map { [$0] } ?? [])
    }

    private func cancelOriginalTransfers(except keep: Set<URL>) {
        for url in Array(warmingOriginals.keys) where !keep.contains(url) {
            warmingOriginals.removeValue(forKey: url)?.cancel()
        }
    }

    func prefetch(near index: Int, completed: @escaping (URL?, String?) -> Void) {
        guard let current, current != lastPrefetch, index + 3 >= files.count else { return }
        lastPrefetch = current
        requestPage(retry: false, completed: completed)
    }

    func step(_ by: Int, atBoundary: Bool, completed: @escaping (URL?, String?) -> Void) -> Bool {
        cancelAdvance()
        guard by > 0, atBoundary, search.hasMore, let current else { return false }
        pendingAdvance = current
        requestPage(retry: search.error != nil, completed: completed)
        return true
    }

    func retry(completed: @escaping (URL?, String?) -> Void) {
        requestPage(retry: true, completed: completed)
    }

    func pause() {
        cancelAdvance()
        stopOriginalPrefetch()
        previewTask?.cancel()
        prewarmTask?.cancel()
        pageTask?.cancel()
        if pageTask != nil { search.cancel() }
        previewTask = nil
        prewarmTask = nil
        pageTask = nil
        current = nil
        lastPrefetch = nil
        preview = nil
    }

    private func cancelAdvance() { pendingAdvance = nil }

    private func requestPage(retry: Bool, completed: @escaping (URL?, String?) -> Void) {
        guard pageTask == nil, let task = search.loadNext(retry: retry) else { return }
        pageTask = Task { [weak self] in
            await task.value
            guard let self, !Task.isCancelled else { return }
            pageTask = nil
            let advance = pendingAdvance
            cancelAdvance()
            appendFiles()
            completed(advance == current ? advance : nil, search.error)
        }
    }
}
