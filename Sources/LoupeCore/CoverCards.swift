import CoreGraphics

/// A browser's folder and zip cards and their covers (folder covers spec, Task 4 review). The browser drops a card's
/// picture whenever it lays its cards out again (a sort, a filter, a folder changing on disk, the folder clicked again,
/// a quick scroll out and back) and asks for it again; the cover queue counts a cover made as done while its card stays
/// wanted. So the mosaics made are kept here, within `limitBytes` (the least recently used go first), and given back
/// at once; a card covered before whose mosaic is no longer kept is told to the queue to forget, so it is made again.
/// What still waits for a cover is the last ask less what was delivered since: back from the viewer, nothing made is
/// made again.
public struct CoverCards {
    /// What an ask needs: pictures to give the cards now, and the cards for the queue (the first `visible` in view),
    /// `forget` among them covered before.
    public struct Ask {
        public var cached: [(id: String, image: CGImage)] = []
        public var queue: [String] = []
        public var visible = 0
        public var forget: [String] = []
    }

    public let limitBytes: Int
    /// Bytes of the mosaics kept.
    public private(set) var bytes = 0
    /// The cards of the last ask still waiting for a cover, in order; the first `visiblePending` in view.
    public private(set) var pending: [String] = []
    public private(set) var visiblePending = 0

    private var kept: [String: (image: CGImage, bytes: Int, use: UInt64)] = [:]
    private var uses: UInt64 = 0
    /// Cards given a cover since the last `reset`.
    private var covered: Set<String> = []

    public init(limitBytes: Int) {
        self.limitBytes = limitBytes
    }

    /// The browser wants covers for `ids` (the first `visible` in view).
    public mutating func ask(_ ids: [String], visible: Int) -> Ask {
        var ask = Ask()
        for (index, id) in ids.enumerated() {
            if let entry = kept[id] {
                uses += 1
                kept[id]?.use = uses
                ask.cached.append((id, entry.image))
                continue
            }
            ask.queue.append(id)
            if index < visible { ask.visible += 1 }
            if covered.contains(id) { ask.forget.append(id) }
        }
        pending = ask.queue
        visiblePending = ask.visible
        return ask
    }

    /// The cover of `id` was made and given to its card.
    public mutating func delivered(_ id: String, _ image: CGImage) {
        covered.insert(id)
        if let index = pending.firstIndex(of: id) {
            pending.remove(at: index)
            if index < visiblePending { visiblePending -= 1 }
        }
        remove(id)
        let size = image.bytesPerRow * image.height
        guard size <= limitBytes else { return }
        uses += 1
        kept[id] = (image, size, uses)
        bytes += size
        while bytes > limitBytes, let oldest = kept.min(by: { $0.value.use < $1.value.use })?.key { remove(oldest) }
    }

    /// The mosaics are no longer right (another layout or card size): none is given back; each covered card asked
    /// for again is made again.
    public mutating func dropImages() {
        kept = [:]
        bytes = 0
    }

    /// Another folder: nothing of the last one.
    public mutating func reset() {
        dropImages()
        covered = []
        pending = []
        visiblePending = 0
    }

    private mutating func remove(_ id: String) {
        if let entry = kept.removeValue(forKey: id) { bytes -= entry.bytes }
    }
}
