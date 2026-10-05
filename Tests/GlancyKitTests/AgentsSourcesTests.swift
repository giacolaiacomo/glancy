import Foundation
import SQLite3
import Testing
@testable import GlancyKit

// Source model: hook lines with and without host fields, host detection, OpenCode (database and
// plugin), the merged attention board, jump targets, the command bar, the caps.

private func tempDir(_ name: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("glancy-\(name)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

// MARK: Hook lines

@Test func oldHookLinesStillParseAsClaudeWithNoHost() {
    let old = #"{"ts":1791192009742,"event":"PostToolUse","session_id":"s1","cwd":"/Users/dev/Projects/web-app","tool_name":"Read","prompt":""}"#
    let e = AgentEventParser.parse(old)!
    #expect(e.agent == .claudeCode)
    #expect(e.host == nil)
    #expect(e.message == nil && e.title == nil)
}

@Test func newHookLinesCarryTheHost() {
    let vscode = #"{"ts":1,"event":"Stop","session_id":"s","cwd":"/p","prompt":"","host_bundle":"com.microsoft.VSCode","term_program":"vscode","entrypoint":"claude-vscode"}"#
    #expect(AgentEventParser.parse(vscode)?.host == AgentHost(kind: .vscode, bundleID: "com.microsoft.VSCode"))
    let terminal = #"{"ts":1,"event":"Stop","session_id":"s","cwd":"/p","host_bundle":"com.apple.Terminal","term_program":"Apple_Terminal","entrypoint":"cli"}"#
    #expect(AgentEventParser.parse(terminal)?.host == AgentHost(kind: .terminal, bundleID: "com.apple.Terminal"))
    // The OpenCode plugin's lines: same format, another agent, a reply and a title.
    let oc = #"{"ts":1,"event":"Stop","session_id":"ses_1","cwd":"/p","agent":"opencode","message":"Done.\n All  good","title":"Fix login"}"#
    let e = AgentEventParser.parse(oc)!
    #expect(e.agent == .opencode && e.message == "Done. All good" && e.title == "Fix login")
    // An agent this build does not know: skipped, never shown as Claude Code.
    #expect(AgentEventParser.parse(#"{"ts":1,"event":"Stop","session_id":"s","cwd":"/p","agent":"future-agent"}"#) == nil)
}

@Test func hostDetectionFromTheHookEnvironment() {
    // VS Code: the extension (entry point), its integrated terminal (TERM_PROGRAM), or the bundle id.
    #expect(AgentHost.detect(bundleID: nil, termProgram: nil, entrypoint: "claude-vscode")?.kind == .vscode)
    #expect(AgentHost.detect(bundleID: nil, termProgram: "vscode", entrypoint: "cli")?.kind == .vscode)
    #expect(AgentHost.detect(bundleID: "com.microsoft.VSCode", termProgram: nil, entrypoint: nil)?.kind == .vscode)
    // Cursor's terminal also says TERM_PROGRAM=vscode: the bundle id wins.
    #expect(AgentHost.detect(bundleID: "com.todesktop.230313mzl4w4u92", termProgram: "vscode", entrypoint: "cli")?.kind == .cursor)
    #expect(AgentHost.detect(bundleID: nil, termProgram: "iTerm.app", entrypoint: "cli") == AgentHost(kind: .terminal, bundleID: "com.googlecode.iterm2"))
    #expect(AgentHost.detect(bundleID: nil, termProgram: "ghostty", entrypoint: nil)?.bundleID == "com.mitchellh.ghostty")
    #expect(AgentHost.detect(bundleID: "com.apple.dt.Xcode", termProgram: nil, entrypoint: nil)?.kind == .xcode)
    #expect(AgentHost.detect(bundleID: "com.jetbrains.intellij", termProgram: nil, entrypoint: nil)?.kind == .jetbrains)
    #expect(AgentHost.detect(bundleID: "com.anthropic.claudefordesktop", termProgram: nil, entrypoint: nil)?.kind == .claudeApp)
    #expect(AgentHost.detect(bundleID: "org.example.NewTerm", termProgram: nil, entrypoint: nil) == AgentHost(kind: .terminal, bundleID: "org.example.NewTerm"))
    #expect(AgentHost.detect(bundleID: nil, termProgram: nil, entrypoint: "cli")?.kind == .terminal)
    #expect(AgentHost.detect(bundleID: nil, termProgram: nil, entrypoint: nil) == nil)
    #expect(AgentHost.detect(bundleID: "", termProgram: "", entrypoint: nil) == nil)
}

/// The shipped hook, run with a temporary HOME and a VS Code environment: its line parses with the host.
@Test func shippedHookRecordsTheHost() throws {
    let jq = ["/usr/bin/jq", "/opt/homebrew/bin/jq", "/usr/local/bin/jq"].first { FileManager.default.isExecutableFile(atPath: $0) }
    guard jq != nil else { return }
    let hook = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("hooks/cc-dashboard-event.sh")
    let home = tempDir("hookhome"); defer { try? FileManager.default.removeItem(at: home) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [hook.path]
    p.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
                     "__CFBundleIdentifier": "com.microsoft.VSCode", "TERM_PROGRAM": "vscode", "CLAUDE_CODE_ENTRYPOINT": "claude-vscode"]
    let input = Pipe()
    p.standardInput = input
    try p.run()
    input.fileHandleForWriting.write(Data(#"{"hook_event_name":"PermissionRequest","session_id":"s1","cwd":"/Users/dev/Projects/api","tool_name":"Bash"}"#.utf8))
    try input.fileHandleForWriting.close()
    p.waitUntilExit()
    #expect(p.terminationStatus == 0)
    let log = home.appendingPathComponent(".claude/hooks/data/cc-dashboard/events.jsonl")
    let line = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").last.map(String.init) ?? ""
    let e = try #require(AgentEventParser.parse(line))
    #expect(e.kind == .permissionRequest && e.toolName == "Bash")
    #expect(e.host == AgentHost(kind: .vscode, bundleID: "com.microsoft.VSCode"))
}

// MARK: Store: source fields and caps

@Test func storeKeepsHostTitleAndReply() {
    var s = AgentSessionStore()
    s.apply(AgentEvent(ts: t0, kind: .userPromptSubmit, sessionID: "a", cwd: "/p/api", prompt: "first ask"))
    s.apply(AgentEvent(ts: t0.addingTimeInterval(1), kind: .userPromptSubmit, sessionID: "a", cwd: "/p/api", prompt: "second ask",
                       host: AgentHost(kind: .vscode)))
    s.apply(AgentEvent(ts: t0.addingTimeInterval(2), kind: .postToolUse, sessionID: "a", cwd: "/p/api", toolName: "Bash"))
    s.apply(AgentEvent(ts: t0.addingTimeInterval(3), kind: .stop, sessionID: "a", cwd: "/p/api", message: "Merged."))
    let a = s.sessions["a"]!
    #expect(a.title == "first ask")
    #expect(a.lastPrompt == "second ask")
    #expect(a.host?.kind == .vscode)              // an event without a host keeps the known one
    #expect(a.lastMessage == "Merged.")
}

@Test func storeIsCappedAndDropsTheLeastUsefulFirst() {
    var s = AgentSessionStore()
    s.maxSessions = 3
    s.apply(ev(.permissionRequest, "waiting", 0, cwd: "/p/a", tool: "Bash"))
    s.apply(ev(.userPromptSubmit, "working", 1, cwd: "/p/b"))
    s.apply(ev(.stop, "done", 2, cwd: "/p/c"))
    s.apply(ev(.userPromptSubmit, "new", 3, cwd: "/p/d"))
    #expect(Set(s.sessions.keys) == ["waiting", "working", "new"])
    for i in 0..<50 { s.apply(ev(.stop, "x\(i)", 10 + Double(i), cwd: "/p/x\(i)")) }
    #expect(s.sessions.count == 3)
    #expect(s.sessions["waiting"] != nil)          // what needs you is the last to go
}

@Test func mergedBoardOrdersByAttentionAcrossSources() {
    var stores = AgentStores()
    func e(_ k: AgentEvent.Kind, _ sid: String, _ sec: Double, _ agent: AgentKind) -> AgentEvent {
        AgentEvent(ts: t0.addingTimeInterval(sec), kind: k, sessionID: sid, cwd: "/p/\(sid)", agent: agent)
    }
    stores.apply(e(.stop, "claude-old-done", 0, .claudeCode))
    stores.apply(e(.stop, "codex-new-done", 50, .codex))
    stores.apply(e(.userPromptSubmit, "opencode-working", 10, .opencode))
    stores.apply(e(.permissionRequest, "codex-waiting", 20, .codex))
    stores.apply(e(.userPromptSubmit, "claude-working", 30, .claudeCode))
    #expect(stores.board.map(\.id) == ["codex-waiting", "claude-working", "opencode-working", "codex-new-done", "claude-old-done"])
    #expect(stores.live.count == 5)
    #expect(stores.session(rowID: "opencode-working")?.agent == .opencode)
    #expect(Set(stores.stores.keys) == [.claudeCode, .codex, .opencode])
    stores.remove(.codex)
    #expect(stores.board.map(\.id) == ["claude-working", "opencode-working", "claude-old-done"])
}

// MARK: Jump targets

private func session(_ agent: AgentKind, _ host: AgentHost?, id: String = "s", path: String = "/Users/dev/Projects/api") -> AgentSession {
    var s = AgentSession(id: id, rowID: id, projectPath: path, cwd: path, label: "api", state: .working,
                         stateSince: t0, startedAt: t0, lastEventAt: t0)
    s.agent = agent
    s.host = host
    return s
}

@Test func jumpTargetFollowsWhereTheSessionRuns() {
    #expect(AgentJump.plan(for: session(.claudeCode, AgentHost(kind: .terminal, bundleID: "com.apple.Terminal")))
            == .terminal(processNames: ["claude"]))
    #expect(AgentJump.plan(for: session(.claudeCode, nil)) == .terminal(processNames: ["claude"]))
    #expect(AgentJump.plan(for: session(.claudeCode, AgentHost(kind: .vscode, bundleID: "com.microsoft.VSCode")))
            == .editor(bundleID: "com.microsoft.VSCode", folder: "/Users/dev/Projects/api", opensFolders: true))
    #expect(AgentJump.plan(for: session(.claudeCode, AgentHost(kind: .vscode)))
            == .editor(bundleID: "com.microsoft.VSCode", folder: "/Users/dev/Projects/api", opensFolders: true))
    #expect(AgentJump.plan(for: session(.claudeCode, AgentHost(kind: .cursor, bundleID: "com.todesktop.230313mzl4w4u92")))
            == .editor(bundleID: "com.todesktop.230313mzl4w4u92", folder: "/Users/dev/Projects/api", opensFolders: true))
    #expect(AgentJump.plan(for: session(.claudeCode, AgentHost(kind: .xcode)))
            == .editor(bundleID: "com.apple.dt.Xcode", folder: "/Users/dev/Projects/api", opensFolders: false))
    #expect(AgentJump.plan(for: session(.codex, AgentHost(kind: .codexApp, bundleID: "com.openai.codex"), id: "codex:0199-abc"))
            == .codexThread(threadID: "0199-abc"))
    #expect(AgentJump.plan(for: session(.codex, AgentHost(kind: .terminal))) == .terminal(processNames: ["codex"]))
    #expect(AgentJump.plan(for: session(.codex, AgentHost(kind: .vscode, bundleID: "com.microsoft.VSCode")))
            == .editor(bundleID: "com.microsoft.VSCode", folder: "/Users/dev/Projects/api", opensFolders: true))
    #expect(AgentJump.plan(for: session(.opencode, AgentHost(kind: .opencodeApp))) == .app(bundleID: "ai.opencode.desktop"))
    #expect(AgentJump.plan(for: session(.opencode, nil)) == .terminal(processNames: ["opencode"]))
    #expect(AgentJump.plan(for: session(.claudeCode, AgentHost(kind: .jetbrains))) == .terminal(processNames: ["claude"]))
}

