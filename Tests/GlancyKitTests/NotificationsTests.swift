import Foundation
import SQLite3
import SwiftUI
import Testing
@testable import GlancyKit

// The system store is never touched: every database here is a temporary SQLite file built with the
// schema the module assumes (see NotificationRecord.swift), in WAL mode like usernoted's.

// MARK: Fixtures

private func plist(app: String? = "com.apple.MobileSMS", date: Double? = 780_000_000,
                   titl: Any? = nil, subt: Any? = nil, body: Any? = nil, extraReq: [String: Any] = [:]) -> Data {
    var req: [String: Any] = extraReq
    if let titl { req["titl"] = titl }
    if let subt { req["subt"] = subt }
    if let body { req["body"] = body }
    var root: [String: Any] = ["req": req, "uuid": Data(UUID().uuidString.utf8)]
    if let app { root["app"] = app }
    if let date { root["date"] = date }
    return try! PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
}

private final class FixtureDB {
    static let standardSchema = """
        CREATE TABLE app (app_id INTEGER PRIMARY KEY, identifier VARCHAR, badge INTEGER NULL);
        CREATE TABLE record (rec_id INTEGER PRIMARY KEY, app_id INTEGER, uuid BLOB, data BLOB, request_date REAL,
            request_last_date REAL, delivered_date REAL, presented Bool, style INTEGER, snooze_fire_date REAL);
        CREATE TABLE dbinfo (key VARCHAR, value VARCHAR);
        """

    let dir: URL
    let url: URL
    private var db: OpaquePointer?

    init(schema: String = FixtureDB.standardSchema) {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("glancy-notif-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("db")
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        exec("PRAGMA journal_mode=WAL;")
        exec(schema)
    }

    deinit {
        sqlite3_close_v2(db)
        try? FileManager.default.removeItem(at: dir)
    }

    func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK { Issue.record("sqlite: \(err.map { String(cString: $0) } ?? "\(rc)")") }
    }

    func app(_ id: Int64, _ identifier: String) { exec("INSERT INTO app (app_id, identifier) VALUES (\(id), '\(identifier)');") }

    @discardableResult
    func record(app: Int64, data: Data, delivered: Double? = 780_000_100, uuid: Data = Data(UUID().uuidString.utf8),
                recID: Int64? = nil) -> Int64 {
        var stmt: OpaquePointer?
        let sql = "INSERT INTO record (rec_id, app_id, uuid, data, delivered_date, presented, style) VALUES (?, ?, ?, ?, ?, 1, 1)"
        #expect(sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        if let recID { sqlite3_bind_int64(stmt, 1, recID) } else { sqlite3_bind_null(stmt, 1) }
        sqlite3_bind_int64(stmt, 2, app)
        uuid.withUnsafeBytes { _ = sqlite3_bind_blob(stmt, 3, $0.baseAddress, Int32(uuid.count), transient) }
        data.withUnsafeBytes { _ = sqlite3_bind_blob(stmt, 4, $0.baseAddress, Int32(data.count), transient) }
        if let delivered { sqlite3_bind_double(stmt, 5, delivered) } else { sqlite3_bind_null(stmt, 5) }
        #expect(sqlite3_step(stmt) == SQLITE_DONE)
        return sqlite3_last_insert_rowid(db)
    }

    func message(_ text: String, app: Int64 = 1) -> Int64 {
        record(app: app, data: plist(titl: "Sara", body: text))
    }

    var walSize: Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path + "-wal"))?[.size] as? Int) ?? 0
    }
}

/// Collects watcher events across threads.
private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [NotificationWatcher.Event] = []
    func add(_ e: NotificationWatcher.Event) { lock.withLock { events.append(e) } }
    var all: [NotificationWatcher.Event] { lock.withLock { events } }

    func wait(until predicate: ([NotificationWatcher.Event]) -> Bool, timeout: TimeInterval = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(all) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate(all)
    }
}

private func newBatches(_ events: [NotificationWatcher.Event]) -> [[SystemNotification]] {
    events.compactMap { if case .new(let l) = $0 { l } else { nil } }
}

