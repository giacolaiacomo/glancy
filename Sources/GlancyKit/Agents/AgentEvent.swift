import Foundation

// One line of ~/.claude/hooks/data/cc-dashboard/events.jsonl, written by
// ~/.claude/hooks/cc-dashboard-event.sh (jq, one compact object per hook call):
// {"ts":1791192060575,"event":"Stop","session_id":"…","cwd":"/…","prompt":"","stop_hook_active":false}
// `ts` is epoch milliseconds; `prompt` is always present ("" when the hook has none);
// `agent_type` is set when the tool call came from a subagent running inside the session.
// Newer hooks add where the session runs: `host_bundle` (__CFBundleIdentifier), `term_program`,
// `entrypoint` (CLAUDE_CODE_ENTRYPOINT). The OpenCode plugin writes the same format with
// `"agent":"opencode"` and the reply in `message`. Every added field is optional: old lines parse.

public struct AgentEvent: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case sessionStart = "SessionStart"
        case sessionEnd = "SessionEnd"
        case userPromptSubmit = "UserPromptSubmit"
        case postToolUse = "PostToolUse"
        case permissionRequest = "PermissionRequest"
        case stop = "Stop"
        case stopFailure = "StopFailure"
        /// The user stopped the turn (Codex `turn_aborted`, OpenCode abort): done, without a peek.
        case interrupted = "Interrupted"
    }

    public var ts: Date
    public var kind: Kind
    public var sessionID: String
    public var cwd: String
    public var toolName: String?
    public var agentType: String?
    public var prompt: String?
    public var source: String?
    public var reason: String?
    /// Which coding agent the event is about.
    public var agent: AgentKind
    /// The app the session runs in, when the source knows it.
    public var host: AgentHost?
    /// The agent's last reply (Codex, OpenCode), one line.
    public var message: String?
    /// The session's title when the source has one (OpenCode's generated title, a Codex first
    /// message found at the top of the file): replaces the title taken from the first prompt.
    public var title: String?

    /// True when the event comes from the session's main agent (not a subagent).
    public var isMainAgent: Bool { agentType == nil }

    public init(ts: Date, kind: Kind, sessionID: String, cwd: String, toolName: String? = nil,
                agentType: String? = nil, prompt: String? = nil, source: String? = nil, reason: String? = nil,
                agent: AgentKind = .claudeCode, host: AgentHost? = nil, message: String? = nil, title: String? = nil) {
        self.ts = ts; self.kind = kind; self.sessionID = sessionID; self.cwd = cwd
        self.toolName = toolName; self.agentType = agentType; self.prompt = prompt
        self.source = source; self.reason = reason
        self.agent = agent; self.host = host; self.message = message; self.title = title
    }
}

public enum AgentEventParser {
    private struct Raw: Decodable {
        let ts: Double?
        let event: String?
        let session_id: String?
        let cwd: String?
        let tool_name: String?
        let agent_type: String?
        let prompt: String?
        let source: String?
        let reason: String?
        let agent: String?
        let host_bundle: String?
        let term_program: String?
        let entrypoint: String?
        let message: String?
        let title: String?
    }

    /// Parses one JSONL line. Returns nil for blank, malformed or unknown-event lines (skipped, never fatal).
    public static func parse(_ line: String) -> AgentEvent? { parse(Data(line.utf8)) }

    public static func parse(_ data: Data) -> AgentEvent? { parse(data, decoder: JSONDecoder()) }

    private static func parse(_ data: Data, decoder: JSONDecoder) -> AgentEvent? {
        guard !data.isEmpty, let raw = try? decoder.decode(Raw.self, from: data),
              let name = raw.event, let kind = AgentEvent.Kind(rawValue: name),
              let sid = raw.session_id, !sid.isEmpty, let ms = raw.ts else { return nil }
        // An agent this build does not know yet: skipped rather than shown as Claude Code.
        let agent: AgentKind
        if let a = raw.agent.nonEmpty {
            guard let k = AgentKind(rawValue: a) else { return nil }
            agent = k
        } else {
            agent = .claudeCode
        }
        return AgentEvent(
            ts: Date(timeIntervalSince1970: ms / 1000),
            kind: kind,
            sessionID: sid,
            cwd: raw.cwd ?? "",
            toolName: raw.tool_name.nonEmpty,
            agentType: raw.agent_type.nonEmpty,
            prompt: raw.prompt.flatMap(userPrompt),
            source: raw.source.nonEmpty,
            reason: raw.reason.nonEmpty,
            agent: agent,
            host: AgentHost.detect(bundleID: raw.host_bundle, termProgram: raw.term_program, entrypoint: raw.entrypoint),
            message: raw.message.flatMap { oneLine($0, max: 200) },
            title: raw.title.flatMap { oneLine($0, max: 120) })
    }

    /// Whitespace collapsed to single spaces, cut to `max` characters (with an ellipsis). nil when empty.
    static func oneLine(_ s: String, max: Int) -> String? {
        let line = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !line.isEmpty else { return nil }
        return line.count > max ? String(line.prefix(max - 1)) + "…" : line
    }

    /// Parses every complete ("\n"-terminated) line in `buffer` and removes it, leaving any
    /// trailing partial line in place for the next read.
    public static func drain(_ buffer: inout Data) -> [AgentEvent] {
        var out: [AgentEvent] = []
        drain(&buffer) { out.append($0) }
        return out
    }

    /// The same, one event at a time: the launch rebuild folds 2 MB of lines into the session
    /// store without holding every event at once, with one decoder for all of them and the
    /// Foundation temporaries released every 256 lines, so the parse leaves no megabytes of
    /// freed-but-dirty heap behind at idle.
    public static func drain(_ buffer: inout Data, _ each: (AgentEvent) -> Void) {
        let decoder = JSONDecoder()
        var start = buffer.startIndex
        var more = true
        while more {
            autoreleasepool {
                for _ in 0..<256 {
                    guard let nl = buffer[start...].firstIndex(of: 0x0A) else { more = false; return }
                    if nl > start, let e = parse(buffer[start..<nl], decoder: decoder) { each(e) }
                    start = buffer.index(after: nl)
                }
            }
        }
        buffer = start == buffer.endIndex ? Data() : Data(buffer[start...])
    }

    /// Messages Claude Code injects as a "prompt" (background agent results, task notifications,
    /// messages from other sessions). They still start a turn, but are not what the user asked.
    static let injectedTags: Set<String> = [
        "agent-message", "task-notification", "cross-session-message", "system-reminder",
        "local-command-stdout", "local-command-caveat", "command-name", "bash-input", "bash-stdout",
    ]

    /// The user's words as one line: nil for an injected message or an empty prompt; wrapper tags
    /// such as `<pasted_content id="…">` removed; whitespace collapsed.
    static func userPrompt(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<") {
            let name = trimmed.dropFirst().prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            if injectedTags.contains(String(name)) { return nil }
        }
        // Most prompts have no tag at all: no regular expression (ICU) for them.
        let untagged = trimmed.contains("<")
            ? trimmed.replacingOccurrences(of: #"</?[a-zA-Z_][\w-]*(\s[^>]*)?>"#, with: " ", options: .regularExpression)
            : trimmed
        let line = untagged.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.isEmpty ? nil : line
    }
}

extension Optional where Wrapped == String {
    var nonEmpty: String? {
        switch self {
        case .some(let s) where !s.isEmpty: return s
        default: return nil
        }
    }
}
