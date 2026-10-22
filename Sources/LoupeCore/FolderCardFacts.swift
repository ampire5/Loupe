import Foundation
import HomeScreenModel

/// `folder-cards` in a folder's settings (folder cards spec, "Переключатель"): how Home draws the folder's folders and
/// archives, kept like `browser-sort` — the folder's own, else its nearest ancestor's, else loupe.conf's.
extension CardStyle {
    public static let settingKey = "folder-cards"

    /// The folder's style, inherited from its ancestors; none set, or text that is no style, is `fallback` (loupe.conf's
    /// `folder-cards`).
    public static func forFolder(_ folder: URL, settings: FolderSettings?, fallback: CardStyle) -> CardStyle {
        settings?.values(for: folder)[settingKey].flatMap { CardStyle(rawValue: $0.lowercased()) } ?? fallback
    }
}

/// The stored summaries of a folder's direct subfolders (`ThumbnailStore.childSummaries`): how many there are and their
/// photos together. A folder card's "+1 204 inside", "at least" while fewer are known than it has subfolders.
public struct ChildSummaries: Equatable, Sendable {
    /// Subfolders with a summary.
    public var count: Int
    /// Their photos.
    public var photos: Int

    public init(count: Int, photos: Int) {
        self.count = count
        self.photos = photos
    }
}

/// What the cover queue learnt about a folder's or zip's card (`FolderCard`'s summary, photo dates and problem, and
/// its subfolders' summaries), kept by Home while the folder is on screen, and made into the kit's `CardSummary` with
/// what may change meanwhile: the visit (`FolderPositions`) and the folder's two-page keys. Pure: put together on the
/// main thread from what is already in memory.
public struct FolderCardFacts: Sendable {
    public var summary: FolderSummary?
    /// The direct subfolders' stored summaries; nil when not asked (no subfolders, or no place in the catalog). "At
    /// least" (`insideIncomplete`) unless there are exactly as many as the folder has subfolders.
    public var inside: ChildSummaries?
    /// The photos' modification dates from this pass's listing (`FolderCard.photoDates`): "+N new" by date.
    public var photoDates: [Date]?
    public var problem: CardProblem?

    public init(summary: FolderSummary? = nil, inside: ChildSummaries? = nil, photoDates: [Date]? = nil,
                problem: CardProblem? = nil) {
        self.summary = summary
        self.inside = inside
        self.photoDates = photoDates
        self.problem = problem
    }

    /// loupe.conf (`base`) with the folder's values on top: what its two-page badges say.
    public static func config(for folder: URL, base: Config, settings: FolderSettings?) -> Config {
        guard let settings else { return base }
        return base.applying(settings.values(for: folder)).config
    }

    /// The card's facts. `visit`: the folder's last visit (progress, ✓, "+N new"; none without one). `config`: the
    /// folder's effective config (`config(for:base:settings:)`): ⧉ with `spread`, RTL with `spread-direction=rtl`
    /// while two pages are on. ✓ is the last photo reached with nothing new since.
    public func cardSummary(visit: FolderVisit?, config: Config) -> CardSummary {
        var card = CardSummary(twoPages: config.spread, rightToLeft: config.spread && config.spreadRightToLeft)
        switch problem {
        case .broken: card.problem = .broken
        case .offline: card.problem = .offline
        case nil: break
        }
        if let summary {
            card.photos = summary.photos
            card.folders = summary.folders
            card.bytes = summary.bytes
            card.first = summary.first
            card.last = summary.last
            card.histogram = summary.histogram
            if summary.folders > 0, let inside, inside.count > 0 {
                card.insidePhotos = inside.photos
                // Fewer rows than subfolders: some unknown; more: some of subfolders gone since. Neither is sure.
                card.insideIncomplete = inside.count != summary.folders
            }
        }
        if let visit {
            card.viewed = visit.progress()
            card.seen = max(0, visit.index + 1)   // "137 / 248": seen as counted at the visit, of the photos now
            if let summary { card.new = max(0, FolderVisit.new(since: visit, summary: summary, dates: photoDates)) }
            card.done = visit.done && card.new == 0
        }
        return card
    }
}
