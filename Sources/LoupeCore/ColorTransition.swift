import Foundation

/// The colour cube on screen with the photo it belongs to, and the fade into it (M3c spec §2.2, §4.3). `Cube` is the
/// GPU cube (`ColorLUT`; generic so this stays pure and testable), compared by identity. The cube travels with the
/// image in one `RenderLoop` snapshot, so a frame never pairs a photo with another photo's cube.
///
/// `cube` is what the photo is shown with (nil: uncorrected, the identity). A fade runs from `from` (nil: the
/// identity) to `cube` over `duration` seconds from `start`, on one clock (`CACurrentMediaTime`) for both threads;
/// `duration` 0 means no fade at all (`mix` 1 at once, `from` is ignored).
public struct ShownColor<Cube: AnyObject & Sendable>: Sendable {
    public let url: URL
    public let cube: Cube?
    public let from: Cube?
    public let start: Double
    public let duration: Double

    /// The cube's weight against `from`, 0...1: linear in time.
    public func mix(at now: Double) -> Double {
        guard isRunning(at: now) else { return 1 }   // the same end as `isRunning`, exactly (no rounding short of 1)
        return max((now - start) / duration, 0)
    }

    /// Whether the fade has not reached its end at `now`: the render loop keeps drawing while it has not.
    public func isRunning(at now: Double) -> Bool { duration > 0 && now < start + duration }

    /// What to show next for `url` with `cube` (nil: none ready or none wanted), given what is `shown` now:
    /// - another photo (or nothing shown yet): the cube at once, no fade (a photo stepped to is shown corrected);
    /// - the same photo with another cube (by identity): a fade from the shown target (the identity when it had no
    ///   cube) to the new one, unless `durationMs` is 0. A fade interrupted this way restarts from the cube it was
    ///   heading to (a small jump, accepted: no third cube);
    /// - the same photo with the same cube (also: none before and after, or the seeded thumbnail giving way to the
    ///   pyramid): `shown` unchanged, a running fade is not restarted.
    public static func next(shown: ShownColor?, url: URL, cube: Cube?, now: Double, durationMs: Int) -> ShownColor {
        guard let shown, shown.url == url else {
            return ShownColor(url: url, cube: cube, from: nil, start: now, duration: 0)
        }
        guard shown.cube !== cube else { return shown }
        guard durationMs > 0 else { return ShownColor(url: url, cube: cube, from: nil, start: now, duration: 0) }
        return ShownColor(url: url, cube: cube, from: shown.cube, start: now, duration: Double(durationMs) / 1000)
    }
}

extension ShownColor: Equatable {
    public static func == (a: ShownColor, b: ShownColor) -> Bool {
        a.url == b.url && a.cube === b.cube && a.from === b.from && a.start == b.start && a.duration == b.duration
    }
}
