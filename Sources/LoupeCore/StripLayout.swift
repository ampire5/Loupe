import Foundation

/// The thumbnail strip as a time axis over the whole folder, like a video scrub bar: cells edge to edge, one
/// per file while they fit (then the strip is centred), otherwise a sample of cells that each show the middle
/// file of an even range. Within a cell the cursor maps to the files of its range linearly, so every file of a
/// 10 000-file folder is reachable. Pure arithmetic in points, no AppKit.
///
/// Two shapes (`strip-aspect`): crop (no aspects) gives every cell 3:2, the thumbnail centre-cropped to it;
/// native gives each cell its photo's proportions, like the scrubber of Apple Photos. A sampled native strip
/// takes its cell count from the mean width and then scales every cell by one factor `k` so the strip fills
/// the width exactly: the cells shown are a sample, so their widths do not add up to the width by themselves.
/// `k` stays within `kRange` (the cells' pictures are cropped by `|1 − 1/k|`): a sample too narrow leaves the
/// rest of the width evenly on both sides, one too wide takes fewer cells.
public struct StripLayout: Equatable {
    /// Crop mode's cell aspect (width : height), and the native strip's guess while no aspect is known.
    public static let cellAspect = 1.5
    /// How far a sampled native strip may scale its cells to fill the width.
    public static let kRange = (1 / 1.15)...1.15

    /// A native strip's aspects (width / height, one per file), checked and summed once per change rather than
    /// on every layout: a resize drag lays out on every move, over folders of 10 000 files.
    public struct Aspects: Sendable {
        public let values: [Double]
        public let sum: Double

        /// Values that are not positive and finite count as `cellAspect`.
        public init(_ values: [Double]) {
            let checked = values.map { $0.isFinite && $0 > 0 ? $0 : StripLayout.cellAspect }
            self.values = checked
            sum = checked.reduce(0, +)
        }
    }

    public let fileCount: Int
    public let width: Double
    public let cellHeight: Double
    /// Crop mode's cell width (3:2 at `cellHeight`); native cells each have their own `width`.
    public let cellWidth: Double
    public let cells: [StripCell]
    /// Left edge of the first cell; positive when the strip is centred (also leaves the remainder of a
    /// sampled crop strip's width evenly on both sides).
    public let originX: Double
    /// From `originX` to the last cell's right edge.
    public let span: Double

    /// No cells when there are no files or not even one cell fits `width`. `aspects` selects the native shape;
    /// nil, or a count other than `fileCount`, is crop mode. `preferredCount` (see `preferredCount(after:…)`)
    /// is the cell count of the sampled native strip before: kept while its `k` stays in `kRange`, so the
    /// aspects streaming in during a generation pass move the cells a little instead of resampling the strip.
    public init(fileCount: Int, width: Double, cellHeight: Double, aspects: Aspects? = nil, preferredCount: Int? = nil) {
        self.fileCount = max(0, fileCount)
        self.width = width
        self.cellHeight = cellHeight
        cellWidth = cellHeight * Self.cellAspect
        assert(aspects == nil || aspects?.values.count == self.fileCount, "one aspect per file")
        let n = self.fileCount
        let laid: (cells: [StripCell], origin: Double)
        if let aspects, aspects.values.count == n {
            laid = Self.native(n, width: width, cellHeight: cellHeight, aspects: aspects, preferredCount: preferredCount)
        } else {
            laid = Self.crop(n, width: width, cellWidth: cellWidth)
        }
        cells = laid.cells
        originX = laid.cells.isEmpty ? 0 : laid.origin
        span = laid.cells.last.map { $0.x + $0.width - laid.origin } ?? 0
    }

    /// The `preferredCount` for the next layout after `previous`: its cell count when it was a sampled strip of
    /// the same files count, width and cell height; nil otherwise (a new width or height starts afresh).
    public static func preferredCount(after previous: StripLayout?, fileCount: Int, width: Double,
                                      cellHeight: Double) -> Int? {
        guard let previous, previous.fileCount == fileCount, previous.width == width,
              previous.cellHeight == cellHeight, !previous.cells.isEmpty, previous.cells.count < fileCount
        else { return nil }
        return previous.cells.count
    }

    /// The even ranges of `count` cells over `n` files, each showing its middle file.
    private static func ranges(_ n: Int, count: Int) -> [(range: Range<Int>, file: Int)] {
        (0..<count).map { i in
            let range = (i * n / count)..<((i + 1) * n / count)
            return (range, range.lowerBound + range.count / 2)
        }
    }

    private static func crop(_ n: Int, width: Double, cellWidth: Double) -> (cells: [StripCell], origin: Double) {
        guard n > 0, cellWidth > 0, width.isFinite, width >= cellWidth else { return ([], 0) }
        let count = min(n, Int((width / cellWidth).rounded(.down)))
        let origin = (width - Double(count) * cellWidth) / 2
        let cells = ranges(n, count: count).enumerated().map { i, r in
            StripCell(range: r.range, file: r.file, x: origin + Double(i) * cellWidth, width: cellWidth)
        }
        return (cells, origin)
    }

