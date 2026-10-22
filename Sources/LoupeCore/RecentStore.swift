import Foundation

/// What a recent entry is: a folder, or a zip archive opened as one.
public enum RecentKind: String, Sendable {
    case folder, archive
}

/// Where in a Stash gallery list a gallery was picked (StashKit's `StashGalleryListContext`, which LoupeCore does not
/// know): the list query's variables, the gallery's index in the list, and the list's length when known.
public struct RecentGalleryList: Equatable, Sendable {
    public var variables: Data
    public var index: Int
    public var count: Int?

    public init(variables: Data, index: Int, count: Int?) {
        self.variables = variables
        self.index = index
        self.count = count
    }
}

/// A recent entry that is a Stash gallery: its id and the list it was opened from (folder steps follow it).
public struct RecentGallery: Equatable, Sendable {
    public var id: String
    public var list: RecentGalleryList?

    public init(id: String, list: RecentGalleryList?) {
        self.id = id
        self.list = list
    }
}

/// One folder, archive or Stash gallery Home lists under Recent (Home spec §2.4).
public struct RecentEntry: Equatable, Sendable {
    /// The standardized folder or archive path; the key.
    public var path: String
    public var kind: RecentKind
    public var gallery: RecentGallery?
    /// The Stash title (`stash-title`); nil: the last path component.
    public var title: String?
    /// The file last viewed, its 0-based index then, and how many files the folder had.
    public var file: String?
    public var index: Int?
    public var count: Int?
    public var opened: Date
    public var hidden: Bool

    public var url: URL { URL(fileURLWithPath: path) }
    public var displayTitle: String { title ?? url.lastPathComponent }
}

/// Home's recent folders, archives and Stash galleries, kept in `Loupe.db` (`recent`). Entering a folder raises it to
/// the front (and shows a hidden one again); viewing a photo updates it in place. Changes are made in memory at once
/// and written on a background queue at most once per `debounce`, and by `flush()` (on quit), as `FolderPositions`.
public final class RecentStore: @unchecked Sendable {
    public static let storedLimit = 200

