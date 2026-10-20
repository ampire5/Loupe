import Foundation

/// The analyses of the photos seen so far, by file and stamp: an edited file is another file, and a photo already
/// analysed is not analysed again when its window is opened again or its thumbnail comes back.
public final class AutoColorCache: @unchecked Sendable {   // all state is behind `lock`
    public static let shared = AutoColorCache()

    private struct Key: Hashable {
        let url: URL
        let modified: Date
        let size: Int
    }

    private let capacity: Int
    private let lock = NSLock()
    private var entries: [Key: AutoColorAnalysis] = [:]
    /// Keys from the least recently stored to the newest.
    private var order: [Key] = []

    public init(capacity: Int = 10_000) {
        self.capacity = max(1, capacity)
    }

    public func analysis(for url: URL, stamp: FileStamp) -> AutoColorAnalysis? {
        lock.lock(); defer { lock.unlock() }
        return entries[Key(url: url, modified: stamp.modified, size: stamp.size)]
    }

    /// Stores `analysis`; beyond the capacity the least recently stored one is dropped.
    public func store(_ analysis: AutoColorAnalysis, for url: URL, stamp: FileStamp) {
        let key = Key(url: url, modified: stamp.modified, size: stamp.size)
        lock.lock(); defer { lock.unlock() }
        if entries.updateValue(analysis, forKey: key) != nil, let at = order.firstIndex(of: key) {
            order.remove(at: at)
        }
        order.append(key)
        while order.count > capacity { entries[order.removeFirst()] = nil }
    }
}
