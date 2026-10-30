import Foundation

fileprivate final class FileViewAddress: @unchecked Sendable {
    let id = UUID()
    var url: URL // protected by FileViewHistory.lock
    init(_ url: URL) { self.url = url }
}

/// Persistent viewing history, deliberately separate from disposable thumbnail/metadata databases. New visits reserve
/// one of a bounded number of receipts before the renderer accepts them; a full writer asks the view to retry, never
/// blocks main or silently drops a successfully presented photo. No history rows are loaded at startup.
public final class FileViewHistory: @unchecked Sendable, PathMoving {
    public static let didChange = Notification.Name("LoupeFileViewHistoryDidChange")
    private let failureLog = WriteFailureLog()
    private let database: StateDatabase?
    private let queue = DispatchQueue(label: "loupe.file-views", qos: .utility)
    private let lock = NSLock()
    private let capacity: Int
    private var reserved = 0
    private var waiters: [UUID: @Sendable () -> Void] = [:]
    private var addresses: [UUID: FileViewAddress] = [:]
    private var pending: [(FileViewAddress, Date)] = []
    private var writing = false
    // Worker-only fallback for unavailable user-state storage. Healthy history remains in SQLite without eviction.
    private var persistent = true
    private var memory: [URL: Date] = [:]
    private var memoryOrder: [URL] = []

    public init(database: StateDatabase?, capacity: Int = 64) {
        self.database = database
        self.capacity = max(1, capacity)
    }
    public func presentation(for url: URL, client: UUID, visibility: FileViewVisibility? = nil,
                             retry: @escaping @Sendable () -> Void) -> FileViewReceipt? {
        presentations(for: [url], client: client, visibility: visibility, retry: retry)?.first
    }
    /// All-or-nothing admission for a spread, so a partial pair cannot retain a slot it can never present.
    public func presentations(for urls: [URL], client: UUID, visibility: FileViewVisibility? = nil,
                              retry: @escaping @Sendable () -> Void) -> [FileViewReceipt]? {
        lock.withLock {
            guard reserved + urls.count <= capacity else { waiters[client] = retry; return nil }
            waiters[client] = nil
            reserved += urls.count
            return urls.map { url in
                let address = FileViewAddress(url)
                addresses[address.id] = address
                return FileViewReceipt(history: self, address: address, visibility: visibility)
            }
        }
    }
    fileprivate func submit(_ address: FileViewAddress, at date: Date) {
        let start = lock.withLock { () -> Bool in
            pending.append((address, date))
            guard !writing else { return false }
            writing = true
            return true
        }
        if start { queue.async { [self] in drain() } }
    }
    fileprivate func release(_ ids: [UUID]) {
        let callbacks = lock.withLock { () -> [@Sendable () -> Void] in
            reserved -= ids.count
            for id in ids { addresses[id] = nil }
            let callbacks = Array(waiters.values)
            waiters.removeAll(keepingCapacity: true)
            return callbacks
        }
        callbacks.forEach { $0() }
    }
    private static func key(_ url: URL) -> String { url.isFileURL ? url.standardizedFileURL.path : url.absoluteString }
    private func drain() {
        while true {
            let requests = lock.withLock { () -> [(FileViewAddress, Date)] in
                guard !pending.isEmpty else { writing = false; return [] }
                let batch = pending
                pending.removeAll(keepingCapacity: true)
                return batch
            }
            guard !requests.isEmpty else { return }
            let batch = lock.withLock { requests.map { ($0.0.url, $0.1) } }
            for (url, date) in batch {
                memory[url] = max(memory[url] ?? date, date)
                memoryOrder.removeAll { $0 == url }; memoryOrder.append(url)
                if memoryOrder.count > 256 { memory[memoryOrder.removeFirst()] = nil }
            }
            if persistent, let database {
                do {
                    try database.perform { db in
                        try db.transaction {
                            for (url, date) in batch {
                                try db.run("""
                                    INSERT INTO file_views(path, viewed) VALUES(?, ?)
                                    ON CONFLICT(path) DO UPDATE SET viewed = MAX(file_views.viewed, excluded.viewed)
                                    """, [.text(Self.key(url)), .double(date.timeIntervalSinceReferenceDate)])
                            }
                        }
                    }
                } catch {
                    persistent = false
                    failureLog.failed(error)
                }
            }
            release(requests.map { $0.0.id })
            let dates = Dictionary(batch.map { ($0.0, memory[$0.0] ?? $0.1) }, uniquingKeysWith: max)
            DispatchQueue.main.async { [self] in
                NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: ["dates": dates])
            }
        }
    }
    /// Addressed reads only, on the existing serial utility worker. May be called from the main actor.
    public func lastViewed(_ urls: [URL]) async -> [URL: Date] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                var result: [URL: Date] = [:]
                for start in stride(from: 0, to: urls.count, by: 256) {
                    let chunk = Array(urls[start..<min(start + 256, urls.count)])
                    let byKey = Dictionary(chunk.map { (Self.key($0), $0) }, uniquingKeysWith: { a, _ in a })
                    if persistent, let database, let data = try? JSONEncoder().encode(Array(byKey.keys)),
                       let json = String(data: data, encoding: .utf8) {
                        do {
                            try database.perform { db in
                                try db.query("SELECT path, viewed FROM file_views WHERE path IN (SELECT value FROM json_each(?))", [.text(json)]) { row in
                                    if let url = byKey[row.text(0)] { result[url] = Date(timeIntervalSinceReferenceDate: row.double(1)) }
                                }
                            }
                        } catch { failureLog.failed(error) }
                    }
                    for url in chunk { if let cached = memory[url] { result[url] = max(result[url] ?? cached, cached) } }
                }
                continuation.resume(returning: result)
            }
        }
    }
    /// Explicit quit/test flush; normal presentation never waits for disk.
    public func flush() { queue.sync { drain() } }
    public func movePaths(from: URL, to: URL) {
        guard from.isFileURL, to.isFileURL else { return }
        let move = PathMove(from: from, to: to)
        lock.withLock {
            for address in addresses.values where address.url.isFileURL {
                if let path = move.moved(Self.key(address.url)) { address.url = URL(fileURLWithPath: path) }
            }
        }
        queue.async { [self] in
            let old = move.from, prefix = move.from + "/", new = move.to
            do {
                try database?.perform { db in
                    try db.transaction {
                        try db.run("""
                            INSERT INTO file_views(path, viewed)
                            SELECT ? || substr(path, ?), viewed FROM file_views
                            WHERE path = ? OR substr(path, 1, ?) = ?
                            ON CONFLICT(path) DO UPDATE SET viewed = MAX(file_views.viewed, excluded.viewed)
                            """, [.text(new), .int(Int64(old.unicodeScalars.count + 1)), .text(old), .int(Int64(prefix.unicodeScalars.count)), .text(prefix)])
                        try db.run("DELETE FROM file_views WHERE path = ? OR substr(path, 1, ?) = ?",
                                   [.text(old), .int(Int64(prefix.unicodeScalars.count)), .text(prefix)])
                    }
                }
                for url in Array(memory.keys) where url.isFileURL {
                    if let path = move.moved(Self.key(url)), let date = memory.removeValue(forKey: url) {
                        let replacement = URL(fileURLWithPath: path)
                        memory[replacement] = max(memory[replacement] ?? date, date)
                        memoryOrder = memoryOrder.map { $0 == url ? replacement : $0 }
                    }
                }
            } catch { failureLog.failed(error) }
        }
    }
}

