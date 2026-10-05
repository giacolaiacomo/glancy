import Foundation

// One line of ~/.claude/hooks/data/cc-dashboard/events.jsonl, written by
// ~/.claude/hooks/cc-dashboard-event.sh (jq, one compact object per hook call):
// {"ts":1791192060575,"event":"Stop","session_id":"…","cwd":"/…","prompt":"","stop_hook_active":false}
// `ts` is epoch milliseconds; `prompt` is always present ("" when the hook has none);
// `agent_type` is set when the tool call came from a subagent running inside the session.

public struct AgentEvent: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case sessionStart = "SessionStart"
        case sessionEnd = "SessionEnd"
        case userPromptSubmit = "UserPromptSubmit"
        case postToolUse = "PostToolUse"
        case permissionRequest = "PermissionRequest"
        case stop = "Stop"
        case stopFailure = "StopFailure"
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

    /// True when the event comes from the session's main agent (not a subagent).
    public var isMainAgent: Bool { agentType == nil }

    public init(ts: Date, kind: Kind, sessionID: String, cwd: String, toolName: String? = nil,
                agentType: String? = nil, prompt: String? = nil, source: String? = nil, reason: String? = nil) {
        self.ts = ts; self.kind = kind; self.sessionID = sessionID; self.cwd = cwd
        self.toolName = toolName; self.agentType = agentType; self.prompt = prompt
        self.source = source; self.reason = reason
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
    }

    /// Parses one JSONL line. Returns nil for blank, malformed or unknown-event lines (skipped, never fatal).
    public static func parse(_ line: String) -> AgentEvent? { parse(Data(line.utf8)) }

    public static func parse(_ data: Data) -> AgentEvent? {
        guard !data.isEmpty, let raw = try? JSONDecoder().decode(Raw.self, from: data),
              let name = raw.event, let kind = AgentEvent.Kind(rawValue: name),
              let sid = raw.session_id, !sid.isEmpty, let ms = raw.ts else { return nil }
        return AgentEvent(
            ts: Date(timeIntervalSince1970: ms / 1000),
            kind: kind,
            sessionID: sid,
            cwd: raw.cwd ?? "",
            toolName: raw.tool_name.nonEmpty,
            agentType: raw.agent_type.nonEmpty,
            prompt: raw.prompt.flatMap(userPrompt),
            source: raw.source.nonEmpty,
            reason: raw.reason.nonEmpty)
    }

    /// Parses every complete ("\n"-terminated) line in `buffer` and removes it, leaving any
    /// trailing partial line in place for the next read.
    public static func drain(_ buffer: inout Data) -> [AgentEvent] {
        var out: [AgentEvent] = []
        var start = buffer.startIndex
        while let nl = buffer[start...].firstIndex(of: 0x0A) {
            if nl > start, let e = parse(Data(buffer[start..<nl])) { out.append(e) }
            start = buffer.index(after: nl)
        }
        buffer = start == buffer.endIndex ? Data() : Data(buffer[start...])
        return out
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
        let untagged = trimmed.replacingOccurrences(of: #"</?[a-zA-Z_][\w-]*(\s[^>]*)?>"#, with: " ", options: .regularExpression)
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
