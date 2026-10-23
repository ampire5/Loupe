import Foundation

/// Why a relist of the folder Home shows failed (its watcher's): `gone` only when the system says there is no such
/// folder and its parent still answers; anything else (a share's error, a time out, a connection dropped, a volume
/// that does not answer) is `notAnswering`, and the folder stays on screen for the next poll to try again. On a share
/// a missing folder and a dropped connection can look alike, so the parent is the volume's witness.
public enum FolderRelistFailure: Equatable, Sendable {
    case gone
    case notAnswering

    public init(_ error: Error, parentAnswers: Bool) {
        self = parentAnswers && Self.isNoSuchFile(error as NSError) ? .gone : .notAnswering
    }

    /// No such file or directory (or not a directory), as POSIX or Cocoa say it, or under a wrapping error.
    private static func isNoSuchFile(_ error: NSError) -> Bool {
        switch error.domain {
        case NSPOSIXErrorDomain:
            if error.code == Int(ENOENT) || error.code == Int(ENOTDIR) { return true }
        case NSCocoaErrorDomain:
            if error.code == CocoaError.fileNoSuchFile.rawValue || error.code == CocoaError.fileReadNoSuchFile.rawValue {
                return true
            }
        default: break
        }
        guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
        return isNoSuchFile(underlying)
    }
}
