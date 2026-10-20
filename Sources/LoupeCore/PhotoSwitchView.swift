import CoreGraphics

/// The view a newly shown photo gets (M4b spec §4.2), one rule for every way of changing photos. A saved view from
/// `folder-view-memory` (`ViewRestore`) comes first; the session asks here only when there is none, with the rules of
/// the new photo's folder (a folder step takes the new folder's `keep-zoom-position` and `default-zoom-mode`).
public enum PhotoSwitchView {
    /// How the photo comes on screen: it is the photo the view is laid out for already (a finer level of it arrived,
    /// the cache asks about it again), another photo stepped to, or the photo `open` brought (a launch, Finder's Open).
    public enum Arrival: Sendable {
        case laidOut, switched, opened
    }

    /// The photo laid out already keeps its view whatever the rules (only its size is taken anew, as before); a switch
    /// follows `next`, an opened photo `opened`. `rules` is read only for those two: the session asks about the photo
    /// on screen on every change, and its folder's settings need not be looked up for it.
    public static func shown(_ arrival: Arrival, current: ViewTransform, imageSize: CGSize,
                             rules: @autoclosure () -> ZoomRules) -> ViewTransform {
        switch arrival {
        case .laidOut: return current.withImageSize(imageSize)
        case .switched: return next(current: current, imageSize: imageSize, rules: rules())
        case .opened: return opened(viewSize: current.viewSize, imageSize: imageSize, rules: rules())
        }
    }

    /// A switch to another photo from `current` (the session passes a running zoom animation's target): with `keep`
    /// the mode and the stored relative centre stay, else the photo opens in `defaultMode`, centred. Either way it
    /// takes `fit-upscale` from the rules, and the transient offset and stretch go.
    public static func next(current: ViewTransform, imageSize: CGSize, rules: ZoomRules) -> ViewTransform {
        guard rules.keep else { return opened(viewSize: current.viewSize, imageSize: imageSize, rules: rules) }
        var t = current.withImageSize(imageSize)
        t.fitUpscale = rules.fitUpscale
        return t
    }

    /// The first photo at launch, or one opened from Finder: `defaultMode`, centred, whatever `keep` says.
    public static func opened(viewSize: CGSize, imageSize: CGSize, rules: ZoomRules) -> ViewTransform {
        ViewTransform(imageSize: imageSize, viewSize: viewSize, mode: rules.defaultMode, fitUpscale: rules.fitUpscale)
    }
}
