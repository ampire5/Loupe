import CoreGraphics
import Foundation

/// Thumbnails decoded at strip-cell size, the most recently used kept (spec §3.2: up to 300, ~100 KB each at
/// 192 × 128). The strip asks for the same few dozen cells every time it scrolls, and decoding the stored
/// 512 px JPEG again for each would be wasted work. Keyed by size too: the strip and a file browser may want
/// the same photo at different sizes.
struct ThumbnailCells {
    struct Key: Hashable {
        let url: URL
        let maxPixel: Int
        /// Turned by the photo's EXIF orientation (as thumbnails are stored), or back to the stored layout
        /// (`exif-orientation=no`).
        var applyingOrientation = true
    }

    let capacity: Int
    private var entries: [Key: (image: CGImage, used: UInt64)] = [:]
    private var clock: UInt64 = 0

    init(capacity: Int) { self.capacity = capacity }

    var count: Int { entries.count }

    /// The image, now the most recently used.
    mutating func image(_ key: Key) -> CGImage? {
        guard let image = entries[key]?.image else { return nil }
        clock += 1
        entries[key] = (image, clock)
        return image
    }

    /// Adds `image`; over capacity, the least recently used goes. A linear scan for it: 300 entries cost
    /// less than keeping a linked list in step.
    mutating func insert(_ image: CGImage, for key: Key) {
        clock += 1
        entries[key] = (image, clock)
        guard entries.count > capacity, let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key else { return }
        entries[oldest] = nil
    }

    /// Every size of `url` (its file changed, or its thumbnail was made again).
    mutating func remove(_ url: URL) {
        entries = entries.filter { $0.key.url != url }
    }

    mutating func removeAll() { entries.removeAll() }
}
