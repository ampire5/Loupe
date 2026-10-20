/// Accumulates timing measurements and answers order statistics, so benchmark
/// reports can show median and tail latency instead of a mean that one slow SMB read skews.
public struct Samples: Sendable {
    private var values: [Double] = []

    public init() {}

    public mutating func add(_ v: Double) { values.append(v) }

    public var count: Int { values.count }

    /// Middle value; the mean of the two middle values for an even count. Nil when empty.
    public var median: Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// Nearest-rank percentile, `p` in 0...100: the smallest sample with at least `p` % of
    /// the samples at or below it. Nil when empty.
    public func percentile(_ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
}
