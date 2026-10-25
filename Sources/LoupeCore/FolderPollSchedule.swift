/// How long after a listing of the open folder the next poll comes (M2.5 spec §4.5). With the folder's kqueue
/// source armed, events report changes (locally and, measured, over smbfs) and the poll is only a safety net,
/// every `watchedFactor` × `folder-poll`; without one (the folder could not be opened for events), every
/// `folder-poll`. Either way never sooner than `listingFactor` listings' time, so a slow share is not listed back
/// to back.
public enum FolderPollSchedule {
    public static let listingFactor = 10
    public static let watchedFactor = 10

    /// nil when polling is off (`folder-poll=0`); `lastListing` is nil before the folder was listed by the session.
    public static func interval(pollMilliseconds: Int, watched: Bool, lastListing: Duration?) -> Duration? {
        guard pollMilliseconds > 0 else { return nil }
        let base = Duration.milliseconds(pollMilliseconds) * (watched ? watchedFactor : 1)
        guard let lastListing else { return base }
        return max(base, lastListing * listingFactor)
    }

    /// The app came to the front or the window was shown again: whether the folder is re-read now. Only when a change
    /// may have gone unseen: no kqueue source, `missed` (an event dropped while the window could not be seen, or the
    /// last listing failed), no listing yet, or the last one older than the watched poll's interval (a file rewritten
    /// in place raises no event). So a return finds a change no later than the poll would have while active; on a
    /// share every listing is network traffic, and each Space switch shows a full-screen window again (21 re-reads in
    /// 50 s with five windows, spikes/rust/reports/bench-results.md, 2026-10-25).
    public static func rereadOnReturn(pollMilliseconds: Int, watched: Bool, missed: Bool,
                                      lastListing: Duration?, sinceListing: Duration?) -> Bool {
        guard watched, !missed, let lastListing, let sinceListing else { return true }
        guard let net = interval(pollMilliseconds: pollMilliseconds, watched: true, lastListing: lastListing) else { return false }
        return sinceListing >= net
    }
}
