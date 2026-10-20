import CoreGraphics
import Foundation

/// How far the render loop may run ahead of the display (spec §6.1): `CAMetalDisplayLink.preferredFrameLatency`
/// and `CAMetalLayer.maximumDrawableCount`. Nil keeps the system default; the environment can override either for a
/// measurement (`LOUPE_FRAME_LATENCY` 1|2, `LOUPE_DRAWABLES` 2|3). Values outside those sets are ignored.
public struct RenderTuning: Equatable, Sendable {
    public var frameLatency: Int?
    public var drawableCount: Int?

    public static let standard = RenderTuning(frameLatency: nil, drawableCount: nil)

    public init(frameLatency: Int?, drawableCount: Int?) {
        self.frameLatency = frameLatency
        self.drawableCount = drawableCount
    }

    public init(environment: [String: String]) {
        self = .standard
        if let v = environment["LOUPE_FRAME_LATENCY"].flatMap(Int.init), [1, 2].contains(v) { frameLatency = v }
        if let v = environment["LOUPE_DRAWABLES"].flatMap(Int.init), [2, 3].contains(v) { drawableCount = v }
    }

    public static let current = RenderTuning(environment: ProcessInfo.processInfo.environment)
}

/// The synthetic pan of `LOUPE_AUTOPAN=<seconds>` (a debug aid for scripted latency runs, spec §6.1): a smooth
/// Lissajous path around the starting point, in view pixels. Horizontal amplitude a quarter of the view width
/// with a 2 s period, vertical a sixth of the view height with a 3 s period: it starts at offset 0 and is back
/// at 0 in x at every multiple of 2 s; the horizontal speed peaks at π/4 view widths per second, like a brisk drag.
public struct AutoPanPath: Sendable {
    public let viewSize: CGSize

    public init(viewSize: CGSize) { self.viewSize = viewSize }

    /// Offset from the starting point at `t` seconds after the start.
    public func offset(at t: Double) -> CGVector {
        CGVector(dx: viewSize.width / 4 * sin(2 * .pi * t / 2),
                 dy: viewSize.height / 6 * sin(2 * .pi * t / 3))
    }

    /// The run length from `LOUPE_AUTOPAN`, nil when unset or not a positive number.
    public static func seconds(environment: [String: String]) -> Double? {
        guard let s = environment["LOUPE_AUTOPAN"].flatMap(Double.init), s > 0, s.isFinite else { return nil }
        return s
    }

    /// The zoom the run pans at, from `LOUPE_AUTOPAN_SCALE` (1 = 100 %, the default): below 1 the frames take the
    /// downscale path through a pyramid level, for tracing it (M3a spec §3.3). Nil-safe: anything not a positive
    /// finite number gives 1.
    public static func scale(environment: [String: String]) -> Double {
        guard let s = environment["LOUPE_AUTOPAN_SCALE"].flatMap(Double.init), s > 0, s.isFinite else { return 1 }
        return s
    }

    /// What the run does, from `LOUPE_AUTOPAN_MODE`: `pan` (the default, and for anything unknown), `zoom`
    /// (`AutoZoomPath`), `glide` (flings that coast on the drag inertia and bounce off the edges), `step` (the pan with
    /// photo steps between, some in bursts), `keys` (zoom keys and a zoom spring-back on a timer, for the zoom
    /// animation's log, M4b) or `seeded` (far steps that show a seeded thumbnail, a zoom key on it while the decoded
    /// photo replaces it, and the mode it ends in).
    public enum Mode: String, Sendable { case pan, zoom, glide, step, keys, seeded }

    public static func mode(environment: [String: String]) -> Mode {
        environment["LOUPE_AUTOPAN_MODE"].flatMap(Mode.init(rawValue:)) ?? .pan
    }
}

/// The synthetic zoom of `LOUPE_AUTOPAN_MODE=zoom`: about the view centre, from `low` up to `high` and back with a
/// `period` of 4 s, even in log scale (a raised cosine of the log), so every doubling takes the same time, like a
/// steady pinch; it starts and ends each period at `low` at rest. From fit to 200 % on a 147 MP photo on 6K that is
/// ~2.2 doublings each way in 2 s, crossing 100 % (the downscale/upscale switch) twice per period.
public struct AutoZoomPath: Sendable {
    public let low: Double
    public let high: Double
    public static let period = 4.0

    public init(low: Double, high: Double) {
        self.low = low
        self.high = high
    }

    /// The scale at `t` seconds after the start.
    public func scale(at t: Double) -> Double {
        let phase = (1 - cos(2 * .pi * t / Self.period)) / 2
        return low * exp(log(high / low) * phase)
    }
}
