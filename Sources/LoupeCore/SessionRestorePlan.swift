import CoreGraphics
import Foundation

/// How a session's windows and tabs come back (Home spec §2.6): only the selected tab of each window opens at once,
/// the others when first shown; a file that is gone puts its tab on Home with a toast.
public enum SessionRestorePlan {
    public enum TabStep: Equatable, Sendable {
        case open(SessionSnapshot.Tab)
        /// Opened when the tab is first selected.
        case lazy(SessionSnapshot.Tab)
        /// Home on that tab; `notAvailable`: the name the toast gives (the tab's file is gone); `keeps`: the tab the
        /// session had there, kept in Last Session until something else is opened in it (a share down for one launch
        /// must not drop it for good).
        case home(HomeTab, notAvailable: String?, keeps: SessionSnapshot.Tab?)
    }

    public struct WindowStep: Equatable, Sendable {
        public var frame: CGRect
        public var screen: String?
        public var fullScreen: Bool
        public var selected: Int
        public var tabs: [TabStep]
    }

    /// `exists(path)`: true, false, or nil when it is not known (a share that did not answer in time — tried anyway).
    public static func steps(_ s: SessionSnapshot, exists: (String) -> Bool?) -> [WindowStep] {
        s.windows.compactMap { w in
            guard !w.tabs.isEmpty else { return nil }
            let selected = min(max(w.selected, 0), w.tabs.count - 1)
            let tabs = w.tabs.enumerated().map { i, tab -> TabStep in
                switch tab {
                case .home(let home):
                    return .home(home, notAvailable: nil, keeps: nil)
                case .file(let path, _) where exists(path) == false:
                    return .home(.recent, notAvailable: URL(fileURLWithPath: path).lastPathComponent, keeps: tab)
                default:
                    return i == selected ? .open(tab) : .lazy(tab)
                }
            }
            return WindowStep(frame: w.frame, screen: w.screen, fullScreen: w.fullScreen, selected: selected, tabs: tabs)
        }
    }
}
