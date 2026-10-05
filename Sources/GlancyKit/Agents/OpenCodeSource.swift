import CoreServices
import Foundation
import SQLite3

// OpenCode sessions, two inputs:
//
// 1. Its database (read-only, nothing to install): ~/.local/share/opencode/opencode.db (SQLite,
//    WAL). Tables `session` (id, parent_id, directory, title, time_updated, time_archived),
//    `message` (data: {"role", "time":{"created","completed"}, "finish", "error":{"name"}}) and
//    `part` (data: {"type":"text"|"tool"|…, "tool", "text"}). FSEvents on its folder say when it
//    was written; a coalesced query then reads the latest message of the recent sessions. Gives
//    working / done / failed / interrupted, the title, the last prompt, tool and reply.
// 2. The optional Glancy plugin (hooks/glancy-opencode.js, installed only from Settings → Agents):
//    OpenCode's own events written as Glancy event lines. Adds what the database cannot know: a
//    permission request waiting for you. Sessions the plugin reports are not also read from the
//    database (no double rows).

/// One session's latest state as the database has it.
struct OpenCodeRow: Sendable, Equatable {
    var id: String
    var directory: String
    var title: String
    var created: Date
    var updated: Date
    /// The latest message.
    var role: String?
    var messageCreated: Date?
    var completed: Date?
    var finish: String?
    var errorName: String?
    /// The latest user message's time and first text.
    var userCreated: Date?
    var userText: String?
    /// The latest tool part (id, tool) and the latest reply text.
    var toolPartID: String?
    var tool: String?
    var replyText: String?
}

enum OpenCodeSnapshot {
    /// What was last reported per session: the state's key and the last tool part.
    struct Seen: Sendable, Equatable {
        var stateKey: String
        var toolPartID: String?
        var title: String
    }

    /// The events that move each session from what was seen to what the rows say now.
    static func events(_ rows: [OpenCodeRow], seen: inout [String: Seen]) -> [AgentEvent] {
        var out: [AgentEvent] = []
        for r in rows {
            let previous = seen[r.id]
            var next = Seen(stateKey: "", toolPartID: r.toolPartID, title: r.title)
            func ev(_ k: AgentEvent.Kind, _ t: Date, tool: String? = nil, prompt: String? = nil, message: String? = nil,
                    title: String? = nil) -> AgentEvent {
                AgentEvent(ts: t, kind: k, sessionID: r.id, cwd: r.directory, toolName: tool, prompt: prompt,
                           agent: .opencode, message: message, title: title)
            }
            let cleanTitle = AgentEventParser.oneLine(r.title, max: 120)
            if previous == nil {
                out.append(ev(.sessionStart, r.created, title: cleanTitle))
            } else if previous?.title != r.title, let t = cleanTitle {
                out.append(ev(.sessionStart, r.updated, title: t))
            }
            let prompt = r.userText.flatMap(AgentEventParser.userPrompt).flatMap { AgentEventParser.oneLine($0, max: 200) }
            let reply = r.replyText.flatMap { AgentEventParser.oneLine($0, max: 200) }
            // A new tool part while the turn runs: the last tool (and proof of activity).
            var tool: AgentEvent?
            if let part = r.toolPartID, part != previous?.toolPartID, let name = r.tool {
                tool = ev(.postToolUse, max(r.messageCreated ?? r.updated, r.userCreated ?? .distantPast), tool: name)
            }
            let turnStart = r.userCreated ?? r.messageCreated ?? r.updated
            var working: Bool {
                switch (r.role, r.completed) {
                case ("user", _), ("assistant", nil): true
                case ("assistant", _?): r.errorName == nil && r.finish == "tool-calls"
                default: false
                }
            }
            if working {
                next.stateKey = "working@\(turnStart.timeIntervalSince1970)"
                if previous?.stateKey != next.stateKey { out.append(ev(.userPromptSubmit, turnStart, prompt: prompt)) }
                if let tool { out.append(tool) }
            } else if r.role == "assistant", let done = r.completed {
                if let e = r.errorName {
                    let aborted = e == "MessageAbortedError"
                    next.stateKey = "\(aborted ? "interrupted" : "failed")@\(done.timeIntervalSince1970)"
                } else {
                    next.stateKey = "done@\(done.timeIntervalSince1970)"
                }
                if previous?.stateKey != next.stateKey {
                    // Seen for the first time already finished: its prompt still belongs on the row.
                    if previous == nil { out.append(ev(.userPromptSubmit, turnStart, prompt: prompt)) }
                    if let tool { out.append(tool) }
                    if let e = r.errorName {
                        out.append(e == "MessageAbortedError" ? ev(.interrupted, done) : ev(.stopFailure, done, message: e))
                    } else {
                        out.append(ev(.stop, done, message: reply))
                    }
                }
            } else {
                next.stateKey = previous?.stateKey ?? "idle"
            }
            seen[r.id] = next
        }
        return out
    }
}

