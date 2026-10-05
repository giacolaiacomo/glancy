import Foundation
import Testing
@testable import GlancyKit

// Near the real clock: the hub drops activities whose `expires` is already past.
let t0 = Date(timeIntervalSince1970: (Date.now.timeIntervalSince1970).rounded(.down))

func ev(_ kind: AgentEvent.Kind, _ sid: String, _ sec: TimeInterval, cwd: String = "/Users/dev/Projects/web-app",
        tool: String? = nil, agent: String? = nil, prompt: String? = nil,
        source: String? = nil, reason: String? = nil) -> AgentEvent {
    AgentEvent(ts: t0.addingTimeInterval(sec), kind: kind, sessionID: sid, cwd: cwd, toolName: tool,
               agentType: agent, prompt: prompt, source: source, reason: reason)
}

extension AgentSessionStore {
    mutating func feed(_ events: [AgentEvent]) -> [AgentTransition] { events.flatMap { apply($0) } }
    func state(_ sid: String) -> AgentState? { sessions[sid]?.state }
}

@Test func basicLifecycle() {
    var s = AgentSessionStore()
    s.apply(ev(.sessionStart, "a", 0, source: "startup"))
    #expect(s.state("a") == .idle)
    s.apply(ev(.userPromptSubmit, "a", 10, prompt: "fix the build"))
    #expect(s.state("a") == .working)
    #expect(s.sessions["a"]?.lastPrompt == "fix the build")
    s.apply(ev(.postToolUse, "a", 20, tool: "Bash"))
    #expect(s.sessions["a"]?.lastTool == "Bash")
    let tr = s.apply(ev(.stop, "a", 262))
    #expect(s.state("a") == .done)
    #expect(tr == [.finished(rowID: "a", label: "web-app", duration: 252, tools: 1)])
    s.apply(ev(.sessionEnd, "a", 300, reason: "prompt_input_exit"))
    #expect(s.state("a") == .ended)
    #expect(s.live.isEmpty)
}

@Test func permissionThenPostToolUseClearsWaiting() {
    var s = AgentSessionStore()
    s.apply(ev(.userPromptSubmit, "a", 0, prompt: "deploy"))
    let tr = s.apply(ev(.permissionRequest, "a", 5, tool: "Bash"))
    #expect(s.state("a") == .waiting)
    #expect(tr == [.needsYou(rowID: "a", label: "web-app", tool: "Bash")])
    // A duplicate request while already waiting does not peek again.
    #expect(s.apply(ev(.permissionRequest, "a", 6, tool: "Bash")).isEmpty)
    s.apply(ev(.postToolUse, "a", 40, tool: "Bash"))
    #expect(s.state("a") == .working)
    #expect(s.sessions["a"]?.waitingTool == nil)
}

@Test func backgroundSubagentDoesNotClearMainAgentWaiting() {
    // Real pattern: main agent asks (AskUserQuestion) while a background subagent keeps working.
    var s = AgentSessionStore()
    s.apply(ev(.userPromptSubmit, "a", 0))
    s.apply(ev(.permissionRequest, "a", 5, tool: "AskUserQuestion"))
    s.apply(ev(.postToolUse, "a", 6, tool: "WebSearch", agent: "general-purpose"))
    s.apply(ev(.postToolUse, "a", 7, tool: "WebFetch", agent: "general-purpose"))
    #expect(s.state("a") == .waiting)
    s.apply(ev(.postToolUse, "a", 60, tool: "AskUserQuestion"))
    #expect(s.state("a") == .working)
}

@Test func subagentPermissionIsClearedBySameSubagent() {
    var s = AgentSessionStore()
    s.apply(ev(.userPromptSubmit, "a", 0))
    s.apply(ev(.permissionRequest, "a", 5, tool: "Bash", agent: "executor"))
    s.apply(ev(.postToolUse, "a", 6, tool: "Read", agent: "Explore"))
    #expect(s.state("a") == .waiting)
    s.apply(ev(.postToolUse, "a", 9, tool: "Bash", agent: "executor"))
    #expect(s.state("a") == .working)
}

@Test func stopClearsWaiting() {
    var s = AgentSessionStore()
    s.apply(ev(.userPromptSubmit, "a", 0))
    s.apply(ev(.permissionRequest, "a", 5, tool: "AskUserQuestion"))
    let tr = s.apply(ev(.stop, "a", 34))
    #expect(s.state("a") == .done)
    #expect(tr.count == 1)
}

