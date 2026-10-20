import Foundation

/// Whether a photo's cache entry may replace what is on screen (M2 spec §4.5, `show-blurry` §3.5).
public enum ShowPolicy {
    /// `finestResident`: the entry's finest resident level (nil: nothing on the GPU). `neededLevel`: the level the
    /// scale it would be shown at needs (`TileGrid.level(forScale:)`). `previewLevel`: its Lfit.
    /// `.no`: sharp enough only. `.fit`: also one level coarser while the scale is Fit or smaller (needed level not
    /// finer than Lfit). `.always`: anything resident.
    /// `jumpPreview`: the entry was seeded by a strip jump or scrub and `strip-jump-preview` is on (M2.5 spec §5.2):
    /// the stretched thumbnail is shown at once, whatever the mode, since the user asked to land far away.
    public static func shouldShow(finestResident: Int?, neededLevel: Int, previewLevel: Int, mode: ShowBlurry,
                                  jumpPreview: Bool = false) -> Bool {
        guard let finest = finestResident else { return false }
        if finest <= neededLevel || jumpPreview { return true }
        switch mode {
        case .no: return false
        case .fit: return neededLevel >= previewLevel && finest <= neededLevel + 1
        case .always: return true
        }
    }

    /// Whether a step that waits for its photo (`wheel-step` / `key-step`, `wait`; nil for any other navigation)
    /// shows the entry even where `shouldShow` would not: the wait can only end once something of the photo is on
    /// screen, so the step shows what it waits for. `thumb`: anything resident, its seeded thumbnail or a decoded
    /// level it already has (a cached neighbour shows that, not a thumbnail flash); `coarse`: any decoded level, not
    /// the thumbnail. `sharp` and `any` add nothing: `show-blurry` decides, as it does for every step; the step only
    /// ever shows more.
    public static func shownByStep(_ wait: StepWait?, finestResident: Int?, seededOnly: Bool) -> Bool {
        guard finestResident != nil, let wait else { return false }
        switch wait {
        case .thumb: return true
        case .coarse: return !seededOnly
        case .sharp, .any: return false
        }
    }

    /// Whether `candidate`, the current photo's entry, only refines what is on screen (`shown`), so it takes the
    /// screen without asking `shouldShow` (a photo shown is never hidden; finer levels just arrive): the same
    /// pyramid, or, while the photo is on screen as its stretched thumbnail, any pyramid of that photo. The first
    /// decoded level replaces a seeded pyramid with a new object (`ImageCache.seed`), and so does a finer seed; with
    /// identity alone the dropped thumbnail would stay on screen until the new pyramid passed `shouldShow` (with
    /// `show-blurry=no`, the preview).
    public static func refinesShown<P: AnyObject & Sendable>(_ candidate: CacheEntryView<P>,
                                                            shown: CacheEntryView<P>?) -> Bool {
        guard let shown, shown.url == candidate.url, shown.failure == nil,
              let pyramid = candidate.pyramid else { return false }
        return shown.pyramid === pyramid || shown.isSeededOnly
    }
}
