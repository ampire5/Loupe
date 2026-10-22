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

    /// Performance cores: an Apple chip's big cores (an M4 Max: 12 of its 16), every physical core on Intel.
    public static let performanceCores: Int = {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.perflevel0.physicalcpu", &count, &size, nil, 0) == 0, count > 0 else {
            return physicalCores
        }
        return Int(count)
    }()

    public static let memoryBytes = Int(clamping: ProcessInfo.processInfo.physicalMemory)

    /// `cache-memory` by default: a fifth of the memory, down to a 256 MB step, 1 to 4 GB. 16 GB keeps the 3 GB Loupe
    /// always had; 8 GB gets 1.5 GB, leaving the system and the user's other apps room; more than 4 GB buys nothing
    /// at the other cache defaults, whose plan at 147 MP (the current and next photo in full, ≈ 0.85 GB each, and 20
    /// previews of 48–100 MB) stays within it. This is the unified-memory rule; `HardwareAdvice` is where defaults are
    /// chosen for the Mac at hand (a discrete card has no upper bound).
    public static let cacheMemory = cacheMemory(memoryBytes: memoryBytes)

    static func cacheMemory(memoryBytes: Int) -> Int {
        let step = 256 << 20
        return min(4 << 30, max(1 << 30, memoryBytes / 5 / step * step))
    }

    /// `jxl-threads-current` by default: one libjxl thread per performance core, 2 to 16. On an i7-10700K (8 cores,
    /// 16 threads) a ~120 MP JPEG XL decodes in 708 / 610 / 515 / 543 / 517 ms with 4 / 6 / 8 / 10 / 16 threads
    /// (VarDCT; a transcoded JPEG 456 / 405 / 313 / 289 / 270 ms), for 2.6 / 3.3 / 3.6 / 4.5 / 5.5 s of CPU: past the
    /// cores the threads only burn CPU. The efficiency cores are left out: they would finish their groups last.
    public static let jxlThreadsCurrent = jxlThreadsCurrent(performanceCores: performanceCores)

    public static func jxlThreadsCurrent(performanceCores: Int) -> Int { min(16, max(2, performanceCores)) }
}
