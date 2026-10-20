import Foundation

/// The base cell height for a drag of the strip's grab band (spec §4.1), as a pure function of how far the cursor
/// has moved since the press. The grabbed edge is the shown top of the cell under the press: a magnified top grows
/// `magnify` times faster than the base, so while it can, the base moves just enough to keep that top under the
/// cursor. Once the cap (`strip-magnify-limit`, `StripMagnifier.effectiveMagnify`) holds the top still or lets it move slower than the
/// cursor, the base moves with the cursor 1:1 instead, so a drag past the cap never lags behind (re-review of Task
/// 15a: a scale fixed at the press left the edge up to 240 pt below the cursor). At the band's top, and without
/// magnification, it is 1:1 throughout.
///
/// The travel the cursor needs for each base height is integrated once at the press (the top's growth or the base's
/// own, whichever is more), so the height is continuous, rises with the cursor and does not depend on the path:
/// back to the press point is back to the start height. The grabbed cell keeps the falloff it had at the press
/// (its share of the magnification): the hover is frozen during the drag.
public struct StripResizeDrag {
    public let startHeight: Double
    private let magnify: Double
    private let windowHeight: Double
    private let viewerShrinks: Bool
    private let padding: Double
    private let limitPercent: Double
    /// The grabbed cell's share of the magnification: its scale is `1 + (m − 1) · falloff` for the applied `m`.
    private let falloff: Double
    /// From the start height upwards and downwards: base heights and the cursor travel that reaches them.
    private var up: [(height: Double, travel: Double)] = []
    private var down: [(height: Double, travel: Double)] = []

    private static let step = 0.25

    /// - Parameters:
    ///   - startHeight: the base cell height at the press.
    ///   - shownHeight: the grabbed cell's shown height then (the start height at the band's top).
    ///   - magnify: `strip-magnify` as configured; the cap is applied here for every height.
    ///   - windowHeight: what the viewer spans with the strip floating over it; in `bar` mode
    ///     (`viewerShrinks`) the viewer ends at the band's top, `startHeight + 2 · padding` and up.
    ///   - limitPercent: `strip-magnify-limit`, the cap the strip view applies too.
    public init(startHeight: Double, shownHeight: Double, magnify: Double, windowHeight: Double,
                viewerShrinks: Bool, padding: Double, limitPercent: Double) {
        self.startHeight = startHeight
        self.magnify = magnify
        self.windowHeight = windowHeight
        self.viewerShrinks = viewerShrinks
        self.padding = padding
        self.limitPercent = limitPercent
        let m = Self.applied(magnify, height: startHeight, windowHeight: windowHeight, viewerShrinks: viewerShrinks,
                             padding: padding, limitPercent: limitPercent)
        falloff = m > 1 && startHeight > 0 ? min(max((shownHeight / startHeight - 1) / (m - 1), 0), 1) : 0
        let range = Config.stripHeightRange
        up = walk(to: max(Double(range.upperBound), startHeight))
        down = walk(to: min(Double(range.lowerBound), startHeight))
    }

    private static func applied(_ magnify: Double, height: Double, windowHeight: Double, viewerShrinks: Bool,
                                padding: Double, limitPercent: Double) -> Double {
        let viewer = windowHeight - (viewerShrinks ? height + 2 * padding : 0)
        return StripMagnifier.effectiveMagnify(magnify, cellHeight: height, viewerHeight: viewer,
                                               limitPercent: limitPercent)
    }

    /// The grabbed cell's shown height at base `height`.
    public func shownHeight(atHeight height: Double) -> Double {
        let m = Self.applied(magnify, height: height, windowHeight: windowHeight, viewerShrinks: viewerShrinks,
                             padding: padding, limitPercent: limitPercent)
        return height * (1 + (m - 1) * falloff)
    }

    /// The base heights from the start to `end` in `step`s, each with the travel to it: per step the top's move
    /// where it outruns the base (the top under the cursor), else the base's own (1:1).
    private func walk(to end: Double) -> [(height: Double, travel: Double)] {
        let direction: Double = end >= startHeight ? 1 : -1
        var path = [(height: startHeight, travel: 0.0)]
        var height = startHeight, travel = 0.0, shown = shownHeight(atHeight: startHeight)
        while (end - height) * direction > 0 {
            let next = direction > 0 ? min(height + Self.step, end) : max(height - Self.step, end)
            let nextShown = shownHeight(atHeight: next)
            travel += max(abs(next - height), (nextShown - shown) * direction)
            height = next
            shown = nextShown
            path.append((height, travel))
        }
        return path
    }

    /// The base height for the cursor `delta` points above the press (negative: below). Past the height range the
    /// base goes on 1:1; the caller clamps it.
    public func height(forDrag delta: Double) -> Double {
        let path = delta >= 0 ? up : down, direction: Double = delta >= 0 ? 1 : -1
        let need = abs(delta)
        guard let last = path.last else { return startHeight + delta }
        guard need < last.travel else { return last.height + direction * (need - last.travel) }
        // The first point the travel reaches, by bisection (travel only grows along the path).
        var low = 0, high = path.count - 1
        while low < high {
            let mid = (low + high) / 2
            if path[mid].travel >= need { high = mid } else { low = mid + 1 }
        }
        guard low > 0 else { return startHeight }
        let a = path[low - 1], b = path[low]
        return a.height + (b.height - a.height) * (need - a.travel) / (b.travel - a.travel)
    }
}