private func n(_ id: Int64, _ app: String = "com.apple.MobileSMS", title: String? = "T", body: String? = "B",
               subtitle: String? = nil, age: TimeInterval = 0) -> SystemNotification {
    SystemNotification(recID: id, bundleID: app, title: title, subtitle: subtitle, body: body,
                       date: Date(timeIntervalSinceReferenceDate: 780_000_000 - age))
}

// MARK: Decoding

@Suite("Notifications · plist decoding")
struct NotificationsDecodingTests {
    @Test func fullRecord() {
        let data = plist(titl: "Giulia", subt: "Contratto", body: "In allegato la versione finale.")
        let r = NotificationDecoder.decode(recID: 7, identifier: "com.apple.mail", data: data, deliveredDate: 780_000_500)
        #expect(r == SystemNotification(recID: 7, bundleID: "com.apple.mail", title: "Giulia", subtitle: "Contratto",
                                        body: "In allegato la versione finale.",
                                        date: Date(timeIntervalSinceReferenceDate: 780_000_500)))
    }

    @Test func missingFields() {
        let bodyOnly = NotificationDecoder.decode(recID: 1, identifier: "x", data: plist(body: "only body"), deliveredDate: nil)
        #expect(bodyOnly?.title == nil && bodyOnly?.subtitle == nil && bodyOnly?.body == "only body")
        // No delivered_date: the plist's date (Mac absolute time).
        #expect(bodyOnly?.date == Date(timeIntervalSinceReferenceDate: 780_000_000))
        // Nothing to show: skipped.
        #expect(NotificationDecoder.decode(recID: 2, identifier: "x", data: plist(), deliveredDate: nil) == nil)
        #expect(NotificationDecoder.decode(recID: 3, identifier: "x", data: plist(titl: "  \n "), deliveredDate: nil) == nil)
        // No `req` at all, a non-dictionary root, garbage bytes: nil, never a crash.
        let noReq = try! PropertyListSerialization.data(fromPropertyList: ["app": "a"], format: .binary, options: 0)
        #expect(NotificationDecoder.decode(recID: 4, identifier: nil, data: noReq, deliveredDate: nil) == nil)
        let array = try! PropertyListSerialization.data(fromPropertyList: ["a", "b"], format: .binary, options: 0)
        #expect(NotificationDecoder.decode(recID: 5, identifier: nil, data: array, deliveredDate: nil) == nil)
        #expect(NotificationDecoder.decode(recID: 6, identifier: nil, data: Data([0, 1, 2, 3]), deliveredDate: nil) == nil)
        // Wrong types inside `req` are ignored field by field.
        let odd = NotificationDecoder.decode(recID: 8, identifier: "x", data: plist(titl: 42, body: "ok"), deliveredDate: nil)
        #expect(odd?.title == nil && odd?.body == "ok")
        // No date anywhere: now.
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let undated = NotificationDecoder.decode(recID: 9, identifier: "x", data: plist(date: nil, titl: "t"), deliveredDate: 0, now: now)
        #expect(undated?.date == now)
    }

    @Test func appIdentifier() {
        // The app table wins; the plist's `app` is the fallback; system prefixes are stripped.
        let d = plist(app: "com.from.plist", titl: "t")
        #expect(NotificationDecoder.decode(recID: 1, identifier: "com.apple.ical", data: d, deliveredDate: nil)?.bundleID == "com.apple.ical")
        #expect(NotificationDecoder.decode(recID: 1, identifier: nil, data: d, deliveredDate: nil)?.bundleID == "com.from.plist")
        #expect(NotificationDecoder.decode(recID: 1, identifier: "", data: d, deliveredDate: nil)?.bundleID == "com.from.plist")
        #expect(NotificationDecoder.decode(recID: 1, identifier: "_system_center_:com.apple.battery", data: d,
                                           deliveredDate: nil)?.bundleID == "com.apple.battery")
        #expect(NotificationDecoder.decode(recID: 1, identifier: nil, data: plist(app: nil, titl: "t"), deliveredDate: nil)?.bundleID == "")
    }

    @Test func unicode() {
        let data = plist(titl: "Zoë 👩🏽‍💻 — 東京", subt: "שלום", body: "Arrivo tra 10′\n\npreso il pane 🥖\t ok")
        let r = NotificationDecoder.decode(recID: 1, identifier: "com.apple.MobileSMS", data: data, deliveredDate: nil)
        #expect(r?.title == "Zoë 👩🏽‍💻 — 東京")
        #expect(r?.subtitle == "שלום")
        // Newlines and tabs collapse to single spaces (one-line peeks and rows).
        #expect(r?.body == "Arrivo tra 10′ preso il pane 🥖 ok")
    }

    @Test func attributedStringValue() {
        // Strings are the norm; an attributed string (should a release use one) is read as text.
        #expect(NotificationDecoder.text(NSAttributedString(string: " rich ")) == "rich")
        #expect(NotificationDecoder.text(nil) == nil)
    }
}