/// Immutable visit identity shared by main, render and presentation threads. Refined/colour frames reuse it.
public final class FileViewReceipt: @unchecked Sendable {
    private let history: FileViewHistory
    private let address: FileViewAddress
    private let visibilityInterval: FileViewInterval?
    private let requiresVisibility: Bool
    private let lock = NSLock()
    private var submitted = false
    // Real-window macOS 27.2 bench dropped the first three drawables before confirming the image. Keep at most
    // 16 attempts (and stop as soon as one presents), instead of an unbounded redraw or a permanently lost first frame.
    private var redrawBudget = 16
    fileprivate init(history: FileViewHistory, address: FileViewAddress, visibility: FileViewVisibility?) {
        self.history = history; self.address = address
        self.visibilityInterval = visibility?.snapshot()
        self.requiresVisibility = visibility != nil
    }
    public var isPending: Bool { lock.withLock { !submitted } }
    public func requestPresentationRetry() -> Bool {
        lock.withLock {
            guard !submitted, redrawBudget > 0 else { return false }
            redrawBudget -= 1
            return true
        }
    }
    public func presented(at date: Date?) {
        guard let date, date.timeIntervalSinceReferenceDate.isFinite, (!requiresVisibility || visibilityInterval?.contains(date) == true) else { return }
        let first = lock.withLock { () -> Bool in
            guard !submitted else { return false }; submitted = true; return true
        }
        if first { history.submit(address, at: date) }
    }
    deinit { if !submitted { history.release([address.id]) } }
}

fileprivate final class FileViewInterval: @unchecked Sendable {
    private let lock = NSLock()
    private let start: Date
    private var end: Date?
    init(start: Date) { self.start = start }
    func close(at date: Date) { lock.withLock { if end == nil { end = date } } }
    var isOpen: Bool { lock.withLock { end == nil } }
    func contains(_ date: Date) -> Bool { lock.withLock { date >= start && (end.map { date <= $0 } ?? true) } }
}

/// A receipt retains its visibility interval, so a delayed callback can still recognize a frame shown before hide.
/// Old intervals live only as long as their bounded in-flight receipts; there is no polling or growing time log.
public final class FileViewVisibility: @unchecked Sendable {
    private let lock = NSLock()
    private var interval: FileViewInterval?
    public init() {}
    public var isVisible: Bool { lock.withLock { interval?.isOpen == true } }
    fileprivate func snapshot() -> FileViewInterval? { lock.withLock { interval?.isOpen == true ? interval : nil } }
    public func setVisible(_ value: Bool, at date: Date = Date()) {
        lock.withLock {
            if value { if interval?.isOpen != true { interval = FileViewInterval(start: date) } }
            else { interval?.close(at: date) }
        }
    }
}
