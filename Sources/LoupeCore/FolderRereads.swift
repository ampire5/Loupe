import Foundation

/// The bookkeeping of a session's folder re-reads (M2.5 spec §4.5), pure so its races are testable; the session
/// does the listing and the clock. Rules:
/// - never two listings of one folder at once: a listing still running for a folder the session left (a hung
///   share) is the one a return to that folder waits for;
/// - a re-read starts no sooner than `FolderPollSchedule.listingFactor` × the folder's last listing after it ended
///   (the poll's own rule), so neither a long copy's folder events nor steps at the end list a slow share back to
///   back; requests meanwhile join the queued listing. `open` and a `rerun` are exempt and start a queued listing at
///   once: a file just opened that the playlist does not know would sit alone in it meanwhile;
/// - a folder event during a listing queues one more after it (the change may be newer than what it read); a
///   poll or an activation does not (`idle`);
/// - a step at the end (`Waiter`, the retry) is answered by the first listing to finish after it — never by one
///   queued just for it, which could come a slow share's ten listings later, when the step is long stale (on
///   `open`'s interim one-file playlist every step ends there). Waiters are dropped with a folder the session left.
public struct FolderRereads<Waiter> {
    public enum Request {
        /// `open` lists the folder; joins a listing already running (its anchor check covers the opened file).
        case open
        /// A folder event (kqueue): needs a listing that starts after it.
        case event
        /// A poll or the app's activation: any listing running or queued will do.
        case idle
        /// A step past an end of the list: `Waiter` runs once the next listing to finish was applied.
        case step(Waiter)
    }

    public enum Action: Equatable {
        case none
        /// List the folder now.
        case start
        /// List it after this long, then call `begin`.
        case startAfter(Duration)
    }

    /// What became of a finished listing, as the session saw it.
    public enum Outcome {
        /// Applied, or failed (the folder could not be listed): waiters run.
        case applied
        /// For a photo the listing does not show (opened or reached meanwhile): list again at once, anchored on it,
        /// the waiters with it.
        case rerun
        /// The session is in another folder, or closed: everything for this folder is dropped.
        case dropped
    }

    private struct Entry {
        var running: Bool
        var waiters: [Waiter] = []
        var again = false
    }

    private var entries: [URL: Entry] = [:]
    private var last: (folder: URL, ended: ContinuousClock.Instant, took: Duration)?

    public init() {}

    /// Whether a listing of `folder` is running (or queued).
    public func isListing(_ folder: URL) -> Bool { entries[folder] != nil }

    public mutating func request(_ request: Request, folder: URL, now: ContinuousClock.Instant) -> Action {
        guard var entry = entries[folder] else {
            switch request {
            case .open: return start(Entry(running: true), folder: folder)
            case .step(let waiter): return schedule(Entry(running: false, waiters: [waiter]), folder: folder, now: now)
            case .event, .idle: return schedule(Entry(running: false), folder: folder, now: now)
            }
        }
        var action = Action.none
        switch request {
        case .idle: break
        case .open:
            // A queued listing starts now; its pending `begin` then finds it running.
            if !entry.running {
                entry.running = true
                action = .start
            }
        case .event: if entry.running { entry.again = true }
        case .step(let waiter): entry.waiters.append(waiter)
        }
        entries[folder] = entry
        return action
    }

    /// A `startAfter` delay ran out: whether to list now (false: it was dropped, or the session is elsewhere).
    public mutating func begin(_ folder: URL, isCurrent: Bool) -> Bool {
        guard var entry = entries[folder], !entry.running else { return false }
        guard isCurrent else {
            entries[folder] = nil
            return false
        }
        entry.running = true
        entries[folder] = entry
        return true
    }

    /// A listing of `folder` ended after `took`: the waiters to run now, and what to do next for the folder.
    public mutating func finish(_ folder: URL, took: Duration, now: ContinuousClock.Instant,
                                outcome: Outcome) -> (waiters: [Waiter], next: Action) {
        guard let entry = entries[folder], entry.running else { return ([], .none) }
        entries[folder] = nil
        last = (folder, now, took)
        switch outcome {
        case .dropped:
            return ([], .none)
        case .rerun:
            let next = Entry(running: true, waiters: entry.waiters)   // starts after any event it held: no `again`
            return ([], start(next, folder: folder))
        case .applied:
            guard entry.again else { return (entry.waiters, .none) }
            return (entry.waiters, schedule(Entry(running: false), folder: folder, now: now))
        }
    }

    /// The steps waiting on `folder`'s listing, handed over now (the quick names pass after an open already gave the
    /// playlist they wait for); the listing itself goes on and no longer runs them.
    public mutating func takeWaiters(_ folder: URL) -> [Waiter] {
        guard let waiters = entries[folder]?.waiters else { return [] }
        entries[folder]?.waiters = []
        return waiters
    }

    /// The session closed: nothing more runs; listings still out are dropped when they end.
    public mutating func reset() {
        entries = [:]
    }

    private mutating func start(_ entry: Entry, folder: URL) -> Action {
        entries[folder] = entry
        return .start
    }

    private mutating func schedule(_ entry: Entry, folder: URL, now: ContinuousClock.Instant) -> Action {
        var entry = entry
        var delay = Duration.zero
        if let last, last.folder == folder {
            delay = last.ended + last.took * FolderPollSchedule.listingFactor - now
        }
        entry.running = delay <= .zero
        entries[folder] = entry
        return entry.running ? .start : .startAfter(delay)
    }
}