// MARK: Database and watcher

@Suite("Notifications · store")
struct NotificationsStoreTests {
    @Test func incrementalQueryOnWAL() throws {
        let fx = FixtureDB()
        fx.app(1, "com.apple.MobileSMS")
        fx.app(2, "com.apple.mail")
        for i in 1...25 { fx.message("m\(i)") }
        #expect(fx.walSize > 0)                              // the rows live in the WAL, not in db yet

        let db = NotificationDatabase(url: fx.url)
        try db.open()
        #expect(db.hasDelivered && db.hasUUID)
        let latest = try db.latest(limit: 20)
        #expect(latest.map(\.recID) == Array(6...25))       // newest 20, oldest first
        #expect(latest.last?.identifier == "com.apple.MobileSMS")

        // Written after the reader opened, still in the WAL: seen by the next statement.
        fx.record(app: 2, data: plist(app: nil, titl: "Giulia", body: "Contratto"))
        fx.message("m27")
        let fresh = try db.rows(from: 25, limit: 50)
        #expect(fresh.map(\.recID) == [25, 26, 27])         // >= cursor; the watcher drops 25
        let cursor = NotificationWatcher.Cursor(recID: 25, uuid: latest.last?.uuid)
        let unseen = cursor.unseen(fresh)
        #expect(unseen.map(\.recID) == [26, 27])
        let decoded = NotificationWatcher.decode(unseen)
        #expect(decoded.map(\.bundleID) == ["com.apple.mail", "com.apple.MobileSMS"])
        #expect(decoded.first?.title == "Giulia")
        // A capped catch-up keeps the newest rows.
        #expect(try db.rows(from: 0, limit: 3).map(\.recID) == [25, 26, 27])
        db.close()
    }

    @Test func recIDReuseIsSeen() throws {
        let fx = FixtureDB()
        fx.app(1, "com.apple.MobileSMS")
        fx.message("a"); let last = fx.message("b")
        let db = NotificationDatabase(url: fx.url)
        try db.open()
        let first = try db.latest(limit: 20)
        let cursor = NotificationWatcher.Cursor(recID: last, uuid: first.last?.uuid)
        #expect(cursor.unseen(try db.rows(from: last, limit: 50)).isEmpty)
        // The newest row is dismissed, and the next one gets its id back (no AUTOINCREMENT).
        fx.exec("DELETE FROM record WHERE rec_id = \(last);")
        let reused = fx.message("c")
        #expect(reused == last)
        #expect(cursor.unseen(try db.rows(from: last, limit: 50)).map(\.recID) == [last])
    }

