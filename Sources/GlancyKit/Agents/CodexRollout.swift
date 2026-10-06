import Foundation

// Codex session rollouts: ~/.codex/sessions/YYYY/MM/DD/rollout-<time>-<thread id>.jsonl, one JSON
// object per line, appended while the session runs (Codex CLI, the Codex app and the VS Code
// extension all write them). Shape, from the files on this Mac (Codex 0.130 – 0.153):
//
//   {"timestamp":"2026-09-22T10:26:43.289Z","ordinal":0,"type":"session_meta","payload":{"id":…,
//     "cwd":…,"originator":"Codex Desktop" | "codex_cli_rs" | "codex_vscode" | "codex_exec",
//     "source":"vscode" | "cli" | "exec" | {"subagent":…}, "base_instructions":{…}}}
//   {"type":"turn_context","payload":{"cwd":…,"approval_policy":"never" | "on-request" | …,
//     "approvals_reviewer":"auto_review" | "user" | null, …}}
//   {"type":"event_msg","payload":{"type":"task_started" | "task_complete" (error?, last_agent_message)
//     | "turn_aborted" | "user_message" (message) | "item_completed" (item.type "UserMessage", content)
//     | "error" | "token_count" | …}}
//   {"type":"response_item","payload":{"type":"function_call" | "custom_tool_call" (name, call_id,
//     arguments/input) | "function_call_output" | "custom_tool_call_output" (call_id, output) | …}}
//
// Lines can be megabytes (command output, reasoning, base instructions). Each line is classified
// from its first bytes; only the few kinds that change a session's state are decoded, and the
// rest are skipped without being buffered. Unknown types are ignored.

/// What to do with a line, decided from its first bytes.
enum CodexLineDecision: Equatable {
    case skip
    /// Decode the whole line (when it is at most `limit` bytes; longer ones are skipped).
    case full(limit: Int)
    /// Everything needed is in the first bytes (a tool output's `call_id`): the rest is skipped.
    case prefixOnly
}

/// Per-rollout parsing state: who the session is and which calls wait for the user. Small.
struct CodexRolloutState: Sendable, Equatable {
    /// "codex:<thread id>" (nil until the session_meta line was read).
    var sessionID: String?
    var cwd = ""
    var host: AgentHost?
    /// A subagent or reviewer thread (source {"subagent":…}): not a session of its own.
    var isSubagent = false
    var approvalPolicy: String?
    var approvalsReviewer: String?
    /// Calls waiting for the user (call_id → tool), cleared by their output or the turn's end.
    var pending: [String: String] = [:]
    /// The newest plan `rate_limits` seen in this rollout (a `token_count` event): Codex's limits.
    var rateLimits: UsageReading?

    static let maxPending = 16

    /// The thread id Codex knows the session by.
    var threadID: String? { sessionID.map { String($0.dropFirst(AgentKind.codex.idPrefix.count)) } }
}

enum CodexRollout {
    static let prefixBytes = 512

    // MARK: Classification (first bytes only)

