import Foundation

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
/// The pill names the current stage: the folder's photos (all of them, those in view too) while some are still to be
/// made ("Thumbnails 120 / 480"), then the subfolders ("Subfolders 5 / 48"); paused, "Paused · 120 / 480"; nothing once both are done.
public struct ThumbsProgress: Equatable, Sendable {
    /// Why the work ahead waits: the user's pause (the popover's "Pause"), or the viewer busy ("Paused while you
    /// browse").
    public enum Pause: Equatable, Sendable {
        case user, browsing
    }

    /// The stage the pill names.
    public enum Stage: Equatable, Sendable {
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

    public init(inView: WorkCount = WorkCount(), rest: WorkCount = WorkCount(), photos: WorkCount = WorkCount(),
                subfolders: WorkCount = WorkCount(), paused: Pause? = nil) {
        self.inView = inView
        self.rest = rest
        self.photos = photos
        self.subfolders = subfolders
        self.paused = paused
    }

    /// The photos while some are still to be made, then the subfolders; nil once both are done.
    public var stage: Stage? {
        if photos.done < photos.total { return .thumbnails }
        if subfolders.done < subfolders.total { return .subfolders }
        return nil
    }

    /// The current stage's count (the pill's ring is its share), nil once all is done.
    public var current: WorkCount? {
        switch stage {
        case .thumbnails: photos
        case .subfolders: subfolders
        case nil: nil
        }
    }

    /// The pill's text: "Thumbnails 120 / 480", "Subfolders 5 / 48", "Paused · 120 / 480"; nil once all is done.
    public var text: String? {
        guard let stage, let current else { return nil }
        let count = "\(current.done) / \(current.total)"
        if paused != nil { return "Paused · \(count)" }
        switch stage {
        case .thumbnails: return "Thumbnails \(count)"
        case .subfolders: return "Subfolders \(count)"
        }
    }

    /// One progress from the generator's counts of the window's photos (`ThumbnailStore.generatorProgress`), the
    /// cover queue's of Home's client (`CoverQueue.progress`), the walk's while one runs (`ThumbsWalk.progress`; nil:
    /// none for this window) and the pauses: the user's wins when both hold. A walk that stopped early ("Too many
    /// folders") leaves no folder counted as still to do.
    public static func join(generator: GeneratorProgress, covers: CoverProgress, walk: WalkProgress?, pausedByUser: Bool,
                            browsing: Bool) -> ThumbsProgress {
        var subfolders = covers.ahead
        if let walk {
            subfolders.done += walk.folders.done
            subfolders.total += walk.stopped == nil ? walk.folders.total : walk.folders.done
        }
        let inView = WorkCount(done: covers.inView.done + covers.margin.done + generator.visible.done,
                               total: covers.inView.total + covers.margin.total + generator.visible.total)
        let rest = WorkCount(done: generator.all.done - generator.visible.done,
                             total: generator.all.total - generator.visible.total)
        return ThumbsProgress(inView: inView, rest: rest, photos: generator.all, subfolders: subfolders,
                              paused: pausedByUser ? .user : browsing ? .browsing : nil)
    }
}