    private let database: StateDatabase?
    private let debounce: Duration
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "loupe.recent", qos: .utility)
    private let lock = NSLock()
    private var entries: [String: RecentEntry] = [:]
    private var dirty: Set<String> = []
    private var writeScheduled = false
    private let failureLog = WriteFailureLog()
    private var changeHandler: (@Sendable () -> Void)?

    /// Called on the main queue after a change.
    public var onChange: (@Sendable () -> Void)? {
        get { lock.withLock { changeHandler } }
        set { lock.withLock { changeHandler = newValue } }
    }

    public init(database: StateDatabase?, debounce: Duration = .seconds(2),
                now: @escaping @Sendable () -> Date = Date.init) {
        self.database = database
        self.debounce = debounce
        self.now = now
        try? database?.perform { db in
            try db.query("""
                SELECT path, kind, gallery_id, gallery_list, gallery_index, gallery_count, title, file, idx, count,
                    opened, hidden FROM recent ORDER BY opened DESC LIMIT ?
                """, [.int(Int64(Self.storedLimit))]) { r in
                var gallery: RecentGallery?
                if !r.isNull(2) {
                    let list = r.isNull(3) ? nil
                        : RecentGalleryList(variables: r.blob(3), index: Int(r.int(4)),
                                            count: r.isNull(5) ? nil : Int(r.int(5)))
                    gallery = RecentGallery(id: r.text(2), list: list)
                }
                let entry = RecentEntry(
                    path: r.text(0), kind: RecentKind(rawValue: r.text(1)) ?? .folder, gallery: gallery,
                    title: r.isNull(6) ? nil : r.text(6), file: r.isNull(7) ? nil : r.text(7),
                    index: r.isNull(8) ? nil : Int(r.int(8)), count: r.isNull(9) ? nil : Int(r.int(9)),
                    opened: Date(timeIntervalSinceReferenceDate: r.double(10)), hidden: r.int(11) != 0)
                entries[entry.path] = entry
            }
        }
    }

    /// `folder` was entered (opened from outside, by a folder step, from Stash): it goes to the front and is shown
    /// again if hidden. `gallery` and `title` replace what was kept when given; `clearsGallery` (an open from outside)
    /// forgets a kept gallery, so the folder is an ordinary one from then on.
    public func entered(_ folder: URL, kind: RecentKind, gallery: RecentGallery?, title: String?, clearsGallery: Bool) {
        let path = Self.key(folder)
        change(path) { e in
            var entry = e ?? RecentEntry(path: path, kind: kind, gallery: nil, title: nil, file: nil, index: nil,
                                         count: nil, opened: now(), hidden: false)
            entry.kind = kind
            entry.opened = now()
            entry.hidden = false
            if let gallery {
                entry.gallery = gallery
                entry.title = title
            } else if clearsGallery {
                entry.gallery = nil
                entry.title = nil
            }
            return entry
        }
    }

    /// `file` (index `index` of `count`) is on screen in `folder`; nothing happens for a folder not entered.
    public func viewed(_ folder: URL, file: String, index: Int, count: Int?) {
        change(Self.key(folder)) { e in
            guard var entry = e else { return nil }
            if entry.file == file, entry.index == index, entry.count == count ?? entry.count { return nil }
            entry.file = file
            entry.index = index
            if let count { entry.count = count }
            return entry
        }
    }

    /// Remove from Recent: hidden until entered again; nothing else forgotten.
    public func hide(_ path: String) {
        change(path) { e in
            guard var entry = e, !entry.hidden else { return nil }
            entry.hidden = true
            return entry
        }
    }

    /// Clear Recent.
    public func hideAll() {
        let paths = lock.withLock { entries.values.filter { !$0.hidden }.map(\.path) }
        for path in paths { hide(path) }
    }

    /// The entry of `folder`, hidden or not; nil when it has none.
    public func entry(for folder: URL) -> RecentEntry? {
        lock.withLock { entries[Self.key(folder)] }
    }

    /// The newest `limit` entries not hidden, newest first.
    public func shown(limit: Int) -> [RecentEntry] {
        guard limit > 0 else { return [] }
        let all = lock.withLock { Array(entries.values) }
        return Array(all.filter { !$0.hidden }.sorted { ($0.opened, $0.path) > ($1.opened, $1.path) }.prefix(limit))
    }

    /// Writes pending changes now and waits for the write; for quitting.
    public func flush() {
        queue.sync { write() }
    }

    private static func key(_ folder: URL) -> String { folder.standardizedFileURL.path }

    /// Applies `body` to the entry at `path` (nil: none); a nil result changes nothing. Beyond `storedLimit` the
    /// oldest entries go.
    private func change(_ path: String, _ body: (RecentEntry?) -> RecentEntry?) {
        let schedule = lock.withLock { () -> Bool? in
            guard let entry = body(entries[path]) else { return nil }
            entries[path] = entry
            dirty.insert(path)
            while entries.count > Self.storedLimit, let oldest = entries.values.min(by: { $0.opened < $1.opened }) {
                entries[oldest.path] = nil
                dirty.insert(oldest.path)
            }
            guard database != nil, !writeScheduled else { return false }
            writeScheduled = true
            return true
        }
        guard let schedule else { return }
        if let handler = onChange { DispatchQueue.main.async { handler() } }
        guard schedule else { return }
        queue.asyncAfter(deadline: .now() + debounce.seconds) { [self] in
            lock.withLock { writeScheduled = false }
            write()
        }
    }

    /// One transaction for everything changed since the last write; a failure keeps the changes pending.
    private func write() {
        guard let database else { return }
        let batch: [(path: String, entry: RecentEntry?)] = lock.withLock {
            let paths = dirty
            dirty = []
            return paths.map { ($0, entries[$0]) }
        }
        guard !batch.isEmpty else { return }
        do {
            try database.perform { db in
                try db.transaction {
                    for (path, entry) in batch {
                        guard let e = entry else {
                            try db.run("DELETE FROM recent WHERE path = ?", [.text(path)])
                            continue
                        }
                        let list = e.gallery?.list
                        func opt(_ v: Int?) -> SQLiteValue { v.map { .int(Int64($0)) } ?? .null }
                        func opt(_ v: String?) -> SQLiteValue { v.map { .text($0) } ?? .null }
                        try db.run("""
                            INSERT OR REPLACE INTO recent(path, kind, gallery_id, gallery_list, gallery_index,
                                gallery_count, title, file, idx, count, opened, hidden)
                            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """, [.text(path), .text(e.kind.rawValue), opt(e.gallery?.id),
                                  list.map { .blob($0.variables) } ?? .null, opt(list?.index), opt(list?.count),
                                  opt(e.title), opt(e.file), opt(e.index), opt(e.count),
                                  .double(e.opened.timeIntervalSinceReferenceDate), .int(e.hidden ? 1 : 0)])
                    }
                    try db.run("""
                        DELETE FROM recent WHERE path IN (SELECT path FROM recent ORDER BY opened DESC LIMIT -1 OFFSET ?)
                        """, [.int(Int64(Self.storedLimit))])
                }
            }
            failureLog.succeeded()
        } catch {
            failureLog.failed(error)
            lock.withLock { dirty.formUnion(batch.map(\.path)) }
        }
    }
}

extension RecentStore: PathMoving {
    /// A rename in the file browser: the recent folders at or under `from` move, and a folder's last photo that was
    /// renamed keeps its card under the new name.
    public func movePaths(from: URL, to: URL) {
        let move = PathMove(from: from, to: to)
        let schedule = lock.withLock { () -> Bool? in
            var changed = false
            for (key, var entry) in entries {
                if let new = move.moved(key) {
                    entries[key] = nil
                    entry.path = new
                    entries[new] = entry
                    dirty.formUnion([key, new])
                    changed = true
                } else if let file = entry.file, let name = move.renamedFile(file, in: key) {
                    entries[key]?.file = name
                    dirty.insert(key)
                    changed = true
                }
            }
            guard changed else { return nil }
            guard database != nil, !writeScheduled else { return false }
            writeScheduled = true
            return true
        }
        guard let schedule else { return }
        if let handler = onChange { DispatchQueue.main.async { handler() } }
        guard schedule else { return }
        queue.asyncAfter(deadline: .now() + debounce.seconds) { [self] in
            lock.withLock { writeScheduled = false }
            write()
        }
    }
}
