/// Locks one continuous scroll to its first intentional axis, including its momentum tail.
/// A fresh finger gesture always wins over the previous coast. Phase-less devices use a quiet gap.
public struct GestureAxisLock: Sendable {
    public enum Axis: Sendable { case horizontal, vertical }
    public struct Delta: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }
    /// Matches the pointer gesture's existing four-point click slop.
    public static let slop = 4.0
    public static let restGap = 0.25
    public private(set) var axis: Axis?
    private var x = 0.0, y = 0.0
    private var lastTime: Double?
    private var wasMomentum = false

    public init() {}
    public mutating func reset() { self = Self() }

    /// Cumulative pointer displacement from a press; once selected, the axis cannot change until reset.
    public mutating func project(x: Double, y: Double) -> Delta {
        if axis == nil, max(abs(x), abs(y)) >= Self.slop, abs(x) != abs(y) {
            axis = abs(x) > abs(y) ? .horizontal : .vertical
        }
        switch axis {
        case .horizontal: return Delta(x: x, y: 0)
        case .vertical: return Delta(x: 0, y: y)
        case nil: return Delta(x: 0, y: 0)
        }
    }

    /// Incremental wheel deltas. Pending travel is delivered once on acquisition, so crossing the slop loses nothing.
    public mutating func filter(x dx: Double, y dy: Double, precise: Bool, momentum: Bool,
                                began: Bool, phased: Bool = false, at time: Double) -> Delta {
        if !momentum, began || wasMomentum || (!phased && lastTime.map { time - $0 >= Self.restGap } == true) {
            reset()
        }
        lastTime = time
        wasMomentum = momentum
        if let axis { return axis == .horizontal ? Delta(x: dx, y: 0) : Delta(x: 0, y: dy) }
        // Momentum arriving before any gesture belongs to an older, unobserved gesture.
        guard !momentum else { return Delta(x: 0, y: 0) }
        x += dx; y += dy
        if !precise, x != 0 || y != 0 { axis = abs(x) > abs(y) ? .horizontal : .vertical }
        let delta = project(x: x, y: y)
        if axis != nil { x = 0; y = 0 }
        return delta
    }
}