    @Test func schemaGuard() throws {
        // `record` without `data`.
        let noData = FixtureDB(schema: """
            CREATE TABLE app (app_id INTEGER PRIMARY KEY, identifier VARCHAR);
            CREATE TABLE record (rec_id INTEGER PRIMARY KEY, app_id INTEGER, payload BLOB);
            """)
        #expect(throws: NotificationSourceError.unsupportedSchema("missing record.data")) {
            try NotificationDatabase(url: noData.url).open()
        }
        // No `app` table at all.
        let noApp = FixtureDB(schema: "CREATE TABLE record (rec_id INTEGER PRIMARY KEY, app_id INTEGER, data BLOB);")
        #expect(throws: NotificationSourceError.unsupportedSchema("missing app.app_id, app.identifier")) {
            try NotificationDatabase(url: noApp.url).open()
        }
        // Optional columns absent: still readable, dates from the plist.
        let lean = FixtureDB(schema: """
            CREATE TABLE app (app_id INTEGER PRIMARY KEY, identifier VARCHAR);
            CREATE TABLE record (rec_id INTEGER PRIMARY KEY, app_id INTEGER, data BLOB);
            """)
        lean.app(1, "com.apple.mail")
        lean.exec("INSERT INTO record (app_id, data) VALUES (1, x'\(plist(titl: "t").map { String(format: "%02x", $0) }.joined())');")
        let db = NotificationDatabase(url: lean.url)
        try db.open()
        #expect(!db.hasDelivered && !db.hasUUID)
        let rows = try db.latest(limit: 5)
        #expect(NotificationWatcher.decode(rows).first?.date == Date(timeIntervalSinceReferenceDate: 780_000_000))
    }

    @Test func notADatabaseOrMissing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glancy-notif-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let junk = dir.appendingPathComponent("db")
        try Data(repeating: 0x41, count: 4096).write(to: junk)
        do {
            try NotificationDatabase(url: junk).open()
            Issue.record("opened junk")
        } catch let e as NotificationSourceError {
            if case .sqlite = e {} else { Issue.record("unexpected \(e)") }
        }
        #expect(throws: NotificationSourceError.missing) {
            try NotificationDatabase(url: dir.appendingPathComponent("nope/db")).open()
        }
    }

    @Test func permissionDeniedMeansFullDiskAccess() throws {
        let fx = FixtureDB()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fx.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fx.url.path) }
        #expect(NotificationDatabase.probe(fx.url) == .needsFullDiskAccess)
        #expect(throws: NotificationSourceError.needsFullDiskAccess) { try NotificationDatabase(url: fx.url).open() }
        // A folder that cannot be listed hides its files the same way.
        let locked = fx.dir.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        #expect(NotificationDatabase.probe(locked.appendingPathComponent("db")) == .needsFullDiskAccess)
    }

    @Test func watcherFollowsWALAndCoalescesBursts() async throws {
        let fx = FixtureDB()
        fx.app(1, "com.apple.MobileSMS")
        fx.message("before")
        let box = EventBox()
        let watcher = NotificationWatcher(url: fx.url, coalesce: .milliseconds(300))
        watcher.start { box.add($0) }
        defer { watcher.stop() }
        #expect(await box.wait { $0.contains { if case .initial(let l) = $0 { l.count == 1 } else { false } } })

        // A burst of three writes inside the coalescing window → one query, one batch.
        for i in 1...3 { fx.message("burst \(i)") }
        #expect(await box.wait { newBatches($0).flatMap { $0 }.count == 3 })
        try await Task.sleep(for: .milliseconds(400))
        #expect(newBatches(box.all).count == 1)
        #expect(newBatches(box.all).first?.map(\.body) == ["burst 1", "burst 2", "burst 3"])

        // Later writes: only what is new.
        fx.message("later")
        #expect(await box.wait { newBatches($0).count == 2 })
        #expect(newBatches(box.all).last?.map(\.body) == ["later"])
    }

    @Test func watcherReopensAfterReplace() async throws {
        let fx = FixtureDB()
        fx.app(1, "com.apple.MobileSMS")
        let uuid = Data("same-row".utf8)
        fx.record(app: 1, data: plist(titl: "Sara", body: "one"), uuid: uuid)
        let box = EventBox()
        let watcher = NotificationWatcher(url: fx.url, coalesce: .milliseconds(50))
        watcher.start { box.add($0) }
        defer { watcher.stop() }
        #expect(await box.wait { !$0.isEmpty })
        // The store is swapped for a new file (rename over it), with one more row.
        let other = FixtureDB()
        other.app(1, "com.apple.MobileSMS")
        other.record(app: 1, data: plist(titl: "Sara", body: "one"), uuid: uuid)
        other.message("two")
        other.exec("PRAGMA wal_checkpoint(TRUNCATE);")
        try FileManager.default.removeItem(at: URL(fileURLWithPath: fx.url.path + "-wal"))
        _ = rename(other.url.path, fx.url.path)
        // Without its WAL a read-only connection cannot open the swapped store: reported, not fatal.
        #expect(await box.wait { $0.contains { if case .unavailable = $0 { true } else { false } } })
        // The writer opens it again (its WAL appears in the folder): reconnected, caught up, no repeat.
        var writer: OpaquePointer?
        #expect(sqlite3_open(fx.url.path, &writer) == SQLITE_OK)
        defer { sqlite3_close_v2(writer) }
        sqlite3_exec(writer, "PRAGMA journal_mode=WAL; INSERT INTO dbinfo VALUES ('k', 'v');", nil, nil, nil)
        let ok = await box.wait { newBatches($0).flatMap { $0 }.map(\.body) == ["two"] }
        #expect(ok, "\(box.all)")
    }

    @Test func watcherReportsBadSchemaAndRetries() async throws {
        let fx = FixtureDB(schema: "CREATE TABLE record (rec_id INTEGER PRIMARY KEY);")
        let box = EventBox()
        let watcher = NotificationWatcher(url: fx.url, coalesce: .milliseconds(50))
        watcher.start { box.add($0) }
        defer { watcher.stop() }
        #expect(await box.wait {
            $0.contains { if case .unavailable(.unsupportedSchema) = $0 { true } else { false } }
        })
        // Fixed (e.g. an OS update reverted): a retry connects.
        fx.exec("DROP TABLE record;")
        fx.exec(FixtureDB.standardSchema)
        watcher.retry()
        #expect(await box.wait { $0.contains { if case .initial = $0 { true } else { false } } })
    }
}

