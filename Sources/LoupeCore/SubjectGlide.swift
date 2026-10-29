import Foundation

/// When subjects found after the photo came may still move its view (smart zoom spec §5): only within `window` of the
/// photo showing, while it is still the photo on screen, and only while its view is the one it came with (`cameWith`:
/// the mode, the centre and the view's size; a finer level laid out changes the image size only). Any zoom, pan or
/// command since, by whatever input, changed one of them; then the view stays and the boxes serve the next visit.
public enum SubjectGlide {
    public static let window: TimeInterval = 0.3

    public static func shouldGlide(shownAt: TimeInterval, now: TimeInterval, cameWith: ViewTransform,
                                   now view: ViewTransform, samePhoto: Bool) -> Bool {
        samePhoto && now - shownAt <= window && view.mode == cameWith.mode && view.center == cameWith.center
            && view.viewSize == cameWith.viewSize
    }
}
