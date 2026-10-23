import Foundation

/// Where defaults are chosen from the Mac, and where a `loupe.conf` value is judged against it. A harmful value
/// (one that would take over the machine) takes effect clamped; a suboptimal one takes effect as written, with a note.
public enum HardwareAdvice {
    public enum Severity: Sendable { case harmful, suboptimal }

    public struct Note: Equatable, Sendable {
        public let severity: Severity
        public let text: String
        /// The value the rule suggests, spelled as `loupe.conf` spells it.
        public let recommended: String

        public init(severity: Severity, text: String, recommended: String) {
            self.severity = severity
            self.text = text
            self.recommended = recommended
        }
    }

    /// What Loupe may keep on a discrete card: half of the card's working set. Nil on unified memory, where the
    /// cache is the card's memory too. The cache holds more on the card than this (the photo on screen, uploads in
    /// flight): `LoupeBench panload` on an i7-10700K iMac with a Radeon Pro 5500 XT 8 GB (working set 8.57 GB, 5K)
    /// panned smoothly up to ~6.6 GB on the card and stalled from ~7.6 GB; `replay --script 100,backfast` over 147 MP
    /// JPEG XL with this tier (4.29 GB) peaked at 6.58–6.65 GB on the card, as the single 4 GiB budget did before
    /// (docs/bench/2026-10-23-memory-tiers.md).
    public static func graphicsMemory(_ p: MachineProfile) -> Int? {
        p.gpu.unifiedMemory ? nil : p.gpu.workingSetBytes / 2
    }

    /// `cache-memory` by default. A discrete card keeps decoded pictures in its own memory, so the system memory is
    /// free for the cache: a fifth of it, down to a 256 MiB step, at least 1 GiB, no upper bound. Unified memory is
    /// shared with everything else: `Machine.cacheMemory(memoryBytes:)`, 1 to 4 GiB.
    public static func defaultCacheMemory(_ p: MachineProfile) -> Int {
        guard !p.gpu.unifiedMemory else { return Machine.cacheMemory(memoryBytes: p.memoryBytes) }
        let step = 256 << 20
        return max(1 << 30, p.memoryBytes / 5 / step * step)
    }

    /// The most `jxl-threads-other` may take: a quarter of the cores, at least one, so the background never holds
    /// more than a quarter of the machine.
    private static func maxThreadsOther(_ p: MachineProfile) -> Int { max(1, p.physicalCores / 4) }

    /// `jxl-threads-other` by default: a quarter of the cores, 1 or 2.
    public static func defaultJXLThreadsOther(_ p: MachineProfile) -> Int { max(1, min(2, p.physicalCores / 4)) }

    /// What `jxl-threads-other = written` does on this Mac: the written number, clamped to a quarter of the cores.
    public static func effectiveJXLThreadsOther(_ written: Int, _ p: MachineProfile) -> Int {
        min(written, maxThreadsOther(p))
    }

    /// The note for one `loupe.conf` line, or nil: no rule for the key, an unparsable value, or a value inside the rule.
    public static func note(forKey key: String, value: String, on p: MachineProfile) -> Note? {
        switch key {
        case "jxl-threads-other":
            guard let written = Int(value), written > 0, written > maxThreadsOther(p) else { return nil }
            let effective = effectiveJXLThreadsOther(written, p)
            return Note(severity: .harmful,
                        text: "Effective \(effective) on this Mac: more would take over half of its "
                            + "\(p.physicalCores) cores in the background.",
                        recommended: String(effective))
        case "jxl-threads-current":
            guard let written = Int(value), written > p.physicalCores else { return nil }
            return Note(severity: .suboptimal,
                        text: "More threads than this Mac's \(p.physicalCores) cores only burn CPU.",
                        recommended: String(Machine.jxlThreadsCurrent(performanceCores: p.performanceCores)))
        case "cache-memory":
            guard let bytes = Config.memoryBytes(value), bytes > p.memoryBytes / 2 else { return nil }
            return Note(severity: .suboptimal,
                        text: "Over half of this Mac's \(decimalGB(p.memoryBytes)) of memory: macOS would squeeze "
                            + "other apps before the cache gives way.",
                        recommended: Config.memoryText(defaultCacheMemory(p)))
        default:
            return nil
        }
    }

    /// One line per harmful value in the config, for the `loupe.conf` warnings. The config itself is untouched.
    public static func warnings(for config: Config, on p: MachineProfile) -> [String] {
        guard let n = note(forKey: "jxl-threads-other", value: String(config.jxlThreadsOther), on: p),
              n.severity == .harmful else { return [] }
        return ["jxl-threads-other=\(config.jxlThreadsOther): using \(n.recommended) on this Mac "
                + "(\(p.physicalCores) cores)"]
    }

    /// Decimal gigabytes with one decimal, as Finder counts: 64 GiB is "68.7 GB".
    public static func decimalGB(_ bytes: Int) -> String { decimalGigabytes(bytes) + " GB" }

    /// The number of `decimalGB` without the unit ("68.7"), for figures that share one: "2.9 / 3.2 GB".
    public static func decimalGigabytes(_ bytes: Int) -> String {
        String(format: "%.1f", Double(bytes) / 1_000_000_000)
    }
}