/// Reads the recent sessions from OpenCode's database, read-only. Opened per query, closed after.
enum OpenCodeDatabase {
    static func recentSessions(db path: String, since: Date, limit: Int) -> [OpenCodeRow]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        let ms = Int64(since.timeIntervalSince1970 * 1000)
        let sessions = """
            SELECT id, directory, title, time_created, time_updated FROM session
            WHERE parent_id IS NULL AND time_archived IS NULL AND time_updated >= ?1
            ORDER BY time_updated DESC LIMIT ?2
            """
        var rows: [OpenCodeRow] = []
        query(db, sessions, bind: [.int(ms), .int(Int64(limit))]) { st in
            rows.append(OpenCodeRow(id: text(st, 0) ?? "", directory: text(st, 1) ?? "", title: text(st, 2) ?? "",
                                    created: date(st, 3) ?? .distantPast, updated: date(st, 4) ?? .distantPast))
        }
        for i in rows.indices {
            let id = rows[i].id
            query(db, """
                SELECT json_extract(data,'$.role'), time_created, json_extract(data,'$.time.completed'),
                       json_extract(data,'$.finish'), json_extract(data,'$.error.name'), id
                FROM message WHERE session_id = ?1 ORDER BY time_created DESC, id DESC LIMIT 1
                """, bind: [.text(id)]) { st in
                rows[i].role = text(st, 0)
                rows[i].messageCreated = date(st, 1)
                rows[i].completed = date(st, 2)
                rows[i].finish = text(st, 3)
                rows[i].errorName = text(st, 4)
            }
            query(db, """
                SELECT m.time_created,
                       (SELECT substr(json_extract(p.data,'$.text'), 1, 400) FROM part p
                        WHERE p.message_id = m.id AND json_extract(p.data,'$.type') = 'text' ORDER BY p.id LIMIT 1)
                FROM message m WHERE m.session_id = ?1 AND json_extract(m.data,'$.role') = 'user'
                ORDER BY m.time_created DESC LIMIT 1
                """, bind: [.text(id)]) { st in
                rows[i].userCreated = date(st, 0)
                rows[i].userText = text(st, 1)
            }
            query(db, """
                SELECT id, json_extract(data,'$.tool') FROM part
                WHERE session_id = ?1 AND json_extract(data,'$.type') = 'tool' ORDER BY time_created DESC, id DESC LIMIT 1
                """, bind: [.text(id)]) { st in
                rows[i].toolPartID = text(st, 0)
                rows[i].tool = text(st, 1)
            }
            if rows[i].role == "assistant", rows[i].completed != nil {
                query(db, """
                    SELECT substr(json_extract(data,'$.text'), 1, 400) FROM part
                    WHERE session_id = ?1 AND json_extract(data,'$.type') = 'text' ORDER BY time_created DESC, id DESC LIMIT 1
                    """, bind: [.text(id)]) { st in rows[i].replyText = text(st, 0) }
            }
        }
        return rows
    }

    private enum Bind { case int(Int64), text(String) }

    private static func query(_ db: OpaquePointer, _ sql: String, bind: [Bind], _ row: (OpaquePointer) -> Void) {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { return }
        defer { sqlite3_finalize(st) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, b) in bind.enumerated() {
            switch b {
            case .int(let v): sqlite3_bind_int64(st, Int32(i + 1), v)
            case .text(let v): sqlite3_bind_text(st, Int32(i + 1), v, -1, transient)
            }
        }
        while sqlite3_step(st) == SQLITE_ROW { row(st) }
    }

    private static func text(_ st: OpaquePointer, _ i: Int32) -> String? {
        guard sqlite3_column_type(st, i) != SQLITE_NULL, let c = sqlite3_column_text(st, i) else { return nil }
        return String(cString: c)
    }

    /// Epoch milliseconds → Date.
    private static func date(_ st: OpaquePointer, _ i: Int32) -> Date? {
        guard sqlite3_column_type(st, i) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: Double(sqlite3_column_int64(st, i)) / 1000)
    }
}

/// Follows OpenCode's database folder with FSEvents and re-reads the recent sessions after it was
/// written (at most once a second while OpenCode streams).
final class OpenCodeDatabaseReader: @unchecked Sendable {
    typealias Deliver = @Sendable ([AgentEvent], _ quiet: Bool) -> Void

    let folder: URL
    let maxSessions: Int
    private let queue = DispatchQueue(label: "glancy.agents.opencode", qos: .utility)
    private var dbPath: String { folder.appendingPathComponent("opencode.db").path }

