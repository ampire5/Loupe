import Foundation

/// Whether a path exists, asked off the caller's thread with a timeout: on a share that stopped answering a `stat`
/// can hang, and a click must still get an answer (Stash spec §2.2).
public enum FileCheck {
    /// True or false; nil when the check did not return within `timeout` (its thread is written off, as
    /// `FolderNavigator` does with a hung listing).
    public static func exists(_ url: URL, timeout: Duration,
                              check: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        async -> Bool? {
        let path = url.path
        return try? await BlockingCall.run(timeout: timeout) { check(path) }
    }
}
