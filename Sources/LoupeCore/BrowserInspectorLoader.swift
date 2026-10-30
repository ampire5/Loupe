import Foundation
import HomeScreenModel

/// One read in progress and one replaceable pending selection. Cancelling an awaiting task cannot interrupt
/// ImageIO or a share's synchronous read: keep that worker until it finishes, even across hide/show cycles.
@MainActor public final class BrowserInspectorLoader {
    public typealias Reader = @Sendable (BrowserEntry) async -> BrowserInspectorResult
    public var onChange: (() -> Void)?
    public private(set) var entry: BrowserEntry?
    public private(set) var result: BrowserInspectorResult?
    public private(set) var isReading = false
    public var content: BrowserInspectorContent { .make(entry: entry, result: result, pending: pending != nil || isReading && result == nil && isActive) }
    public var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            revision += 1
            if isActive { pending = entry; start() }
            else { pending = nil; result = nil }
            onChange?()
        }
    }

    private let reader: Reader
    private let settleDelay: Duration
    private var revision = 0
    private var pending: BrowserEntry?
    private var worker: Task<Void, Never>?
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
    // A selected-file cache only; previews come from ThumbnailStore, never full-sized pixels.
    // 24 × 160px RGBA previews ≈ 2.4 MB. UI/work-bound measurements: docs/bench/2026-10-29-file-inspector.md.
    private let capacity = 24

    public init(settleDelay: Duration = .milliseconds(120), reader: @escaping Reader = { entry in
        await Task.detached(priority: .utility) { BrowserInspectorResult.read(entry) }.value
    }) {
        self.settleDelay = settleDelay
        self.reader = reader
    }

    public func select(_ entry: BrowserEntry?) {
        guard entry != self.entry else { return }
        // Catalog facts can arrive while this file is being read. They enrich the immediate summary without
        // invalidating that read or dropping its completed metadata; only a changed identity/stamp starts over.
        if let previous = self.entry, let entry,
           previous.id == entry.id, previous.url == entry.url, previous.kind == entry.kind,
           previous.size == entry.size, previous.date == entry.date {
            self.entry = entry
            onChange?()
            return
        }
        self.entry = entry
        revision += 1
        result = nil
        pending = isActive ? entry : nil
        onChange?()
        start()
    }

    private func start() {
        guard worker == nil, isActive, pending != nil else { return }
        worker = Task { [weak self] in
            while let self, self.isActive, self.pending != nil {
                let settling = self.revision
                try? await Task.sleep(for: self.settleDelay)
                guard self.isActive else { break }
                if self.revision != settling { continue }
                guard let next = self.pending else { break }
                let token = self.revision
                self.pending = nil
                if let key = Key(next), let cached = self.cache[key] {
                    self.result = cached
                    self.order.removeAll { $0 == key }; self.order.append(key)
                    self.onChange?()
                    continue
                }
                guard next.isFile, next.url.isFileURL else {
                    self.onChange?()
                    continue
                }
                self.isReading = true
                let value = await self.reader(next)
                self.isReading = false
                if let key = Key(next), value.metadata.error == nil {
                    self.cache[key] = value
                    self.order.removeAll { $0 == key }; self.order.append(key)
                    while self.order.count > self.capacity { self.cache[self.order.removeFirst()] = nil }
                }
                if self.isActive, self.revision == token { self.result = value; self.onChange?() }
            }
            self?.worker = nil
        }
    }
}