@MainActor @Test func clickUsesThePlanOfTheRow() async {
    let model = AgentsModel()
    var targets: [TerminalJumper.Target] = []
    model.jumper = { t in targets.append(t); return .activatedApp(app: "x") }
    model.ingest([AgentEvent(ts: t0, kind: .userPromptSubmit, sessionID: "codex:th-1", cwd: "/p/web", agent: .codex,
                             host: AgentHost(kind: .codexApp, bundleID: "com.openai.codex")),
                  AgentEvent(ts: t0, kind: .userPromptSubmit, sessionID: "vs", cwd: "/p/api",
                             host: AgentHost(kind: .vscode, bundleID: "com.microsoft.VSCode"))], rebuild: true)
    model.jump(to: "codex:th-1")
    await model.jumpTask?.value
    model.jump(to: "vs")
    await model.jumpTask?.value
    #expect(targets.map(\.plan) == [.codexThread(threadID: "th-1"),
                                     .editor(bundleID: "com.microsoft.VSCode", folder: "/p/api", opensFolders: true)])
    #expect(model.jumpNote == nil)
}

@MainActor @Test func unknownHostsAreLookedUpOnceWhenThePanelOpens() async {
    let model = AgentsModel()
    let calls = LockedCounter()
    model.hostLookup = { cwds, names in
        calls.bump()
        calls.names = names
        return cwds.contains("/p/api") ? ["/p/api": "com.mitchellh.ghostty"] : [:]
    }
    model.ingest([ev(.userPromptSubmit, "a", 0, cwd: "/p/api"),
                  AgentEvent(ts: t0, kind: .userPromptSubmit, sessionID: "codex:c", cwd: "/p/web", agent: .codex, host: AgentHost(kind: .terminal)),
                  AgentEvent(ts: t0, kind: .userPromptSubmit, sessionID: "known", cwd: "/p/k", host: AgentHost(kind: .vscode))], rebuild: true)
    model.visibilityChanged(.expanded(.agents))
    await model.hostTask?.value
    #expect(model.store.session(rowID: "a")?.host == AgentHost(kind: .terminal, bundleID: "com.mitchellh.ghostty"))
    #expect(model.store.session(rowID: "known")?.host == AgentHost(kind: .vscode))
    #expect(calls.names == ["claude", "codex"])
    model.visibilityChanged(.collapsed)
    model.visibilityChanged(.expanded(nil))
    await model.hostTask?.value
    #expect(calls.value == 1)                    // looked up once, not on every open
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    private var _names = Set<String>()
    var names: Set<String> {
        get { lock.withLock { _names } }
        set { lock.withLock { _names = newValue } }
    }
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

// MARK: Command bar

@MainActor @Test func commandBarFindsSessionsAcrossSources() {
    let module = AgentsModule(logURL: tempDir("cmd").appendingPathComponent("events.jsonl"))
    module.model.ingest([
        AgentEvent(ts: t0, kind: .userPromptSubmit, sessionID: "codex:1", cwd: "/Users/dev/Projects/web-app", prompt: "Add dark mode",
                   agent: .codex, host: AgentHost(kind: .codexApp, bundleID: "com.openai.codex")),
        AgentEvent(ts: t0, kind: .permissionRequest, sessionID: "c2", cwd: "/Users/dev/Projects/api", toolName: "Bash", prompt: "Run the migrations"),
        AgentEvent(ts: t0, kind: .stop, sessionID: "ses_3", cwd: "/Users/dev/Projects/mobile", agent: .opencode, message: "Login fixed"),
    ], rebuild: true)
    #expect(module.results(for: "a").isEmpty)                                 // too short
    #expect(module.results(for: "web").first?.title == "web-app")
    #expect(module.results(for: "dark mode").map(\.id) == ["agents.session.codex:1"])
    #expect(module.results(for: "migrations").first?.subtitle?.hasPrefix("Claude Code · ") == true)
    #expect(module.results(for: "login").first?.title == "mobile")             // the reply matches too
    #expect(module.results(for: "codex").map(\.title) == ["web-app"])         // the agent's name
    #expect(module.results(for: "projects").first?.title == "api")            // waiting ranks first on a path match
    let cmds = module.commands()
    #expect(cmds.contains { $0.id == "agents.show" })
    #expect(cmds.first { $0.id == "agents.needsYou" }?.title.contains("api") == true)
}

// MARK: OpenCode

/// A database with OpenCode's tables (the columns Glancy reads) in a temp folder.
private func openCodeDB(_ folder: URL, _ sql: [String]) {
    var db: OpaquePointer?
    sqlite3_open(folder.appendingPathComponent("opencode.db").path, &db)
    defer { sqlite3_close(db) }
    let schema = [
        "CREATE TABLE session (id text PRIMARY KEY, project_id text NOT NULL, parent_id text, slug text NOT NULL, directory text NOT NULL, title text NOT NULL, version text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, time_archived integer)",
        "CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL)",
        "CREATE TABLE part (id text PRIMARY KEY, message_id text NOT NULL, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL)",
    ]
    for q in schema + sql { sqlite3_exec(db, q, nil, nil, nil) }
}

private func ms(_ sec: Double) -> Int { Int((t0.timeIntervalSince1970 + sec) * 1000) }

@Test func openCodeDatabaseRowsAndStates() throws {
    let dir = tempDir("opencode"); defer { try? FileManager.default.removeItem(at: dir) }
    openCodeDB(dir, [
        "INSERT INTO session VALUES ('ses_a','p',NULL,'a','/Users/dev/Projects/api','Fix the login flow','1',\(ms(0)),\(ms(30)),NULL)",
        "INSERT INTO session VALUES ('ses_child','p','ses_a','c','/Users/dev/Projects/api','Subagent','1',\(ms(0)),\(ms(30)),NULL)",
        "INSERT INTO session VALUES ('ses_old','p',NULL,'o','/Users/dev/Projects/old','Old','1',\(ms(-90000)),\(ms(-90000)),NULL)",
        #"INSERT INTO message VALUES ('msg_1','ses_a',\#(ms(1)),\#(ms(1)),'{"role":"user","time":{"created":\#(ms(1))}}')"#,
        #"INSERT INTO part VALUES ('prt_1','msg_1','ses_a',\#(ms(1)),\#(ms(1)),'{"type":"text","text":"Why does login  fail?"}')"#,
        #"INSERT INTO message VALUES ('msg_2','ses_a',\#(ms(2)),\#(ms(5)),'{"role":"assistant","time":{"created":\#(ms(2)),"completed":\#(ms(5))},"finish":"tool-calls"}')"#,
        #"INSERT INTO part VALUES ('prt_2','msg_2','ses_a',\#(ms(3)),\#(ms(3)),'{"type":"tool","tool":"bash","state":{"status":"completed"}}')"#,
    ])
    var rows = try #require(OpenCodeDatabase.recentSessions(db: dir.appendingPathComponent("opencode.db").path,
                                                             since: t0.addingTimeInterval(-3600), limit: 12))
    #expect(rows.map(\.id) == ["ses_a"])                     // no subagent, nothing older than the window
    #expect(rows[0].role == "assistant" && rows[0].finish == "tool-calls" && rows[0].tool == "bash")
    #expect(rows[0].userText == "Why does login  fail?")

    var seen: [String: OpenCodeSnapshot.Seen] = [:]
    var store = AgentSessionStore()
    for e in OpenCodeSnapshot.events(rows, seen: &seen) { store.apply(e) }
    var s = try #require(store.sessions["ses_a"])
    #expect(s.state == .working)                             // a step finished with tool calls: more to come
    #expect(s.title == "Fix the login flow")
    #expect(s.lastPrompt == "Why does login fail?")
    #expect(s.lastTool == "bash")
    #expect(s.agent == .opencode)
    // Nothing changed: no events.
    #expect(OpenCodeSnapshot.events(rows, seen: &seen).isEmpty)

    // The turn ends with a reply.
    rows[0].role = "assistant"; rows[0].completed = t0.addingTimeInterval(40); rows[0].finish = "stop"
    rows[0].replyText = "The cookie domain was wrong; fixed."
    let tr = OpenCodeSnapshot.events(rows, seen: &seen).flatMap { store.apply($0) }
    s = store.sessions["ses_a"]!
    #expect(s.state == .done)
    #expect(s.lastMessage == "The cookie domain was wrong; fixed.")
    #expect(tr.count == 1)

    // Aborted: done quietly; another error: failed.
    rows[0].completed = t0.addingTimeInterval(80); rows[0].errorName = "MessageAbortedError"; rows[0].userCreated = t0.addingTimeInterval(60)
    rows[0].finish = nil
    var events = OpenCodeSnapshot.events(rows, seen: &seen)
    #expect(events.map(\.kind) == [.interrupted])
    rows[0].completed = t0.addingTimeInterval(90); rows[0].errorName = "ProviderAuthError"
    events = OpenCodeSnapshot.events(rows, seen: &seen)
    #expect(events.map(\.kind) == [.stopFailure])
}