// MARK: Privacy, grouping, coalescing

@Suite("Notifications · privacy and peeks")
@MainActor
struct NotificationsPrivacyTests {
    private func settings() -> NotificationsSettings {
        let suite = "ai.glancy.test.notifications.\(UUID().uuidString)"
        return NotificationsSettings(defaults: UserDefaults(suiteName: suite)!)
    }

    @Test func glancyMutedByDefault() {
        let s = settings()
        #expect(s.muted.keys.contains("ai.glancy.app"))
        #expect(!s.hidePreviews)
        let model = NotificationsModel(settings: s)
        let shown = model.ingest([n(1, "ai.glancy.app"), n(2)])
        #expect(shown.map(\.recID) == [2])
        #expect(model.items.map(\.recID) == [2])
    }

    @Test func muteFiltering() {
        let model = NotificationsModel(settings: settings())
        model.replace(with: [n(1, "com.apple.mail"), n(2, "com.apple.MobileSMS"), n(3, "com.apple.mail")])
        model.mute("com.apple.mail")
        #expect(model.items.map(\.recID) == [2])
        // Case-insensitive (the store sometimes lower-cases bundle IDs).
        #expect(model.ingest([n(4, "COM.APPLE.MAIL"), n(5)]).map(\.recID) == [5])
        model.unmute("com.apple.mail")
        #expect(model.ingest([n(6, "com.apple.mail")]).map(\.recID) == [6])
        #expect(NotificationFilter.isMuted("com.Apple.Mail", ["com.apple.mail"]))
    }

    @Test func hidePreviews() {
        let item = n(1, title: "Sara", body: "Arrivo tra 10 minuti", subtitle: "Famiglia")
        #expect(NotificationFilter.lines(item, appName: "Messages", hidePreviews: false) == ("Sara", "Famiglia — Arrivo tra 10 minuti"))
        #expect(NotificationFilter.lines(item, appName: "Messages", hidePreviews: true) == ("Sara", nil))
        let untitled = n(2, title: nil, body: "secret body")
        #expect(NotificationFilter.lines(untitled, appName: "Messages", hidePreviews: true) == ("Messages", nil))
        #expect(NotificationFilter.lines(untitled, appName: "Messages", hidePreviews: false) == ("secret body", nil))
        let model = NotificationsModel(settings: settings())
        model.settings.hidePreviews = true
        #expect(model.lines(item).detail == nil)
    }

