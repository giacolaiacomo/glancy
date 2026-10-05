import Foundation

// The session state machine (SPEC §3 Agents). A pure value type: events and the clock go in,
// sessions and transitions come out. No timers here; the model asks `nextDeadline` and schedules
// one wake-up.

public enum AgentState: String, Sendable, CaseIterable, Comparable {
    case waiting, working, done, failed, idle, ended

    /// Attention order: what needs the user first.
    var rank: Int {
        switch self {
        case .waiting: 0
        case .working: 1
        case .done: 2
        case .failed: 3
        case .idle: 4
        case .ended: 5
        }
    }

    public static func < (a: AgentState, b: AgentState) -> Bool { a.rank < b.rank }
}

public struct AgentSession: Identifiable, Sendable, Equatable {
    /// Current Claude Code session id.
    public var id: String
    /// Stable row identity: survives `/resume` and `/clear` hand-offs in the same folder.
    public var rowID: String
    /// The folder the session belongs to (where it started; `cd` into a subfolder does not move it).
    public var projectPath: String
    /// The latest `cwd` the hooks reported.
    public var cwd: String
    public var label: String
    public var state: AgentState
    /// When the current state began (event time).
    public var stateSince: Date
    /// When the row first appeared.
    public var startedAt: Date
    public var lastEventAt: Date
    /// Start of the current (or last) turn: UserPromptSubmit, or the first activity after a pause.
    public var turnStartedAt: Date?
    /// Tool calls (main agent and subagents) in the current turn.
    public var turnTools: Int
    /// Duration of the last completed turn.
    public var lastTurnDuration: TimeInterval?
    public var lastTool: String?
    /// The subagent type that ran `lastTool`, nil when the main agent did.
    public var lastToolAgent: String?
    public var lastPrompt: String?
    /// The tool that asked for permission (while `waiting`).
    public var waitingTool: String?
    /// Who asked: nil = main agent, otherwise the subagent type. Only a PostToolUse from the same
    /// agent clears `waiting` (a background subagent's tool calls do not).
    public var waitingAgent: String?
    /// Last time a subagent did something while the main agent was not working (background agents).
    public var backgroundActivityAt: Date?
    public var endReason: String?
    /// True once a SessionStart fixed `projectPath`.
    var projectPinned = false

    public init(id: String, rowID: String, projectPath: String, cwd: String, label: String = "",
                state: AgentState, stateSince: Date, startedAt: Date, lastEventAt: Date,
                turnStartedAt: Date? = nil, turnTools: Int = 0, lastTurnDuration: TimeInterval? = nil,
                lastTool: String? = nil, lastToolAgent: String? = nil, lastPrompt: String? = nil,
                waitingTool: String? = nil, waitingAgent: String? = nil,
                backgroundActivityAt: Date? = nil, endReason: String? = nil) {
        self.id = id; self.rowID = rowID; self.projectPath = projectPath; self.cwd = cwd
        self.label = label; self.state = state; self.stateSince = stateSince
        self.startedAt = startedAt; self.lastEventAt = lastEventAt; self.turnStartedAt = turnStartedAt
        self.turnTools = turnTools; self.lastTurnDuration = lastTurnDuration; self.lastTool = lastTool
        self.lastToolAgent = lastToolAgent; self.lastPrompt = lastPrompt; self.waitingTool = waitingTool
        self.waitingAgent = waitingAgent; self.backgroundActivityAt = backgroundActivityAt
        self.endReason = endReason
    }

    public var isLive: Bool { state != .ended }

    /// done/failed are "fresh" (green/red in the wings) for `AgentSessionStore.freshFor`.
    public func isFresh(at now: Date) -> Bool {
        (state == .done || state == .failed) && now.timeIntervalSince(stateSince) < AgentSessionStore.freshFor
    }
}

/// Something worth a peek. Emitted only for live transitions (the model drops them during rebuild).
public enum AgentTransition: Sendable, Equatable {
    case finished(rowID: String, label: String, duration: TimeInterval?, tools: Int)
    case needsYou(rowID: String, label: String, tool: String?)
}

