import Foundation

/// A job of `SubjectQueue`: one photo to look at.
public protocol SubjectJob {
    var url: URL { get }
    /// A second ask for the same photo joins the waiting one (its callbacks, its urgency) instead of replacing it.
    mutating func merge(_ other: Self)
}

/// The order `SubjectFinder` looks at photos in (smart zoom spec §5): the photo on screen first (it replaces the one
/// asked for before), then at most `aheadLimit` photos ahead, the nearest kept; one job at a time; nothing taken while the
/// photo on screen is decoding (`busy`): freeing it lets the owner take the next job, nothing polls. Pure, so the
/// bounds are tested without Vision or a window.
public struct SubjectQueue<Job: SubjectJob> {
    public let aheadLimit: Int
    public var busy = false
    public private(set) var running = false
    private var current: Job?
    private var ahead: [Job] = []

    public init(aheadLimit: Int) {
        self.aheadLimit = aheadLimit
    }

    /// What waits, the photo on screen first.
    public var pending: [Job] { (current.map { [$0] } ?? []) + ahead }

    /// The photo on screen (`ahead` false) replaces another one before it; a photo ahead joins while there is room. An
    /// ask for a photo already waiting merges into its job (a photo ahead that comes on screen moves up with it).
    public mutating func ask(_ job: Job, ahead isAhead: Bool) {
        if current?.url == job.url {
            current?.merge(job)
        } else if let i = ahead.firstIndex(where: { $0.url == job.url }) {
            ahead[i].merge(job)
            if !isAhead { current = ahead.remove(at: i) }
        } else if isAhead {
            if ahead.count < aheadLimit { ahead.append(job) }
        } else {
            current = job
        }
    }

    /// Drops the waiting photos not in `urls` (a step left them behind, the analysis was turned off).
    public mutating func keepOnly(_ urls: Set<URL>) {
        if let c = current, !urls.contains(c.url) { current = nil }
        ahead.removeAll { !urls.contains($0.url) }
    }

    /// The next job, nil while one runs, the foreground is busy or nothing waits.
    public mutating func take() -> Job? {
        guard !running, !busy else { return nil }
        let job: Job
        if let c = current { job = c; current = nil } else if !ahead.isEmpty { job = ahead.removeFirst() } else { return nil }
        running = true
        return job
    }

    /// The running job is done.
    public mutating func finish() { running = false }
}
