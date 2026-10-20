/// The sign that turns a precise (trackpad, Magic Mouse) scroll's deltas into the fingers' own movement: with
/// "natural scrolling" (`NSEvent.isDirectionInvertedFromDevice`) the deltas follow the fingers, otherwise the system
/// flipped them. The gestures that go by the fingers whatever that setting says (the held-button folder step, the
/// strip's scrub) share it, so they cannot drift apart; the three-finger swipe reads raw touches and needs none.
public enum FingerDirection {
    public static func sign(invertedFromDevice: Bool) -> Double { invertedFromDevice ? 1 : -1 }
}
