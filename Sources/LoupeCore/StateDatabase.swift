import Foundation

/// `Loupe.db` (spec §8): the app's small persistent state: the last photo of each folder (`folder_positions`), the
/// scaling values saved per folder (`folder_settings`), Home's recent folders (`recent`) and the sessions
/// (`sessions`). One SQLite file in
/// `~/Library/Application Support/Loupe`, apart from the thumbnail cache in `~/Library/Caches/Loupe` (which may
/// be wiped; this may not). `FolderPositions` and `FolderSettings` share one instance. Only the primary Loupe
/// process opens it.
///
/// A database that cannot be read (corrupt, not a database) is set aside as `Loupe.db.broken-<unix time>` and
/// a new one made, as the thumbnail cache does. The JSON files earlier builds kept (`folder-positions.json`,
/// `folder-settings.json`) are not migrated: they are never read, renamed or deleted.
public final class StateDatabase: @unchecked Sendable {
    public static let fileName = "Loupe.db"
    /// Ruling R9: the visit columns came without a new version (`addVisitColumns`), so an older Loupe opens the file.
    public static let schemaVersion = 2
    /// The version a pre-release build of the folder cards stamped its files with: the same tables, accepted and
    /// stamped `schemaVersion` again.
    static let prereleaseVersion = 3

    /// `~/Library/Application Support/Loupe`.
    public static var defaultDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Loupe", isDirectory: true)
    }

    /// `Loupe.db` itself.
    public let url: URL
    private let connection: SQLiteConnection
    private let lock = NSLock()

    /// Opens or creates `Loupe.db` in `directory` (created too if missing). Throws when the file cannot be used
    /// even after a damaged one is set aside, or was made by a newer Loupe; the caller then keeps its stores in
    /// memory.
    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(Self.fileName)
        self.url = url
        connection = try Self.open(url)
    }

    /// Opens `url` and prepares it; a damaged file is set aside first and the database made anew.
    private static func open(_ url: URL) throws -> SQLiteConnection {
        let fm = FileManager.default
        func attempt() throws -> SQLiteConnection {
            // A -wal / -shm left without its database would bring back pages of the old file.
            if !fm.fileExists(atPath: url.path) {
                for suffix in ["-wal", "-shm"] { try? fm.removeItem(atPath: url.path + suffix) }
            }
            let db = try SQLiteConnection(path: url.path, pragmas: pragmas)
            do { try prepare(db) } catch { db.close(); throw error }
            return db
        }
        do {
            return try attempt()
        } catch let error as SQLiteError where ThumbnailDatabase.isDamage(error) {
            try ThumbnailDatabase.setAside(url, reason: error.message)
            return try attempt()
        }
    }

    /// Runs `body` on the connection, one caller at a time (the two stores write from their own queues).
    func perform<T>(_ body: (SQLiteConnection) throws -> T) rethrows -> T {
        try lock.withLock { try body(connection) }
    }

    // MARK: - Opening

    private static let pragmas = ["journal_mode=WAL", "synchronous=NORMAL", "busy_timeout=2000"]

    /// Schema 2 (Home spec §3.1) only adds `recent` and `sessions`; a version 1 file keeps its rows.
    /// `folder_positions` has the visit too (`idx` the photo, `count` of how many, `visited` when; all null until a
    /// visit is recorded): new files from the statement below, older ones by `addVisitColumns`.
    /// `touched` is a counter that only grows: recency for the stores' folder caps. `view` is the
    /// `SavedView.text` (zoom mode and position) the folder's last photo was left in, null when none was saved.
    private static let schema = """
        CREATE TABLE IF NOT EXISTS folder_positions(path TEXT PRIMARY KEY, file TEXT NOT NULL, view TEXT,
            touched INTEGER NOT NULL, idx INTEGER, count INTEGER, visited REAL);
        CREATE TABLE IF NOT EXISTS folder_settings(path TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL,
            touched INTEGER NOT NULL, PRIMARY KEY(path, key));
        CREATE TABLE IF NOT EXISTS recent(path TEXT PRIMARY KEY, kind TEXT NOT NULL, gallery_id TEXT,
            gallery_list BLOB, gallery_index INTEGER, gallery_count INTEGER, title TEXT, file TEXT, idx INTEGER,
            count INTEGER, opened REAL NOT NULL, hidden INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS sessions(id INTEGER PRIMARY KEY, name TEXT NOT NULL, saved REAL NOT NULL,
            is_last INTEGER NOT NULL DEFAULT 0, json BLOB NOT NULL);
        CREATE UNIQUE INDEX IF NOT EXISTS sessions_name ON sessions(name) WHERE is_last = 0;
        """

    /// The file browser's pinned folders and small values (the last folder), file browser spec §4.2: added to any
    /// version 2 file without a new version, so a Loupe from before the browser still opens it (it never reads them).
    private static let browserTables = """
        CREATE TABLE IF NOT EXISTS file_views(path TEXT PRIMARY KEY, viewed REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS browser_pins(path TEXT PRIMARY KEY, pinned REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS browser_state(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        """

    /// The visit columns of `folder_positions`, added to a file that has not got them (made by a Loupe before the
    /// folder cards: `CREATE TABLE IF NOT EXISTS` kept the table as it was) on every open, outside the version, as
    /// `browserTables`: an older Loupe still opens the file and never reads them. Its rows stay, the new fields null.
    private static func addVisitColumns(_ db: SQLiteConnection) throws {
        var columns: Set<String> = []
        try db.query("SELECT name FROM pragma_table_info('folder_positions')", []) { columns.insert($0.text(0)) }
        // No table (a file of a Loupe that never kept positions): nothing to add to.
        let missing = [("idx", "INTEGER"), ("count", "INTEGER"), ("visited", "REAL")].filter { !columns.contains($0.0) }
        guard !columns.isEmpty, !missing.isEmpty else { return }
        try db.transaction {
            for (name, type) in missing { try db.execute("ALTER TABLE folder_positions ADD COLUMN \(name) \(type)") }
        }
    }

    private static func prepare(_ db: SQLiteConnection) throws {
        var version: Int64 = 0
        try db.query("PRAGMA user_version", []) { version = $0.int(0) }
        guard version <= Int64(prereleaseVersion) else {
            throw SQLiteError(code: -1, message: "\(fileName) has schema version \(version), newer than this Loupe's \(schemaVersion)")
        }
        // Older (or the pre-release's 3): made up to date, then stamped `schemaVersion`.
        if version != Int64(schemaVersion) {
            try db.transaction {
                try db.execute(schema)
                try db.execute("PRAGMA user_version = \(schemaVersion)")
            }
        }
        try addVisitColumns(db)
        try db.execute(browserTables)
    }
}
