import Foundation
import HomeScreenModel

/// How far the generator is with a window's folder (`ThumbnailStore.generatorProgress`): its photos in view and the
/// margin (the request's visible ones), and all of them.
public struct GeneratorProgress: Equatable, Sendable {
    public var visible: WorkCount
    public var all: WorkCount

    public init(visible: WorkCount = WorkCount(), all: WorkCount = WorkCount()) {
        self.visible = visible
        self.all = all
    }
}

/// How far Home's preparation of a folder is, for the toolbar's pill and its popover (thumbs-ahead spec, "Пилюля в
/// тулбаре"): one value joined from the three counters (the generator's for the window, the cover queue's for the
/// client, the subtree walk's for the command) and the pauses.
///
/// The pill names the current stage: what is in view and the margin (the cards' covers and the photos) while some of it
/// is still to be made ("In view 6 / 24"), then the folder's photos (all of them, those in view too: "Thumbnails 120 /
/// 480"), then the subfolders ("Subfolders 5 / 48"); paused, "Paused · 120 / 480"; nothing once all are done.
public struct ThumbsProgress: Equatable, Sendable {
    /// Why the work ahead waits: the user's pause (the popover's "Pause"), or the viewer busy ("Paused while you
    /// browse").
    public enum Pause: Equatable, Sendable {
        case user, browsing
    }

    /// The stage the pill names.
    public enum Stage: Equatable, Sendable {
        /// The covers of the cards in view and the margin, and the photos in view and the margin (stages 1–2): what
        /// the user is looking at, so work as much as the rest.
        case inView
        /// The folder's photos (stage 3).
        case thumbnails
        /// The visible cards' subfolders (stage 4), and the walk's folders on command (stage 5).
        case subfolders
    }

    /// What is in view and the margin (stages 1–2): the folder's cards (their covers) and its photos (thumbnails).
    public var inView: WorkCount
    /// The rest of the folder's photos, out of view and the margin (stage 3).
    public var rest: WorkCount
    /// All of the folder's photos, those in view too: the pill's "Thumbnails 120 / 480".
    public var photos: WorkCount
    /// The visible cards' subfolders (a cover and a summary each), with the walk's folders while it runs.
    public var subfolders: WorkCount
    public var paused: Pause?
    /// The word for the popover about the subfolders: the walk's (`WalkProgress.waiting`, else `stopped`), else
    /// "Waiting for the share" while the visible cards' subfolders wait on a share that does not answer; nil without
    /// one.
    public var walkNote: String?
    /// The subtree walk of this window is under way (`WalkProgress.running`): the popover offers "Stop preparing".
    public var subtreeRunning: Bool
    /// Of what is in view still to do, how much waits on a share that is offline or does not answer (covers the queue
    /// retries for good, photos it cannot read, photos waiting for a listing that does not come): not work under way,
    /// so the in-view stage counts only the rest.
    public var inViewWaiting: Int
    /// Of the folder's photos still to do, how many wait on a share that is offline: not work under way either.
    public var photosWaiting: Int

    public init(inView: WorkCount = WorkCount(), rest: WorkCount = WorkCount(), photos: WorkCount = WorkCount(),
                subfolders: WorkCount = WorkCount(), paused: Pause? = nil, walkNote: String? = nil,
                subtreeRunning: Bool = false, inViewWaiting: Int = 0, photosWaiting: Int = 0) {
        self.inView = inView
        self.rest = rest
        self.photos = photos
        self.subfolders = subfolders
        self.paused = paused
        self.walkNote = walkNote
        self.subtreeRunning = subtreeRunning
        self.inViewWaiting = inViewWaiting
        self.photosWaiting = photosWaiting
    }

    /// What is in view while some of it is still to be made, then the photos, then the subfolders; nil once all are
    /// done.
    public var stage: Stage? {
        if inView.done + inViewWaiting < inView.total { return .inView }
        if photos.done + photosWaiting < photos.total { return .thumbnails }
        if subfolders.done < subfolders.total { return .subfolders }
        return nil
    }

    /// The current stage's count (the pill's ring is its share), nil once all is done.
    public var current: WorkCount? {
        switch stage {
        case .inView: inView
        case .thumbnails: photos
        case .subfolders: subfolders
        case nil: nil
        }
    }

