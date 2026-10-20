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
}
