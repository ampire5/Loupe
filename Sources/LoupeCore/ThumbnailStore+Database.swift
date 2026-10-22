import Foundation

// The database side: opened on first use, written in batches, and made anew when it is deleted or damaged
// under the running app (spec §3.2, §3.7). Every call goes through `perform`, which decides what a failure
// means; the thumbnails always stay usable from memory.

extension ThumbnailStore {
    /// The open database, opening it on first use; nil for memory only.
    func database() -> ThumbnailDatabase? {
        switch disk {
        case .open(let db):
            return db
        case .none:
            return nil
        case .unopened:
            guard let directory, wantsDisk else { disk = .none; return nil }
            do {
                let db = try ThumbnailDatabase(directory: directory, thumbSize: thumbSize)
                disk = .open(db)
                storedBytes = try db.storedBytes()
                return db
            } catch {
                warn("cannot open the thumbnail cache in \(directory.path) (\(error)); thumbnails stay in memory")
                disk = .none
                return nil
            }
        }
    }

    /// Runs `body` on the database. A damaged file is set aside and made anew (spec §3.7); any other failure
    /// is reported once and leaves the thumbnails in memory. Nil when it failed or there is no database.
    func perform<T>(_ what: String, _ body: (ThumbnailDatabase) throws -> T) -> T? {
        guard let db = database() else { return nil }
        do {
            return try body(db)
        } catch where ThumbnailDatabase.isDamage(error) && !recovering {
            recovering = true
            defer { recovering = false }
            do {
                reopened(try db.replaceDamaged())
            } catch {
                warn("cannot recreate the thumbnail cache (\(error)); thumbnails stay in memory")
                closeDatabase()
                disk = .none
            }
            return nil
        } catch {
            warn("thumbnail cache \(what) failed (\(error)); thumbnails stay in memory")
            return nil
        }
    }

    /// Before a batch and a folder sync: the databases deleted under us (the user emptied `Caches/Loupe`) are
    /// made again. True when that happened, in which case every folder was synced anew.
    func checkReopen() -> Bool {
        guard let result = perform("reopen", { try $0.reopenIfDeleted() }), result != .nothing else { return false }
        reopened(result)
        return true
    }

    /// New database files: what the old ones held is gone, and after `.catalog` so are their ids. Thumbnails
    /// waiting for a batch are kept by URL and find their new ids in the sync.
    func reopened(_ result: ThumbnailDatabase.Reopened) {
        databaseEpoch += 1
        storedBytes = perform("count", { try $0.storedBytes() }) ?? 0
        if result == .catalog {
            ids = [:]
            touched = []
        }
        stored = []
        resyncFolders()
        replan()
    }

    func closeDatabase() {
        if case .open(let db) = disk { db.close() }
        databaseEpoch += 1
        commitTimer?.cancel()
        commitTimer = nil
        disk = .unopened
        ids = [:]
        stored = []
        uncommitted = []
        touched = []
        pendingSummaries = [:]
        storedBytes = 0
    }

    func scheduleCommit() {
        guard commitTimer == nil, case .open = disk else { return }
        let delay = commitDelay
        commitTimer = Task { [weak self] in
            guard (try? await Task.sleep(for: delay)) != nil else { return }
            await self?.commit()
        }
    }

    /// Writes the waiting thumbnails and accesses in one batch. Written thumbnails leave memory (the
    /// database has them). On a failed write they stay in memory and leave the batch queue: they are tried
    /// again when their folder is next synced (`sync` queues `made` entries whose stamp matches), or in the
    /// very next batch when the write failed on a damaged file that was just made anew.
    func commit() {
        commitTimer?.cancel()
        commitTimer = nil
        guard case .open = disk, !uncommitted.isEmpty || !touched.isEmpty || !pendingSummaries.isEmpty else { return }
        _ = checkReopen()
        let batch = uncommitted.compactMap { url -> (url: URL, item: (id: Int64, stamp: FileStamp, jpeg: Data, info: ImageInfo))? in
            guard let thumbnail = made[url], let id = ids[url] else { return nil }
            return (url, (id, thumbnail.stamp, thumbnail.jpeg, thumbnail.info))
        }
        let touches = Array(touched)
        // Summaries a failed write loses are made again on the cards' next pass.
        let summaries = Array(pendingSummaries.values)
        pendingSummaries = [:]
        let epoch = databaseEpoch
        let written = perform("write", { db -> Void in
            try db.put(batch.map(\.item))
            try db.touch(touches)
        }) != nil
        // On their own: a summary that cannot be written never costs the thumbnails their batch.
        if !summaries.isEmpty, databaseEpoch == epoch { _ = perform("summaries", { try $0.putSummaries(summaries) }) }
        if !batch.isEmpty { commitCount += 1 }
        touched = []
        guard written else {
            if databaseEpoch == epoch { uncommitted = [] } else { scheduleCommit() }
            return
        }
        uncommitted = []
        for (url, _) in batch {
            removeMade(url)
            stored.insert(url)
        }
        storedBytes += batch.reduce(0) { $0 + $1.item.jpeg.count }
        if storedBytes > limitBytes { enforceLimit() }
    }

    /// Down to 90 % of the limit, oldest access first; what went from the open folders is not made again
    /// until they are opened again.
    func enforceLimit() {
        let before = stored
        guard perform("limit", { db -> Void in
            _ = try db.enforceLimit(limitBytes)
            storedBytes = try db.storedBytes()
        }) != nil else { return }
        refreshStored()
        // Before the replan, or the queue would take them again at once.
        evicted.formUnion(before.subtracting(stored))
        replan()
    }

    /// `stored` again from the database, after something else deleted thumbnails. The caller replans.
    func refreshStored() {
        let known = Array(ids)
        guard let have = perform("check", { try $0.hasThumbnail(known.map(\.value)) }) else { return }
        stored = Set(known.filter { have.contains($0.value) }.map(\.key))
    }

    /// The JPEG of `url` from memory or the database. A thumbnail the database turns out not to have any
    /// more (evicted by another process, say) is pending again.
    func storedJPEG(_ url: URL) -> Data? { storedThumbnail(url)?.jpeg }

    /// `storedJPEG` with the source's `ImageInfo` stored beside it (the catalog row's), never the photo's.
    func storedThumbnail(_ url: URL) -> (jpeg: Data, info: ImageInfo)? {
        if let thumbnail = made[url] {
            used(url)
            return (thumbnail.jpeg, thumbnail.info)
        }
        guard stored.contains(url), let id = ids[url] else { return nil }
        guard let found = perform("read", { try $0.thumbnail(id) }), let found else {
            stored.remove(url)
            replan()
            return nil
        }
        touch(url)
        return found
    }

    func touch(_ url: URL) {
        guard let id = ids[url] else { return }
        touched.insert(id)
        scheduleCommit()
    }
}
