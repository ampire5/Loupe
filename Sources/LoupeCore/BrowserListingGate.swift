import Foundation

/// Which listing of the file browser's source is still wanted (file browser spec §4.2): each place shown begins a new
/// one, and a listing, a watcher's relist or a "folder gone" of an older place is dropped.
public struct BrowserListingGate: Sendable {
    private var token = 0
    /// The folder of the current listing; nil on Places.
    public private(set) var path: String?

    public init() {}

    public mutating func begin(_ path: String?) -> Int {
        token &+= 1
        self.path = path
        return token
    }

    public func isCurrent(_ token: Int) -> Bool { token == self.token }
}
