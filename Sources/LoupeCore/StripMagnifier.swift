import Foundation

/// Dock-style magnification of the thumbnail strip (spec §4.3, Build 1.1: the user asked for the photos to "part
/// and one to grow", like the icons in the Dock, instead of a preview over the strip). Like the Dock, it is a
/// continuous function of the cursor's x: each cell grows by how close its centre is to the cursor, so the cells
/// swell and shrink smoothly as the cursor moves instead of jumping a cell at a time. Pure arithmetic over the base
/// layout's frames; picking a file stays on the base layout.
public enum StripMagnifier {
    /// `strip-magnify` as applied: lowered so a cell `cellHeight` tall grows to at most `limitPercent` % of
    /// `viewerHeight` (`strip-magnify-limit`: the wave must never cover much of the photo, user, Build 1.1; a fixed
    /// 15 % until the Build 2 trial, where it held ×4 to ×1.1–2.4 on a tall strip), never below 1 (a strip already
    /// taller than that does not grow at all). Every place that models the shown cells (the view, the resize drag)
    /// must pass the same limit.
    public static func effectiveMagnify(_ magnify: Double, cellHeight: Double, viewerHeight: Double,
                                        limitPercent: Double) -> Double {
        guard cellHeight > 0, viewerHeight.isFinite, viewerHeight > 0 else { return max(1, magnify) }
        return max(1, min(magnify, limitPercent / 100 * viewerHeight / cellHeight))
    }

    /// The scale of a cell whose centre is `distance` cell widths from the cursor: `magnify` at 0, falling off as
    /// cos² to 1 at `reach + 1` (negative `reach` counts as 0: only cells within one width of the cursor grow).
    /// `reach` may be fractional (Build 2 trial), so the falloff's width is continuous in the setting.
    public static func scale(distance: Double, magnify: Double, reach: Double) -> Double {
        let span = max(0, reach) + 1
        let d = abs(distance)
        guard d < span else { return 1 }
        let c = cos(Double.pi * d / (2 * span))
        return 1 + (magnify - 1) * c * c
    }

    /// Each cell's scale with the cursor at `cursorX`; all 1 without a cursor, beside every cell, or for `magnify` 1.
    ///
    /// The rule for the distance unit: distances are measured in base widths of the cell under the cursor, that width
    /// interpolated linearly between neighbouring cells' centres (exactly the cell's own width at its centre). Taken
    /// literally, "the width of the cell under the cursor" would change abruptly at a boundary between native cells
    /// of different widths, and every scale with it.
    public static func scales(baseCells: [(x: Double, width: Double)], cursorX: Double?, magnify: Double,
                              reach: Double) -> [Double] {
        let none = Array(repeating: 1.0, count: baseCells.count)
        guard let x = cursorX, magnify != 1, magnify.isFinite, magnify > 0, hoveredCell(baseCells, x) != nil
        else { return none }
        let unit = unitWidth(baseCells, x)
        guard unit > 0 else { return none }
        return baseCells.map { scale(distance: (x - ($0.x + $0.width / 2)) / unit, magnify: magnify, reach: reach) }
    }

    /// The frames of the cells with the cursor at `cursorX` (nil: not over the strip), every cell `height` tall
    /// at rest. Heights grow upwards from the cells' bottom edge, so a frame has no y. The point under the cursor
    /// stays under it: the cell there grows around the cursor in proportion to where the cursor is in it, the cells
    /// left of it move left and those right of it right. The strip may overflow its bounds (nothing is clipped:
    /// the overlay draws over the photo). Gaps between base cells, if any, are kept. A cursor beside every cell,
    /// or `magnify` 1, gives the base frames.
    public static func frames(baseCells: [(x: Double, width: Double)], height: Double, cursorX: Double?,
                              magnify: Double, reach: Double = 2) -> [(x: Double, width: Double, height: Double)] {
        var frames = baseCells.map { (x: $0.x, width: $0.width, height: height) }
        let s = scales(baseCells: baseCells, cursorX: cursorX, magnify: magnify, reach: reach)
        guard let x = cursorX, let hovered = hoveredCell(baseCells, x), s.contains(where: { $0 != 1 })
        else { return frames }
        for i in frames.indices {
            frames[i].width = baseCells[i].width * s[i]
            frames[i].height = height * s[i]
        }
        let into = (x - baseCells[hovered].x) / baseCells[hovered].width
        frames[hovered].x = x - into * frames[hovered].width
        for i in stride(from: hovered - 1, through: 0, by: -1) {
            let gap = baseCells[i + 1].x - (baseCells[i].x + baseCells[i].width)
            frames[i].x = frames[i + 1].x - gap - frames[i].width
        }
        for i in (hovered + 1)..<max(hovered + 1, baseCells.count) {
            let gap = baseCells[i].x - (baseCells[i - 1].x + baseCells[i - 1].width)
            frames[i].x = frames[i - 1].x + frames[i - 1].width + gap
        }
        return frames
    }

    /// `frames` (from `frames(baseCells:…cursorX:…)`) moved sideways as one so the cell under the cursor stays on
    /// screen, `0...width`: a strip that fills the window would otherwise show its first or last photo magnified
    /// but cut by the window's edge.
    ///
    /// The shift is the one that brings the cell under the cursor inside, ramped down to nothing towards the cell's
    /// edges (full over the middle half, smoothstep to 0 at the edges). At a cell boundary it must be 0: there the
    /// magnified frames put the boundary exactly under the cursor, where the base layout switches files, and any
    /// shift would show one cell under the cursor while a click picks the other. Ramping keeps the frames
    /// continuous in the cursor (a shift taken from the hovered cell alone snapped the whole strip sideways when the
    /// hovered cell changed) and the cursor over its cell: the full shift does, no shift does, and so does any
    /// fraction of it.
    public static func keepingInside(_ frames: [(x: Double, width: Double, height: Double)],
                                     baseCells: [(x: Double, width: Double)], cursorX: Double?,
                                     width: Double) -> [(x: Double, width: Double, height: Double)] {
        guard let x = cursorX, let hovered = hoveredCell(baseCells, x), frames.count == baseCells.count
        else { return frames }
        let f = frames[hovered]
        let full = f.x < 0 ? -f.x : min(0, width - (f.x + f.width))
        guard full != 0 else { return frames }
        let into = (x - baseCells[hovered].x) / baseCells[hovered].width
        let r = min(1, 4 * min(into, 1 - into))
        let dx = full * r * r * (3 - 2 * r)
        guard dx != 0 else { return frames }
        return frames.map { (x: $0.x + dx, width: $0.width, height: $0.height) }
    }

    private static func hoveredCell(_ cells: [(x: Double, width: Double)], _ x: Double) -> Int? {
        cells.firstIndex { x >= $0.x && x < $0.x + $0.width }
    }

    /// The base width at `x`, linear between neighbouring cells' centres (the cell's own width at its centre).
    private static func unitWidth(_ cells: [(x: Double, width: Double)], _ x: Double) -> Double {
        let centres = cells.map { $0.x + $0.width / 2 }
        guard let first = centres.first, let last = centres.last else { return 0 }
        if x <= first { return cells[0].width }
        if x >= last { return cells[cells.count - 1].width }
        let j = centres.lastIndex { $0 <= x } ?? 0
        let t = (x - centres[j]) / (centres[j + 1] - centres[j])
        return cells[j].width + (cells[j + 1].width - cells[j].width) * t
    }
}