@Test func openCodePluginIsTheShippedFileAndInstallsOnlyItsOwnFile() throws {
    let shipped = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("hooks/glancy-opencode.js")
    #expect(try String(contentsOf: shipped, encoding: .utf8) == OpenCodePluginInstaller.source)

    let dir = tempDir("ocplugins"); defer { try? FileManager.default.removeItem(at: dir) }
    let installer = OpenCodePluginInstaller(pluginsFolder: dir.appendingPathComponent("plugins"))
    #expect(!installer.isInstalled)
    #expect(try installer.install() == nil)
    #expect(installer.isInstalled && !installer.isOutdated)
    try installer.uninstall()
    #expect(!FileManager.default.fileExists(atPath: installer.pluginURL.path))

    // Someone else's glancy.js: kept aside, never overwritten; Uninstall leaves foreign files alone.
    try Data("export const Mine = async () => ({})\n".utf8).write(to: installer.pluginURL)
    try installer.uninstall()
    #expect(FileManager.default.fileExists(atPath: installer.pluginURL.path))
    let backup = try #require(try installer.install(now: Date(timeIntervalSince1970: 100)))
    #expect(backup.lastPathComponent == "glancy.js.backup-100")
    #expect(try String(contentsOf: backup, encoding: .utf8).hasPrefix("export const Mine"))
    #expect(installer.isInstalled)
}

