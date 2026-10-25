import AppKit
import Foundation
import LoupeCore

/// Tells its session as soon as the open folder may have changed (M2.5 spec §4.5; the user wants changes "as fast
/// as possible"). Two sources, one callback: kqueue on the folder (a file added, removed or renamed, debounced
/// 300 ms so a copy of many files is one re-read per window, not one per file; smbfs delivers these too, measured
/// 2026-10-15), and a poll while the app is active for what kqueue does not report — a file rewritten in place (only
/// the directory's own entries raise its events). With the source armed the poll is a safety net every
/// 10 × `folder-poll`; without one (the folder could not be opened) every `folder-poll`; one interval after the last
/// listing finished and stretched on a slow share either way (`FolderPollSchedule`). The app's activation and the
/// window shown again re-read the folder (files may have come or gone meanwhile, spec §4.5) only when a change may
/// have gone unseen (`FolderPollSchedule.rereadOnReturn`): kqueue goes on while the app is in the background.
@MainActor final class FolderWatcher {
    static let debounce: Duration = .milliseconds(300)

    /// Called on the main actor when the folder should be re-read; `isPoll` for a poll (a listing already running
    /// will do), false for a folder event (the change may be newer than a listing in flight).
    var onChange: ((_ isPoll: Bool) -> Void)?
    private(set) var folder: URL?
    /// The window cannot be seen (windows spec §3.6; on a share every poll is network traffic): no polls, and a folder
    /// event is dropped and marks the folder missed (the re-read when the pause is lifted covers it). Lifted, the
    /// folder is re-read at once ("when its window appears") if `rereadOnReturn` says so, the app active or not; the
    /// activation's re-read that may follow is an idle request too, which the listing still running takes in, so a
    /// window shown as the app comes forward lists its folder once whatever comes first.
    var isPaused = false {
        didSet {
            guard isPaused != oldValue, let folder else { return }
            DebugLog.log("folder watch \(folder.lastPathComponent): \(isPaused ? "paused" : "resumed")")
            if isPaused {
                cancelPoll()
                debounceTask?.cancel()   // the re-read when the pause is lifted covers it
                debounceTask = nil
            } else {
                returned()
            }
        }
    }
    private var source: DispatchSourceFileSystemObject?
    /// Opens the folder off the main thread (the path lookup can go to a share's server).
    private let opener = FolderOpener()
    private var debounceTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    /// How long the session's last listing of this folder took and when it ended; nil before the first.
    private var lastListing: Duration?
    private var lastListingEnded: ContinuousClock.Instant?
    /// Since when a change may have gone unseen: an event dropped while paused, or a listing that failed.
    private var missedSince: ContinuousClock.Instant?
    private var observers: [NSObjectProtocol] = []
    /// The folder whose failure to open was last logged: a share without events retries at every listing.
    private var loggedOpenFailure: URL?

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.isPaused == false { self?.returned() } }
        })
        // Polling is for the folder the user is looking at; kqueue goes on in the background (it costs nothing).
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelPoll() }
        })
    }

    /// Watches `folder` from now on; the same folder again changes nothing.
    func watch(_ folder: URL) {
        guard folder != self.folder else { return }
        self.folder = folder
        lastListing = nil
        lastListingEnded = nil
        missedSince = nil
        debounceTask?.cancel()
        debounceTask = nil
        DebugLog.log("folder watch \(folder.lastPathComponent)")
        arm()
        schedulePoll()
    }

    /// A listing of the folder finished, taking `duration`: the next poll is one interval from now. A folder that
    /// lists again after its source was lost (deleted and made again, a share remounted) is watched again.
    func listed(in duration: Duration, succeeded: Bool) {
        let now = ContinuousClock.now
        lastListing = duration
        lastListingEnded = now
        if !succeeded {
            missedSince = missedSince ?? now
        } else if let since = missedSince, since <= now - duration {
            missedSince = nil   // a listing that began after the miss saw it
        }
        // An open still out will deliver (a folder event re-arms itself); another would only repeat it.
        if succeeded && source == nil && !opener.isOpening { arm() }
        schedulePoll()
    }

    /// The session is closing: no more callbacks.
    func stop() {
        folder = nil
        opener.cancel()
        source?.cancel()
        source = nil
        debounceTask?.cancel()
        debounceTask = nil
        cancelPoll()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    // MARK: kqueue

    /// (Re)opens the folder by path: after the folder itself was renamed or deleted, or its volume went away
    /// (`.revoke`), the old descriptor watches a vnode that is no longer at that path. The open runs off the main
    /// thread; until it returns the folder counts as unwatched (polled every `folder-poll`), and once the source is
    /// on the poll moves to the watched interval (after a folder event, the re-read it starts reschedules anyway).
    private func arm() {
        source?.cancel()
        source = nil
        guard let folder else {
            opener.cancel()
            return
        }
        opener.open(folder) { [weak self] outcome in
            self?.armed(folder, outcome)
        }
    }

    private func armed(_ folder: URL, _ outcome: FolderOpener.Outcome) {
        guard folder == self.folder, source == nil else {
            if case .opened(let fd) = outcome { Darwin.close(fd) }
            return
        }
        guard case .opened(let fd) = outcome else {
            if case .failed(let error) = outcome, loggedOpenFailure != folder {
                loggedOpenFailure = folder
                DebugLog.log("folder watch: cannot open \(folder.path) (errno \(error)); polling only")
            }
            return
        }
        loggedOpenFailure = nil
        DebugLog.log("folder watch \(folder.lastPathComponent): kqueue on")
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                               eventMask: [.write, .delete, .rename, .extend, .attrib, .revoke],
                                                               queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let events = source?.data else { return }
            MainActor.assumeIsolated { self?.folderEvent(events) }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        self.source = source
        schedulePoll()
    }

    private func folderEvent(_ events: DispatchSource.FileSystemEvent) {
        if !events.isDisjoint(with: [.delete, .rename, .revoke]) { arm() }
        guard !isPaused else {
            missedSince = missedSince ?? .now
            return
        }
        // The first event of a burst starts the window; the rest of the burst lands in the same re-read.
        guard debounceTask == nil else { return }
        DebugLog.log("folder event \(events.rawValue)")
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled, let self else { return }
            self.debounceTask = nil
            self.onChange?(false)
        }
    }

    // MARK: Polling

    /// The app came to the front or the window was shown again: the folder is re-read if a change may have gone
    /// unseen, else only the polls start again.
    private func returned() {
        guard let folder else { return }
        let reread = FolderPollSchedule.rereadOnReturn(pollMilliseconds: Settings.shared.config.folderPollMilliseconds,
                                                       watched: source != nil, missed: missedSince != nil,
                                                       lastListing: lastListing,
                                                       sinceListing: lastListingEnded.map { ContinuousClock.now - $0 })
        if reread { return self.reread() }
        DebugLog.log("folder watch \(folder.lastPathComponent): back, no re-read (kqueue on, listed "
                     + "\(lastListingEnded.map { Int((ContinuousClock.now - $0) / .seconds(1)) } ?? 0) s ago)")
        schedulePoll()
    }

    /// Re-reads the folder now (an idle request: a listing running will do) and polls from here.
    private func reread() {
        guard folder != nil else { return }
        onChange?(true)
        schedulePoll()
    }

    private func schedulePoll() {
        cancelPoll()
        guard folder != nil, !isPaused, NSApp.isActive,
              let interval = FolderPollSchedule.interval(pollMilliseconds: Settings.shared.config.folderPollMilliseconds,
                                                         watched: source != nil, lastListing: lastListing) else { return }
        pollTask = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled, let self else { return }
            self.onChange?(true)
            // The listing this starts reschedules when it finishes; this one keeps polling if it never does
            // (a re-read that was dropped).
            self.schedulePoll()
        }
    }

    private func cancelPoll() {
        pollTask?.cancel()
        pollTask = nil
    }
}
