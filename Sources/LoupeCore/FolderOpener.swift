import Darwin
import Foundation

/// Opens a folder's descriptor for kqueue (`O_EVTONLY`) off the main thread. On smbfs the open is a path lookup
/// that can go to the server, and a share that stalls must not freeze the UI.
///
/// The latest `open` wins: a result for a folder asked for earlier, or after `cancel`, is closed here and never
/// delivered. While an open of a folder is still out, asking for the same folder again does not start a second
/// one (a hung share would pile up threads, one per retry); it opens again once that one returns, since the
/// request may be for a new vnode at the path (the folder renamed, deleted and made again, a share remounted).
@MainActor public final class FolderOpener {
    /// A descriptor (the receiver owns it), or the errno of the failed open.
    public enum Outcome: Equatable, Sendable {
        case opened(Int32)
        case failed(errno: Int32)
    }

    public typealias Open = @Sendable (String) -> Outcome

    private let openPath: Open
    private let closeDescriptor: @Sendable (Int32) -> Void
    private let queue: DispatchQueue
    private var wanted: (folder: URL, token: UInt64, done: @MainActor (Outcome) -> Void)?
    private var nextToken: UInt64 = 0
    /// The folder whose open is out now, and the token it was started for.
    private var inFlight: (folder: URL, token: UInt64)?

    public init(open: @escaping Open = FolderOpener.openForEvents,
                close: @escaping @Sendable (Int32) -> Void = { _ = Darwin.close($0) },
                queue: DispatchQueue = .global(qos: .utility)) {
        self.openPath = open
        self.closeDescriptor = close
        self.queue = queue
    }

    public nonisolated static let openForEvents: Open = { path in
        let fd = Darwin.open(path, O_EVTONLY)
        return fd >= 0 ? .opened(fd) : .failed(errno: errno)
    }

    /// Opens `folder`; `done` runs on the main actor with the outcome unless a later `open` or `cancel` came first.
    public func open(_ folder: URL, done: @escaping @MainActor (Outcome) -> Void) {
        nextToken += 1
        wanted = (folder, nextToken, done)
        if inFlight?.folder != folder { start() }
    }

    /// No delivery for what was asked so far; a descriptor still on its way is closed when it arrives.
    public func cancel() {
        wanted = nil
    }

    /// An open of the folder asked for last is out: its outcome is on the way.
    public var isOpening: Bool { inFlight != nil }

    private func start() {
        guard let wanted else { return }
        let started = (folder: wanted.folder, token: wanted.token)
        inFlight = started
        let openPath = self.openPath, closeDescriptor = self.closeDescriptor, path = wanted.folder.path
        queue.async { [weak self] in
            let outcome = openPath(path)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else {
                        if case .opened(let fd) = outcome { closeDescriptor(fd) }
                        return
                    }
                    self.finished(started, outcome)
                }
            }
        }
    }

    private func finished(_ started: (folder: URL, token: UInt64), _ outcome: Outcome) {
        if inFlight?.token == started.token { inFlight = nil }
        guard let wanted, wanted.token == started.token else {
            if case .opened(let fd) = outcome { closeDescriptor(fd) }
            // Asked again for this folder while it was out: open it anew now.
            if let wanted, wanted.folder == started.folder, inFlight == nil { start() }
            return
        }
        self.wanted = nil
        wanted.done(outcome)
    }
}
