import Foundation

/// Why a relist of the folder Home shows failed (its watcher's): `gone` only when the system says there is no such
/// folder and the nearest ancestor that is there answers (`ancestors`, walked up from the parent past the missing
/// ones: an ancestor trashed or renamed takes its subfolders with it); anything else (a share's error, a time out, a
/// connection dropped, an ancestor that does not answer, no probe at all) is `notAnswering`, and the folder stays on
/// screen for the next poll to try again. On a share a missing folder and a dropped connection can look alike, so an
/// answering ancestor is the volume's witness.
public enum FolderRelistFailure: Equatable, Sendable {
    case gone
    case notAnswering

    /// One ancestor's answer (`AncestorProbe`): there and listable, not there, or no answer (an error, a time out).
    public enum Probe: Equatable, Sendable { case answers, missing, noAnswer }

    public init(_ error: Error, ancestors: [Probe]) {
        let witness = ancestors.first { $0 != .missing }
        self = witness == .answers && Self.isNoSuchFile(error as NSError) ? .gone : .notAnswering
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

/// The ancestors of a folder whose relist failed, asked from the parent up until one is there or does not answer
/// (`FolderRelistFailure.Probe`), on one thread of its own at utility QoS. One probe at a time: while one is out (an
/// `opendir` hung on a share stays out past its deadline) another is skipped (nil), so a relist that fails fast every
/// poll never piles up stuck threads.
public final class AncestorProbe: @unchecked Sendable {
    private let open: @Sendable (String) -> FolderRelistFailure.Probe
    private let lock = NSLock()
    private var busy = false

    public init(open: @escaping @Sendable (String) -> FolderRelistFailure.Probe = AncestorProbe.openDirectory) {
        self.open = open
    }

    /// A probe is out (its thread has not returned).
    public var isBusy: Bool { get async { lock.withLock { busy } } }

    /// The ancestors' answers, parent first; `[.noAnswer]` when `timeout` passes first; nil while another probe is out.
    public func run(_ folder: URL, timeout: Duration) async -> [FolderRelistFailure.Probe]? {
        let started = lock.withLock { () -> Bool in
            guard !busy else { return false }
            busy = true
            return true
        }
        guard started else { return nil }
        let open = self.open
        return await withCheckedContinuation { (c: CheckedContinuation<[FolderRelistFailure.Probe], Never>) in
            let once = OnceResume(c)
            let thread = Thread { [self] in
                var answers: [FolderRelistFailure.Probe] = []
                var at = folder.standardizedFileURL.deletingLastPathComponent()
                while true {
                    let answer = open(at.path)
                    answers.append(answer)
                    guard answer == .missing, at.path != "/" else { break }
                    at = at.deletingLastPathComponent()
                }
                lock.withLock { busy = false }
                once.resume(answers)
            }
            thread.qualityOfService = .utility
            thread.start()
            Task {
                try? await Task.sleep(for: timeout)
                once.resume([.noAnswer])
            }
        }
    }

    /// `opendir`: there (listable), not there (`ENOENT`, `ENOTDIR`), or anything else (no answer).
    @Sendable public static func openDirectory(_ path: String) -> FolderRelistFailure.Probe {
        if let dir = opendir(path) {
            closedir(dir)
            return .answers
        }
        return errno == ENOENT || errno == ENOTDIR ? .missing : .noAnswer
    }
}

/// A continuation resumed once, by whichever comes first.
private final class OnceResume<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    init(_ c: CheckedContinuation<T, Never>) { continuation = c }
    func resume(_ value: T) {
        lock.withLock { () -> CheckedContinuation<T, Never>? in
            defer { continuation = nil }
            return continuation
        }?.resume(returning: value)
    }
}
