import Foundation

public enum FolderStripID: Hashable, Sendable {
    case folder(URL)
    case gallery(String)
}

/// Browsing is provisional. A generation guards the final session commit as well as preview replies.
public struct FolderStripState: Sendable {
    public private(set) var opened: FolderStripID?
    public private(set) var browsed: FolderStripID?
    public private(set) var generation: UInt64 = 0
    private var requested: UInt64?
    public init() {}
    @discardableResult public mutating func browse(_ id: FolderStripID) -> UInt64 {
        generation &+= 1; browsed = id; requested = nil
        return generation
    }
    public mutating func settle() -> FolderStripID? {
        guard let browsed, browsed != opened, requested != generation else { return nil }
        requested = generation
        return browsed
    }
    public mutating func cancel() {
        generation &+= 1; browsed = opened; requested = nil
    }
    @discardableResult public mutating func acceptOpened(_ id: FolderStripID, generation token: UInt64) -> Bool {
        guard token == generation, browsed == id else { return false }
        opened = id; requested = nil
        return true
    }
    public mutating func synchronize(_ id: FolderStripID) {
        generation &+= 1; opened = id; browsed = id; requested = nil
    }
}
