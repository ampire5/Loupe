import CoreGraphics
import Foundation

/// When the ‹ button is on screen: a reveal zone with hysteresis around it, as the hidden toolbars at a screen edge
/// do. It comes up as the pointer gets within `revealDistance` of it and goes once the pointer is beyond
/// `hideDistance` (or out of the window), so it does not flicker on the zone's edge. Movement elsewhere and the strip
/// do not show it.
public enum BackButtonPolicy {
    public static let revealDistance: CGFloat = 80
    public static let hideDistance: CGFloat = 120

    /// `pointer` and `button` in one coordinate space; nil `pointer`: outside the window.
    public static func isShown(wasShown: Bool, pointer: CGPoint?, button: CGRect, canGoBack: Bool) -> Bool {
        guard canGoBack, let p = pointer else { return false }
        let dx = max(button.minX - p.x, 0, p.x - button.maxX)
        let dy = max(button.minY - p.y, 0, p.y - button.maxY)
        let distance = (dx * dx + dy * dy).squareRoot()
        return distance <= revealDistance || (wasShown && distance <= hideDistance)
    }
}

/// Where File › Back (⌘[) and the "‹" button go: the Home tab the photo was opened from, else Recent — a photo opened
/// from the Finder, a session or a step goes back to Home too. Nothing while Home is on screen or nothing is open.
public enum HomeBack {
    /// Back to Folders opens the browser on the photo now on screen (its folder, it selected), wherever the steps went
    /// since (file browser spec §4.4); the other tabs come back as they were.
    public static func showsCurrentPhoto(_ tab: HomeTab) -> Bool { tab == .folders }

    public static func target(returnsTo: HomeTab?, showingHome: Bool, hasPhoto: Bool, stashAvailable: Bool) -> HomeTab? {
        guard !showingHome, hasPhoto else { return nil }
        if returnsTo == .stash, stashAvailable { return .stash }
        if returnsTo == .folders { return .folders }
        return .recent
    }
}
