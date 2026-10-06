import Foundation
import Testing
@testable import GlancyKit

// Codex rollouts. Fixture lines keep the exact key order and shapes of the rollouts on this Mac
// (Codex 0.130 – 0.153: desktop app, CLI, subagent/reviewer threads), with made-up content.

enum CodexFixtures {
    static let thread = "01a0c8a7-0000-7000-8000-000000000001"

    static func meta(_ id: String = thread, originator: String = "Codex Desktop", source: String = #""vscode""#,
                     cwd: String = "/Users/dev/Projects/web-app", at t: String = "2026-09-22T10:26:43.289Z") -> String {
        #"{"timestamp":"\#(t)","ordinal":0,"type":"session_meta","payload":{"session_id":"\#(id)","id":"\#(id)","timestamp":"\#(t)","cwd":"\#(cwd)","originator":"\#(originator)","cli_version":"0.153.4","source":\#(source),"thread_source":"user","model_provider":"openai","base_instructions":{"text":"\#(String(repeating: "You are a coding agent. ", count: 400))"}}}"#
    }

    static func turnContext(policy: String = "never", reviewer: String = #""auto_review""#, cwd: String = "/Users/dev/Projects/web-app",
                            at t: String) -> String {
        #"{"timestamp":"\#(t)","ordinal":5,"type":"turn_context","payload":{"turn_id":"t1","root_turn_id":"t1","cwd":"\#(cwd)","workspace_roots":["\#(cwd)"],"approval_policy":"\#(policy)","approvals_reviewer":\#(reviewer),"model":"gpt","effort":"high"}}"#
    }

    static func taskStarted(_ t: String) -> String {
        #"{"timestamp":"\#(t)","ordinal":1,"type":"event_msg","payload":{"type":"task_started","turn_id":"t1","started_at":1790072899,"model_context_window":258400,"collaboration_mode_kind":"default"}}"#
    }

    static func userItem(_ text: String, _ t: String) -> String {
        #"{"timestamp":"\#(t)","ordinal":9,"type":"event_msg","payload":{"type":"item_completed","thread_id":"\#(thread)","turn_id":"t1","item":{"type":"UserMessage","id":"u1","client_id":"c1","content":[{"type":"text","text":"\#(text)"}]}}}"#
    }

    static func userMessage(_ text: String, _ t: String) -> String {
        #"{"timestamp":"\#(t)","type":"event_msg","payload":{"type":"user_message","message":"\#(text)","images":[],"local_images":[],"text_elements":[]}}"#
    }

    static func commandItem(_ t: String, output: Int = 100) -> String {
        #"{"timestamp":"\#(t)","ordinal":12,"type":"event_msg","payload":{"type":"item_completed","thread_id":"\#(thread)","turn_id":"t1","item":{"type":"CommandExecution","id":"exec-1","process_id":"1","command":["/bin/zsh","-lc","ls"],"aggregated_output":"\#(String(repeating: "x", count: output))","status":"completed"}}}"#
    }

    static func call(_ name: String, id: String, args: String = #"{\"cmd\":\"ls\"}"#, _ t: String) -> String {
        #"{"timestamp":"\#(t)","ordinal":13,"type":"response_item","payload":{"type":"function_call","name":"\#(name)","arguments":"\#(args)","call_id":"\#(id)"}}"#
    }

    static func customCall(_ name: String, id: String, _ t: String) -> String {
        #"{"timestamp":"\#(t)","ordinal":13,"type":"response_item","payload":{"type":"custom_tool_call","id":"ctc_1","status":"completed","call_id":"\#(id)","name":"\#(name)","input":"text(1)"}}"#
    }

    static func output(_ id: String, _ t: String, size: Int = 50) -> String {
        #"{"timestamp":"\#(t)","ordinal":14,"type":"response_item","payload":{"type":"function_call_output","call_id":"\#(id)","output":"\#(String(repeating: "o", count: size))"}}"#
    }

