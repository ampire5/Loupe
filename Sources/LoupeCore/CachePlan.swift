import Foundation

/// How much of a photo's pyramid is wanted resident. Ordered by that amount: coarse = level Lfit + 1 and
/// coarser, preview = Lfit and coarser, full = every level; bytes is the compressed file only.
public enum CacheGoal: Int, Comparable, Sendable {
    case bytes, coarse, preview, full

    public static func < (a: CacheGoal, b: CacheGoal) -> Bool { a.rawValue < b.rawValue }
}

/// One wanted cache state: `index` in the playlist reaches `goal`, which adds `cost` bytes of memory.
public struct CacheItem: Equatable, Sendable {
    public let index: Int
    public let goal: CacheGoal
    public let cost: Int

    public init(index: Int, goal: CacheGoal, cost: Int) {
        self.index = index
        self.goal = goal
        self.cost = cost
    }
}

/// What the plan knows about one playlist entry. Unknown fields are estimated, so a folder can be planned
/// before anything in it has been probed.
public struct EntryFacts: Equatable, Sendable {
    public var pixelSize: PixelSize?   // nil before probe; as stored
    /// The file's EXIF orientation (`.up` before probe): Lfit is the fit of the picture as shown.
    public var orientation: ImageOrientation
    public var fileSize: Int?          // nil before stat/read
    public var failed = false
    /// Its full resolution is resident or being decoded: worth keeping, never worth starting (spec §11.1.7).
    public var fullKept = false

    public init(pixelSize: PixelSize? = nil, orientation: ImageOrientation = .up, fileSize: Int? = nil,
                failed: Bool = false, fullKept: Bool = false) {
        self.pixelSize = pixelSize
        self.orientation = orientation
        self.fileSize = fileSize
        self.failed = failed
        self.fullKept = fullKept
    }
}

/// Where the viewer is in the playlist.
public struct CacheFocus: Equatable, Sendable {
    public var count: Int
    public var current: Int
    /// +1 or -1 (the last step); 0 is read as +1.
    public var direction: Int
    /// The current photo has stayed put for 150 ms: worth decoding at full resolution.
    public var dwelling: Bool
    /// The current zoom needs a level finer than Lfit (e.g. 100 %): plan its full resolution first, no separate preview.
    public var needsFull: Bool
    /// The screen the window is on, in pixels (not the window: resizing must not invalidate previews).
    public var screen: PixelSize
    /// The photo shown before the current one (the one just left), nil when there is none: it keeps its full
    /// resolution if it has it, ahead of n1's (spec §11.1.7), so flipping back at 100 % stays sharp.
    public var previous: Int?
    /// The user is scrubbing the strip (M2.5 spec §5.3): the current photo is the one under the cursor, only passing
    /// through, and shown from its thumbnail. Nothing is planned, so no read or decode starts and those waiting are
    /// cancelled, as in fast stepping; what is resident stays (eviction is lazy). Dropping the flag plans as before.
    public var scrubbing: Bool
    /// `exif-orientation`: photos are shown turned by their orientation, so Lfit is the fit of the oriented size
    /// (`TileGrid.previewLevel(forScreen:orientation:)`); off, of the stored one.
    public var appliesOrientation: Bool
    /// The current photo was opened from outside (a launch, Finder, File › Open) and not moved from since: the user
    /// chose it, so its full resolution is wanted at once, decoded next to its preview rather than after the dwell
    /// (docs/bench/2026-10-15-startup.md). The neighbours still wait for the dwell.
    public var opened: Bool
    /// The second page of the pair on screen (spread), nil for a single page. It is current too: planned right
    /// after the current photo, with the same goals, and its full resolution is wanted on dwell like the current's.
    public var companion: Int?
    /// How far the neighbours go: 1 for single pages, 2 when the viewer steps by pairs. Neighbours are then
    /// planned as pairs beside the one on screen (ahead first, reading order within a pair).
    public var step: Int

    public init(count: Int, current: Int, direction: Int, dwelling: Bool, needsFull: Bool, screen: PixelSize,
                previous: Int? = nil, scrubbing: Bool = false, appliesOrientation: Bool = true, opened: Bool = false,
                companion: Int? = nil, step: Int = 1) {
        self.companion = companion
        self.step = step
        self.count = count
        self.current = current
        self.direction = direction
        self.dwelling = dwelling
        self.needsFull = needsFull
        self.screen = screen
        self.previous = previous
        self.scrubbing = scrubbing
        self.appliesOrientation = appliesOrientation
        self.opened = opened
    }
}

/// Turns the playlist position into the ordered list of cache states worth having (spec §3.2, §11.1.7). The list is
/// in priority order and fits `cache-memory`, except that the current photo's items are always included (they
/// are never skipped by the ceiling, only reduce the room left for neighbours); the cache executes it front
/// to back and degrades whatever it holds that is not in it.
public enum CachePlan {
    /// Stand-ins for a photo that has not been probed or stat'ed and has no known siblings: a 147 MP JPEG.
    public static let defaultPixelSize = PixelSize(width: 10502, height: 14000)
    public static let defaultFileSize = 12_000_000
    /// Neighbours up to this far away get a full-Lfit preview; farther ones a coarse one.
    public static let nearDistance = 3