@Test func lateToolUseAfterStopDoesNotReopenTheTurn() {
    // claude-island #98: a PostToolUse line written after Stop but stamped before it.
    var s = AgentSessionStore()
    s.apply(ev(.userPromptSubmit, "a", 0))
    s.apply(ev(.stop, "a", 30))
    s.apply(ev(.postToolUse, "a", 29.9, tool: "Bash"))
    #expect(s.state("a") == .done)
    #expect(s.sessions["a"]?.lastTool == "Bash")      // metadata still updates
}

@Test func backgroundAgentsAfterStopKeepDoneButMainAgentResumes() {
    var s = AgentSessionStore()
    s.apply(ev(.userPromptSubmit, "a", 0))
    s.apply(ev(.stop, "a", 30))
    s.apply(ev(.postToolUse, "a", 31, tool: "Bash", agent: "executor"))
    #expect(s.state("a") == .done)
    #expect(s.sessions["a"]?.backgroundActivityAt == t0.addingTimeInterval(31))
    // The background agent reports back and the main agent continues without a prompt.
    s.apply(ev(.postToolUse, "a", 90, tool: "Read"))
    #expect(s.state("a") == .working)
    #expect(s.sessions["a"]?.turnStartedAt == t0.addingTimeInterval(90))
    let tr = s.apply(ev(.stop, "a", 120))
    #expect(tr == [.finished(rowID: "a", label: "web-app", duration: 30, tools: 1)])
}

@Test func stopAfterStopFailureStaysFailed() {
    var s = AgentSessionStore()
    s.apply(ev(.userPromptSubmit, "a", 0))
    s.apply(ev(.stopFailure, "a", 10))
    #expect(s.state("a") == .failed)
    #expect(s.apply(ev(.stop, "a", 10.5)).isEmpty)
    #expect(s.state("a") == .failed)
    s.apply(ev(.stopFailure, "a", 11))                   // repeated failure: still one state
    #expect(s.state("a") == .failed)
    // New work clears the failure.
    s.apply(ev(.postToolUse, "a", 40, tool: "Bash"))
    #expect(s.state("a") == .working)
}

@Test func stopFailureRightAfterStopWins() {
    var s = AgentSessionStore()
    s.apply(ev(.userPromptSubmit, "a", 0))
    s.apply(ev(.stop, "a", 10))
    s.apply(ev(.stopFailure, "a", 9.9))                  // same turn, landed second
    #expect(s.state("a") == .failed)
}

@Test func resumeHandoffKeepsTheProjectRow() {
    var s = AgentSessionStore()
    s.apply(ev(.sessionStart, "old", 0, source: "startup"))
    s.apply(ev(.userPromptSubmit, "old", 5, prompt: "first prompt"))
    s.apply(ev(.stop, "old", 50))
    s.apply(ev(.sessionEnd, "old", 100, reason: "resume"))
    s.apply(ev(.sessionStart, "new", 100.3, source: "resume"))
    #expect(s.sessions["old"] == nil)                    // no ghost "ended" row
    let row = s.sessions["new"]
    #expect(row?.rowID == "old")
    #expect(row?.startedAt == t0)
    #expect(row?.lastPrompt == "first prompt")
    #expect(row?.label == "web-app")
    #expect(s.live.count == 1)
    s.apply(ev(.userPromptSubmit, "new", 110, prompt: "again"))
    #expect(s.session(rowID: "old")?.state == .working)
}

@Test func resumeIntoAPreviouslyEndedSessionId() {
    var s = AgentSessionStore()
    s.apply(ev(.sessionStart, "b", 0, source: "startup"))
    s.apply(ev(.sessionEnd, "b", 10, reason: "prompt_input_exit"))
    s.apply(ev(.sessionStart, "a", 20, source: "startup"))
    s.apply(ev(.sessionEnd, "a", 30, reason: "resume"))
    s.apply(ev(.sessionStart, "b", 30.2, source: "resume"))
    #expect(s.sessions["a"] == nil)
    #expect(s.state("b") == .idle)
    #expect(s.sessions["b"]?.rowID == "a")
    #expect(s.live.count == 1)
}

@Test func handoffNeedsSameFolderAndShortGap() {
    var s = AgentSessionStore()
    s.apply(ev(.sessionStart, "a", 0, cwd: "/x/site"))
    s.apply(ev(.sessionEnd, "a", 10, cwd: "/x/site", reason: "resume"))
    s.apply(ev(.sessionStart, "b", 10.5, cwd: "/x/web-app", source: "resume"))   // other folder
    s.apply(ev(.sessionStart, "c", 60, cwd: "/x/site", source: "resume"))          // too late
    #expect(s.sessions["b"]?.rowID == "b")
    #expect(s.sessions["c"]?.rowID == "c")
    #expect(s.state("a") == .ended)
}

