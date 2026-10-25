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

    /// The first listing of the folder Home shows failed: how long until it is listed again, one unwatched poll later
    /// (`FolderPollSchedule`, stretched by how long the failure took), as a relist that failed would be (a failed first
    /// listing arms no watcher, spikes/rust/reports/listing-unavailable-bug.md, candidate C). nil: not again — the
    /// folder is `gone`, a permission was refused (another try gets the same answer), or polling is off.
    public static func retryFirstListing(after error: Error, ancestors: [Probe], pollMilliseconds: Int,
                                         took: Duration) -> Duration? {
        guard FolderRelistFailure(error, ancestors: ancestors) == .notAnswering, !isPermission(error as NSError) else { return nil }
        return FolderPollSchedule.interval(pollMilliseconds: pollMilliseconds, watched: false, lastListing: took)
    }

    private static func isPermission(_ error: NSError) -> Bool {
        switch error.domain {
        case NSPOSIXErrorDomain:
            if error.code == Int(EACCES) || error.code == Int(EPERM) { return true }
        case NSCocoaErrorDomain:
            if error.code == CocoaError.fileReadNoPermission.rawValue { return true }
        default: break
        }
        guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
        return isPermission(underlying)
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
///
/// The walk never leaves the folder's volume: it stops at the folder's mount point (as the mount table gave it while
/// the folder was listed), and a mount point that is missing, or no longer in the mount table, is no answer. A share
/// dropped or a disk ejected takes its mount point with it (or leaves an empty folder that is not the volume), and the
/// volume above it answering says nothing about the folder.
public final class AncestorProbe: @unchecked Sendable {
    private let open: @Sendable (String) -> FolderRelistFailure.Probe
    private let mountPoints: @Sendable () -> [String]
    private let lock = NSLock()
    private var busy = false

    /// `mountPoints`: the mount table's mount points now (`getfsstat` with `MNT_NOWAIT`, which asks no file system).
    public init(open: @escaping @Sendable (String) -> FolderRelistFailure.Probe = AncestorProbe.openDirectory,
                mountPoints: @escaping @Sendable () -> [String] = AncestorProbe.tableMountPoints) {
        self.open = open
        self.mountPoints = mountPoints
    }

    /// The mount table's mount points (`getfsstat` with `MNT_NOWAIT`: no file system asked, never hangs).
    @Sendable public static func tableMountPoints() -> [String] { ThumbnailStore.mounts().map(\.point) }

    /// `folder`'s mount point from the mount table (no file system asked), as written: what `run` stays under.
    public static func mountPoint(of folder: URL) -> String? {
        mountPoint(of: folder.standardizedFileURL.path, in: tableMountPoints())
    }

    /// `mountPoint`'s pure part: the longest mount point in `table` that holds `path`, at whatever path it is mounted.
    static func mountPoint(of path: String, in table: [String]) -> String? {
        table.filter { Self.path(path, isUnder: $0) }.max { $0.count < $1.count }
    }

    private static func path(_ path: String, isUnder point: String) -> Bool {
        path == point || path.hasPrefix(point == "/" ? "/" : point + "/")
    }

    /// A probe is out (its thread has not returned).
    public var isBusy: Bool { get async { lock.withLock { busy } } }

    /// The ancestors' answers, parent first, up to `mountPoint` (the folder's, from `mountPoint(of:)` while it was
    /// listed); `.noAnswer` last when the walk would go above it, and `[.noAnswer]` when it is unknown or no longer in
    /// the mount table, or when `timeout` passes first; nil while another probe is out.
    public func run(_ folder: URL, mountPoint: String?, timeout: Duration) async -> [FolderRelistFailure.Probe]? {
        let started = lock.withLock { () -> Bool in
            guard !busy else { return false }
            busy = true
            return true
        }
        guard started else { return nil }
        let open = self.open, mountPoints = self.mountPoints
        return await withCheckedContinuation { (c: CheckedContinuation<[FolderRelistFailure.Probe], Never>) in
            let once = OnceResume(c)
            let thread = Thread { [self] in
                var answers: [FolderRelistFailure.Probe] = []
                if let mountPoint, mountPoints().contains(mountPoint) {
                    var at = folder.standardizedFileURL.deletingLastPathComponent()
                    while true {
                        guard Self.path(at.path, isUnder: mountPoint) else {
                            answers.append(.noAnswer)   // above the volume: no witness
                            break
                        }
                        let answer = open(at.path)
                        answers.append(answer)
                        guard answer == .missing, at.path != "/" else { break }
                        at = at.deletingLastPathComponent()
                    }
                } else {
                    answers = [.noAnswer]
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
