import Foundation

/// A session kept in `Loupe.db`.
public struct SavedSession: Equatable, Sendable {
    public var id: Int64
    public var name: String
    public var saved: Date
    public var isLast: Bool
    public var snapshot: SessionSnapshot
    var revision = Data()
}

/// The sessions (Home spec §2.6) in `Loupe.db` (`sessions`): named ones, written at once, and Last Session. Last
/// Session is the previous run's (`is_last = 1`) and stays as it is while this run works: this run's windows go to its
/// own row (`is_last = 2`), saved as windows change, at most once per `debounce`, and by `flush()` on quit, and that row
/// becomes Last Session at the next launch (`beginRun`). So a photo opened right after a launch never costs the
/// session before it.
public final class SessionStore: @unchecked Sendable {
    public enum MutationResult: Equatable, Sendable {
        case saved
        case nameTaken
        case confirmationRequired(Replacement)
        case missing
        case changed
        case unavailable
        case writeFailed
    }

    /// Identifies the version displayed in a Save As replacement prompt.
    public struct Replacement: Equatable, Sendable {
        fileprivate let id: Int64
        fileprivate let revision: Data
    }

    public static let lastName = "Last Session"
    private static let previousRun = 1, thisRun = 2

    private let database: StateDatabase?
    private let debounce: Duration
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "loupe.sessions", qos: .utility)
    private let lock = NSLock()
    private var pendingLast: SessionSnapshot?
    private var lastInMemory: SessionSnapshot?
    private var writeScheduled = false
    private let failureLog = WriteFailureLog()

    public init(database: StateDatabase?, debounce: Duration = .seconds(2),
                now: @escaping @Sendable () -> Date = Date.init) {
        self.database = database
        self.debounce = debounce
        self.now = now
    }

    /// Last Session becomes `s` within `debounce`, without its windows that show only Home (spec §2.6); a snapshot of
    /// Home alone leaves it as it is.
    public func saveLast(_ snapshot: SessionSnapshot) {
        guard !snapshot.isOnlyHome else { return }
        var s = snapshot
        s.windows.removeAll { SessionSnapshot(windows: [$0]).isOnlyHome }
        let schedule = lock.withLock { () -> Bool in
            pendingLast = s
            lastInMemory = s
            guard database != nil, !writeScheduled else { return false }
            writeScheduled = true
            return true
        }
        guard schedule else { return }
        queue.asyncAfter(deadline: .now() + debounce.seconds) { [self] in
            lock.withLock { writeScheduled = false }
            writeLast()
        }
    }

    /// At launch: what the run before saved becomes Last Session; a run that saved nothing leaves the one before it.
    public func beginRun() {
        perform { db in
            var saved = false
            try db.query("SELECT 1 FROM sessions WHERE is_last = ?", [.int(Int64(Self.thisRun))]) { _ in saved = true }
            guard saved else { return }
            try db.transaction {
                try db.run("DELETE FROM sessions WHERE is_last = ?", [.int(Int64(Self.previousRun))])
                _ = try db.run("UPDATE sessions SET is_last = ? WHERE is_last = ?",
                               [.int(Int64(Self.previousRun)), .int(Int64(Self.thisRun))])
            }
        }
    }

    /// Saves a new name, or replaces exactly the version the caller confirmed. A newly occupied
    /// name or an intervening edit requires fresh confirmation, without loading the existing snapshot.
    public func save(_ snapshot: SessionSnapshot, name: String, replacing confirmed: Replacement? = nil) async -> MutationResult {
        await onQueue {
            self.mutate { db in
                var existing: Replacement?
                try db.query("SELECT id, revision FROM sessions WHERE name = ? AND is_last = 0", [.text(name)]) {
                    existing = Replacement(id: $0.int(0), revision: $0.blob(1))
                }
                if let existing {
                    guard existing == confirmed else { return .confirmationRequired(existing) }
                    return try self.writeSnapshot(snapshot, id: existing.id, in: db)
                }

                let json = snapshot.encoded()
                guard !json.isEmpty else { return .writeFailed }
                return try Self.write(
                    "INSERT INTO sessions(name, saved, is_last, json, revision) VALUES(?, ?, 0, ?, randomblob(16)) RETURNING id",
                    [.text(name), .double(self.now().timeIntervalSinceReferenceDate), .blob(json)], in: db
                )
            }
        }
    }

    public func rename(_ session: SavedSession, to name: String) async -> MutationResult {
        await onQueue {
            self.mutate(session) { db in
                var taken = false
                try db.query("SELECT 1 FROM sessions WHERE name = ? AND is_last = 0 AND id != ?",
                             [.text(name), .int(session.id)]) { _ in taken = true }
                guard !taken else { return .nameTaken }
                return try Self.write("UPDATE sessions SET name = ?, revision = randomblob(16) WHERE id = ? AND is_last = 0 RETURNING id",
                                      [.text(name), .int(session.id)], in: db)
            }
        }
    }

    public func replace(_ session: SavedSession, with snapshot: SessionSnapshot) async -> MutationResult {
        await onQueue {
            self.mutate(session) { db in try self.writeSnapshot(snapshot, id: session.id, in: db) }
        }
    }

    public func delete(_ session: SavedSession) async -> MutationResult {
        await onQueue {
            self.mutate(session) { db in
                try Self.write("DELETE FROM sessions WHERE id = ? RETURNING id", [.int(session.id)], in: db)
            }
        }
    }

    private func writeSnapshot(_ snapshot: SessionSnapshot, id: Int64, in db: SQLiteConnection) throws -> MutationResult {
        let json = snapshot.encoded()
        guard !json.isEmpty else { return .writeFailed }
        return try Self.write("UPDATE sessions SET json = ?, saved = ?, revision = randomblob(16) WHERE id = ? AND is_last = 0 RETURNING id",
                              [.blob(json), .double(now().timeIntervalSinceReferenceDate), .int(id)], in: db)
    }

    private static func write(_ sql: String, _ args: [SQLiteValue], in db: SQLiteConnection) throws -> MutationResult {
        var wrote = false
        try db.query(sql, args) { _ in wrote = true }
        return wrote ? .saved : .writeFailed
    }

    private func mutate(_ session: SavedSession? = nil, _ body: (SQLiteConnection) throws -> MutationResult) -> MutationResult {
        guard database != nil else { return .unavailable }
        var result = MutationResult.writeFailed
        let ok = perform { db in
            try db.transaction {
                if let session {
                    var revision: Data?
                    try db.query("SELECT revision FROM sessions WHERE id = ? AND is_last = ?",
                                 [.int(session.id), .int(Int64(session.isLast ? Self.previousRun : 0))]) { revision = $0.blob(0) }
                    guard let revision else { result = .missing; return }
                    guard revision == session.revision else { result = .changed; return }
                }
                result = try body(db)
            }
        }
        return ok ? result : .writeFailed
    }

    /// Last Session first, then the newest saved; rows whose JSON does not decode are left out.
    public func all() async -> [SavedSession] {
        await onQueue {
            if self.database == nil, let last = self.lock.withLock({ self.lastInMemory }) {
                return [SavedSession(id: 0, name: Self.lastName, saved: self.now(), isLast: true, snapshot: last)]
            }
            var out: [SavedSession] = []
            self.perform { db in
                try db.query("SELECT id, name, saved, is_last, json, revision FROM sessions WHERE is_last != ? ORDER BY is_last DESC, saved DESC",
                             [.int(Int64(Self.thisRun))]) { r in
                    guard let snapshot = SessionSnapshot.decode(r.blob(4)) else { return }
                    let isLast = r.int(3) != 0
                    out.append(SavedSession(id: r.int(0), name: isLast ? Self.lastName : r.text(1),
                                            saved: Date(timeIntervalSinceReferenceDate: r.double(2)), isLast: isLast,
                                            snapshot: snapshot, revision: r.blob(5)))
                }
            }
            return out
        }
    }

    /// Reads only the previous run. A pending write belongs to this run and has its own deadline.
    public func last() async -> SessionSnapshot? {
        await onQueue {
            guard self.database != nil else { return self.lock.withLock { self.lastInMemory } }
            var last: SessionSnapshot?
            self.perform { db in
                try db.query("SELECT json FROM sessions WHERE is_last = ? ORDER BY saved DESC",
                             [.int(Int64(Self.previousRun))]) { r in
                    if last == nil { last = SessionSnapshot.decode(r.blob(0)) }
                }
            }
            return last
        }
    }

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async(qos: .userInitiated) { continuation.resume(returning: body()) }
        }
    }

    /// Writes a pending Last Session now and waits for it; for quitting.
    public func flush() async {
        await onQueue { self.writeLast() }
    }

    private func writeLast() {
        guard let s = lock.withLock({ () -> SessionSnapshot? in defer { pendingLast = nil }; return pendingLast }) else {
            return
        }
        let ok = perform { db in
            try db.transaction {
                try db.run("DELETE FROM sessions WHERE is_last = ?", [.int(Int64(Self.thisRun))])
                _ = try db.run("INSERT INTO sessions(name, saved, is_last, json, revision) VALUES(?, ?, ?, ?, randomblob(16))",
                               [.text(Self.lastName), .double(now().timeIntervalSinceReferenceDate),
                                .int(Int64(Self.thisRun)), .blob(s.encoded())])
            }
        }
        if !ok { lock.withLock { if pendingLast == nil { pendingLast = s } } }
    }

    @discardableResult
    private func perform(_ body: (SQLiteConnection) throws -> Void) -> Bool {
        guard let database else { return false }
        do {
            try database.perform(body)
            failureLog.succeeded()
            return true
        } catch {
            failureLog.failed(error)
            return false
        }
    }
}

