import Foundation

/// Which listing of the file browser's source is still wanted (file browser spec §4.2): each place shown begins a new
/// one, and a listing, a watcher's relist or a "folder gone" of an older place is dropped.
public struct BrowserListingGate: Sendable {
    private var token = 0
    /// The folder of the current listing; nil on Places.
    public private(set) var path: String?
    /// A complete listing of the current place went on (`admits`).
    private var hasComplete = false

    public init() {}

    public mutating func begin(_ path: String?) -> Int {
        token &+= 1
        hasComplete = false
        self.path = path
        return token
    }

    public func isCurrent(_ token: Int) -> Bool { token == self.token }

    /// Whether a listing of `token`'s place goes on (to the source's state and the view): not one of an older place,
    /// nor a names-only part once a complete listing of this one went (a relist's first pass on a share has nothing
    /// the complete one lacks, and would drop its stamps), as the kit's browser does on screen.
    public mutating func admits(complete: Bool, token: Int) -> Bool {
        guard isCurrent(token) else { return false }
        if complete { hasComplete = true } else if hasComplete { return false }
        return true
    }
}
