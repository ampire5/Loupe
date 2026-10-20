import CoreGraphics
import Foundation

/// The windows and tabs of a session (Home spec §2.6), as kept in `Loupe.db` (`sessions.json`).
public struct SessionSnapshot: Codable, Equatable, Sendable {
    public static let version = 1

    public var v = SessionSnapshot.version
    /// Front to back.
    public var windows: [Window]

    public struct Window: Codable, Equatable, Sendable {
        public var frame: CGRect
        /// `NSScreen.localizedName` of the screen it was on.
        public var screen: String?
        public var fullScreen: Bool
        /// Index into `tabs` of the tab on screen.
        public var selected: Int
        public var tabs: [Tab]

        public init(frame: CGRect, screen: String?, fullScreen: Bool, selected: Int, tabs: [Tab]) {
            self.frame = frame
            self.screen = screen
            self.fullScreen = fullScreen
            self.selected = selected
            self.tabs = tabs
        }
    }

    public enum Tab: Codable, Equatable, Sendable {
        /// A photo and its view (`SavedView.text`).
        case file(path: String, view: String?)
        /// A Stash gallery, its list (`StashGalleryListContext`) and the photo on screen in it.
        case gallery(id: String, list: Data?, index: Int?, count: Int?, file: String?, view: String?)
        case home(HomeTab)
        /// Home over what the tab had: the photo under it (‹ goes back to it) and the browser's folder, at least one
        /// of them (`homeKeeping` makes a plain `home` otherwise).
        indirect case homeOver(HomeTab, folder: String?, under: Tab?)

        /// Home on `tab`; a plain `home` when there is nothing under it to keep.
        public static func homeKeeping(_ tab: HomeTab, folder: String?, under: Tab?) -> Tab {
            folder == nil && under == nil ? .home(tab) : .homeOver(tab, folder: folder, under: under)
        }
    }

    public init(windows: [Window]) {
        self.windows = windows
    }

    public var tabCount: Int { windows.reduce(0) { $0 + $1.tabs.count } }

    /// Nothing but Home with nothing under it: not worth keeping as Last Session.
    public var isOnlyHome: Bool {
        windows.allSatisfy { $0.tabs.allSatisfy { if case .home = $0 { true } else { false } } }
    }

    /// Nil for JSON that does not decode or a newer version than this Loupe's.
    public static func decode(_ data: Data) -> SessionSnapshot? {
        guard let s = try? JSONDecoder().decode(SessionSnapshot.self, from: data), s.v <= version else { return nil }
        return s
    }

    public func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }
}

/// Where a restored window goes (Home spec §2.6).
public enum SessionFrames {
    /// `frame` as it was when some screen shows its centre; else centred on `main` at its size (no larger than `main`).
    public static func fit(_ frame: CGRect, screens: [CGRect], main: CGRect) -> CGRect {
        if screens.contains(where: { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) }) { return frame }
        let size = CGSize(width: min(frame.width, main.width), height: min(frame.height, main.height))
        return CGRect(x: main.midX - size.width / 2, y: main.midY - size.height / 2, width: size.width,
                      height: size.height)
    }
}
