import Dispatch
import Foundation
import LoupeCore
import LoupeRender

/// Feeds the system's memory pressure to the cache (M2 spec §11.3): `warning` halves the cache's effective
/// `cache-memory`, `critical` quarters it, `normal` restores it (the cache also restores it by itself 30 s after
/// the last event). With `LOUPE_DEBUG` set, `LOUPE_SIMULATE_PRESSURE=warning|critical` applies that level a few
/// seconds after launch, to see the limit change without a real shortage (`memory_pressure` needs root).
@MainActor final class MemoryPressureMonitor {
    private let cache: ImageCache<MetalPyramidLoader>
    private var source: DispatchSourceMemoryPressure?

    init(cache: ImageCache<MetalPyramidLoader>) {
        self.cache = cache
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical, .normal], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            // The event handler runs on the main queue, so assuming isolation is sound.
            MainActor.assumeIsolated { self.apply(Self.level(of: source.data), simulated: false) }
        }
        source.resume()
        self.source = source
        if DebugLog.isEnabled, let level = Self.simulatedLevel(ProcessInfo.processInfo.environment["LOUPE_SIMULATE_PRESSURE"]) {
            DebugLog.log("memory pressure: will simulate \(level) in 4 s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.apply(level, simulated: true) }
        }
    }

    deinit { source?.cancel() }

    /// Events reach the cache in the order they came: each one's task waits for the previous one's.
    private var chain: Task<Void, Never>?

    private func apply(_ level: MemoryPressure, simulated: Bool) {
        let cache = cache, previous = chain
        chain = Task {
            await previous?.value
            guard DebugLog.isEnabled else {
                await cache.setMemoryPressure(level)
                return
            }
            let before = await cache.stats()
            await cache.setMemoryPressure(level)
            let after = await cache.stats()
            DebugLog.log("memory pressure \(level)\(simulated ? " (simulated)" : ""): limit "
                         + "\(before.effectiveLimitBytes >> 20) -> \(after.effectiveLimitBytes >> 20) MB "
                         + "(cache-memory \(after.limitBytes >> 20) MB), used \(before.usedBytes >> 20) -> "
                         + "\(after.usedBytes >> 20) MB")
        }
    }

    /// `critical` wins over `warning` if both bits are set; no bit at all means pressure is over.
    nonisolated static func level(of event: DispatchSource.MemoryPressureEvent) -> MemoryPressure {
        if event.contains(.critical) { return .critical }
        if event.contains(.warning) { return .warning }
        return .normal
    }

    nonisolated static func simulatedLevel(_ text: String?) -> MemoryPressure? {
        switch text?.lowercased() {
        case "warning": .warning
        case "critical": .critical
        default: nil
        }
    }
}
