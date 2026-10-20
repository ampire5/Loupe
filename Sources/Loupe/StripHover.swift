import LoupeCore

/// One strip's hover bookkeeping (spec §4.3): the file under the cursor, the file the cursor has rested on for
/// `restDelay`, and the magnification around that file, which the cell pictures are sized for. The rested file lags
/// the hovered one while the cursor moves, so a sweep across the strip asks for no pictures; once the cursor rests,
/// the magnified cells get pictures for their size and the cell under the cursor that file (in a sampled strip, one
/// of the files of its range).
@MainActor final class StripHover {
    static let restDelay: Duration = .milliseconds(100)

    /// The file under the cursor; nil while the cursor is not over the strip.
    private(set) var file: Int?
    /// The hovered file once it stayed under the cursor `restDelay`.
    private(set) var restedFile: Int?
    /// Each cell's magnification with the cursor on `restedFile` (empty without one). Computed once per rest, layout
    /// or setting, with the cursor at the middle of the file's slot, so small moves within the file change nothing.
    private(set) var restedScales: [Double] = []
    private var restTask: Task<Void, Never>?

    /// The cursor came to rest on a new file: the cell pictures are to be sized again (`retarget` first).
    var onRest: (() -> Void)?

    /// A new file under the cursor (nil: none). False when it is the one already hovered.
    func set(_ new: Int?) -> Bool {
        guard new != file else { return false }
        file = new
        restTask?.cancel()
        restTask = nil
        guard new != nil else { return true }
        restTask = Task { [weak self] in
            try? await Task.sleep(for: Self.restDelay)
            guard !Task.isCancelled, let self else { return }
            self.restTask = nil
            guard let file = self.file, file != self.restedFile else { return }
            self.restedFile = file
            self.onRest?()
        }
        return true
    }

    /// No hover. True when a rest went away with it: the cells go back to their own files at their own size.
    @discardableResult func drop() -> Bool {
        file = nil
        cancel()
        guard restedFile != nil else { return false }
        restedFile = nil
        restedScales = []
        return true
    }

    /// The window closes: no more rests.
    func cancel() {
        restTask?.cancel()
        restTask = nil
    }

    /// `restedScales` for `layout` and the magnification settings.
    func retarget(layout: StripLayout, magnify: Double, reach: Double) {
        guard let restedFile, (0..<layout.fileCount).contains(restedFile) else {
            restedScales = []
            return
        }
        restedScales = StripMagnifier.scales(baseCells: layout.cells.map { (x: $0.x, width: $0.width) },
                                             cursorX: layout.x(ofFile: restedFile), magnify: magnify, reach: reach)
    }

    /// The cell that shows the rested file instead of its own, if any.
    func restedCell(in layout: StripLayout) -> Int? { restedFile.flatMap(layout.cell(containingFile:)) }

    /// How much larger than its base size the cell's picture is to be (1: its base size).
    func pictureScale(ofCell index: Int) -> Double {
        restedScales.indices.contains(index) ? max(1, restedScales[index]) : 1
    }
}
