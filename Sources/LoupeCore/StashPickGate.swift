/// The gallery a Stash click asked for last (Stash spec §2.2): each click takes a token, and only the latest token's
/// open may replace the photos or hide Stash; `cancel` (Stash shown again, the window closing) drops them all.
public struct StashPickGate: Sendable {
    private var latest = 0
    private var cancelled = false

    public init() {}

    public mutating func begin() -> Int {
        latest &+= 1
        cancelled = false
        return latest
    }

    public func isCurrent(_ token: Int) -> Bool { !cancelled && token == latest }

    public mutating func cancel() { cancelled = true }
}
