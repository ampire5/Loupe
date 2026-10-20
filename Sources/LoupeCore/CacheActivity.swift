/// What the viewer cache is doing, as far as the background thumbnail generator cares (spec §3.6): it reads only
/// while the cache is `.idle`, and gives up the read it has in flight when the current photo needs I/O again.
public enum CacheActivity: Sendable, Equatable {
    /// Nothing in flight or waiting.
    case idle
    /// Only neighbours' reads or jobs are in flight or waiting.
    case neighbours
    /// The current photo has a read, job or stamp check in flight or waiting.
    case current
}