    /// The pill's text: "In view 6 / 24", "Thumbnails 120 / 480", "Subfolders 5 / 48", "Paused · 120 / 480"; nil once all is done.
    public var text: String? {
        guard let stage, let current else { return nil }
        let count = "\(current.done) / \(current.total)"
        if paused != nil { return "Paused · \(count)" }
        switch stage {
        case .inView: return "In view \(count)"
        case .thumbnails: return "Thumbnails \(count)"
        case .subfolders: return "Subfolders \(count)"
        }
    }

    /// One progress from the generator's counts of the window's photos (`ThumbnailStore.generatorProgress`), the
    /// cover queue's of Home's client (`CoverQueue.progress`), the walk's while one runs (`ThumbsWalk.progress`; nil:
    /// none for this window) and the pauses: the user's wins when both hold. A walk that stopped early ("Too many
    /// folders") leaves no folder counted as still to do. `aheadWaitsForShare`: the share of the folder on screen is
    /// offline (`ThumbnailStore.isShareOffline`), so its cards' subfolders still to do wait for it, and the popover says
    /// so as the walk does. `unlistedInView`: the photos in view and the margin that the generator does not count yet
    /// because the folder's listing is still names only (a share's first pass gives no stamps): they wait to be made,
    /// so they count in view, none of them done. `shareOffline`: the share of the folder on screen is offline, so
    /// all of what is in view and of the folder's photos still to do waits for it; `unlistedWaitsForShare`: the complete listing does not come
    /// (it failed, or the share does not answer), so the unlisted photos wait for it. What waits is not work: the
    /// state is not working on its account, and says "Waiting for the share".
    public static func join(generator: GeneratorProgress, covers: CoverProgress, walk: WalkProgress?, pausedByUser: Bool,
                            browsing: Bool, aheadWaitsForShare: Bool = false, unlistedInView: Int = 0,
                            shareOffline: Bool = false, unlistedWaitsForShare: Bool = false) -> ThumbsProgress {
        var subfolders = covers.ahead
        if let walk {
            subfolders.done += walk.folders.done
            subfolders.total += walk.stopped == nil ? walk.folders.total : walk.folders.done
        }
        let inView = WorkCount(done: covers.inView.done + covers.margin.done + generator.visible.done,
                               total: covers.inView.total + covers.margin.total + generator.visible.total
                                   + unlistedInView)
        let rest = WorkCount(done: generator.all.done - generator.visible.done,
                             total: generator.all.total - generator.visible.total)
        let aheadWaits = aheadWaitsForShare && covers.ahead.done < covers.ahead.total
        let inViewLeft = inView.total - inView.done
        let inViewWaiting = shareOffline ? inViewLeft : unlistedWaitsForShare ? min(unlistedInView, inViewLeft) : 0
        let waits = aheadWaits || inViewWaiting > 0
        return ThumbsProgress(inView: inView, rest: rest, photos: generator.all, subfolders: subfolders,
                              paused: pausedByUser ? .user : browsing ? .browsing : nil,
                              walkNote: walk.flatMap { $0.waiting ?? $0.stopped } ?? (waits ? ThumbsWalk.waitingForShare : nil),
                              subtreeRunning: walk?.running ?? false, inViewWaiting: inViewWaiting,
                              photosWaiting: shareOffline ? generator.all.total - generator.all.done : 0)
    }

    /// What the toolbar's pill and its popover draw (`HomeBrowserView.setProgress`): the text and the current stage's
    /// share, the rows "In view", "Rest of folder", "Subfolders", and the note under them: "Paused" (the user's),
    /// "Paused while you browse" (the viewer's), else the walk's word. Nil once all is done.
    public var state: ThumbsProgressState? {
        stage == nil ? nil : display
    }

    /// The same, whether or not anything is still to do (View › Thumbnails… for any folder): once all is done (or
    /// with nothing at all) not `working`, so the pill stays out while the popover shows the counts.
    public var display: ThumbsProgressState {
        let note: String? = switch paused {
        case .user: "Paused"
        case .browsing: "Paused while you browse"
        case nil: walkNote
        }
        let count = current
        return ThumbsProgressState(
            fraction: count.map { $0.total > 0 ? Double($0.done) / Double($0.total) : 0 } ?? 0, text: text ?? "",
            paused: paused != nil,
            rows: [.init(title: "In view", done: inView.done, total: inView.total),
                   .init(title: "Rest of folder", done: rest.done, total: rest.total),
                   .init(title: "Subfolders", done: subfolders.done, total: subfolders.total)],
            pauseNote: note, pausedByUser: paused == .user, working: stage != nil, subtreeRunning: subtreeRunning)
    }
}
