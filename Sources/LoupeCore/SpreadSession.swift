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
    /// page stands alone, so only a change across width = height matters.
    public static func changesPairing(from old: PixelSize?, to new: PixelSize) -> Bool {
        isLandscape(old) != isLandscape(new)
    }

    private static func isLandscape(_ s: PixelSize?) -> Bool { s.map { $0.width > $0.height } ?? false }

    /// The size a page is laid out at beside a page of size `other`: its own when known, else `other`'s height at its
    /// aspect, else `other` itself (two pages of a book are mostly alike). Its real size replaces it once read.
    public static func pageSize(known: CGSize?, aspect: Double?, other: CGSize) -> CGSize {
        if let known, known.width > 0, known.height > 0 { return known }
        if let aspect, aspect.isFinite, aspect > 0 { return CGSize(width: other.height * aspect, height: other.height) }
        return other
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

    /// `D`: `spread` the other way round in `config`, as loupe.conf spells it.
    public static func toggled(_ config: Config) -> String { config.spread ? "no" : "yes" }

    /// `⌥D`: `spread-shift` the other way round in `config`.
    public static func toggledShift(_ config: Config) -> String { config.spreadShift ? "no" : "yes" }

    public static func toast(on: Bool) -> String { on ? "Two pages" : "One page" }

    /// `⇧D`, after loupe.conf took the value.
    public static func savedToast(on: Bool) -> String { toast(on: on) + " · saved as default" }

    public static func toast(shift: Bool) -> String { shift ? "Pages shifted" : "Pages not shifted" }
}