    static func complete(_ t: String, message: String = "All tests pass.") -> String {
        #"{"timestamp":"\#(t)","ordinal":20,"type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":"\#(message)","started_at":1790072899,"completed_at":1790072906,"duration_ms":6679}}"#
    }

    static func completeWithError(_ t: String) -> String {
        #"{"timestamp":"\#(t)","ordinal":21,"type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","error":{"message":"Selected model is at capacity.","codex_error_info":"server_overloaded"},"started_at":1,"completed_at":2,"duration_ms":1}}"#
    }

    static func aborted(_ t: String) -> String {
        #"{"timestamp":"\#(t)","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"t1","reason":"interrupted","completed_at":1778503735,"duration_ms":67109}}"#
    }

    static func tokenCount(_ t: String) -> String {
        #"{"timestamp":"\#(t)","ordinal":15,"type":"event_msg","payload":{"type":"token_count","info":{"total":1}}}"#
    }

    static func reasoning(_ t: String, size: Int) -> String {
        #"{"timestamp":"\#(t)","ordinal":16,"type":"response_item","payload":{"type":"reasoning","summary":[],"encrypted_content":"\#(String(repeating: "r", count: size))"}}"#
    }

    static let subagentSource = #"{"subagent":{"thread_spawn":{"parent_thread_id":"p","depth":1,"agent_nickname":"Ada","agent_role":"worker"}}}"#
    static let guardianSource = #"{"subagent":{"other":"guardian"}}"#

    /// A desktop session: one turn that runs a command and finishes.
    static func finishedTurn() -> [String] {
        [meta(), taskStarted("2026-09-22T10:26:43.300Z"), turnContext(at: "2026-09-22T10:26:45.738Z"),
         userItem("Add dark mode to the settings page", "2026-09-22T10:26:45.754Z"),
         customCall("exec", id: "c1", "2026-09-22T10:26:56.888Z"), commandItem("2026-09-22T10:26:57.197Z", output: 4000),
         output("c1", "2026-09-22T10:26:59.916Z"), tokenCount("2026-09-22T10:26:59.917Z"),
         complete("2026-09-22T10:27:44.836Z")]
    }
}

private func parse(_ lines: [String]) -> (events: [AgentEvent], state: CodexRolloutState) {
    var state = CodexRolloutState()
    var splitter = CodexLineSplitter()
    var out: [AgentEvent] = []
    splitter.feed(Data((lines.joined(separator: "\n") + "\n").utf8)) { line, d in
        out += CodexRollout.events(line: line, decision: d, state: &state)
    }
    return (out, state)
}

private func ts(_ s: String) -> Date { CodexRollout.parseTimestamp(s)! }

@Test func codexClassifiesFromTheFirstBytes() {
    func d(_ line: String) -> CodexLineDecision { CodexRollout.classify(Data(line.utf8).prefix(CodexRollout.prefixBytes)) }
    #expect(d(CodexFixtures.meta()) == .full(limit: 2 << 20))
    #expect(d(CodexFixtures.taskStarted("2026-09-22T10:26:43.300Z")) == .full(limit: 1 << 20))
    #expect(d(CodexFixtures.userItem("hi", "2026-09-22T10:26:43.300Z")) == .full(limit: 1 << 20))
    #expect(d(CodexFixtures.commandItem("2026-09-22T10:26:43.300Z")) == .skip)
    #expect(d(CodexFixtures.output("c", "2026-09-22T10:26:43.300Z")) == .prefixOnly)
    #expect(d(CodexFixtures.tokenCount("2026-09-22T10:26:43.300Z")) == .skip)
    #expect(d(CodexFixtures.reasoning("2026-09-22T10:26:43.300Z", size: 10)) == .skip)
    #expect(d(#"{"timestamp":"x","type":"world_state","payload":{"full":true}}"#) == .skip)
    #expect(d(#"{"timestamp":"x","type":"some_future_type","payload":{"type":"new"}}"#) == .skip)
}

