import Foundation

/// A session kept in `Loupe.db`.
public struct SavedSession: Equatable, Sendable {
    public var id: Int64
    public var name: String
    public var saved: Date
    public var isLast: Bool
    public var snapshot: SessionSnapshot
}

/// The sessions (Home spec §2.6) in `Loupe.db` (`sessions`): named ones, written at once, and Last Session. Last
/// Session is the previous run's (`is_last = 1`) and stays as it is while this run works: this run's windows go to its
/// own row (`is_last = 2`), saved as windows change, at most once per `debounce`, and by `flush()` on quit, and that row
/// becomes Last Session at the next launch (`beginRun`). So a photo opened right after a launch never costs the
/// session before it.
public final class SessionStore: @unchecked Sendable {
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

    /// Saves `s` as `name`, replacing a session of that name.
    public func save(_ s: SessionSnapshot, name: String) {
        perform { db in
            try db.transaction {
                try db.run("DELETE FROM sessions WHERE name = ? AND is_last = 0", [.text(name)])
                _ = try db.run("INSERT INTO sessions(name, saved, is_last, json) VALUES(?, ?, 0, ?)",
                               [.text(name), .double(now().timeIntervalSinceReferenceDate), .blob(s.encoded())])
            }
        }
    }

    /// False when another session has that name.
    public func rename(_ id: Int64, to name: String) -> Bool {
        var taken = false
        perform { db in
            try db.query("SELECT 1 FROM sessions WHERE name = ? AND is_last = 0 AND id != ?", [.text(name), .int(id)]) { _ in
                taken = true
            }
            if !taken { _ = try db.run("UPDATE sessions SET name = ? WHERE id = ?", [.text(name), .int(id)]) }
        }
        return !taken
    }

    public func replace(_ id: Int64, with s: SessionSnapshot) {
        perform { db in
            _ = try db.run("UPDATE sessions SET json = ?, saved = ? WHERE id = ?",
                           [.blob(s.encoded()), .double(now().timeIntervalSinceReferenceDate), .int(id)])
        }
    }

    public func delete(_ id: Int64) {
        perform { db in _ = try db.run("DELETE FROM sessions WHERE id = ?", [.int(id)]) }
    }

    /// Last Session first, then the newest saved; rows whose JSON does not decode are left out.
    public func all() -> [SavedSession] {
        flushIfPending()
        var out: [SavedSession] = []
        perform { db in
            try db.query("SELECT id, name, saved, is_last, json FROM sessions WHERE is_last != ? ORDER BY is_last DESC, saved DESC",
                         [.int(Int64(Self.thisRun))]) { r in
                guard let snapshot = SessionSnapshot.decode(r.blob(4)) else { return }
                let isLast = r.int(3) != 0
                out.append(SavedSession(id: r.int(0), name: isLast ? Self.lastName : r.text(1),
                                        saved: Date(timeIntervalSinceReferenceDate: r.double(2)), isLast: isLast,
                                        snapshot: snapshot))
            }
        }
        if database == nil, let last = lock.withLock({ lastInMemory }) {
            out.append(SavedSession(id: 0, name: Self.lastName, saved: now(), isLast: true, snapshot: last))
        }
        return out
    }

    public func last() -> SessionSnapshot? {
        all().first { $0.isLast }?.snapshot
    }

    /// Writes a pending Last Session now and waits for it; for quitting.
    public func flush() {
        queue.sync { writeLast() }
    }

    private func flushIfPending() {
        if lock.withLock({ pendingLast != nil }) { flush() }
    }

    private func writeLast() {
        guard let s = lock.withLock({ () -> SessionSnapshot? in defer { pendingLast = nil }; return pendingLast }) else {
            return
        }
        let ok = perform { db in
            try db.transaction {
                try db.run("DELETE FROM sessions WHERE is_last = ?", [.int(Int64(Self.thisRun))])
                _ = try db.run("INSERT INTO sessions(name, saved, is_last, json) VALUES(?, ?, ?, ?)",
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
                    if new != s { _ = try db.run("UPDATE sessions SET json = ? WHERE id = ?", [.blob(new.encoded()), .int(id)]) }
                }
            }
        }
    }
}
