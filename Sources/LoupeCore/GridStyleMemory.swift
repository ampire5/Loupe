import Foundation
import HomeScreenModel

/// `grid-style-memory`: how Home's Square / Aspect toggle (⌥T, the toolbar's button) is remembered. `tab` (the
/// default): each window or tab keeps its own for the session, a new one starts from `grid-style`; `folder`: saved for
/// the folder in its settings and inherited by the ones under it, like `folder-cards`; `global`: written to loupe.conf's
/// `grid-style`.
public enum GridStyleMemory: String, CaseIterable, Sendable {
    case tab, folder, global
}

/// `grid-style` in a folder's settings (`grid-style-memory=folder`): kept like `browser-sort` and `folder-cards` — the
/// folder's own, else its nearest ancestor's, else loupe.conf's.
extension GridStyle {
    public static let settingKey = "grid-style"

    /// The folder's style, inherited from its ancestors; none set, or text that is no style, is `fallback` (loupe.conf's
    /// `grid-style`).
    public static func forFolder(_ folder: URL, settings: FolderSettings?, fallback: GridStyle) -> GridStyle {
        settings?.values(for: folder)[settingKey].flatMap { GridStyle(rawValue: $0.lowercased()) } ?? fallback
    }
}

/// One tab's Square / Aspect under `grid-style-memory`: what it shows and where a toggle is saved. Pure; the window
/// controller keeps one and does the writes `choose` asks for.
public struct TabGridStyle: Equatable, Sendable {
    /// The tab's own choice, for the session: `tab`, and `folder` off a folder (Recent, a session).
    public private(set) var own: GridStyle?

    public init() {}

    /// What the tab shows on `folder` (nil: not a folder). `global`: loupe.conf's `grid-style`.
    public func style(memory: GridStyleMemory, global: GridStyle, folder: URL?, settings: FolderSettings?) -> GridStyle {
        switch memory {
        case .global: return global
        case .tab: return own ?? global
        case .folder:
            guard let folder else { return own ?? global }
            return GridStyle.forFolder(folder, settings: settings, fallback: global)
        }
    }

    /// A session's tab comes back with its own choice (`SessionSnapshot.Browser.style`), under `tab` only: under
    /// `folder` and `global` the style is not the tab's.
    public mutating func restore(_ style: GridStyle?, memory: GridStyleMemory) {
        if memory == .tab { own = style }
    }

    /// Where a toggle is saved: nowhere (the tab's own), in the folder's settings, or as loupe.conf's `grid-style`.
    public enum Save: Equatable, Sendable {
        case none
        case folder(URL, GridStyle)
        case global(GridStyle)
    }

    /// The user chose `style` on `folder` (nil: not a folder).
    public mutating func choose(_ style: GridStyle, memory: GridStyleMemory, folder: URL?) -> Save {
        switch memory {
        case .global: return .global(style)
        case .folder:
            if let folder { return .folder(folder, style) }
            own = style
            return .none
        case .tab:
            own = style
            return .none
        }
    }
}