extension SessionStore: PathMoving {
    /// A rename in the file browser: every session's tabs on a file at or under `from` follow it.
    public func movePaths(from: URL, to: URL) {
        let move = PathMove(from: from, to: to)
        func moved(_ s: SessionSnapshot) -> SessionSnapshot {
            var s = s
            for w in s.windows.indices {
                s.windows[w].tabs = s.windows[w].tabs.map { tab in
                    if case .file(let path, let view) = tab, let new = move.moved(path) { return .file(path: new, view: view) }
                    return tab
                }
            }
            return s
        }
        // Keep the path rewrite together with Last Session writes on the session queue.
        queue.sync {
            lock.withLock {
                pendingLast = pendingLast.map(moved)
                lastInMemory = lastInMemory.map(moved)
            }
            perform { db in
                var rows: [(Int64, SessionSnapshot)] = []
                try db.query("SELECT id, json FROM sessions", []) { r in
                    if let s = SessionSnapshot.decode(r.blob(1)) { rows.append((r.int(0), s)) }
                }
                try db.transaction {
                    for (id, s) in rows {
                        let new = moved(s)
                        if new != s { _ = try db.run("UPDATE sessions SET json = ?, revision = randomblob(16) WHERE id = ?", [.blob(new.encoded()), .int(id)]) }
                    }
                }
            }
        }
    }
}
