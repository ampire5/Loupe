import Foundation

/// The Mac Loupe runs on, and the defaults that follow from it: fast on a big machine, never taking over a small
/// one. Each default is a function of the figure it depends on, so tests pin the formula, not this machine.
public enum Machine {
    /// Physical cores, efficiency cores included (an M4 Max: 16; an i7-10700K: 8, not its 16 threads).
    public static let physicalCores: Int = {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.physicalcpu", &count, &size, nil, 0) == 0, count > 0 else {
            return ProcessInfo.processInfo.activeProcessorCount
        }
        return Int(count)
    }()

    public static let memoryBytes = Int(clamping: ProcessInfo.processInfo.physicalMemory)

    /// `cache-memory` by default: a fifth of the memory, down to a 256 MB step, 1 to 4 GB. 16 GB keeps the 3 GB Loupe
    /// always had; 8 GB gets 1.5 GB, leaving the system and the user's other apps room; more than 4 GB buys nothing
    /// at the other cache defaults, whose plan at 147 MP (the current and next photo in full, ≈ 0.85 GB each, and 20
    /// previews of 48–100 MB) stays within it.
    public static let cacheMemory = cacheMemory(memoryBytes: memoryBytes)

    static func cacheMemory(memoryBytes: Int) -> Int {
        let step = 256 << 20
        return min(4 << 30, max(1 << 30, memoryBytes / 5 / step * step))
    }
}
