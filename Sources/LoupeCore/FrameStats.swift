import Foundation

/// Whether the stats bar shows (`I` toggles `hidden ↔ compact`). A stored `extended` (the old second-line mode) reads as compact.
public enum StatsMode: String, Sendable {
    case hidden, compact

    public var next: StatsMode {
        switch self {
        case .hidden: .compact
        case .compact: .hidden
        }
    }

    /// The mode to start with: the stored one, else compact.
    public static func stored(_ text: String?) -> StatsMode {
        text.flatMap(StatsMode.init(rawValue:)) ?? .compact
    }
}

/// GPU time and presentation intervals of the last `capacity` presented frames, for the panel's Diagnostics rows.
public struct FrameStats: Sendable {
    public static let capacity = 240
    /// A frame is late when it came more than this many refresh periods after the previous one.
    public static let dropFactor = 1.5
    /// A gap at least this long (seconds) is the link idling (frames are drawn only on change) unless an update
    /// waited across it; shorter ones are always counted.
    public static let activeGap = 0.25

    private var gpu: [Double] = []
    /// Refreshes missed before each frame.
    private var drops: [Int] = []

    public init() {}

    /// One presented frame: its GPU time, the time since the previous presented frame and the display's
    /// refresh period (all but `gpuMs` in seconds). A late frame counts every refresh it missed (at least one).
    /// `interval` <= 0 means unknown (the first frame after the link was paused): never a drop. A gap of
    /// `activeGap` or more counts only when `pending`: the frame's update was already waiting when the previous
    /// frame was presented, so the gap was a stall, not idling.
    public mutating func record(gpuMs: Double, interval: Double, period: Double, pending: Bool = false) {
        gpu.append(gpuMs)
        var missed = 0
        if interval > Self.dropFactor * period, period > 0, interval < Self.activeGap || pending {
            missed = max(1, Int((interval / period).rounded()) - 1)
        }
        drops.append(missed)
        if gpu.count > Self.capacity {
            gpu.removeFirst()
            drops.removeFirst()
        }
    }

    /// Median GPU time over the window, nil before the first frame.
    public var gpuP50: Double? { percentile(0.5) }
    public var gpuP90: Double? { percentile(0.9) }
    /// Refreshes missed in the window (a stall counts every one).
    public var dropped: Int { drops.reduce(0, +) }

    /// Nearest rank.
    private func percentile(_ p: Double) -> Double? {
        guard !gpu.isEmpty else { return nil }
        let sorted = gpu.sorted()
        return sorted[max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1)]
    }
}
