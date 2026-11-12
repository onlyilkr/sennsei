import Foundation
import SQLite3

public enum InsightsStoreError: Error, Equatable {
    case cannotOpen(String)
    case failed(String)
}

enum SQLValue {
    case text(String), int(Int64), double(Double), null
}

struct SQLRow {
    let stmt: OpaquePointer
    func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
}

/// Short-lived connection; closed on deinit so every operation releases the file.
final class SQLiteConnection {
    private let handle: OpaquePointer

    init(path: String, readOnly: Bool) throws {
        var db: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let db { sqlite3_close_v2(db) }
            throw InsightsStoreError.cannotOpen(message)
        }
        handle = db
        sqlite3_busy_timeout(db, 2000)
        sqlite3_exec(db, "PRAGMA secure_delete = ON", nil, nil, nil)
    }

    deinit { sqlite3_close_v2(handle) }

    private var message: String { String(cString: sqlite3_errmsg(handle)) }

    /// For fixed SQL without user data (BEGIN, COMMIT, VACUUM, PRAGMA).
    func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw InsightsStoreError.failed(message) }
    }

    func query(_ sql: String, _ binds: [SQLValue] = [], _ row: (SQLRow) throws -> Void = { _ in }) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw InsightsStoreError.failed(message)
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in binds.enumerated() {
            let i = Int32(index + 1)
            let rc: Int32
            switch value {
            case .text(let s): rc = sqlite3_bind_text(stmt, i, s, -1, transient)
            case .int(let n): rc = sqlite3_bind_int64(stmt, i, n)
            case .double(let d): rc = sqlite3_bind_double(stmt, i, d)
            case .null: rc = sqlite3_bind_null(stmt, i)
            }
            guard rc == SQLITE_OK else { throw InsightsStoreError.failed(message) }
        }
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW: try row(SQLRow(stmt: stmt))
            case SQLITE_DONE: return
            default: throw InsightsStoreError.failed(message)
            }
        }
    }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}

