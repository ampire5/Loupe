import Foundation

/// The window's title, which is also its tab's label: what is on screen, never what was there before — Home's tab
/// while Home covers the viewer (the photo behind it still loads and changes), else the photo's name.
public enum WindowTitle {
    /// A pair on screen (spread) shows both names: `a.jpg · b.jpg`.
    public static func text(home: HomeTab?, file: URL?, companion: URL? = nil) -> String {
        if let home { return title(of: home) }
        guard let file else { return "Loupe" }
        let name = ArchivePath.shortName(file)
        return companion.map { name + " · " + ArchivePath.shortName($0) } ?? name
    }

    /// A restored tab not shown yet.
    public static func text(of tab: SessionSnapshot.Tab) -> String {
        switch tab {
        case .file(let path, _): ArchivePath.shortName(URL(fileURLWithPath: path))
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
