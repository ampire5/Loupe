import FilmstripModel

/// Where a scroll event over the thumbnail strip goes (`FilmstripView.routeScroll`): Loupe's own rules, the folder
/// gesture's held button and the viewer's spent gesture among them, which the kit's strip leaves to its owner.
public enum StripRoute {
    /// Precise scrolling with no folder-gesture button held is the strip's. A held button belongs to the folder
    /// gesture as anywhere in the window, except during the strip's own press, which the gesture leaves alone too.
    /// The owner's (`.owner`): a notched wheel steps photos, a scroll with a folder-gesture button held steps folders
    /// (`FolderScrollGesture`). Nobody's (`.ignore`): during the strip's own press (scrub, resize), which owns the
    /// selection until its release, and the rest of a gesture the viewer's guard has spent.
    /// `spent`: the viewer's scroll guard says the rest of this gesture does nothing (a folder step or a three-finger
    /// swipe fired during it, so its fingers and coast go on after the click is let go; or three fingers are down).
    /// Asked only for a scroll that would be the strip's, since asking feeds the guard (it must see every such gesture
    /// begin, to drop its latch).
    public static func route(precise: Bool, held: MouseButtons, folderGesture: Bool, pressed: Bool,
                             spent: @autoclosure () -> Bool) -> FilmstripScrollRoute {
        guard precise else { return .owner }
        if pressed { return .ignore }
        if folderGesture, !held.isDisjoint(with: FolderScrollGesture.triggers(precise: true)) { return .owner }
        return spent() ? .ignore : .strip
    }
}