/// Local, file-backed history for Insights. The file is created lazily by the first `append`; reads and
/// maintenance on a missing file are no-ops. A file that is not a valid database is never modified.
public actor InsightsStore {
    static let rawRetentionDays = 90
    static let summaryRetentionMonths = 12

    let url: URL

    public init(url: URL) { self.url = url }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Sennsei", isDirectory: true).appendingPathComponent("insights.sqlite")
    }

    // MARK: - Connection

    /// Opens the existing database, or returns nil when there is no file or it holds no Insights tables yet.
    /// Throws for a file that is not a database.
    func openExisting(readOnly: Bool) throws -> SQLiteConnection? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let db = try SQLiteConnection(path: url.path, readOnly: readOnly)
        var hasTables = false
        try db.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'activity'") { _ in hasTables = true }
        guard hasTables else { return nil }
        try Self.checkSchemaVersion(db)
        return db
    }

    /// Refuses a database written by a newer schema (never modified).
    private static func checkSchemaVersion(_ db: SQLiteConnection) throws {
        var hasMeta = false
        try db.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'meta'") { _ in hasMeta = true }
        guard hasMeta else { return }
        var version: Int?
        try db.query("SELECT value FROM meta WHERE key = 'schema_version'") { version = Int($0.text(0)) }
        if let version, version > 1 { throw InsightsStoreError.failed("unsupported schema_version \(version)") }
    }

    private func openCreating() throws -> SQLiteConnection {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            let dir = url.deletingLastPathComponent()
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw InsightsStoreError.cannotOpen("cannot create \(url.lastPathComponent)")
            }
        }
        let db = try SQLiteConnection(path: url.path, readOnly: false)
        try Self.checkSchemaVersion(db)
        try db.transaction {
            try db.exec("""
                CREATE TABLE IF NOT EXISTS activity(app TEXT NOT NULL, app_name TEXT, kind TEXT NOT NULL, route TEXT NOT NULL, noise TEXT, start REAL NOT NULL, "end" REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS noise(mode TEXT NOT NULL, start REAL NOT NULL, "end" REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS battery(time REAL NOT NULL, percent INTEGER NOT NULL, charging INTEGER);
                CREATE TABLE IF NOT EXISTS daily(day REAL NOT NULL, app TEXT NOT NULL, kind TEXT NOT NULL, seconds REAL NOT NULL, PRIMARY KEY(day, app, kind));
                CREATE TABLE IF NOT EXISTS app_names(app TEXT PRIMARY KEY, name TEXT);
                CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE INDEX IF NOT EXISTS activity_end ON activity("end");
                CREATE INDEX IF NOT EXISTS noise_end ON noise("end");
                CREATE INDEX IF NOT EXISTS battery_time ON battery(time);
                INSERT OR IGNORE INTO meta(key, value) VALUES('schema_version', '1');
                """)
        }
        return db
    }

    // MARK: - Writes

    public func append(_ output: RecorderOutput) throws {
        guard !output.isEmpty else { return }
        let db = try openCreating()
        try db.transaction {
            for a in output.activity {
                try db.query(
                    "INSERT INTO activity(app, app_name, kind, route, noise, start, \"end\") VALUES(?,?,?,?,?,?,?)",
                    [.text(a.app), a.appName.map(SQLValue.text) ?? .null, .text(a.kind.rawValue), .text(a.route.rawValue),
                     a.noiseMode.map { .text($0.rawValue) } ?? .null,
                     .double(a.start.timeIntervalSince1970), .double(a.end.timeIntervalSince1970)])
            }
            for a in output.activity {
                guard let name = a.appName else { continue }
                try db.query(
                    "INSERT INTO app_names(app, name) VALUES(?,?) ON CONFLICT(app) DO UPDATE SET name = excluded.name",
                    [.text(a.app), .text(name)])
            }
            for n in output.noise {
                try db.query(
                    "INSERT INTO noise(mode, start, \"end\") VALUES(?,?,?)",
                    [.text(n.mode.rawValue), .double(n.start.timeIntervalSince1970), .double(n.end.timeIntervalSince1970)])
            }
            for b in output.battery {
                try db.query(
                    "INSERT INTO battery(time, percent, charging) VALUES(?,?,?)",
                    [.double(b.time.timeIntervalSince1970), .int(Int64(b.percent)), b.charging.map { .int($0 ? 1 : 0) } ?? .null])
            }
        }
    }

    /// Rolls raw activity older than 90 days into per-local-day summaries (removing the raw rows so nothing is
    /// counted twice), drops noise/battery rows older than 90 days and summaries older than 12 months.
    public func prune(now: Date, calendar: Calendar = .current) throws {
        guard let db = try openExisting(readOnly: false) else { return }
        let rawCutoff = (calendar.date(byAdding: .day, value: -Self.rawRetentionDays, to: now)
            ?? now.addingTimeInterval(-Double(Self.rawRetentionDays) * 86_400)).timeIntervalSince1970
        let summaryCutoff = (calendar.date(byAdding: .month, value: -Self.summaryRetentionMonths, to: now)
            ?? now.addingTimeInterval(-365 * 86_400)).timeIntervalSince1970

        try db.transaction {
            struct Key: Hashable { var day: Double; var app: String; var kind: String }
            var rolled: [Key: Double] = [:]
            try db.query("SELECT app, kind, start, \"end\" FROM activity WHERE \"end\" < ?1", [.double(rawCutoff)]) {
                let start = Date(timeIntervalSince1970: $0.double(2))
                let day = calendar.startOfDay(for: start).timeIntervalSince1970
                rolled[Key(day: day, app: $0.text(0), kind: $0.text(1)), default: 0] += max(0, $0.double(3) - $0.double(2))
            }
            for (key, seconds) in rolled {
                try db.query(
                    """
                    INSERT INTO daily(day, app, kind, seconds) VALUES(?,?,?,?)
                    ON CONFLICT(day, app, kind) DO UPDATE SET seconds = seconds + excluded.seconds
                    """,
                    [.double(key.day), .text(key.app), .text(key.kind), .double(seconds)])
            }
            try db.query("DELETE FROM activity WHERE \"end\" < ?1", [.double(rawCutoff)])
            try db.query("DELETE FROM noise WHERE \"end\" < ?1", [.double(rawCutoff)])
            try db.query("DELETE FROM battery WHERE time < ?1", [.double(rawCutoff)])
            try db.query("DELETE FROM daily WHERE day < ?1", [.double(summaryCutoff)])
            try db.exec("DELETE FROM app_names WHERE app NOT IN (SELECT app FROM activity) AND app NOT IN (SELECT app FROM daily)")
        }
    }

    public func deleteAll() throws {
        guard let db = try openExisting(readOnly: false) else { return }
        try db.transaction {
            for table in ["activity", "noise", "battery", "daily", "app_names"] { try db.exec("DELETE FROM \(table)") }
        }
        try db.exec("VACUUM")
    }

    public func delete(app: String) throws {
        guard let db = try openExisting(readOnly: false) else { return }
        try db.transaction {
            try db.query("DELETE FROM activity WHERE app = ?1", [.text(app)])
            try db.query("DELETE FROM daily WHERE app = ?1", [.text(app)])
            try db.query("DELETE FROM app_names WHERE app = ?1", [.text(app)])
        }
    }
}