public struct AgentSessionStore: Sendable {
    public static let staleAfter: TimeInterval = 30 * 60
    public static let endedRemovedAfter: TimeInterval = 10 * 60
    public static let freshFor: TimeInterval = 2 * 60
    /// Sessions silent this long are dropped (terminal closed without SessionEnd). Not in SPEC; see report.
    public static let forgetAfter: TimeInterval = 12 * 3600
    /// SessionEnd(resume|clear) → SessionStart in the same folder within this window = same row.
    public static let handoffWindow: TimeInterval = 15

    public private(set) var sessions: [String: AgentSession] = [:]
    private var handoffs: [String: (rowID: String, sessionID: String, at: Date)] = [:]
    /// Labels depend only on (id, projectPath, startedAt, live): recompute only when one changes.
    private var labelInputs: [String: LabelInput] = [:]

    public init() {}

    // MARK: Events

    @discardableResult
    public mutating func apply(_ e: AgentEvent) -> [AgentTransition] {
        var transitions: [AgentTransition] = []
        let isNew = sessions[e.sessionID] == nil
        if isNew {
            // An unknown session that only reports its end carries no information.
            guard e.kind != .sessionEnd else { return [] }
            sessions[e.sessionID] = makeSession(for: e)
        }
        guard var s = sessions[e.sessionID] else { return [] }
        let wasEnded = s.state == .ended
        s.lastEventAt = max(s.lastEventAt, e.ts)
        if !e.cwd.isEmpty { adoptCWD(e.cwd, into: &s, pin: e.kind == .sessionStart) }

        // Out-of-order guard: hooks run concurrently, so a line can land after a later one.
        // An event older than the current state never changes the state (claude-island #98).
        let inOrder = e.ts >= s.stateSince

        switch e.kind {
        case .sessionStart:
            if s.state == .ended && inOrder { set(&s, .idle, at: e.ts) }
            if isNew || wasEnded, e.source == "resume" || e.source == "clear" { claimHandoff(for: &s, at: e.ts) }

        case .userPromptSubmit:
            if let p = e.prompt { s.lastPrompt = p }
            if inOrder {
                s.turnStartedAt = e.ts
                s.turnTools = 0
                set(&s, .working, at: e.ts)
            }

        case .postToolUse:
            s.lastTool = e.toolName
            s.lastToolAgent = e.agentType
            if s.state == .working || s.state == .waiting { s.turnTools += 1 }
            guard inOrder else { break }
            if s.state == .waiting {
                if e.agentType == s.waitingAgent { set(&s, .working, at: e.ts) }
            } else if e.isMainAgent {
                if s.state != .working {
                    // The main agent resumed without a prompt (e.g. a background task reported back).
                    s.turnStartedAt = e.ts
                    s.turnTools = 1
                    set(&s, .working, at: e.ts)
                }
            } else if s.state != .working {
                s.backgroundActivityAt = e.ts
            }

        case .permissionRequest:
            guard inOrder else { break }
            if s.turnStartedAt == nil { s.turnStartedAt = e.ts }
            s.waitingTool = e.toolName
            s.waitingAgent = e.agentType
            if s.state != .waiting {
                set(&s, .waiting, at: e.ts)
                transitions.append(.needsYou(rowID: s.rowID, label: s.label, tool: e.toolName))
            }

        case .stop:
            // A Stop does not clear a failure: only new work (prompt / tool use) does.
            guard inOrder, s.state != .done, s.state != .failed, s.state != .ended else { break }
            let duration = s.turnStartedAt.map { e.ts.timeIntervalSince($0) }
            let hadTurn = s.state == .working || s.state == .waiting
            s.lastTurnDuration = duration
            set(&s, .done, at: e.ts)
            if hadTurn {
                transitions.append(.finished(rowID: s.rowID, label: s.label, duration: duration, tools: s.turnTools))
            }

        case .stopFailure:
            // A failure wins over a Stop that landed just before it for the same turn.
            let sameTurn = s.state == .done && e.ts.timeIntervalSince(s.stateSince) < 5
            guard inOrder || sameTurn, s.state != .failed, s.state != .ended else { break }
            if let t = s.turnStartedAt { s.lastTurnDuration = e.ts.timeIntervalSince(t) }
            set(&s, .failed, at: e.ts)

        case .sessionEnd:
            guard inOrder else { break }
            s.endReason = e.reason
            set(&s, .ended, at: e.ts)
            if e.reason == "resume" || e.reason == "clear" {
                handoffs[s.projectPath] = (s.rowID, s.id, e.ts)
            }
        }

        sessions[s.id] = s
        relabelIfNeeded()
        // Labels may have changed with this event: report the final ones.
        return transitions.map { t in
            switch t {
            case let .finished(row, _, d, n): .finished(rowID: row, label: label(ofRow: row), duration: d, tools: n)
            case let .needsYou(row, _, tool): .needsYou(rowID: row, label: label(ofRow: row), tool: tool)
            }
        }
    }

