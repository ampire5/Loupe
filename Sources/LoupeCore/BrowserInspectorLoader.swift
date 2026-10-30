import Foundation
import CoreGraphics
import HomeScreenModel

/// One catalog/source read in progress and one replaceable pending selection. Synchronous source work is allowed
/// to finish when hidden but cannot publish for another selection or spawn replacement reads in parallel.
@MainActor public final class BrowserInspectorLoader {
    public typealias Reader = @Sendable (BrowserEntry) async -> BrowserInspectorResult
    public typealias Catalog = @Sendable (BrowserEntry) async -> BrowserInspectorSeed?
    public var onChange: (() -> Void)?
    public private(set) var entry: BrowserEntry?
    public private(set) var result: BrowserInspectorResult?
    public private(set) var isReading = false
    public var thumbnail: CGImage? { result?.thumbnail ?? seedThumbnail }
    public var content: BrowserInspectorContent { .make(entry: entry, result: result, pending: isActive && entry != nil && result == nil && (pending != nil || isReading)) }
    public var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            revision += 1
            prepare()
            onChange?()
            start()
        }
    }

    private let reader: Reader
    private let catalog: Catalog?
    private let settleDelay: Duration
    private var revision = 0
    private var pending: BrowserEntry?
    private var worker: Task<Void, Never>?
    private var seedThumbnail: CGImage?
    private struct Key: Hashable {
        var url: URL
        var size: Int64
        var modified: Date
        init?(_ entry: BrowserEntry) {
            guard let size = entry.size, let date = entry.date else { return nil }
            url = entry.url; self.size = size; modified = date
        }
    }
    private var cache: [Key: BrowserInspectorResult] = [:]
    private var order: [Key] = []
    // 24 × 160px RGBA previews ≈ 2.4 MB; docs/bench/2026-10-29-file-inspector.md.
    private let capacity = 24

    public init(settleDelay: Duration = .milliseconds(120), catalog: Catalog? = nil, reader: @escaping Reader = { entry in
        await Task.detached(priority: .utility) { BrowserInspectorResult.read(entry) }.value
    }) {
        self.settleDelay = settleDelay; self.catalog = catalog; self.reader = reader
    }

    private func prepare() {
        seedThumbnail = nil
        result = nil
        pending = nil
        guard isActive, let entry else { return }
        if let key = Key(entry), let hit = cache[key] {
            result = hit
            order.removeAll { $0 == key }; order.append(key)
        } else { pending = entry }
    }

    public func select(_ entry: BrowserEntry?) {
        guard entry != self.entry else { return }
        if let previous = self.entry, let entry,
           previous.id == entry.id, previous.url == entry.url, previous.kind == entry.kind,
           previous.size == entry.size, previous.date == entry.date {
            // A source callback without facts must not erase an already delivered catalog seed.
            var enriched = entry
            enriched.facts = BrowserInspectorSeed.supplement(enriched.facts, with: previous.facts)
            self.entry = enriched
            onChange?()
            return
        }
        self.entry = entry
        revision += 1
        prepare()
        onChange?()
        start()
    }

    private func start() {
        guard worker == nil, isActive, pending != nil else { return }
        worker = Task { [weak self] in
            while let self, self.isActive, let next = self.pending {
                let token = self.revision
                self.pending = nil
                guard next.isFile, next.url.isFileURL else { self.onChange?(); continue }
                self.isReading = true
                // Catalog lookup does not wait for the source-read debounce. It never accesses the source file.
                let seed = await self.catalog?(next)
                if let seed, self.isActive, self.revision == token {
                    let currentFacts = self.entry?.facts
                    self.entry?.facts = BrowserInspectorSeed.supplement(currentFacts, with: seed.facts)
                    self.seedThumbnail = seed.thumbnail
                    self.onChange?()
                }
                if let metadata = seed?.metadata {
                    let value = BrowserInspectorResult(metadata: metadata, fileSize: next.size.flatMap(Int.init(exactly:)),
                                                       thumbnail: seed?.thumbnail)
                    self.isReading = false
                    self.remember(value, for: next)
                    if self.isActive, self.revision == token { self.result = value; self.onChange?() }
                    continue
                }
                try? await Task.sleep(for: self.settleDelay)
                guard self.isActive, self.revision == token else { self.isReading = false; continue }
                var value = await self.reader(next)
                value.thumbnail = value.thumbnail ?? seed?.thumbnail
                self.isReading = false
                self.remember(value, for: next)
                if self.isActive, self.revision == token { self.result = value; self.onChange?() }
            }
            self?.worker = nil
        }
    }
    private func remember(_ value: BrowserInspectorResult, for entry: BrowserEntry) {
        guard let key = Key(entry), value.metadata.error == nil else { return }
        cache[key] = value
        order.removeAll { $0 == key }; order.append(key)
        while order.count > capacity { cache[order.removeFirst()] = nil }
    }

}
