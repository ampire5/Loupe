import Foundation

/// A photo that will be framed on its subject (`step-zoom=subject`, Zoom to Subject) and whose subjects are not known
/// yet waits for them a moment before it is shown, the photo before staying on screen meanwhile (owner, 2026-10-28):
/// it then comes framed, rather than at Fit and gliding to its subject once they are in (a jump through the strip, a
/// photo the analysis ahead had not reached).
public enum FramingHold {
    /// The longest a photo waits. Chosen, not measured on the slow machine: Vision takes about 11 ms a photo on an M4 Max
    /// and the catalog less (docs/bench/2026-10-28-smart-zoom.md); an Intel Mac runs Vision on the CPU, and the wait
    /// caps what that costs a step there, after which the photo shows at Fit and glides as before.
    public static let wait: TimeInterval = 0.2

    /// Whether a photo about to be shown waits: it will be framed, its subjects are not known, it is a decoded level
    /// (`seeded`: only its thumbnail, which the finder does not look at), no step waits for it to show
    /// (`byStep`: `wheel-step`/`key-step`, fast stepping), and it is not a photo `open` brought or a saved view restores
    /// (`opened`), which are not framed.
    public static func holds(framing: Bool, known: Bool, seeded: Bool, byStep: Bool, opened: Bool) -> Bool {
        framing && !known && !seeded && !byStep && !opened
    }
}