    private func makeSession(for e: AgentEvent) -> AgentSession {
        let state: AgentState = switch e.kind {
        case .sessionStart: .idle
        case .userPromptSubmit, .postToolUse: .working
        case .permissionRequest: .waiting
        case .stop: .done
        case .stopFailure: .failed
        case .sessionEnd: .ended
        }
        // A session first seen mid-turn starts its turn now; `stateSince` is the event time so the
        // first event itself is "in order".
        return AgentSession(
            id: e.sessionID, rowID: e.sessionID, projectPath: e.cwd, cwd: e.cwd,
            state: state, stateSince: e.ts, startedAt: e.ts, lastEventAt: e.ts,
            turnStartedAt: (state == .working || state == .waiting) ? e.ts : nil)
    }

    private func set(_ s: inout AgentSession, _ state: AgentState, at t: Date) {
        if state != .waiting { s.waitingTool = nil; s.waitingAgent = nil }
        if state == .working { s.backgroundActivityAt = nil }
        if state != .ended { s.endReason = nil }
        guard s.state != state else { return }
        s.state = state
        s.stateSince = t
    }

    /// The project folder is where the session started (SessionStart pins it); `cd`, worktrees
    /// and subfolders never move it. A session first seen mid-stream (its start fell outside the
    /// rebuild window) widens to an ancestor folder when one shows up.
    private func adoptCWD(_ cwd: String, into s: inout AgentSession, pin: Bool) {
        s.cwd = cwd
        if pin {
            s.projectPath = cwd; s.projectPinned = true
        } else if !s.projectPinned, s.projectPath.hasPrefix(cwd.withSlash) {
            s.projectPath = cwd
        }
    }

    /// `/resume` and `/clear` end one session id and start another in the same folder: keep the row.
    private mutating func claimHandoff(for s: inout AgentSession, at t: Date) {
        guard let h = handoffs[s.projectPath], h.sessionID != s.id,
              t.timeIntervalSince(h.at) <= Self.handoffWindow, t >= h.at else { return }
        handoffs[s.projectPath] = nil
        let previous = sessions.removeValue(forKey: h.sessionID)
        s.rowID = h.rowID
        if let p = previous {
            s.startedAt = p.startedAt
            s.lastPrompt = s.lastPrompt ?? p.lastPrompt
            s.lastTool = s.lastTool ?? p.lastTool
        }
    }

    // MARK: Clock

    /// Applies time-based transitions: stale → idle, ended rows removed, silent rows forgotten.
    /// Returns true when anything changed.
    @discardableResult
    public mutating func expire(now: Date) -> Bool {
        var changed = false
        for (id, var s) in sessions {
            let silent = now.timeIntervalSince(s.lastEventAt)
            if s.state == .ended {
                if now.timeIntervalSince(s.stateSince) >= Self.endedRemovedAfter {
                    sessions[id] = nil; changed = true
                }
            } else if silent >= Self.forgetAfter {
                sessions[id] = nil; changed = true
            } else if silent >= Self.staleAfter, s.state != .waiting, s.state != .idle {
                set(&s, .idle, at: s.lastEventAt.addingTimeInterval(Self.staleAfter))
                sessions[id] = s; changed = true
            }
        }
        handoffs = handoffs.filter { now.timeIntervalSince($0.value.at) <= Self.handoffWindow }
        if changed { relabelIfNeeded() }
        return changed
    }