@MainActor @Test func openCodeSourceReadsThePluginLogAndDropsDatabaseDuplicates() async throws {
    let dir = tempDir("ocsource"); defer { try? FileManager.default.removeItem(at: dir) }
    let log = dir.appendingPathComponent("agents/opencode-events.jsonl")
    try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
    let lines = [
        #"{"ts":\#(ms(0)),"event":"SessionStart","session_id":"ses_p","cwd":"/Users/dev/Projects/api","agent":"opencode","host_bundle":"com.mitchellh.ghostty","title":"Ship it"}"#,
        #"{"ts":\#(ms(1)),"event":"UserPromptSubmit","session_id":"ses_p","cwd":"/Users/dev/Projects/api","agent":"opencode","prompt":"deploy"}"#,
        #"{"ts":\#(ms(2)),"event":"PermissionRequest","session_id":"ses_p","cwd":"/Users/dev/Projects/api","agent":"opencode","tool_name":"bash"}"#,
    ]
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: log)
    let source = OpenCodeSource(dataFolder: dir.appendingPathComponent("no-opencode-here"), pluginLog: log,
                                installer: OpenCodePluginInstaller(pluginsFolder: dir.appendingPathComponent("plugins")))
    let model = AgentsModel()
    source.start { kind, update in model.apply(update, from: kind) }
    let end = Date.now.addingTimeInterval(3)
    while model.store.session(rowID: "ses_p")?.state != .waiting, Date.now < end { try await Task.sleep(for: .milliseconds(20)) }
    let s = try #require(model.store.session(rowID: "ses_p"))
    #expect(s.state == .waiting && s.waitingTool == "bash")
    #expect(s.title == "Ship it")
    #expect(s.host == AgentHost(kind: .terminal, bundleID: "com.mitchellh.ghostty"))
    #expect(source.status().level == .missing)
    source.stop()
}

