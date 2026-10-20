import Foundation

/// `show-blurry`: whether a not-yet-sharp image may be shown while the sharp one loads.
public enum ShowBlurry: String, Sendable {
    /// Only an image that is sharp enough for the current scale.
    case no
    /// A coarse far preview (one level softer) is fine at Fit scale or smaller, never when zoomed in further.
    case fit
    /// Show whatever is resident at once and refine it (EdgeView's "Normal first, then High Quality").
    case always
}

/// The `cache-*` and `show-blurry` settings the cache plan works to (spec §3.5), validated.
public struct CacheLimits: Equatable, Sendable {
    /// `cache-full`: 0 the current photo only, 1 also the next, 2 also the previous.
    public var full = 1
    /// `cache-previews`: photos kept at least at preview resolution, the current one included.
    public var previews = 20
    /// `cache-far-previews=coarse`: previews beyond the near neighbours are one level coarser (a quarter of the memory).
    public var farPreviewsCoarse = true
    /// `cache-files`: neighbours kept as compressed bytes.
    public var files = 24
    /// `cache-memory`: a fuse over the sum of everything planned.
    public var memory = 3 << 30
    /// `cache-idle-trim`: how long a tab may go unused before its cache is trimmed; nil: never.
    public var idleTrim: Duration? = .seconds(30 * 60)
    /// `cache-idle-keep`: what the trim leaves.
    public var idleKeep = CacheIdleKeep.full
    public var showBlurry = ShowBlurry.no

    public init() {}

    public init(config: Config) {
        full = config.cacheFull
        previews = config.cachePreviews
        farPreviewsCoarse = config.cacheFarPreviewsCoarse
        files = config.cacheFiles
        memory = config.cacheMemory
        idleTrim = config.cacheIdleTrimMinutes == 0 ? nil : .seconds(config.cacheIdleTrimMinutes * 60)
        idleKeep = config.cacheIdleKeep
        showBlurry = config.showBlurry
    }
}