@Test func codexTimestamps() {
    let d = CodexRollout.parseTimestamp("2026-09-22T10:26:43.289Z")!
    #expect(abs(d.timeIntervalSince1970 - 1790072803.289) < 0.001)
    #expect(CodexRollout.parseTimestamp("2026-09-22T10:26:43Z")!.timeIntervalSince1970 == 1790072803)
    #expect(CodexRollout.parseTimestamp("not a date") == nil)
}

@Test func codexFinishedTurnFromADesktopSession() {
    let (events, state) = parse(CodexFixtures.finishedTurn())
    #expect(state.sessionID == "codex:" + CodexFixtures.thread)
    #expect(state.threadID == CodexFixtures.thread)
    #expect(state.host == AgentHost(kind: .codexApp, bundleID: "com.openai.codex"))
    #expect(events.map(\.kind) == [.sessionStart, .userPromptSubmit, .userPromptSubmit, .postToolUse, .stop])
    #expect(events.allSatisfy { $0.agent == .codex && $0.cwd == "/Users/dev/Projects/web-app" })
    #expect(events[2].prompt == "Add dark mode to the settings page")
    #expect(events[3].toolName == "exec")
    #expect(events[4].message == "All tests pass.")

    var store = AgentSessionStore()
    let transitions = events.flatMap { store.apply($0) }
    let s = store.sessions["codex:" + CodexFixtures.thread]!
    #expect(s.state == .done)
    #expect(s.title == "Add dark mode to the settings page")
    #expect(s.lastMessage == "All tests pass.")
    #expect(s.agent == .codex)
    #expect(s.label == "web-app")
    #expect(transitions.count == 1)
    if case let .finished(_, label, duration, _)? = transitions.first {
        #expect(label == "web-app")
        #expect(abs((duration ?? 0) - ts("2026-09-22T10:27:44.836Z").timeIntervalSince(ts("2026-09-22T10:26:45.754Z"))) < 0.01)
    }
}

@Test func codexHostFromOriginator() {
    #expect(CodexRollout.host(originator: "Codex Desktop", source: "vscode").kind == .codexApp)
    #expect(CodexRollout.host(originator: "codex_vscode", source: "vscode") == AgentHost(kind: .vscode, bundleID: "com.microsoft.VSCode"))
    #expect(CodexRollout.host(originator: "codex_cli_rs", source: "cli") == AgentHost(kind: .terminal))
    #expect(CodexRollout.host(originator: "codex_exec", source: "exec").kind == .terminal)
    #expect(CodexRollout.host(originator: nil, source: "cli").kind == .terminal)
    #expect(CodexRollout.host(originator: "something_new", source: "mcp") == .unknown)
}

@Test func codexSubagentAndReviewerThreadsAreNotSessions() {
    for source in [CodexFixtures.subagentSource, CodexFixtures.guardianSource] {
        let lines = [CodexFixtures.meta("child", source: source), CodexFixtures.taskStarted("2026-09-22T10:26:43.300Z"),
                     CodexFixtures.userMessage("The following is the Codex agent history", "2026-09-22T10:26:44.000Z"),
                     CodexFixtures.complete("2026-09-22T10:26:50.000Z", message: "{\\\"outcome\\\":\\\"allow\\\"}")]
        let (events, state) = parse(lines)
        #expect(events.isEmpty)
        #expect(state.isSubagent)
    }
}

@Test func codexFailedAndInterruptedTurns() {
    var lines = [CodexFixtures.meta(), CodexFixtures.taskStarted("2026-09-22T11:00:00.000Z"),
                 CodexFixtures.completeWithError("2026-09-22T11:05:00.000Z")]
    var store = AgentSessionStore()
    parse(lines).events.forEach { store.apply($0) }
    let sid = "codex:" + CodexFixtures.thread
    #expect(store.sessions[sid]?.state == .failed)
    #expect(store.sessions[sid]?.lastMessage == "Selected model is at capacity.")

    lines = [CodexFixtures.meta(), CodexFixtures.taskStarted("2026-09-22T11:00:00.000Z"),
             CodexFixtures.aborted("2026-09-22T11:01:00.000Z")]
    store = AgentSessionStore()
    let transitions = parse(lines).events.flatMap { store.apply($0) }
    #expect(store.sessions[sid]?.state == .done)
    #expect(transitions.isEmpty)                     // interrupted by the user: no peek
}

