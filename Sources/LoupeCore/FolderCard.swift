import CoreGraphics
import Foundation
import HomeScreenModel

/// A cover's listing of a folder (or a zip's directory): its names, and on a local volume (a listing with stat) or for a
/// zip also its summary (without the folder's date, which the caller has) and its photos' dates.
public struct CoverListing: Equatable, Sendable {
    public var names: CoverNames
    public var summary: FolderSummary?
    /// The photos' modification dates (folder cards' "+N new"); nil from a names-only listing and for a zip.
    public var photoDates: [Date]?

    public init(names: CoverNames, summary: FolderSummary? = nil, photoDates: [Date]? = nil) {
        self.names = names
        self.summary = summary
        self.photoDates = photoDates
    }

    /// From a listing (`BrowserListingSource.names`, with stat on a local volume: the summary and the photos' dates
    /// then; a names-only listing gives neither, its summary is the caller's from the names).
    public init(listing entries: [BrowserEntry], dated: Bool) {
        let files = entries.filter { $0.kind == .file }, folders = entries.filter { $0.kind == .folder }
        self.init(names: CoverNames(files: files.map(\.name), folders: folders.map(\.name)),
                  summary: dated ? .of(listing: entries, folderModified: nil) : nil,
                  photoDates: dated ? files.compactMap(\.date) : nil)
    }
}

/// What a folder card has against it (folder cards spec, "Значки").
public enum CardProblem: Equatable, Sendable {
    /// The zip's directory cannot be read: the card says so but is not dimmed (it opens, with the viewer's message).
    case broken
    /// The share does not answer (the cover's listing gave no name in time twice in a row) or its volume is gone: the
    /// card is dimmed, like a place that does not answer.
    case offline
}

/// A folder's or zip's card from the cover queue (`ThumbnailStore.folderCard`): its pictures and the facts of its band.
public struct FolderCard: Sendable {
    public var images: [CGImage]
    /// Made from this pass's listing, else the catalog's (kept even when the folder changed since, until a listing
    /// counts it again); nil when there is none.
    public var summary: FolderSummary?
    public var problem: CardProblem?
    /// The photos' modification dates from this pass's listing with stat (a local volume); nil when the card came
    /// from the catalog, on a share and for a zip.
    public var photoDates: [Date]?

    public init(images: [CGImage], summary: FolderSummary? = nil, problem: CardProblem? = nil,
                photoDates: [Date]? = nil) {
        self.images = images
        self.summary = summary
        self.problem = problem
        self.photoDates = photoDates
    }
}

/// Where the catalog keeps the open folder and its date (`putOpenFolderSummary`), from one blocking call.
struct OpenFolderPlace: Sendable {
    var location: ThumbnailLocation?
    var modified: Date?
}
