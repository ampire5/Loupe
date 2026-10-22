import Foundation

/// The thumbnails held in memory (`made`) under a byte cap: those of folders no window shows go first, least
/// recently used first; then those of shown folders, farthest from the current photo first (the generation order
/// backwards), never the key window's visible cells.
///
/// With a database `made` holds only a batch's worth between commits, but memory only (`thumb-cache-size=0`, or a
/// database that cannot be opened) it is every thumbnail of the session: at ~50 KB each, a walk through 20–40 k
/// photos would hold 1–2 GB of JPEGs beside the viewer's 1–4 GB `cache-memory`, past the 3 GB-a-window bar.
/// `memoryCap` (256 MB, ~5,000 thumbnails at the default 512 px, ~1,500 at 1024 px) keeps a few big folders' worth.
/// Thumbnails waiting for a batch are never dropped (the database would lose them). Like the database's limit,
/// what goes from a folder still shown is not made again until that folder is opened again, or a folder bigger
/// than the cap would be read in circles; going farthest first, what is gone is what the user is least likely to
/// reach (the strip and the jump preview keep the photos around the current one and the cells on screen).
extension ThumbnailStore {
    public static let defaultMemoryCap = 256 << 20

    /// The caller enforces the cap once the thumbnail's batch bookkeeping is done (`enforceMemoryCap`).
    func setMade(_ url: URL, _ thumbnail: Made) {
        madeBytes += thumbnail.jpeg.count - (made[url]?.jpeg.count ?? 0)
        made[url] = thumbnail
        used(url)
    }

    func removeMade(_ url: URL) {
        guard let old = made.removeValue(forKey: url) else { return }
        madeBytes -= old.jpeg.count
        madeAccess[url] = nil
    }

    func removeAllMade() {
        made = [:]
        madeBytes = 0
        madeAccess = [:]
    }

    /// A thumbnail in memory was made or shown: among folders no window shows, the last to go.
    func used(_ url: URL) {
        guard made[url] != nil else { return }
        accessClock += 1
        madeAccess[url] = accessClock
    }

    /// Over the cap: down to 90 % of it (so this runs once per a tenth of the cap), in `memoryVictims` order.
    func enforceMemoryCap() {
        guard madeBytes > memoryCap else { return }
        let target = memoryCap / 10 * 9
        for url in memoryVictims() {
            guard madeBytes > target else { break }
            if listed[url] != nil { evicted.insert(url) }
            forget(url)
        }
    }

    /// The thumbnails the cap may drop, first to go first: those the generation order leaves out (folders no
    /// window shows, files of a window without a position), least recently used first; then the shown folders'
    /// in that order backwards. Never one waiting for its batch, nor a cell on the key window's strip.
    func memoryVictims() -> [URL] {
        let requests = windows.sorted { $0.key < $1.key }.map(\.value.request)
        var keep = uncommitted
        for request in requests where request.isKey {
            for index in request.visible where request.files.indices.contains(index) { keep.insert(request.files[index]) }
        }
        let ordered = ThumbnailQueue.order(requests, skip: [])
        let inOrder = Set(ordered)
        let outside = made.keys.filter { !inOrder.contains($0) && !keep.contains($0) }
            .sorted { madeAccess[$0, default: 0] < madeAccess[$1, default: 0] }
        return outside + ordered.reversed().filter { made[$0] != nil && !keep.contains($0) }
    }
}
