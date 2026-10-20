/// `wheel-step` and `key-step`: what a step through the folder waits for before the next one may go (`StepGate`).
/// A fast spin of a notched wheel or a held arrow key used to step every time while the screen kept an older photo
/// until the newest one was sharp enough, so most photos never showed; waiting slows the steps down instead, so
/// every step shows its photo, at the quality picked here: `thumb` (fastest, its stretched stored thumbnail),
/// `coarse` (a level decoded from the file, less blurry), `sharp` (slowest, sharp enough for the scale). `any`
/// waits for nothing: one step per display frame (keys: no limit), the way it was.
public enum StepWait: String, Sendable, CaseIterable {
    case thumb, coarse, sharp, any

    /// Case-insensitive; `rawValue` is the canonical spelling written back to loupe.conf.
    public init?(text: String) {
        self.init(rawValue: text.lowercased())
    }

    /// Whether the screen showing the current photo at `quality` (nil: another photo, or nothing) ends the wait.
    public func isSatisfied(by quality: ShownQuality?) -> Bool {
        let needed: ShownQuality
        switch self {
        case .any: return true
        case .thumb: needed = .thumb
        case .coarse: needed = .coarse
        case .sharp: needed = .sharp
        }
        return quality.map { $0 >= needed } ?? false
    }
}

/// How well the screen shows the current photo, coarsest first.
public enum ShownQuality: Int, Comparable, Sendable {
    /// Its stretched stored thumbnail: the cache entry holds the seeded level only.
    case thumb
    /// A level decoded from the file itself (a progressive JPEG's first look, a coarse preview) that is not sharp
    /// enough for the scale yet.
    case coarse
    /// Sharp enough for the scale: the test `ShowPolicy` uses for `show-blurry=no`.
    case sharp

    public static func < (a: ShownQuality, b: ShownQuality) -> Bool { a.rawValue < b.rawValue }

    /// The quality of the current photo's entry on screen. `finestResident`: its finest resident level (nil:
    /// nothing on the GPU); `neededLevel`: the level the scale needs (`TileGrid.level(forScale:)`). A failure counts
    /// as sharp: it is what the screen will show of that photo, nothing better is coming, so no wait holds on to it.
    public static func of(finestResident: Int?, neededLevel: Int, seededOnly: Bool, failed: Bool) -> ShownQuality? {
        if failed { return .sharp }
        guard let finest = finestResident else { return nil }
        if seededOnly { return .thumb }
        return finest <= neededLevel ? .sharp : .coarse
    }
}
