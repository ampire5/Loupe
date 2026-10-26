import Foundation
import HomeScreenModel

// Folders' last complete listings in the catalog (`StoredListing`, `ThumbnailDatabase.putListing`): Home shows a
// folder's at once when it opens again, in this run or a later one, and the share's listing replaces it when it comes.

extension ThumbnailStore {
    /// Keeps `entries`, a listing of `folder`, for its next opening. `namesOnly`: all its names without dates and sizes
    /// (a cold share can take a minute for those): each one keeps the date, size and count the listing kept before had
    /// for its name. A zip's listing is its photos, from its own directory: not kept.
    public func storeListing(_ entries: [BrowserEntry], of folder: URL, namesOnly: Bool = false) async {
        guard !ArchivePath.isArchive(folder) else { return }
        let locate = self.locate
        // `resolve` may block on a slow share, the encoding is a few ms for a big folder: neither on the actor.
        guard let location = await Self.offActor(qos: .utility, { locate(folder.appendingPathComponent("_")) }) else { return }
        let before = namesOnly ? perform("stored listing", { try $0.listing(at: location) }) ?? nil : nil
        guard let data = await Self.offActor(qos: .utility, { () -> Data? in
            guard let before, let old = StoredListing.decode(before, in: folder) else { return StoredListing.encode(entries) }
            let known = Dictionary(old.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            return StoredListing.encode(entries.map { e in
                guard let k = known[e.name], k.kind == e.kind else { return e }
                var e = e
                e.date = e.date ?? k.date
                e.size = e.size ?? k.size
                e.count = e.count ?? k.count
                return e
            })
        }) else { return }
        _ = perform("store listing") { try $0.putListing(data, at: location) }
    }

    /// The listing kept for `folder` from an earlier opening; nil without one.
    public func storedListing(_ folder: URL) async -> [BrowserEntry]? {
        guard !ArchivePath.isArchive(folder) else { return nil }
        let locate = self.locate
        guard let location = await Self.offActor({ locate(folder.appendingPathComponent("_")) }),
              let data = perform("stored listing", { try $0.listing(at: location) }) ?? nil else { return nil }
        return await Self.offActor { StoredListing.decode(data, in: folder) }
    }
}
