import LoupeCore

/// One strip's hover bookkeeping (spec §4.3): the file under the cursor, and the file the cursor has rested on for
/// `restDelay`, which gets the label. The rested file lags the hovered one while the cursor moves, so a sweep across
/// the strip does not flicker labels.
@MainActor final class StripHover {
    static let restDelay: Duration = .milliseconds(100)

    /// The file under the cursor; nil while the cursor is not over the strip.
    private(set) var file: Int?
    /// The hovered file once it stayed under the cursor `restDelay`.
    private(set) var restedFile: Int?
    private var restTask: Task<Void, Never>?

    /// The cursor came to rest on a new file: its label goes up.
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

    /// No hover. True when a hover went away with it.
    @discardableResult func drop() -> Bool {
        let had = file != nil
        file = nil
        restedFile = nil
        cancel()
        return had
    }

    /// The window closes: no more rests.
    func cancel() {
        restTask?.cancel()
        restTask = nil
    }
}