    /// The next instant at which `expire` or the "fresh" colour would change something.
    public func nextDeadline(after now: Date) -> Date? {
        var best: Date?
        func consider(_ d: Date) { if d > now, best.map({ d < $0 }) ?? true { best = d } }
        for s in sessions.values {
            switch s.state {
            case .ended:
                consider(s.stateSince.addingTimeInterval(Self.endedRemovedAfter))
            case .working, .done, .failed:
                consider(s.lastEventAt.addingTimeInterval(Self.staleAfter))
                if s.state != .working { consider(s.stateSince.addingTimeInterval(Self.freshFor)) }
                consider(s.lastEventAt.addingTimeInterval(Self.forgetAfter))
            case .waiting, .idle:
                consider(s.lastEventAt.addingTimeInterval(Self.forgetAfter))
            }
        }
        return best
    }

    // MARK: Views of the state

    /// Live sessions (not ended), oldest row first: the stable order of the wing dots.
    public var live: [AgentSession] {
        sessions.values.filter(\.isLive).sorted { ($0.startedAt, $0.rowID) < ($1.startedAt, $1.rowID) }
    }

    /// Board order: what needs you first, then by label.
    public var board: [AgentSession] {
        sessions.values.sorted {
            $0.state != $1.state ? $0.state < $1.state
                : ($0.label.localizedLowercase, $0.rowID) < ($1.label.localizedLowercase, $1.rowID)
        }
    }

    public func session(rowID: String) -> AgentSession? {
        sessions.values.first { $0.rowID == rowID }
    }

    private func label(ofRow row: String) -> String { session(rowID: row)?.label ?? "" }

    // MARK: Labels

    /// Last path component of the project folder; when two sessions in different folders share it,
    /// prefix parents until they differ; when two live sessions share the folder, number them.
    mutating func relabelIfNeeded() {
        let inputs = sessions.mapValues { LabelInput(path: $0.projectPath, started: $0.startedAt, live: $0.isLive) }
        guard inputs != labelInputs else { return }
        labelInputs = inputs
        let labels = Self.labels(for: sessions.values.map { ($0.id, $0.projectPath, $0.startedAt, $0.isLive) })
        for (id, l) in labels where sessions[id]?.label != l { sessions[id]?.label = l }
    }

    struct LabelInput: Equatable, Sendable {
        let path: String
        let started: Date
        let live: Bool
    }

    static func labels(for items: [(id: String, path: String, started: Date, live: Bool)]) -> [String: String] {
        let home = NSHomeDirectory()
        func components(_ p: String) -> [String] {
            p == home ? ["~"] : p.split(separator: "/").map(String.init)
        }
        var out: [String: String] = [:]
        let byName = Dictionary(grouping: items) { components($0.path).last ?? "/" }
        for (name, group) in byName {
            let paths = Set(group.map(\.path))
            var pathLabel: [String: String] = [:]
            if paths.count == 1 {
                pathLabel[group[0].path] = name
            } else {
                for p in paths {
                    let mine = components(p)
                    var k = 2
                    while k < mine.count {
                        let suffix = mine.suffix(k)
                        let clash = paths.contains { $0 != p && Array(components($0).suffix(k)) == Array(suffix) }
                        if !clash { break }
                        k += 1
                    }
                    pathLabel[p] = mine.suffix(k).joined(separator: "/")
                }
            }
            // Several live sessions in the very same folder: "api", "api 2", …
            for (path, same) in Dictionary(grouping: group, by: \.path) {
                let base = pathLabel[path] ?? name
                let liveOnes = same.filter(\.live).sorted { ($0.started, $0.id) < ($1.started, $1.id) }
                for (i, item) in liveOnes.enumerated() { out[item.id] = i == 0 ? base : "\(base) \(i + 1)" }
                for item in same where !item.live { out[item.id] = base }
            }
        }
        return out
    }
}

extension String {
    var withSlash: String { hasSuffix("/") ? self : self + "/" }
}
