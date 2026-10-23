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
    /// The subfolders' modification dates by name, those a listing with stat gave (the work ahead's freshness:
    /// `ThumbnailStore.subfolderModified`); empty from a names-only listing.
    public var folderDates: [String: Date]

    public init(names: CoverNames, summary: FolderSummary? = nil, photoDates: [Date]? = nil,
                folderDates: [String: Date] = [:]) {
        self.names = names
        self.summary = summary
        self.photoDates = photoDates
        self.folderDates = folderDates
    }

    /// From a listing (`BrowserListingSource.names`, with stat on a local volume: the summary and the photos' dates
    /// then; a names-only listing gives neither, its summary is the caller's from the names).
    public init(listing entries: [BrowserEntry], dated: Bool) {
        let files = entries.filter { $0.kind == .file }, folders = entries.filter { $0.kind == .folder }
        self.init(names: CoverNames(files: files.map(\.name), folders: folders.map(\.name)),
                  summary: dated ? .of(listing: entries, folderModified: nil) : nil,
                  photoDates: dated ? files.compactMap(\.date) : nil,
                  folderDates: dated ? Dictionary(folders.compactMap { entry in entry.date.map { (entry.name, $0) } },
                                                  uniquingKeysWith: { first, _ in first }) : [:])
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
    /// The pictures came from the catalog (or a remembered pick) at once and the folder is still to be listed for its
    /// summary: the next `folderCard` for it does that (the cover queue keeps the card, its work "not done", and asks
    /// again at its pace). On an offline share it stays pending until a call may probe the share
    /// (`coverOfflineProbeInterval`) and the share answers it (a probe that does not answer spends nothing), or the
    /// share answers otherwise: each such call re-reads the four pictures from the catalog and lists nothing (~20 ms
    /// in a debug build on an 8-core Intel iMac, four 512 px thumbnails of a 200-photo folder; the queue's retry delay
    /// grows to a minute).
    public var summaryPending: Bool

    public init(images: [CGImage], summary: FolderSummary? = nil, problem: CardProblem? = nil,
                photoDates: [Date]? = nil, summaryPending: Bool = false) {
        self.images = images
        self.summary = summary
        self.problem = problem
        self.photoDates = photoDates
        self.summaryPending = summaryPending
    }
}

/// Where the catalog keeps the open folder and its date (`putOpenFolderSummary`), from one blocking call.
struct OpenFolderPlace: Sendable {
    var location: ThumbnailLocation?
    var modified: Date?
}
