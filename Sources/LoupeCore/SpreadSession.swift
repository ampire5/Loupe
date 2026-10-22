import CoreGraphics
import Foundation

/// A folder's spread keys as the viewer reads them: whether two pages are shown and how they pair.
public struct SpreadRules: Equatable, Sendable {
    public var on: Bool
    public var options: SpreadOptions

    public init(on: Bool, options: SpreadOptions) {
        self.on = on
        self.options = options
    }

    /// `spread`, `spread-shift`, `spread-direction`, `spread-landscape` of `config` (loupe.conf with a folder's values).
    public init(config: Config) {
        self.init(on: config.spread, options: config.spreadOptions)
    }

    public static let off = SpreadRules(on: false, options: SpreadOptions(shift: false, rightToLeft: false,
                                                                         landscapeAlone: true))
}

/// How the viewer moves through a folder shown as a spread (spread spec, «Листание»): a step goes to the next or
/// previous pair, Home / End to the first / last one. The current photo is any page of the pair on screen (turning
/// two pages on mid-folder shows the pair containing it); a step lands on the first page of the next pair. Inactive
/// (spread off, or a view narrower than it is tall: `SpreadLayout.showsTwo`) it steps by single pages.
public struct SpreadNavigation: Sendable {
    /// The folder's plan; nil while the spread is off.
    public let plan: SpreadPlan?
    /// The view is wide enough for two pages.
    public let showsTwo: Bool

    public init(plan: SpreadPlan?, showsTwo: Bool) {
        self.plan = plan
        self.showsTwo = showsTwo
    }

    /// Pairs are shown: the spread is on and the view is wide enough.
    public var isActive: Bool { plan != nil && showsTwo }

    /// Why the page at `current` shows alone with two pages on, when the screen does not say it: a narrow view, a wide
    /// page or a wide neighbour. Nil while off or for a pair.
    public func refusal(at current: Int) -> SpreadRefusal? {
        guard let plan else { return nil }
        return showsTwo ? plan.refusal(at: current) : .narrowWindow
    }

    /// The pair on screen with `current`, nil while inactive.
    public func pair(at current: Int) -> SpreadPair? {
        guard showsTwo else { return nil }
        return plan?.pair(containing: current)
    }

    /// The other page of the pair on screen with `current`, nil for a single page.
    public func companion(of current: Int) -> Int? {
        guard let pair = pair(at: current), let second = pair.second else { return nil }
        return current == pair.first ? second : pair.first
    }

    /// The cache focus's `previousCompanion`: the other page of the pair `previous` (the photo current before) is in,
    /// from the plan, so a strip scrub's origin (`StripScrub`, the previous photo for the whole scrub) keeps its own
    /// page however many cells the scrub passed. Nil for none, one page or a page alone.
    public func previousCompanion(of previous: Int?) -> Int? {
        previous.flatMap(companion(of:))
    }

    /// The cache focus's `companion` and `step` with `current` (neighbours go by pairs while pairs are shown).
    public func focus(current: Int) -> (companion: Int?, step: Int) {
        (companion(of: current), isActive ? 2 : 1)
    }

    /// Where a step of `step` (> 0 forward) from `current` lands in a playlist of `count`: the first page of the pair
    /// `step` pairs away, or `current + step` while inactive. Nil past either end (no wrap-around).
    public func target(from current: Int, by step: Int, count: Int) -> Int? {
        guard let plan, let start = pair(at: current) else {
            let (target, overflow) = current.addingReportingOverflow(step)
            return !overflow && (0..<count).contains(target) ? target : nil
        }
        var pair = start
        for _ in 0..<step.magnitude {
            guard let next = step > 0 ? plan.next(after: pair) : plan.previous(before: pair) else { return nil }
            pair = next
        }
        return pair.first
    }

    /// Home: the first page; `current` itself when it already is in the first pair.
    public func first(from current: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let plan, let pair = pair(at: current), let first = plan.first else { return 0 }
        return pair == first ? current : first.first
    }

    /// End: the first page of the last pair (the last page while inactive); `current` when it already is in that pair.
    public func last(from current: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let plan, let pair = pair(at: current), let last = plan.last else { return count - 1 }
        return pair == last ? current : last.first
    }

    /// The page that stays when a pair on screen (`shown`) gives way to one page (a narrow view, the spread turned off):
    /// its first page in reading order (spread spec, «Узкое окно»). Nil: nothing to move, `current` stays.
    public static func single(after shown: SpreadPair?, current: Int) -> Int? {
        guard let shown, shown.second != nil, shown.first != current else { return nil }
        return shown.first
    }
}

