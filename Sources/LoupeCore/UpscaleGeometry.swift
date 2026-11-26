import Foundation

/// Fixed-size model inputs split into disjoint output regions. Context is discarded at interior seams.
public enum UpscaleGeometry {
    public struct Window: Equatable, Sendable {
        public let origin: Int
        public let content: Range<Int>
    }

    public static func windows(length: Int, tile: Int, margin: Int) -> [Window] {
        guard length > 0, tile > 0, margin >= 0, margin <= (tile - 1) / 2 else { return [] }
        var result: [Window] = []
        var start = 0
        while start < length {
            let origin = min(max(start - margin, 0), max(length - tile, 0))
            let end = origin + tile >= length ? length : origin + tile - margin
            result.append(Window(origin: origin, content: start..<end))
            start = end
        }
        return result
    }

    /// Matches TiledImage's retained BGRA8 array slices, including aprons and the coarser levels.
    public static func residentBytes(_ size: PixelSize) -> Int? {
        let maxSide = TileGrid.maxTilesPerLevel * TileGrid.tileSize
        guard (1...maxSide).contains(size.width), (1...maxSide).contains(size.height) else { return nil }
        let grid = TileGrid(imageSize: size)
        guard grid.fitsTextureArrays else { return nil }
        return (0..<grid.levelCount).reduce(0) {
            $0 + grid.columns($1) * grid.rows($1) * TileGrid.slotSize * TileGrid.slotSize * 4
        }
    }
}

/// Byte-bounded cache of completed results. Recency is updated on use, including cross-window hits.
public struct UpscaleResultCache<Key: Hashable, Value> {
    private struct Entry {
        let value: Value
        let bytes: Int
        var lastUse: UInt64
    }

    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    public private(set) var bytes = 0

    public init() {}

    public mutating func value(for key: Key) -> Value? {
        guard var entry = entries[key] else { return nil }
        clock += 1
        entry.lastUse = clock
        entries[key] = entry
        return entry.value
    }

    public mutating func insert(_ value: Value, key: Key, bytes cost: Int, limit: Int) {
        guard cost > 0, cost <= limit else { return }
        removeValue(for: key)
        trim(to: limit - cost)
        clock += 1
        entries[key] = Entry(value: value, bytes: cost, lastUse: clock)
        bytes += cost
    }

    package mutating func removeValue(for key: Key) {
        bytes -= entries.removeValue(forKey: key)?.bytes ?? 0
    }

    public mutating func trim(to limit: Int) {
        while bytes > limit, let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse }) {
            bytes -= oldest.value.bytes
            entries.removeValue(forKey: oldest.key)
        }
    }
}
