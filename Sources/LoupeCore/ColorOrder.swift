import Foundation

/// The order in which a window's colour corrector analyses photos and builds their cubes (M3c spec §3.1): the
/// current photo, then its neighbours one by one on alternate sides, the side of travel first.
public enum ColorOrder {
    /// Playlist indices: `current`, then +1, −1, +2, −2… (−1 first when `direction` is negative), `reach` of them in
    /// all (`cache-previews`). A side that runs out is skipped and the other fills the reach; nothing for an empty
    /// list, a `current` outside it or a reach below 1.
    public static func order(count: Int, current: Int, direction: Int, reach: Int) -> [Int] {
        guard (0..<count).contains(current), reach > 0 else { return [] }
        let side = direction < 0 ? -1 : 1
        var result = [current]
        var offset = 1
        while result.count < min(reach, count) {
            for index in [current + side * offset, current - side * offset]
            where (0..<count).contains(index) && result.count < reach {
                result.append(index)
            }
            offset += 1
        }
        return result
    }
}

/// Which photos of a window's colour corrector are analysed again whatever the analysis cache holds for their stamp
/// (M3c spec §3.1). A photo whose file changed (another stamp) while in the order is restamped: the thumbnail read for
/// the new stamp may still be the old file's (the thumbnail store forgets it only when it hears the new stamp), so the
/// next thumbnail to arrive makes the photo stale. It stays stale until an analysis from a job that started while it
/// was stale is stored; a job that started before may have read the old thumbnail, so its analysis (cached under the
/// new stamp) is overwritten by the next job's.
public struct ColorRestamps: Sendable {
    private var restamped: Set<URL> = []
    private var stale: Set<URL> = []

    public init() {}

    /// The cached analysis of `url` is not to be trusted: a job analyses it anew.
    public func isStale(_ url: URL) -> Bool { stale.contains(url) }

    /// `url`'s file has another stamp now.
    public mutating func restamp(_ url: URL) { restamped.insert(url) }

    /// `url`'s thumbnail arrived; true when that made it stale (it was restamped).
    public mutating func thumbnailArrived(_ url: URL) -> Bool {
        guard restamped.remove(url) != nil else { return false }
        stale.insert(url)
        return true
    }

    /// A job stored an analysis of `url`; `startedStale` is `isStale(url)` when the job started.
    public mutating func analysed(_ url: URL, startedStale: Bool) {
        if startedStale { stale.remove(url) }
    }

    /// Forgets the photos that left the order.
    public mutating func keep(_ urls: Set<URL>) {
        restamped.formIntersection(urls)
        stale.formIntersection(urls)
    }
}
