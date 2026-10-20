import Foundation

/// The metadata of the photos seen with the info panel open, by file and stamp (path + size + modification date): an
/// edited file is another entry, and a photo flipped back to is not read again. The least recently used one goes first.
/// The read itself runs off the actor, so a slow share delays only its own caller, and two askers for one file share it.
public actor PhotoMetadataCache {
    private struct Key: Hashable {
        let path: String
        let size: Int
        let modified: Date?
    }

    private let capacity: Int
    private let reader: @Sendable (URL) -> PhotoMetadata
    private var entries: [Key: PhotoMetadata] = [:]
    /// Keys from the least recently used to the newest.
    private var order: [Key] = []
    private var inFlight: [Key: Task<PhotoMetadata, Never>] = [:]

    public init(capacity: Int = 64, reader: @escaping @Sendable (URL) -> PhotoMetadata = { PhotoMetadata.read($0) }) {
        self.capacity = max(1, capacity)
        self.reader = reader
    }

    public func metadata(for url: URL, size: Int, modified: Date?) async -> PhotoMetadata {
        let key = Key(path: url.path, size: size, modified: modified)
        if let hit = entries[key] {
            touch(key)
            return hit
        }
        if let running = inFlight[key] { return await running.value }
        let reader = self.reader
        let task = Task.detached { reader(url) }
        inFlight[key] = task
        let value = await task.value
        inFlight[key] = nil
        // A failed read (a share that hiccuped between the stat and ImageIO) is not kept: the next ask reads again.
        if value.error != nil { return value }
        entries[key] = value
        touch(key)
        while order.count > capacity { entries[order.removeFirst()] = nil }
        return value
    }

    private func touch(_ key: Key) {
        if let at = order.firstIndex(of: key) { order.remove(at: at) }
        order.append(key)
    }
}