    public static func make(focus: CacheFocus, limits: CacheLimits, facts: (Int) -> EntryFacts) -> [CacheItem] {
        guard !focus.scrubbing, (0..<focus.count).contains(focus.current) else { return [] }
        return withoutActuallyEscaping(facts) { facts in
            var builder = Builder(focus: focus, limits: limits, facts: facts)
            builder.run()
            return builder.items
        }
    }

    /// Median (by pixel count) of the known sizes, else the default: the best guess for an unprobed photo.
    private static func estimatedSize(count: Int, facts: (Int) -> EntryFacts) -> PixelSize {
        let known = (0..<count).compactMap { facts($0).pixelSize }.filter { $0.width > 0 && $0.height > 0 }
        guard !known.isEmpty else { return defaultPixelSize }
        return known.sorted { $0.width * $0.height < $1.width * $1.height }[known.count / 2]
    }

    private struct Entry {
        let facts: EntryFacts
        let grid: TileGrid
        let lfit: Int
        /// Level where the coarse preview starts; equal to `lfit` when the pyramid has nothing coarser.
        let coarseLevel: Int
    }

    private struct Builder {
        let focus: CacheFocus
        let limits: CacheLimits
        let facts: (Int) -> EntryFacts
        let estimate: PixelSize
        let direction: Int
        var items: [CacheItem] = []
        var total = 0
        var entries: [Int: Entry] = [:]
        /// Photos that have a preview or coarse item (or a full one), for `cache-previews`.
        var previewed: Set<Int> = []

        init(focus: CacheFocus, limits: CacheLimits, facts: @escaping (Int) -> EntryFacts) {
            self.focus = focus
            self.limits = limits
            self.facts = facts
            estimate = CachePlan.estimatedSize(count: focus.count, facts: facts)
            direction = focus.direction < 0 ? -1 : 1
        }

        mutating func run() {
            let current = focus.current
            let nextGroup = group(ahead: true, unit: 1), previousGroup = group(ahead: false, unit: 1)

            // 1-2. The current photo: what is on screen, then the sharp version once the user stays.
            if focus.needsFull {
                _ = add(current, .full, allLevels: true, exempt: true)
            } else {
                _ = add(current, .preview, exempt: true)
            }
            // The bytes of the photo being viewed are always kept, whatever cache-files says (it counts
            // neighbours only): the full decode after the dwell must never fetch the file from SMB again.
            _ = add(current, .bytes, exempt: true)
            // Opened: at once, unless the preview already is full resolution (Lfit 0), which would decode it twice.
            let openedFull = focus.opened && entry(current).lfit > 0
            if (focus.dwelling || openedFull) && !focus.needsFull { _ = add(current, .full, exempt: true) }

            // The companion page is current too. Its full resolution is part of the pair on screen, so it is not
            // counted against `cache-full` (see `CacheLimits.full`).
            if let companion = companionPage {
                if focus.needsFull {
                    _ = add(companion, .full, allLevels: true, exempt: true)
                } else {
                    _ = add(companion, .preview, exempt: true)
                }
                _ = add(companion, .bytes, exempt: true)
                let companionOpenedFull = focus.opened && entry(companion).lfit > 0
                if (focus.dwelling || companionOpenedFull) && !focus.needsFull { _ = add(companion, .full, exempt: true) }
            }

            // 3. Previews for the photos (the pages of the pairs) most likely to come next.
            for index in nextGroup + previousGroup where isPlannable(index) && previewed.count < limits.previews {
                _ = add(index, .preview)
            }
            // 3a. The photo just left keeps its full resolution if it still has it (or is decoding it), ahead of
            // n1's: flipping back at 100 % must not lose sharpness (spec §11.1.7). Never a new decode: planned only
            // when already kept.
            if let left = focus.previous, left != current, left != companionPage, !plansFull(left), isPlannable(left),
               entry(left).facts.fullKept {
                _ = add(left, .full)
            }
            // 4. Full resolution for the next one, so a flip lands sharp.
            if limits.full >= 1 && focus.dwelling {
                for index in nextGroup where previewed.contains(index) && !plansFull(index) { _ = add(index, .full) }
            }

            // 5. Compressed bytes, nearest first.
            var files = 0
            for index in neighbours() {
                if files >= limits.files { break }
                if isPlannable(index) && add(index, .bytes) { files += 1 }
            }

            // 6. Previews for the rest, two ahead for one behind; far ones one level coarser.
            for index in neighbours() {
                if previewed.count >= limits.previews { break }
                guard !nextGroup.contains(index), !previousGroup.contains(index), isPlannable(index) else { continue }
                _ = add(index, goalForPreview(at: index))
            }

            // 7. Full resolution for the previous one.
            if limits.full >= 2 && focus.dwelling {
                for index in previousGroup where previewed.contains(index) && !plansFull(index) { _ = add(index, .full) }
            }
        }