    // Touched only on `queue`.
    private var deliver: Deliver?
    private var watcher: FSEventsWatcher?
    private var appearance: FolderAppearanceWatcher?
    private var seen: [String: OpenCodeSnapshot.Seen] = [:]
    private var running = false
    var now: @Sendable () -> Date = { .now }

    init(folder: URL, maxSessions: Int = 12) {
        self.folder = folder
        self.maxSessions = maxSessions
    }

    func start(_ deliver: @escaping Deliver) {
        queue.async { [self] in
            guard !running else { return }
            running = true
            self.deliver = deliver
            let begin: @Sendable () -> Void = { [weak self] in
                guard let self, self.running else { return }
                self.appearance = nil
                self.watcher = FSEventsWatcher(root: self.folder, latency: 1.0, queue: self.queue) { [weak self] changes in
                    // Only the database and its WAL: our own read touches the -shm index, which must
                    // not trigger another read.
                    guard let self, changes.contains(where: { Self.isDataFile($0.path) }) else { return }
                    self.refresh(quiet: false)
                }
                self.refresh(quiet: true)
            }
            if FileManager.default.fileExists(atPath: folder.path) {
                begin()
            } else {
                deliver([], true)
                let a = FolderAppearanceWatcher(folder, queue: queue, ready: begin)
                appearance = a
                a.start()
            }
        }
    }

    func stop() {
        queue.sync { [self] in
            running = false
            deliver = nil
            watcher?.cancel(); watcher = nil
            appearance?.cancel(); appearance = nil
            seen = [:]
        }
    }

    func sync(_ body: () -> Void = {}) { queue.sync(execute: body) }

    static func isDataFile(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name == "opencode.db" || name == "opencode.db-wal"
    }

    private func refresh(quiet: Bool) {
        guard running else { return }
        guard FileManager.default.fileExists(atPath: dbPath) else { deliver?([], quiet); return }
        let rows = autoreleasepool {
            OpenCodeDatabase.recentSessions(db: dbPath, since: now().addingTimeInterval(-AgentSessionStore.forgetAfter),
                                            limit: maxSessions)
        } ?? []
        // Forget what is no longer listed (bounded by `maxSessions`).
        let ids = Set(rows.map(\.id))
        seen = seen.filter { ids.contains($0.key) }
        let events = OpenCodeSnapshot.events(rows.reversed(), seen: &seen)
        if quiet || !events.isEmpty { deliver?(events, quiet) }
    }
}

/// The OpenCode source: the database, plus the plugin's event log when it is installed.
@MainActor
final class OpenCodeSource: AgentSource {
    nonisolated static let defaultDataFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/opencode", isDirectory: true)
    nonisolated static let defaultPluginLog: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Glancy/agents/opencode-events.jsonl")
    }()

    let kind = AgentKind.opencode
    let database: OpenCodeDatabaseReader
    let pluginLog: JSONLTailReader
    let installer: OpenCodePluginInstaller
    /// Sessions the plugin has reported: the database's events for them are dropped.
    private var pluginSessions = Set<String>()

    init(dataFolder: URL = OpenCodeSource.defaultDataFolder, pluginLog: URL = OpenCodeSource.defaultPluginLog,
         installer: OpenCodePluginInstaller = OpenCodePluginInstaller()) {
        database = OpenCodeDatabaseReader(folder: dataFolder)
        self.pluginLog = JSONLTailReader(url: pluginLog, rebuildBytes: 512 << 10)
        self.installer = installer
    }

    func start(_ sink: @escaping @MainActor (AgentKind, AgentSourceUpdate) -> Void) {
        pluginSessions = []
        pluginLog.start { [weak self] events, rebuild in
            let mine = events.filter { $0.agent == .opencode }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.pluginSessions.count > 256 { self.pluginSessions = [] }
                    for e in mine { self.pluginSessions.insert(e.sessionID) }
                    sink(.opencode, .events(mine, quiet: rebuild))
                }
            }
        }
        database.start { [weak self] events, quiet in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    sink(.opencode, .events(events.filter { !self.pluginSessions.contains($0.sessionID) }, quiet: quiet))
                }
            }
        }
    }

    func stop() {
        pluginLog.stop()
        database.stop()
        pluginSessions = []
    }

    func status() -> AgentSourceStatus {
        let hasDB = FileManager.default.fileExists(atPath: database.folder.appendingPathComponent("opencode.db").path)
        switch (hasDB, installer.isInstalled) {
        case (_, true): return AgentSourceStatus(.ok, AgentsText.t("Plugin installed: also shows when it needs you"))
        case (true, false): return AgentSourceStatus(.ok, AgentsText.t("Reading its database · install the plugin to see when it needs you"))
        case (false, false): return AgentSourceStatus(.missing, AgentsText.t("Not set up: OpenCode has not run on this Mac yet"))
        }
    }
}
