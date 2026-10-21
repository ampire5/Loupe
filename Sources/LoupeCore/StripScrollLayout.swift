import Foundation

/// One cell of the thumbnail strip: `range` is the files it stands for and `file` the one it shows
/// (the middle of the range). `x` is its left edge in points from the strip view's left edge, `width` its
/// width (the strip's cell height is the layout's).
public struct StripCell: Equatable, Sendable {
    public let range: Range<Int>
    public let file: Int
    public let x: Double
    public let width: Double
}

/// The thumbnail strip as Photos' filmstrip: one narrow cell per file on a line that moves under the strip's
/// fixed centre, the current photo there in its own proportions. Pure arithmetic in points, no AppKit.
///
/// Every cell shares one width `cellWidth` — the strip's width over the file count, kept between 9:16 of the
/// height (`narrowAspect`, a big folder) and `maxAspect` of it (`strip-cell-max`, a few files) — but is never wider
/// than its photo (`narrowWidth(of:)`). The base line lays the narrow cells out with a `gapRatio` gap from x 0;
/// an offset is the base x under the strip's centre. At rest the current cell expands (`expansion` 0 → 1) to its
/// photo's proportions with `currentPaddingRatio` on each side, around its own centre, pushing its neighbours
/// apart; the base line, and so the file under a point, ignores that expansion.
///
/// While no known photo is narrower than `cellWidth` the base line is a formula; otherwise its cell starts are
/// prefix sums made once here (O(n)) and searched by bisection. A window of cells costs O(visible cells) either way.
public struct StripScrollLayout: Equatable, Sendable {
    /// The narrow cell's aspect (width : height) in a big folder: 9:16, as Photos.
    public static let narrowAspect = 0.5625
    /// The gap between cells, as a share of the height.
    public static let gapRatio = 0.028
    /// Photos' corner radius as a share of the height (`strip-corner-radius` gives the radius; 3 pt ≈ 0.045 · 68).
    public static let radiusRatio = 0.045
    /// The expanded current cell's space on each side, as a share of the height.
    public static let currentPaddingRatio = 0.12
    /// The length of the fading edges, as a share of the height.
    public static let fadeRatio = 0.85
    /// The current cell's aspect while its photo's is not known.
    public static let unknownCurrentAspect = 1.5

    public let fileCount: Int
    public let width: Double
    public let cellHeight: Double
    /// The width every cell shares (0 for an empty folder).
    public let cellWidth: Double
    public let gap: Double
    /// The aspects by file (`nil`: not known); shorter than the folder while they arrive.
    private let aspects: [Double?]
    /// The left edge of each narrow cell on the base line, plus the end (`fileCount + 1` values); empty while
    /// every cell is `cellWidth` wide.
    private let starts: [Double]

    public init(fileCount: Int, width: Double, cellHeight: Double, maxAspect: Double, aspects: [Double?]) {
        self.fileCount = max(0, fileCount)
        self.width = width
        self.cellHeight = cellHeight
        self.aspects = aspects
        gap = Self.gapRatio * cellHeight
        if self.fileCount == 0 {
            cellWidth = 0
        } else {
            let lower = Self.narrowAspect * cellHeight, upper = max(lower, maxAspect * cellHeight)
            cellWidth = min(max(width / Double(self.fileCount), lower), upper)
        }
        let cellWidth = cellWidth, cellHeight = cellHeight
        let narrower = aspects.prefix(self.fileCount).contains { $0.map { $0 * cellHeight < cellWidth } ?? false }
        guard narrower else {
            starts = []
            return
        }
        var starts = [Double](repeating: 0, count: self.fileCount + 1)
        var x = 0.0
        for file in 0..<self.fileCount {
            starts[file] = x
            let aspect = file < aspects.count ? aspects[file] : nil
            x += (aspect.map { min(cellWidth, $0 * cellHeight) } ?? cellWidth) + gap
        }
        starts[self.fileCount] = x
        self.starts = starts
    }

    /// The file's cell width while it is not the expanded current one: `cellWidth`, or its photo's width at the
    /// cell height when that is narrower.
    public func narrowWidth(of file: Int) -> Double {
        guard file >= 0, file < aspects.count, let aspect = aspects[file] else { return cellWidth }
        return min(cellWidth, aspect * cellHeight)
    }

    /// The base x of the file's left edge.
    private func start(of file: Int) -> Double {
        starts.isEmpty ? Double(file) * (cellWidth + gap) : starts[file]
    }