@Test func codexQuestionWaitsForYouUntilAnswered() {
    let lines = [CodexFixtures.meta(), CodexFixtures.taskStarted("2026-09-22T11:00:00.000Z"),
                 CodexFixtures.call("request_user_input", id: "q1", args: #"{\"questions\":[]}"#, "2026-09-22T11:00:10.000Z"),
                 CodexFixtures.output("q1", "2026-09-22T11:02:00.000Z")]
    var state = CodexRolloutState()
    var store = AgentSessionStore()
    var splitter = CodexLineSplitter()
    var transitions: [AgentTransition] = []
    var states: [AgentState] = []
    for l in lines {
        splitter.feed(Data((l + "\n").utf8)) { line, d in
            for e in CodexRollout.events(line: line, decision: d, state: &state) { transitions += store.apply(e) }
        }
        states.append(store.sessions.values.first?.state ?? .ended)
    }
    #expect(states == [.idle, .working, .waiting, .working])
    #expect(transitions.contains { if case .needsYou(_, _, let tool) = $0 { tool == "question" } else { false } })
    #expect(state.pending.isEmpty)
}

@Test func codexEscalatedCommandWaitsOnlyWhenTheUserApproves() {
    let escalated = #"{\"cmd\":\"rm -rf build\",\"sandbox_permissions\":\"require_escalated\"}"#
    // Approvals go to the user (on-request, no auto-reviewer): waiting.
    var lines = [CodexFixtures.meta(), CodexFixtures.turnContext(policy: "on-request", reviewer: "null", at: "2026-09-22T11:00:00.000Z"),
                 CodexFixtures.taskStarted("2026-09-22T11:00:00.100Z"),
                 CodexFixtures.call("exec_command", id: "e1", args: escalated, "2026-09-22T11:00:10.000Z")]
    var store = AgentSessionStore()
    parse(lines).events.forEach { store.apply($0) }
    #expect(store.sessions.values.first?.state == .waiting)
    #expect(store.sessions.values.first?.waitingTool == "exec_command")
    // The auto-reviewer decides, or approvals are off: still working.
    for ctx in [CodexFixtures.turnContext(policy: "on-request", at: "2026-09-22T11:00:00.000Z"),
                CodexFixtures.turnContext(policy: "never", reviewer: "null", at: "2026-09-22T11:00:00.000Z")] {
        lines[1] = ctx
        store = AgentSessionStore()
        parse(lines).events.forEach { store.apply($0) }
        #expect(store.sessions.values.first?.state == .working)
    }
}

@Test func codexOlderUserMessageEventAndUnknownLines() {
    let lines = [CodexFixtures.meta(originator: "codex_cli_rs", source: #""cli""#),
                 #"{"timestamp":"2026-05-10T15:47:50.251Z","type":"brand_new_kind","payload":{"type":"x"}}"#,
                 "not json at all",
                 "",
                 CodexFixtures.userMessage("<environment_context>cwd</environment_context> fix   the build", "2026-05-10T15:47:50.300Z")]
    let (events, state) = parse(lines)
    #expect(state.host?.kind == .terminal)
    #expect(events.map(\.kind) == [.sessionStart, .userPromptSubmit])
    #expect(events.last?.prompt == "cwd fix the build")
}

@Test func codexSplitterNeverBuffersSkippedLines() {
    // A 3 MB reasoning line fed in 64 KB chunks: dropped as it streams.
    var splitter = CodexLineSplitter()
    let big = Data((CodexFixtures.reasoning("2026-09-22T10:00:00.000Z", size: 3 << 20) + "\n").utf8)
    var maxBuffered = 0
    var seen = 0
    var i = 0
    while i < big.count {
        let chunk = big[i..<min(i + 65536, big.count)]
        splitter.feed(Data(chunk)) { _, _ in seen += 1 }
        maxBuffered = max(maxBuffered, splitter.buffered)
        i += 65536
    }
    #expect(seen == 0)
    #expect(maxBuffered <= 65536 + CodexRollout.prefixBytes)
    // A big tool output keeps only its call id.
    var calls: [Data] = []
    let out = Data((CodexFixtures.output("c9", "2026-09-22T10:00:00.000Z", size: 2 << 20) + "\n" + CodexFixtures.taskStarted("2026-09-22T10:00:01.000Z") + "\n").utf8)
    splitter.feed(out) { line, d in calls.append(line); _ = d }
    #expect(calls.count == 2)
    #expect(calls[0].count == CodexRollout.prefixBytes)
    #expect(splitter.buffered == 0)
}

@Test func codexSplitterHandlesLinesCutAcrossChunks() {
    let text = CodexFixtures.finishedTurn().joined(separator: "\n") + "\n"
    let data = Data(text.utf8)
    for size in [1, 7, 300, 513, 4096] {
        var splitter = CodexLineSplitter()
        var state = CodexRolloutState()
        var kinds: [AgentEvent.Kind] = []
        var i = 0
        while i < data.count {
            splitter.feed(Data(data[i..<min(i + size, data.count)])) { line, d in
                kinds += CodexRollout.events(line: line, decision: d, state: &state).map(\.kind)
            }
            i += size
        }
        #expect(kinds == [.sessionStart, .userPromptSubmit, .userPromptSubmit, .postToolUse, .stop], "chunk \(size)")
    }
}

// MARK: Reader on temp folders

private final class Updates: @unchecked Sendable {
    private let lock = NSLock()
    private var _rebuilt: AgentSessionStore?
    private var _events: [(AgentEvent, Bool)] = []
    var rebuilt: AgentSessionStore? { lock.withLock { _rebuilt } }
    var events: [(event: AgentEvent, quiet: Bool)] { lock.withLock { _events.map { ($0.0, $0.1) } } }
    var deliver: CodexSessionsReader.Deliver {
        { [self] u in
            lock.withLock {
                switch u {
                case .rebuilt(let s): _rebuilt = s
                case let .events(e, quiet): _events += e.map { ($0, quiet) }
                }
            }
        }
    }
}

private func tempRoot() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("glancy-codex-\(UUID().uuidString)/sessions")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func write(_ lines: [String], to url: URL, append: Bool = false) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = Data((lines.joined(separator: "\n") + "\n").utf8)
    if append, let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(data); try? h.close()
    } else {
        try? data.write(to: url)
    }
}

