import CoreGraphics

/// The info panel's area while the back button ("‹ Recent" / "‹ Stash", top left) is on screen: a panel kept in the
/// top left corner stands below the button; in any other corner it does not move.
public enum PanelArea {
    /// The button's 16 pt inset, its 40 pt height and 8 pt below it.
    public static let backButtonBand: CGFloat = 64

    /// `base` (y down) less the band at its top when the button is shown and the panel is in the top left corner.
    public static func area(_ base: CGRect, backButtonShown: Bool, corner: PanelCorner) -> CGRect {
        guard backButtonShown, corner == .topLeft else { return base }
        let band = min(backButtonBand, base.height)
        return CGRect(x: base.minX, y: base.minY + band, width: base.width, height: base.height - band)
    }

    /// The corner the panel is in: nearest to where it is now (`current`, area points, y down; a drag or resize under
    /// way), else its stored place's. A drag out of the top left corner so leaves the band at once, and a drop at the
    /// top right is not stored 64 pt low.
    public static func corner(current: CGRect?, stored: PanelPlacement, in base: CGRect) -> PanelCorner {
        guard let current else { return stored.corner }
        return PanelPlacement.nearest(to: current, in: base).corner
    }
}
