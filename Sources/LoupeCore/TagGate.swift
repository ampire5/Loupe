/// Decides whether a frame may be drawn into the drawable the display link just vended, given the
/// colour-space tag the layer carries (generic over the tag so the rule is testable without CoreGraphics).
///
/// A `CAMetalLayer` drawable keeps the colour space the layer had when the drawable was vended; retagging
/// the layer afterwards only affects drawables vended later. Drawing a frame in a new colour space into
/// the old drawable therefore presents it with the old tag (sRGB or Adobe RGB values read as Display P3:
/// oversaturated) until the next frame. So when the tag has to change, the layer is retagged and that
/// callback draws nothing; the snapshot stays undrawn and the next callback, with a fresh drawable,
/// draws it correctly.
public struct TagGate<Tag: Equatable> {
    public enum Decision: Equatable, Sendable {
        /// The layer already carries the required tag: draw into this callback's drawable.
        case draw
        /// The tag differs: retag the layer now and draw nothing; the next callback draws.
        case retagAndDefer
    }

    /// The tag the layer carries; nil until the first retag (whatever the layer was created with is unknown).
    public private(set) var current: Tag?

    public init() {}

    /// Call before drawing a snapshot that needs `required`. On `.retagAndDefer` the gate already records
    /// `required` as the layer's tag; the caller must apply it to the layer.
    public mutating func decide(required: Tag) -> Decision {
        guard current != required else { return .draw }
        current = required
        return .retagAndDefer
    }
}