    private static func native(_ n: Int, width: Double, cellHeight: Double, aspects: Aspects,
                               preferredCount: Int?) -> (cells: [StripCell], origin: Double) {
        guard n > 0, cellHeight > 0, width.isFinite, width > 0 else { return ([], 0) }
        let values = aspects.values
        let total = aspects.sum * cellHeight
        if total <= width {
            var x = (width - total) / 2
            let origin = x
            let cells = (0..<n).map { i -> StripCell in
                let w = values[i] * cellHeight
                defer { x += w }
                return StripCell(range: i..<(i + 1), file: i, x: x, width: w)
            }
            return (cells, origin)
        }
        /// The sample of `count` cells and the `k` that makes it fill the width.
        func sample(_ count: Int) -> (shown: [(range: Range<Int>, file: Int)], k: Double) {
            let shown = ranges(n, count: count)
            return (shown, width / (shown.reduce(0) { $0 + values[$1.file] } * cellHeight))
        }
        var chosen: (shown: [(range: Range<Int>, file: Int)], k: Double)?
        if let preferredCount, (1..<n).contains(preferredCount) {
            let kept = sample(preferredCount)
            if kRange.contains(kept.k) { chosen = kept }
        }
        if chosen == nil {
            let fromMean = Int((width / (total / Double(n))).rounded(.down))
            guard fromMean > 0 else { return ([], 0) }
            // A sample much wider than the mean (every middle file a landscape, say) takes fewer cells; a single
            // cell wider than the strip still fits it.
            for count in stride(from: fromMean, through: 1, by: -1) {
                let candidate = sample(count)
                if candidate.k >= kRange.lowerBound || count == 1 {
                    chosen = candidate
                    break
                }
            }
        }
        guard let chosen else { return ([], 0) }
        let k = min(chosen.k, kRange.upperBound)
        let fills = k == chosen.k
        // Too narrow a sample: the cells at most `kRange.upperBound`, the rest of the width on both sides.
        var x = fills ? 0 : (width - width / chosen.k * k) / 2
        let origin = x
        var cells: [StripCell] = []
        cells.reserveCapacity(chosen.shown.count)
        for (i, r) in chosen.shown.enumerated() {
            // Filling: the last cell ends at `width` exactly, whatever the rounding of the sum before it.
            let w = fills && i == chosen.shown.count - 1 ? width - x : values[r.file] * cellHeight * k
            cells.append(StripCell(range: r.range, file: r.file, x: x, width: w))
            x += w
        }
        return (cells, origin)
    }

    /// Unknown aspects (nil) become the median of the known ones, or 3:2 when none is known: a folder of
    /// portraits guesses portrait for the files not seen yet.
    public static func filledAspects(_ known: [Double?]) -> [Double] {
        let sorted = known.compactMap { $0 }.sorted()
        let guess: Double
        if sorted.isEmpty {
            guess = cellAspect
        } else if sorted.count % 2 == 1 {
            guess = sorted[sorted.count / 2]
        } else {
            guess = (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        }
        return known.map { $0 ?? guess }
    }

    /// The file under `x`: the cell under it, then linear over the cell's range; nil outside
    /// `originX ..< originX + span`.
    public func fileIndex(atX x: Double) -> Int? {
        guard !cells.isEmpty, x >= originX, x < originX + span else { return nil }
        // Cells are contiguous and ascending: binary search for the last cell starting at or before `x`.
        var lo = 0, hi = cells.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if cells[mid].x <= x { lo = mid } else { hi = mid - 1 }
        }
        let cell = cells[lo]
        let offset = Int(((x - cell.x) / cell.width * Double(cell.range.count)).rounded(.down))
        return cell.range.lowerBound + min(max(offset, 0), cell.range.count - 1)
    }

    /// The x of the centre of the file's slot within its cell (the cell centre when there is a cell per
    /// file). Inverse of `fileIndex(atX:)`. Meaningless without cells (returns `originX`).
    public func x(ofFile index: Int) -> Double {
        let clamped = min(max(index, 0), fileCount - 1)
        guard let c = cell(containingFile: clamped) else { return originX }
        let cell = cells[c]
        return cell.x + (Double(clamped - cell.range.lowerBound) + 0.5) / Double(cell.range.count) * cell.width
    }

    /// Index into `cells` of the cell whose range contains the file; nil when out of range or no cells.
    public func cell(containingFile index: Int) -> Int? {
        guard !cells.isEmpty, (0..<fileCount).contains(index) else { return nil }
        // Ranges are contiguous and ascending: binary search for the last cell starting at or before `index`.
        var lo = 0, hi = cells.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if cells[mid].range.lowerBound <= index { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}