private func eventually(_ timeout: Double = 10, _ cond: () -> Bool) async -> Bool {
    let end = Date.now.addingTimeInterval(timeout)
    while Date.now < end {
        if cond() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return cond()
}

/// Fixture lines stamped near now (the reader forgets sessions silent for 12 h).
private func nowStamp(_ offset: TimeInterval = 0) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: Date.now.addingTimeInterval(offset))
}

@Test func codexReaderRebuildsRecentSessionsAndSkipsSubagents() async {
    let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let day = root.appendingPathComponent("2026/09/22")
    write([CodexFixtures.meta("main-1", at: nowStamp(-60)), CodexFixtures.taskStarted(nowStamp(-50)),
           CodexFixtures.userItem("Write the docs", nowStamp(-49)), CodexFixtures.complete(nowStamp(-10))],
          to: day.appendingPathComponent("rollout-a-main-1.jsonl"))
    write([CodexFixtures.meta("child", source: CodexFixtures.guardianSource, at: nowStamp(-30)), CodexFixtures.taskStarted(nowStamp(-29))],
          to: day.appendingPathComponent("rollout-b-child.jsonl"))
    // Old: its file is older than 12 h.
    let old = day.appendingPathComponent("rollout-c-old.jsonl")
    write([CodexFixtures.meta("old"), CodexFixtures.taskStarted("2026-09-01T00:00:00.000Z")], to: old)
    try? FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-13 * 3600)], ofItemAtPath: old.path)

    let reader = CodexSessionsReader(root: root)
    let u = Updates()
    reader.start(u.deliver)
    #expect(await eventually { u.rebuilt != nil })
    reader.sync()
    let store = u.rebuilt!
    #expect(Array(store.sessions.keys) == ["codex:main-1"])
    #expect(store.sessions["codex:main-1"]?.state == .done)
    #expect(store.sessions["codex:main-1"]?.title == "Write the docs")
    #expect(reader.trackedCount == 1)
    reader.stop()
}