@Test func compactKeepsWorking() {
    var s = AgentSessionStore()
    s.apply(ev(.userPromptSubmit, "a", 0))
    s.apply(ev(.sessionStart, "a", 100, source: "compact"))
    #expect(s.state("a") == .working)
}

@Test func staleIdleAndEndedRemoval() {
    var s = AgentSessionStore()
    s.apply(ev(.userPromptSubmit, "work", 0))
    s.apply(ev(.userPromptSubmit, "wait", 0, cwd: "/x/site"))
    s.apply(ev(.permissionRequest, "wait", 1, cwd: "/x/site", tool: "Bash"))
    s.apply(ev(.sessionStart, "gone", 0, cwd: "/x/Old"))
    s.apply(ev(.sessionEnd, "gone", 2, cwd: "/x/Old", reason: "other"))

    // First deadline: the ended row's removal at 2 + 600 s.
    #expect(s.nextDeadline(after: t0.addingTimeInterval(3)) == t0.addingTimeInterval(602))
    let removed = s.expire(now: t0.addingTimeInterval(602))
    #expect(removed)
    #expect(s.sessions["gone"] == nil)

    // Next: stale at 30'.
    #expect(s.nextDeadline(after: t0.addingTimeInterval(602)) == t0.addingTimeInterval(1800))
    let early = s.expire(now: t0.addingTimeInterval(1799))
    #expect(!early)
    let stale = s.expire(now: t0.addingTimeInterval(1800))
    #expect(stale)
    #expect(s.state("work") == .idle)
    #expect(s.state("wait") == .waiting)                 // waiting never goes stale
    #expect(s.sessions["work"]?.stateSince == t0.addingTimeInterval(1800))
}

@Test func freshDoneDeadline() {
    var s = AgentSessionStore()
    s.apply(ev(.userPromptSubmit, "a", 0))
    s.apply(ev(.stop, "a", 10))
    #expect(s.sessions["a"]!.isFresh(at: t0.addingTimeInterval(129)))
    #expect(!s.sessions["a"]!.isFresh(at: t0.addingTimeInterval(130)))
    #expect(s.nextDeadline(after: t0.addingTimeInterval(11)) == t0.addingTimeInterval(130))
}

@Test func projectFolderIsPinnedAtStartAndCwdMovesFreely() {
    var s = AgentSessionStore()
    s.apply(ev(.sessionStart, "a", 0, cwd: "/x/tessera"))
    s.apply(ev(.postToolUse, "a", 1, cwd: "/x", tool: "Bash"))
    s.apply(ev(.postToolUse, "a", 2, cwd: "/x/tessera/Sources", tool: "Bash"))
    #expect(s.sessions["a"]?.label == "tessera")
    #expect(s.sessions["a"]?.cwd == "/x/tessera/Sources")
    // Seen mid-stream (start outside the window): widens to an ancestor that shows up.
    s.apply(ev(.postToolUse, "b", 3, cwd: "/y/web-app/evals/bench", tool: "Bash"))
    s.apply(ev(.postToolUse, "b", 4, cwd: "/y/web-app", tool: "Bash"))
    #expect(s.sessions["b"]?.label == "web-app")
}

@MainActor @Test func modelPostsActivityAndPeeks() async {
    let hub = ActivityHub()
    let model = AgentsModel()
    model.hub = hub
    model.now = { t0.addingTimeInterval(20) }
    model.ingest([ev(.userPromptSubmit, "a", 0), ev(.postToolUse, "a", 1, tool: "Bash")], rebuild: true)
    #expect(hub.top?.priority == 50)
    #expect(hub.peek == nil)                             // rebuild never peeks
    #expect(model.summary == AgentWingSummary(state: .working, count: 1))

    model.ingest([ev(.permissionRequest, "a", 15, tool: "Bash")], rebuild: false)
    #expect(hub.top?.priority == 90)
    #expect(hub.peek?.module == .agents)
    #expect(model.dots == [AgentDot(id: "a", state: .waiting, fresh: false)])

    model.visibilityChanged(.collapsed)
    #expect(!model.pulse)
    model.visibilityChanged(.expanded(.agents))
    #expect(model.pulse)
    model.visibilityChanged(.hidden)
    #expect(!model.pulse)

    model.now = { t0.addingTimeInterval(30) }
    model.ingest([ev(.stop, "a", 30)], rebuild: false)
    #expect(model.summary == AgentWingSummary(state: .done, count: 1))
    #expect(hub.top?.expires == t0.addingTimeInterval(150))
    #expect(model.scheduledWake == t0.addingTimeInterval(150))
    model.reset()
}