        /// Already has a full item (the photo just left, 3a): never planned twice.
        private func plansFull(_ index: Int) -> Bool { items.contains { $0.index == index && $0.goal == .full } }

        private mutating func goalForPreview(at index: Int) -> CacheGoal {
            let far = abs(index - focus.current) > CachePlan.nearDistance
            guard far && limits.farPreviewsCoarse else { return .preview }
            let e = entry(index)
            return e.coarseLevel > e.lfit ? .coarse : .preview
        }

        /// In the playlist and not failed; the current photo is planned even after a failure.
        private mutating func isPlannable(_ index: Int) -> Bool {
            (0..<focus.count).contains(index) && !entry(index).facts.failed
        }

        /// The second page of the pair, when it is a different photo in the playlist.
        private var companionPage: Int? {
            guard let companion = focus.companion, companion != focus.current,
                  (0..<focus.count).contains(companion) else { return nil }
            return companion
        }

        /// The pages on screen: the current photo and its companion.
        private var shown: ClosedRange<Int> {
            let c = focus.current
            guard let k = companionPage else { return c...c }
            return min(c, k)...max(c, k)
        }

        /// Group size of the neighbours: pairs while the viewer steps by pairs.
        private var groupSize: Int { max(focus.step, 1) }

        /// The in-range pages of the `unit`-th group (1 = nearest) ahead of or behind what is on screen, in
        /// the order of the plan: nearest first ahead, the farther page first behind (so in the forward direction a
        /// pair behind reads in page order, in the reverse one it does not); one page when single.
        private func group(ahead: Bool, unit: Int) -> [Int] {
            let size = groupSize
            let edge = (ahead == (direction > 0)) ? shown.upperBound : shown.lowerBound
            let sign = ahead ? direction : -direction
            let offsets = Array((((unit - 1) * size + 1)...(unit * size)))
            let ordered = ahead ? offsets : offsets.reversed()
            return ordered.map { edge + sign * $0 }.filter { (0..<focus.count).contains($0) }
        }

        /// Playlist indices around what is on screen in planning order: n1, p1, then n2, n3, p2, n4, n5, p3, ...
        /// (two ahead for one behind), where each is a group of `step` pages. Ends at the playlist's edges;
        /// out-of-range indices are skipped.
        private func neighbours() -> some Sequence<Int> {
            var unit = 0
            var pending: [Int] = []
            return sequence(state: ()) { _ -> Int? in
                while pending.isEmpty {
                    let ahead = unit == 0 ? [1] : [2 * unit, 2 * unit + 1]
                    let behind = unit == 0 ? [1] : [unit + 1]
                    let groups = ahead.map { group(ahead: true, unit: $0) } + behind.map { group(ahead: false, unit: $0) }
                    guard !(groups[0].isEmpty && groups[ahead.count].isEmpty) else { return nil }
                    pending = Array(groups.joined())
                    unit += 1
                }
                return pending.removeFirst()
            }
        }

        private mutating func entry(_ index: Int) -> Entry {
            if let cached = entries[index] { return cached }
            let facts = facts(index)
            let grid = TileGrid(imageSize: facts.pixelSize ?? estimate)
            let lfit = grid.previewLevel(forScreen: focus.screen,
                                         orientation: focus.appliesOrientation ? facts.orientation : .up)
            let made = Entry(facts: facts, grid: grid, lfit: lfit, coarseLevel: min(lfit + 1, grid.levelCount - 1))
            entries[index] = made
            return made
        }

        /// Appends the item unless it would push the total over `cache-memory`. A skipped item changes
        /// nothing, so later (smaller) ones are still tried and no tier's count is spent on it.
        /// `exempt` (the current photo's items) bypasses the ceiling, so a tiny `cache-memory` can never leave
        /// the photo on screen undisplayable; its cost still counts in the total, leaving neighbours less room.
        private mutating func add(_ index: Int, _ goal: CacheGoal, allLevels: Bool = false, exempt: Bool = false) -> Bool {
            let e = entry(index)
            let levels = e.grid.levelCount
            let cost: Int
            switch goal {
            case .bytes: cost = e.facts.fileSize ?? CachePlan.defaultFileSize
            case .coarse: cost = e.grid.byteCount(levels: e.coarseLevel..<levels)
            case .preview: cost = e.grid.byteCount(levels: e.lfit..<levels)
            case .full: cost = e.grid.byteCount(levels: 0..<(allLevels ? levels : e.lfit))
            }
            guard exempt || total + cost <= limits.memory else { return false }
            total += cost
            items.append(CacheItem(index: index, goal: goal, cost: cost))
            if goal != .bytes { previewed.insert(index) }
            return true
        }
    }
}