@Test func codexReaderFollowsAppendsNewFilesAndArchiving() async {
    let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let a = root.appendingPathComponent("2026/10/06/rollout-a.jsonl")
    write([CodexFixtures.meta("a", at: nowStamp(-20)), CodexFixtures.taskStarted(nowStamp(-19))], to: a)
    let reader = CodexSessionsReader(root: root)
    let u = Updates()
    reader.start(u.deliver)
    #expect(await eventually { u.rebuilt != nil })
    #expect(u.rebuilt?.sessions["codex:a"]?.state == .working)

    // New bytes only: the turn ends.
    write([CodexFixtures.complete(nowStamp())], to: a, append: true)
    #expect(await eventually { u.events.contains { $0.event.kind == .stop && $0.event.sessionID == "codex:a" && !$0.quiet } })

    // A new session in a new day folder.
    let b = root.appendingPathComponent("2026/10/07/rollout-b.jsonl")
    write([CodexFixtures.meta("b", originator: "codex_cli_rs", source: #""cli""#, at: nowStamp()), CodexFixtures.taskStarted(nowStamp())], to: b)
    #expect(await eventually { u.events.contains { $0.event.sessionID == "codex:b" && $0.event.kind == .userPromptSubmit } })
    #expect(u.events.first { $0.event.sessionID == "codex:b" }?.event.host?.kind == .terminal)

    // Archived (moved away): the row ends.
    try? FileManager.default.moveItem(at: a, to: root.deletingLastPathComponent().appendingPathComponent("archived-a.jsonl"))
    #expect(await eventually { u.events.contains { $0.event.kind == .sessionEnd && $0.event.sessionID == "codex:a" } })
    reader.stop()
}

@Test func codexReaderCapsFollowedFiles() async {
    let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    for i in 0..<6 {
        write([CodexFixtures.meta("s\(i)", at: nowStamp(Double(-60 + i))), CodexFixtures.taskStarted(nowStamp(Double(-59 + i)))],
              to: root.appendingPathComponent("2026/10/06/rollout-\(i).jsonl"))
    }
    let reader = CodexSessionsReader(root: root, maxFiles: 3)
    let u = Updates()
    reader.start(u.deliver)
    #expect(await eventually { u.rebuilt != nil })
    #expect(u.rebuilt?.sessions.count == 3)
    #expect(reader.trackedCount == 3)
    write([CodexFixtures.meta("s9", at: nowStamp()), CodexFixtures.taskStarted(nowStamp())],
          to: root.appendingPathComponent("2026/10/06/rollout-9.jsonl"))
    #expect(await eventually { u.events.contains { $0.event.sessionID == "codex:s9" } })
    #expect(reader.trackedCount == 3)
    reader.stop()
}

@Test func codexReaderWaitsForTheFolder() async {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("glancy-codex-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let root = base.appendingPathComponent("sessions")
    let reader = CodexSessionsReader(root: root)
    let u = Updates()
    reader.start(u.deliver)
    #expect(await eventually { u.rebuilt != nil })
    #expect(u.rebuilt?.sessions.isEmpty == true)
    write([CodexFixtures.meta("late", at: nowStamp()), CodexFixtures.taskStarted(nowStamp())],
          to: root.appendingPathComponent("2026/10/06/rollout-late.jsonl"))
    #expect(await eventually { u.rebuilt?.sessions["codex:late"] != nil || u.events.contains { $0.event.sessionID == "codex:late" } })
    reader.stop()
}