/// The page sizes a spread is planned and laid out with, from what the viewer knows without reading a file: the
/// headers of the pages it has read (exact) and the thumbnail store's aspects (its catalog); nil is unknown, which
/// `SpreadPlan` counts as portrait.
public enum SpreadSizes {
    /// Height of a size made from an aspect alone: only its shape matters to the plan.
    static let aspectHeight = 10_000

    /// One per file: its header's size where known, else one of the store's aspect, else nil. `aspects` is parallel
    /// to `files` (shorter: the rest unknown).
    public static func sizes(files: [URL], aspects: [Double?], headers: [URL: PixelSize]) -> [PixelSize?] {
        var sizes = [PixelSize?](repeating: nil, count: files.count)
        for i in files.indices {
            if !headers.isEmpty, let header = headers[files[i]] {
                sizes[i] = header
            } else if i < aspects.count, let aspect = aspects[i] {
                sizes[i] = size(aspect: aspect)
            }
        }
        return sizes
    }

    /// A size of that shape (width / height), nil for none.
    public static func size(aspect: Double) -> PixelSize? {
        guard aspect.isFinite, aspect > 0 else { return nil }
        return PixelSize(width: max(1, Int((aspect * Double(aspectHeight)).rounded())), height: aspectHeight)
    }

    /// Whether a page that was planned at `old` (nil: unknown, portrait) pairs differently at `new`: only a landscape
    /// page stands alone, so only a change across `SpreadPlan.landscapeAspect` matters.
    public static func changesPairing(from old: PixelSize?, to new: PixelSize) -> Bool {
        SpreadPlan.isLandscape(old) != SpreadPlan.isLandscape(new)
    }

    /// The size a page is laid out at beside a page of size `other`: its own when known, else `other`'s height at the
    /// store's aspect; its real size replaces it once read. Nil while neither is known: the pair waits for the page's
    /// header, since a stand-in of `other`'s shape would show a pair that a wide page then takes back (a flicker, then
    /// one page). A page that `failed` has no size to wait for and keeps `other` (two pages of a book are mostly alike).
    public static func pageSize(known: CGSize?, aspect: Double?, other: CGSize, failed: Bool = false) -> CGSize? {
        if let known, known.width > 0, known.height > 0 { return known }
        if let aspect, aspect.isFinite, aspect > 0 { return CGSize(width: other.height * aspect, height: other.height) }
        return failed ? other : nil
    }

    /// Whether the photo on screen is laid out at a size its pair does not keep, so a saved view of the pair waits for
    /// the real one (`ViewRestore.waiting`): the other page has a stand-in size (`standIn`), or a page is planned beside
    /// it (`companionPlanned`) and not read yet (`companionRead`: its header is in, or it failed), which with no store
    /// aspect leaves the photo alone until the header comes (`pageSize`). A page that failed keeps its stand-in for
    /// good, and a wide one takes the pair back (no page planned): either way the size on screen is final.
    public static func isProvisional(standIn: Bool, companionPlanned: Bool, companionRead: Bool) -> Bool {
        standIn || (companionPlanned && !companionRead)
    }
}

/// How the view follows a page whose layout changed under it (spread spec, «Раскладка пары»): two pages on or off, a
/// narrow view, the other page's real size replacing a stand-in. The transform's picture is the pair's virtual one, so
/// a relative centre or a times-fit zoom would name another spot or scale of the page; the page on screen keeps both.
public enum SpreadZoom {
    /// `t` (its picture holding the page at `from`; nil: the page is the whole picture) laid out at `size` with the
    /// page at `to`: the centre names the same spot of the page, and a free zoom keeps the scale the page is drawn at
    /// (pages are as tall as their picture, so that is the picture's scale times the rects' height ratio). Named modes
    /// stay; transient offset and stretch go, as with `withImageSize`.
    public static func carried(_ t: ViewTransform, from: CGRect?, to size: CGSize, at to: CGRect?) -> ViewTransform {
        let old = from ?? CGRect(origin: .zero, size: t.imageSize)
        let new = to ?? CGRect(origin: .zero, size: size)
        var next = t.withImageSize(size)
        guard old.width > 0, old.height > 0, new.width > 0, new.height > 0, size.width > 0, size.height > 0 else {
            return next
        }
        // The spot of the page under the centre, 0…1 of the page.
        let px = (t.center.x * t.imageSize.width - old.minX) / old.width
        let py = (t.center.y * t.imageSize.height - old.minY) / old.height
        next.center = CGPoint(x: (new.minX + px * new.width) / size.width, y: (new.minY + py * new.height) / size.height)
        if case .free = t.mode {
            next.mode = .free(t.scale * old.height / new.height / next.fitScale)
        }
        return next
    }
}

