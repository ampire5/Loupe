import Foundation

/// The window's title, which is also its tab's label: what is on screen, never what was there before — Home's tab
/// while Home covers the viewer (the photo behind it still loads and changes), else the photo's name.
public enum WindowTitle {
    public static func text(home: HomeTab?, file: URL?) -> String {
        if let home { return title(of: home) }
        return file?.lastPathComponent ?? "Loupe"
    }

    /// A restored tab not shown yet.
    public static func text(of tab: SessionSnapshot.Tab) -> String {
        switch tab {
        case .file(let path, _): URL(fileURLWithPath: path).lastPathComponent
        case .gallery(_, _, _, _, let file, _): file ?? "Stash"
        case .home(let home), .homeOver(let home, _, _): title(of: home)
        }
    }

    public static func title(of tab: HomeTab) -> String {
        switch tab {
        case .recent: "Recent"
        case .sessions: "Sessions"
        case .folders: "Folders"
        case .stash: "Stash"
        }
    }
}