// MARK: Per-source switches

@MainActor
private final class FakeSource: AgentSource {
    let kind: AgentKind
    var running = false
    var starts = 0
    private var sink: (@MainActor (AgentKind, AgentSourceUpdate) -> Void)?
    init(_ kind: AgentKind) { self.kind = kind }
    func start(_ sink: @escaping @MainActor (AgentKind, AgentSourceUpdate) -> Void) { running = true; starts += 1; self.sink = sink }
    func stop() { running = false; sink = nil }
    func status() -> AgentSourceStatus { AgentSourceStatus(.ok, "fake") }
    func send(_ events: [AgentEvent]) { sink?(kind, .events(events, quiet: true)) }
}

@MainActor @Test func turningASourceOffStopsItAndClearsItsRows() {
    let suite = "glancy.tests.agents.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let claude = FakeSource(.claudeCode), codex = FakeSource(.codex)
    let module = AgentsModule(sources: [claude, codex], defaults: defaults)
    module.start(hub: ActivityHub())
    #expect(claude.running && codex.running)
    codex.send([AgentEvent(ts: t0, kind: .userPromptSubmit, sessionID: "codex:x", cwd: "/p/x", agent: .codex)])
    claude.send([ev(.userPromptSubmit, "c", 0, cwd: "/p/c")])
    #expect(module.model.sessions.count == 2)

    module.setSource(.codex, enabled: false)
    #expect(!codex.running)
    #expect(module.model.sessions.map(\.id) == ["c"])
    #expect(module.sourceStatus(.codex) == AgentSourceStatus(.off, AgentsText.t("Off")))
    #expect(module.settingsSummary == "Claude Code")

    // Remembered across runs; on again starts it.
    module.stop()
    module.start(hub: ActivityHub())
    #expect(!codex.running && claude.running)
    module.setSource(.codex, enabled: true)
    #expect(codex.running && codex.starts == 2)
    module.stop()
    #expect(!claude.running && !codex.running)
}
