import Foundation
import SQLite3

/// Why the system store cannot be read right now.
enum NotificationSourceError: Error, Equatable, Sendable {
    /// TCC refused the read: Glancy lacks Full Disk Access.
    case needsFullDiskAccess
    /// The store is not where macOS 15+ keeps it.
    case missing
    /// The tables or columns are not the ones the decoder knows (a newer or older macOS).
    case unsupportedSchema(String)
    /// Any other SQLite failure.
    case sqlite(Int32, String)
}

/// One raw row of `record` joined with `app`.
struct NotificationRow: Sendable {
    let recID: Int64
    let identifier: String?
    let uuid: Data?
    let data: Data
    let delivered: Double?
}

/// A read-only connection to the Notification Center store. Not thread-safe: the watcher confines it
/// to its own serial queue. Never writes: opened with `SQLITE_OPEN_READONLY` and `mode=ro`, no
/// statement other than SELECT and PRAGMA table_info is ever prepared.
final class NotificationDatabase {
    let url: URL
    private var db: OpaquePointer?
    private(set) var hasDelivered = false
    private(set) var hasUUID = false

    static let requiredRecord: Set<String> = ["rec_id", "app_id", "data"]
    static let requiredApp: Set<String> = ["app_id", "identifier"]

    init(url: URL) { self.url = url }
    deinit { close() }

    var isOpen: Bool { db != nil }

    /// Opens the store and checks its schema. WAL-aware: `mode=ro` (not `immutable=1`), so each new
    /// statement sees the latest committed snapshot, including what is still in `db-wal`.
    func open() throws {
        close()
        if let denied = Self.probe(url) { throw denied }
        let path = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2("file:\(path)?mode=ro", &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close_v2(handle)
            throw mapped(rc, message)
        }
        db = handle
        sqlite3_busy_timeout(handle, 100)
        do {
            let record = try columns(of: "record")
            let app = try columns(of: "app")
            let missing = Self.requiredRecord.subtracting(record).map { "record." + $0 }
                + Self.requiredApp.subtracting(app).map { "app." + $0 }
            guard missing.isEmpty else { throw NotificationSourceError.unsupportedSchema("missing " + missing.sorted().joined(separator: ", ")) }
            hasDelivered = record.contains("delivered_date")
            hasUUID = record.contains("uuid")
        } catch {
            close()
            throw error
        }
    }

    func close() {
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    /// The newest `limit` rows, oldest first.
    func latest(limit: Int) throws -> [NotificationRow] {
        try select("ORDER BY r.rec_id DESC LIMIT ?", bind: [Int64(limit)]).reversed()
    }

    /// Rows with `rec_id >= recID` (the caller drops the one it already has), newest `limit`, oldest first.
    /// `>=` and not `>`: `rec_id` has no AUTOINCREMENT, so when the newest row is removed its id is
    /// handed to the next one (the watcher tells them apart by `uuid`).
    func rows(from recID: Int64, limit: Int) throws -> [NotificationRow] {
        try select("WHERE r.rec_id >= ? ORDER BY r.rec_id DESC LIMIT ?", bind: [recID, Int64(limit)]).reversed()
    }

    // MARK: Access check

    /// Tells a TCC refusal from a missing file without SQLite: a plain read-only `open(2)`.
    static func probe(_ url: URL) -> NotificationSourceError? {
        let fd = Darwin.open(url.path, O_RDONLY)
        if fd >= 0 { Darwin.close(fd); return nil }
        let err = errno
        if err == EPERM || err == EACCES { return .needsFullDiskAccess }
        // A protected folder can hide its files: listing it tells a refusal from an absence.
        if let dir = opendir(url.deletingLastPathComponent().path) { closedir(dir); return .missing }
        let dirErr = errno
        return dirErr == EPERM || dirErr == EACCES ? .needsFullDiskAccess : .missing
    }

    // MARK: Internals

    private func mapped(_ rc: Int32, _ message: String) -> NotificationSourceError {
        let primary = rc & 0xFF
        if primary == SQLITE_AUTH || primary == SQLITE_PERM || primary == SQLITE_CANTOPEN {
            return Self.probe(url) ?? .sqlite(rc, message)
        }
        return .sqlite(rc, message)
    }

    private func columns(of table: String) throws -> Set<String> {
        var names: Set<String> = []
        try query("PRAGMA table_info(\(table))", bind: []) { stmt in
            if let c = sqlite3_column_text(stmt, 1) { names.insert(String(cString: c)) }
        }
        return names
    }

    private func select(_ tail: String, bind: [Int64]) throws -> [NotificationRow] {
        let delivered = hasDelivered ? "r.delivered_date" : "NULL"
        let uuid = hasUUID ? "r.uuid" : "NULL"
        let sql = "SELECT r.rec_id, a.identifier, r.data, \(delivered), \(uuid) FROM record r "
            + "LEFT JOIN app a ON a.app_id = r.app_id " + tail
        var rows: [NotificationRow] = []
        try query(sql, bind: bind) { stmt in
            guard let data = Self.blob(stmt, 2) else { return }
            let identifier = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil
                : sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            let deliveredDate = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 3)
            rows.append(NotificationRow(recID: sqlite3_column_int64(stmt, 0), identifier: identifier,
                                        uuid: Self.blob(stmt, 4), data: data, delivered: deliveredDate))
        }
        return rows
    }

    private func query(_ sql: String, bind: [Int64], row: (OpaquePointer) -> Void) throws {
        guard let db else { throw NotificationSourceError.sqlite(SQLITE_MISUSE, "closed") }
        var stmt: OpaquePointer?
        var rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw mapped(rc, String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in bind.enumerated() { sqlite3_bind_int64(stmt, Int32(i + 1), value) }
        while true {
            rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { row(stmt); continue }
            if rc == SQLITE_DONE { return }
            throw mapped(rc, String(cString: sqlite3_errmsg(db)))
        }
    }

    /// A BLOB (or TEXT, as bytes) column, nil when NULL.
    private static func blob(_ stmt: OpaquePointer, _ col: Int32) -> Data? {
        switch sqlite3_column_type(stmt, col) {
        case SQLITE_NULL: return nil
        case SQLITE_TEXT:
            guard let c = sqlite3_column_text(stmt, col) else { return nil }
            return Data(bytes: c, count: Int(sqlite3_column_bytes(stmt, col)))
        default:
            let n = Int(sqlite3_column_bytes(stmt, col))
            guard n > 0, let p = sqlite3_column_blob(stmt, col) else { return Data() }
            return Data(bytes: p, count: n)
        }
    }
}
