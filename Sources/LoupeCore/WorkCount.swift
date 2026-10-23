import Foundation

/// How far a piece of work is: how many of its items are done, of how many (the thumbs-ahead plan's progress counts:
/// `CoverProgress` and those after it).
public struct WorkCount: Equatable, Sendable {
    public var done: Int
    public var total: Int

    public init(done: Int = 0, total: Int = 0) {
        self.done = done
        self.total = total
    }
}