    /// The base x of the file's centre: every cell narrow, gaps only.
    public func centre(of file: Int) -> Double {
        start(of: file) + narrowWidth(of: file) / 2
    }

    /// The file whose cell, with half a gap on each side, holds base x; the first or last beyond the ends; nil for
    /// an empty folder.
    public func file(atBase x: Double) -> Int? {
        guard fileCount > 0 else { return nil }
        let shifted = x + gap / 2
        if starts.isEmpty {
            let file = Int((shifted / (cellWidth + gap)).rounded(.down).clamped(to: -1...Double(fileCount)))
            return min(max(file, 0), fileCount - 1)
        }
        // The last file whose start is at or before `shifted`.
        var low = 0, high = fileCount - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= shifted { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// The offsets that put a file under the centre: the first file's to the last's.
    public var offsetRange: ClosedRange<Double> {
        guard fileCount > 0 else { return 0...0 }
        return centre(of: 0)...centre(of: fileCount - 1)
    }

    /// The length of the fading edges.
    public var fadeLength: Double { Self.fadeRatio * cellHeight }

    /// How far each edge of `cells` (as `cells(offset:current:expansion:)` gives them) fades: `fadeLength` where the
    /// strip goes on past that edge, so it shows there is more, 0 where it ends inside the view; never over the
    /// current cell.
    public func fades(cells: [StripCell], current: Int) -> (left: Double, right: Double) {
        guard let first = cells.first, let last = cells.last else { return (0, 0) }
        var left = first.x < 0 ? fadeLength : 0
        var right = last.x + last.width > width ? fadeLength : 0
        if let shown = cells.first(where: { $0.file == current }) {
            left = min(left, max(0, shown.x))
            right = min(right, max(0, width - shown.x - shown.width))
        }
        return (left, right)
    }

    /// The cells on screen, plus one beyond each edge, left to right, in view x: base x `offset` at the strip's
    /// centre, `current` expanded by `expansion` (0 narrow … 1 its photo's proportions, padded).
    public func cells(offset: Double, current: Int, expansion: Double) -> [StripCell] {
        guard fileCount > 0, let middle = file(atBase: offset) else { return [] }
        let e = min(max(expansion, 0), 1)
        var grown = 0.0, padding = gap
        if e > 0, current >= 0, current < fileCount {
            let narrow = narrowWidth(of: current)
            let aspect = (current < aspects.count ? aspects[current] : nil) ?? Self.unknownCurrentAspect
            let full = min(max(aspect * cellHeight, narrow), width)
            grown = (full - narrow) * e
            padding = gap + (Self.currentPaddingRatio * cellHeight - gap) * e
        }
        // The current cell grows around its centre; every cell beyond it moves out by half of that and the
        // padding's extra.
        let shift = grown / 2 + (padding - gap)
        let origin = width / 2 - offset
        func cell(_ file: Int) -> StripCell {
            let narrow = narrowWidth(of: file)
            let x: Double, w: Double
            if file == current && grown > 0 {
                w = narrow + grown
                x = origin + centre(of: file) - w / 2
            } else {
                w = narrow
                x = origin + start(of: file) + (file < current ? -shift : file > current ? shift : 0)
            }
            return StripCell(range: file..<(file + 1), file: file, x: x, width: w)
        }
        var left: [StripCell] = [], right: [StripCell] = []
        var file = middle - 1
        while file >= 0 {
            let c = cell(file)
            left.append(c)
            if c.x + c.width < 0 { break }
            file -= 1
        }
        file = middle + 1
        while file < fileCount {
            let c = cell(file)
            right.append(c)
            if c.x > width { break }
            file += 1
        }
        return left.reversed() + [cell(middle)] + right
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double { min(max(self, range.lowerBound), range.upperBound) }
}

/// The strip across a playlist change (a listing that arrives in parts, `FolderWatcher`, a re-read).
public enum StripPlaylist {
    /// Each old index's place in the new list, by URL; files that went have none. A list that only grew at its end
    /// maps without hashing.
    public static func indexMap(from old: [URL], to new: [URL]) -> [Int: Int] {
        if new.starts(with: old) { return Dictionary(uniqueKeysWithValues: old.indices.map { ($0, $0) }) }
        var places: [URL: Int] = [:]
        places.reserveCapacity(new.count)
        for (index, url) in new.enumerated() where places[url] == nil { places[url] = index }
        var map: [Int: Int] = [:]
        for (index, url) in old.enumerated() { if let place = places[url] { map[index] = place } }
        return map
    }
}