    @Test func keepsLast20InMemory() {
        let model = NotificationsModel(settings: settings())
        model.replace(with: (1...30).map { n(Int64($0)) })
        #expect(model.items.count == 20 && model.items.first?.recID == 30)
        model.ingest((31...35).map { n(Int64($0)) })
        #expect(model.items.count == 20)
        #expect(model.items.map(\.recID) == Array((16...35).reversed()))
        // A reused rec_id replaces the old entry.
        model.ingest([n(35, "com.apple.mail")])
        #expect(model.items.filter { $0.recID == 35 }.map(\.bundleID) == ["com.apple.mail"])
    }

    @Test func groupedByApp() {
        let items = [n(1, "a", age: 300), n(2, "b", age: 200), n(3, "a", age: 100), n(4, "c", age: 400)]
        let groups = NotificationFilter.groups(items)
        #expect(groups.map(\.bundleID) == ["a", "b", "c"])
        #expect(groups[0].items.map(\.recID) == [3, 1])
    }

    @Test func burstCoalescer() {
        var c = PeekCoalescer(window: 3)
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        #expect(c.offer(at: t0) == .show)
        #expect(c.offer(at: t0.addingTimeInterval(0.5)) == .update)
        #expect(c.offer(at: t0.addingTimeInterval(2.9)) == .update)
        #expect(c.offer(at: t0.addingTimeInterval(3.1)) == .show)
        c.reset()
        #expect(c.offer(at: t0.addingTimeInterval(3.2)) == .show)
    }

    @Test func moduleCoalescesPeeksAndRespectsPanel() {
        let module = NotificationsModule(databaseURL: URL(fileURLWithPath: "/nonexistent/glancy/db"), settings: settings())
        let hub = ActivityHub()
        module.start(hub: hub)
        defer { module.stop() }
        module.handle(.initial([n(1)]))
        #expect(hub.peek == nil)                               // what was there at launch is not announced
        module.handle(.new([n(2)]))
        let first = hub.peek?.id
        #expect(first != nil)
        module.handle(.new([n(3), n(4)]))                       // same burst: same peek, updated in place
        #expect(hub.peek?.id == first)
        #expect(module.model.items.map(\.recID) == [4, 3, 2, 1])
        // Muted: neither listed nor announced.
        module.handle(.new([n(5, "ai.glancy.app")]))
        #expect(module.model.items.count == 4)
        // Panel open: listed, never peeked.
        let quiet = NotificationsModule(databaseURL: URL(fileURLWithPath: "/nonexistent/glancy/db"), settings: settings())
        let hub2 = ActivityHub()
        quiet.start(hub: hub2)
        defer { quiet.stop() }
        quiet.visibilityChanged(.expanded(.notifications))
        quiet.handle(.new([n(9)]))
        #expect(hub2.peek == nil && quiet.model.items.count == 1)
        quiet.visibilityChanged(.hidden)
        quiet.handle(.new([n(10)]))
        #expect(hub2.peek == nil)
    }

    @Test func unavailableStates() {
        #expect(NotificationsModule.state(for: .needsFullDiskAccess) == .needsFullDiskAccess)
        if case .unavailable = NotificationsModule.state(for: .unsupportedSchema("x")) {} else { Issue.record("schema") }
        if case .unavailable = NotificationsModule.state(for: .missing) {} else { Issue.record("missing") }
    }
}

// MARK: Opt-in default

@Suite("Notifications · opt-in")
@MainActor
struct NotificationsOptInTests {
    @Test func offByDefaultAndForExistingUsers() {
        let suite = "ai.glancy.test.optin.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!AppSettings(defaults: defaults).isEnabled(.notifications))
        // An existing user who had turned something else off: notifications still off.
        defaults.set(["hud"], forKey: "disabledModules")
        let existing = AppSettings(defaults: defaults)
        #expect(!existing.isEnabled(.notifications) && !existing.isEnabled(.hud) && existing.isEnabled(.agents))
        // Turned on: stays on across launches; turned off again: off.
        existing.setEnabled(.notifications, true)
        #expect(AppSettings(defaults: defaults).isEnabled(.notifications))
        AppSettings(defaults: defaults).setEnabled(.notifications, false)
        #expect(!AppSettings(defaults: defaults).isEnabled(.notifications))
        #expect(!AppSettings(defaults: defaults).isEnabled(.hud))
    }
}