    static func classify(_ prefix: Data) -> CodexLineDecision {
        guard let top = stringValue(of: "type", in: prefix) else {
            // Keys in an unexpected order: decode small lines, skip big ones.
            return .full(limit: 64 << 10)
        }
        switch top {
        case "session_meta": return .full(limit: 2 << 20)
        case "turn_context": return .full(limit: 512 << 10)
        case "event_msg":
            guard let p = payloadType(in: prefix) else { return .skip }
            switch p {
            case "task_started", "task_complete", "turn_aborted", "user_message", "error":
                return .full(limit: 1 << 20)
            case "token_count":   // ~1 KB, carries the plan's rate_limits
                return .full(limit: 64 << 10)
            case "item_completed":
                return stringValue(of: "type", in: prefix, after: #""item":{"#) == "UserMessage" ? .full(limit: 1 << 20) : .skip
            default: return .skip
            }
        case "response_item":
            switch payloadType(in: prefix) {
            case "function_call", "custom_tool_call": return .full(limit: 1 << 20)
            case "function_call_output", "custom_tool_call_output": return .prefixOnly
            default: return .skip
            }
        default:
            return .skip
        }
    }

    private static func payloadType(in d: Data) -> String? {
        stringValue(of: "type", in: d, after: #""payload":{"#)
    }

    /// The string value of the first `"key":"…"` in `d` (after `marker`, when given). Plain byte
    /// search: no JSON decoding. Escapes inside the value are not interpreted (ids and types have none).
    static func stringValue(of key: String, in d: Data, after marker: String? = nil) -> String? {
        var from = d.startIndex
        if let marker {
            guard let r = d.range(of: Data(marker.utf8), in: from..<d.endIndex) else { return nil }
            from = r.upperBound
        }
        let needle = Data("\"\(key)\":\"".utf8)
        guard let r = d.range(of: needle, in: from..<d.endIndex) else { return nil }
        var i = r.upperBound
        var out = Data()
        while i < d.endIndex, d[i] != 0x22 {          // closing quote
            if d[i] == 0x5C { return nil }            // an escape: not a plain id/type
            out.append(d[i]); i += 1
            if out.count > 256 { return nil }
        }
        guard i < d.endIndex else { return nil }
        return String(data: out, encoding: .utf8)
    }

    // MARK: Lines → events

    /// The events one line produces for the session, updating `state`.
    static func events(line: Data, decision: CodexLineDecision, state: inout CodexRolloutState) -> [AgentEvent] {
        let ts = stringValue(of: "timestamp", in: line.prefix(prefixBytes)).flatMap(parseTimestamp) ?? Date()
        if decision == .prefixOnly {
            guard !state.isSubagent, let sid = state.sessionID,
                  let call = stringValue(of: "call_id", in: line.prefix(prefixBytes)),
                  let tool = state.pending.removeValue(forKey: call) else { return [] }
            // The user answered (or approved): the agent goes on.
            return [event(.postToolUse, sid, ts, state, tool: tool)]
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = obj["type"] as? String else { return [] }
        let payload = obj["payload"] as? [String: Any] ?? [:]

        if type == "session_meta" {
            return meta(payload, ts: ts, state: &state)
        }
        // Account-wide numbers: taken from any rollout, subagents' included.
        if type == "event_msg", payload["type"] as? String == "token_count" {
            if let rl = payload["rate_limits"] as? [String: Any], let r = UsageParser.codexRateLimits(rl, at: ts),
               r.updated >= (state.rateLimits?.updated ?? .distantPast) {
                state.rateLimits = r
            }
            return []
        }
        guard !state.isSubagent, let sid = state.sessionID else { return [] }

        switch type {
        case "turn_context":
            if let cwd = payload["cwd"] as? String, !cwd.isEmpty { state.cwd = cwd }
            state.approvalPolicy = payload["approval_policy"] as? String ?? state.approvalPolicy
            state.approvalsReviewer = payload["approvals_reviewer"] as? String
            return []

        case "event_msg":
            switch payload["type"] as? String {
            case "task_started":
                state.pending = [:]
                return [event(.userPromptSubmit, sid, ts, state)]
            case "user_message":
                let text = (payload["message"] as? String).flatMap(prompt)
                return [event(.userPromptSubmit, sid, ts, state, prompt: text)]
            case "item_completed":
                guard let item = payload["item"] as? [String: Any], item["type"] as? String == "UserMessage" else { return [] }
                let text = userText(item["content"]).flatMap(prompt)
                return text == nil ? [] : [event(.userPromptSubmit, sid, ts, state, prompt: text)]
            case "task_complete":
                state.pending = [:]
                if let err = payload["error"] as? [String: Any] {
                    let msg = (err["message"] as? String).flatMap { AgentEventParser.oneLine($0, max: 200) }
                    return [event(.stopFailure, sid, ts, state, message: msg)]
                }
                let msg = (payload["last_agent_message"] as? String).flatMap { AgentEventParser.oneLine($0, max: 200) }
                return [event(.stop, sid, ts, state, message: msg)]
            case "turn_aborted":
                state.pending = [:]
                return [event(.interrupted, sid, ts, state)]
            case "error":
                let msg = (payload["message"] as? String).flatMap { AgentEventParser.oneLine($0, max: 200) }
                return [event(.stopFailure, sid, ts, state, message: msg)]
            default:
                return []
            }

        case "response_item":
            guard let name = payload["name"] as? String else { return [] }
            let call = payload["call_id"] as? String
            let args = payload["arguments"] as? String ?? payload["input"] as? String ?? ""
            if let call, let tool = waitingTool(name: name, arguments: args, state: state) {
                if state.pending.count < CodexRolloutState.maxPending { state.pending[call] = tool }
                return [event(.permissionRequest, sid, ts, state, tool: tool)]
            }
            return [event(.postToolUse, sid, ts, state, tool: name)]

        default:
            return []
        }
    }

    /// A call that waits for the user: a question (`request_user_input`), or a command that needs
    /// approval (escalated sandbox) when approvals go to the user rather than to the auto-reviewer.
    static func waitingTool(name: String, arguments: String, state: CodexRolloutState) -> String? {
        if name.hasPrefix("request_user_input") { return "question" }
        guard arguments.contains("require_escalated") else { return nil }
        let policy = state.approvalPolicy ?? "on-request"
        guard policy != "never", state.approvalsReviewer != "auto_review" else { return nil }
        return name
    }

    private static func meta(_ p: [String: Any], ts: Date, state: inout CodexRolloutState) -> [AgentEvent] {
        guard let id = p["id"] as? String ?? p["session_id"] as? String, !id.isEmpty else { return [] }
        // Subagents and reviewers report through their parent: never a row of their own.
        if let source = p["source"] as? [String: Any], source["subagent"] != nil {
            state.isSubagent = true
            return []
        }
        state.isSubagent = false
        state.sessionID = AgentKind.codex.idPrefix + id
        if let cwd = p["cwd"] as? String, !cwd.isEmpty { state.cwd = cwd }
        state.host = host(originator: p["originator"] as? String, source: p["source"] as? String)
        return [event(.sessionStart, state.sessionID!, ts, state)]
    }

    /// Codex desktop app, the VS Code extension, or the CLI / `codex exec` in a terminal.
    static func host(originator: String?, source: String?) -> AgentHost {
        let o = (originator ?? "").lowercased()
        if o.contains("desktop") { return AgentHost(kind: .codexApp, bundleID: "com.openai.codex") }
        if o.contains("vscode") { return AgentHost(kind: .vscode, bundleID: "com.microsoft.VSCode") }
        if o.contains("cli") || o.contains("exec") { return AgentHost(kind: .terminal) }
        switch source {
        case "cli", "exec": return AgentHost(kind: .terminal)
        case "vscode": return AgentHost(kind: .vscode, bundleID: "com.microsoft.VSCode")
        default: return .unknown
        }
    }

    private static func event(_ kind: AgentEvent.Kind, _ sid: String, _ ts: Date, _ state: CodexRolloutState,
                              tool: String? = nil, prompt: String? = nil, message: String? = nil) -> AgentEvent {
        AgentEvent(ts: ts, kind: kind, sessionID: sid, cwd: state.cwd, toolName: tool, prompt: prompt,
                   agent: .codex, host: state.host, message: message)
    }

    /// The text of a UserMessage item: content is a list of strings or of {"type":"text","text":…}.
    static func userText(_ content: Any?) -> String? {
        guard let list = content as? [Any] else { return content as? String }
        let parts = list.compactMap { el -> String? in
            if let s = el as? String { return s }
            return (el as? [String: Any])?["text"] as? String
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// The user's words, one line, at most 200 characters.
    static func prompt(_ raw: String) -> String? {
        AgentEventParser.userPrompt(raw).flatMap { AgentEventParser.oneLine($0, max: 200) }
    }

    /// "2026-09-22T10:26:43.289Z" (fraction optional). No formatter: fast and thread-safe.
    static func parseTimestamp(_ s: String) -> Date? {
        let b = Array(s.utf8)
        guard b.count >= 20, b[4] == 0x2D, b[7] == 0x2D, b[10] == 0x54, b[13] == 0x3A, b[16] == 0x3A else { return nil }
        func num(_ r: Range<Int>) -> Int? {
            var v = 0
            for i in r { let c = Int(b[i]) - 48; guard (0...9).contains(c) else { return nil }; v = v * 10 + c }
            return v
        }
        guard let y = num(0..<4), let mo = num(5..<7), let d = num(8..<10),
              let h = num(11..<13), let mi = num(14..<16), let sec = num(17..<19) else { return nil }
        var frac = 0.0
        var i = 19
        if i < b.count, b[i] == 0x2E {
            i += 1
            var scale = 0.1
            while i < b.count, (48...57).contains(b[i]) { frac += Double(b[i] - 48) * scale; scale /= 10; i += 1 }
        }
        var tm = Darwin.tm()
        tm.tm_year = Int32(y - 1900); tm.tm_mon = Int32(mo - 1); tm.tm_mday = Int32(d)
        tm.tm_hour = Int32(h); tm.tm_min = Int32(mi); tm.tm_sec = Int32(sec)
        let t = timegm(&tm)
        return Date(timeIntervalSince1970: TimeInterval(t) + frac)
    }
}

/// Splits a byte stream into lines and hands over only the ones worth decoding. A line is
/// classified from its first `CodexRollout.prefixBytes` bytes; skipped lines are dropped as they
/// stream in, so a 5 MB command output never sits in memory.
struct CodexLineSplitter: Sendable {
    private var partial = Data()
    private var decision: CodexLineDecision?
    private var skipping = false

    /// Bytes held for the current line (tests check that skipped lines are not buffered).
    var buffered: Int { partial.count }

    mutating func feed(_ chunk: Data, _ each: (Data, CodexLineDecision) -> Void) {
        var i = chunk.startIndex
        while i < chunk.endIndex {
            let nl = chunk[i...].firstIndex(of: 0x0A)
            let end = nl ?? chunk.endIndex
            if !skipping {
                partial.append(chunk[i..<end])
                if decision == nil, partial.count >= CodexRollout.prefixBytes || nl != nil {
                    let d = CodexRollout.classify(partial.prefix(CodexRollout.prefixBytes))
                    decision = d
                    switch d {
                    case .skip:
                        drop()
                    case .prefixOnly:
                        each(partial.prefix(CodexRollout.prefixBytes), d)
                        drop()
                    case .full:
                        break
                    }
                }
                if case .full(let limit)? = decision, partial.count > limit { drop() }
            }
            guard let nl else { return }
            if !skipping, let d = decision, case .full = d, !partial.isEmpty { each(partial, d) }
            partial = Data()
            decision = nil
            skipping = false
            i = chunk.index(after: nl)
        }
    }

    private mutating func drop() {
        partial = Data()
        skipping = true
    }
}