/// A pair giving way to its first page alone while the second was current (`D` off, a narrow view): the viewer
/// navigates to the first page, which keeps its spot and drawn scale (`SpreadZoom.carried`) instead of a switch's
/// carried zoom. Carried when the page is shown, from the transform of then, so a resize meanwhile (a narrow collapse
/// comes during a live resize) is the window's current size; a zoom key, a pan or another layout meanwhile drops it.
public struct SpreadCollapse: Equatable, Sendable {
    public let page: URL
    /// The page's rect in the pair's virtual picture, and its own size.
    public let rect: CGRect
    public let pageSize: CGSize
    /// The pair's view when the pair gave way: its picture's size, mode and centre.
    private let sourceSize: CGSize
    private let sourceMode: ZoomMode
    private let sourceCenter: CGPoint

    public init(page: URL, rect: CGRect, pageSize: CGSize, from t: ViewTransform) {
        self.page = page
        self.rect = rect
        self.pageSize = pageSize
        sourceSize = t.imageSize
        sourceMode = t.mode
        sourceCenter = t.center
    }

    /// The view `url` laid out at `size` gets over `base` (the transform of now: still the pair's picture, at the
    /// window's current size): the page's spot and scale carried out of the pair; nil for another photo or size, or
    /// when `base` is no longer the pair's view as it was (a zoom key's mode, a pan, a resize that rescaled a free
    /// zoom), which then takes the normal switch.
    public func transform(for url: URL, size: CGSize, over base: ViewTransform) -> ViewTransform? {
        guard url == page, size == pageSize, base.imageSize == sourceSize, base.mode == sourceMode,
              base.center == sourceCenter else { return nil }
        return SpreadZoom.carried(base, from: rect, to: size, at: nil)
    }
}

/// What the viewer's spread keys do (spread spec, «Поведение»), on the model of `ZoomKeys`: `D` turns two pages on or
/// off for the window's folder, `⇧D` saves the window's value as loupe.conf's default, `⌥D` shifts the pairs by a
/// page. Pure: the window controller writes `FolderSettings` / loupe.conf and shows these toasts.
public enum SpreadKeys {
    /// The key `D` writes and `⇧D` saves.
    public static let key = "spread"
    /// The key `⌥D` writes.
    public static let shiftKey = "spread-shift"
    /// The key View › Right to Left writes.
    public static let directionKey = "spread-direction"
    /// The key View › Landscape Pages Alone writes.
    public static let landscapeKey = "spread-landscape"

    /// `D`: `spread` the other way round in `config`, as loupe.conf spells it.
    public static func toggled(_ config: Config) -> String { config.spread ? "no" : "yes" }

    /// `⌥D`: `spread-shift` the other way round in `config`.
    public static func toggledShift(_ config: Config) -> String { config.spreadShift ? "no" : "yes" }

    public static func toast(on: Bool) -> String { on ? "Two pages" : "One page" }

    /// `D`, with why the page shows alone when the screen does not say it (`SpreadNavigation.refusal`).
    public static func toast(on: Bool, refusal: SpreadRefusal?) -> String {
        guard on, let refusal else { return toast(on: on) }
        switch refusal {
        case .widePage: return toast(on: on) + " · this page is wide"
        case .wideNext: return toast(on: on) + " · next page is wide"
        case .narrowWindow: return toast(on: on) + " · window too narrow"
        }
    }

    /// `⇧D`, after loupe.conf took the value.
    public static func savedToast(on: Bool) -> String { toast(on: on) + " · saved as default" }

    public static func toast(shift: Bool) -> String { shift ? "Pages shifted" : "Pages not shifted" }

    /// View › Right to Left: `spread-direction` the other way round in `config`.
    public static func toggledDirection(_ config: Config) -> String { config.spreadRightToLeft ? "ltr" : "rtl" }

    public static func toast(rightToLeft: Bool) -> String { rightToLeft ? "Right to left" : "Left to right" }

    /// View › Landscape Pages Alone: `spread-landscape` the other way round in `config`.
    public static func toggledLandscape(_ config: Config) -> String { config.spreadLandscapeAlone ? "pair" : "alone" }

    public static func toast(landscapeAlone: Bool) -> String {
        landscapeAlone ? "Landscape pages alone" : "Landscape pages in pairs"
    }
}
