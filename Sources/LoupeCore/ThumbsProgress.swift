import Foundation

/// How far Home's preparation of a folder is, for the toolbar's pill and its popover (thumbs-ahead spec, "Пилюля в
/// тулбаре"): one value joined from the three counters (the generator's for the window, the cover queue's for the
/// client, the subtree walk's for the command) and the pauses.
///
/// The pill names the current stage: the rest of the folder's photos while some are still to be made ("Thumbnails
/// 120 / 480"), then the subfolders ("Subfolders 5 / 48"); paused, "Paused · 120 / 480"; nothing once both are done.
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

    /// The folder's cards in view and their margin (stages 1–2).
    public var inView: WorkCount
    /// The folder's photos: those with a thumbnail of all listed (stage 3, the generator's window).
    public var rest: WorkCount
    /// The visible cards' subfolders (a cover and a summary each), with the walk's folders while it runs.
    public var subfolders: WorkCount
    public var paused: Pause?

    public init(inView: WorkCount = WorkCount(), rest: WorkCount = WorkCount(), subfolders: WorkCount = WorkCount(),
                paused: Pause? = nil) {
        self.inView = inView
        self.rest = rest
        self.subfolders = subfolders
        self.paused = paused
    }

    /// The photos while some are still to be made, then the subfolders; nil once both are done.
    public var stage: Stage? {
        if rest.done < rest.total { return .thumbnails }
        if subfolders.done < subfolders.total { return .subfolders }
        return nil
    }

    /// The current stage's count (the pill's ring is its share), nil once all is done.
    public var current: WorkCount? {
        switch stage {
        case .thumbnails: rest
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

    /// One progress from the generator's count of the window's listing (`ThumbnailStore.generatorProgress`), the
    /// cover queue's of Home's client (`CoverQueue.progress`), the walk's while one runs (`ThumbsWalk.progress`; nil:
    /// none for this window) and the pauses: the user's wins when both hold. A walk that stopped early ("Too many
    /// folders") leaves no folder counted as still to do.
    public static func join(generator: WorkCount, covers: CoverProgress, walk: WalkProgress?, pausedByUser: Bool,
                            browsing: Bool) -> ThumbsProgress {
        var subfolders = covers.ahead
        if let walk {
            subfolders.done += walk.folders.done
            subfolders.total += walk.stopped == nil ? walk.folders.total : walk.folders.done
        }
        let inView = WorkCount(done: covers.inView.done + covers.margin.done,
                               total: covers.inView.total + covers.margin.total)
        return ThumbsProgress(inView: inView, rest: generator, subfolders: subfolders,
                              paused: pausedByUser ? .user : browsing ? .browsing : nil)
    }
}
