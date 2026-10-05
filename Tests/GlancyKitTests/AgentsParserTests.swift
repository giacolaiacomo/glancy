import Foundation
import Testing
@testable import GlancyKit

// Lines copied from the real cc-dashboard log, cwd anonymised.
enum AgentsFixtures {
    static let lines = [
        #"{"ts":1790986676137,"event":"SessionEnd","session_id":"d1ed2c91-3be1-4ffd-bff1-796469bf7390","cwd":"/Users/dev/Projects/web-app","prompt":"","reason":"resume"}"#,
        #"{"ts":1790986676391,"event":"SessionStart","session_id":"d4f52575-6e7e-43b6-af28-92b7a8f18797","cwd":"/Users/dev/Projects/web-app","prompt":"","source":"resume"}"#,
        #"{"ts":1790986690768,"event":"UserPromptSubmit","session_id":"d4f52575-6e7e-43b6-af28-92b7a8f18797","cwd":"/Users/dev/Projects/web-app","prompt":"done but I still see the old page\non example.com?"}"#,
        #"{"ts":1790986717481,"event":"PostToolUse","session_id":"d4f52575-6e7e-43b6-af28-92b7a8f18797","cwd":"/Users/dev/Projects/web-app","tool_name":"Bash","prompt":""}"#,
        #"{"ts":1791192009742,"event":"PostToolUse","session_id":"00f34ea5-6f0d-41ce-8bfe-8f986210770a","cwd":"/Users/dev/Projects/web-app","tool_name":"Read","agent_type":"executor","prompt":""}"#,
        #"{"ts":1790963579693,"event":"PermissionRequest","session_id":"06fc17fd-5088-4191-be8d-b47de77af0e6","cwd":"/Users/dev/app/website","tool_name":"AskUserQuestion","prompt":""}"#,
        #"{"ts":1791192060575,"event":"Stop","session_id":"6d598f82-b648-451f-84dc-82043f28c9ef","cwd":"/Users/dev/app/website","prompt":"","stop_hook_active":false}"#,
        #"{"ts":1791066830729,"event":"StopFailure","session_id":"00f34ea5-6f0d-41ce-8bfe-8f986210770a","cwd":"/Users/dev/Projects/web-app/evals/bench","prompt":""}"#,
    ]
}

@Test func parsesEveryRealEventShape() throws {
    let events = AgentsFixtures.lines.compactMap(AgentEventParser.parse)
    #expect(events.count == AgentsFixtures.lines.count)

    let end = events[0]
    #expect(end.kind == .sessionEnd)
    #expect(end.reason == "resume")
    #expect(end.ts == Date(timeIntervalSince1970: 1790986676.137))
    #expect(end.prompt == nil)                      // "" is "no prompt"

    #expect(events[1].source == "resume")
    #expect(events[2].prompt == "done but I still see the old page on example.com?")   // one line
    #expect(events[3].toolName == "Bash")
    #expect(events[3].isMainAgent)
    #expect(events[4].agentType == "executor")
    #expect(!events[4].isMainAgent)
    #expect(events[5].kind == .permissionRequest)
    #expect(events[5].toolName == "AskUserQuestion")
    #expect(events[6].kind == .stop)
    #expect(events[7].kind == .stopFailure)
    #expect(events[7].cwd == "/Users/dev/Projects/web-app/evals/bench")
}

@Test func skipsBlankMalformedAndUnknownLines() {
    #expect(AgentEventParser.parse("") == nil)
    #expect(AgentEventParser.parse("{\"ts\":1,\"event\":\"Stop\"") == nil)                       // truncated
    #expect(AgentEventParser.parse(#"{"ts":1,"event":"Notification","session_id":"a","cwd":"/x"}"#) == nil)
    #expect(AgentEventParser.parse(#"{"ts":1,"event":"Stop","cwd":"/x"}"#) == nil)              // no session
    #expect(AgentEventParser.parse(#"{"event":"Stop","session_id":"a","cwd":"/x"}"#) == nil)    // no ts
}

@Test func drainKeepsThePartialLine() {
    var buf = Data((AgentsFixtures.lines[2] + "\n" + AgentsFixtures.lines[3] + "\n" + "garbage\n" + AgentsFixtures.lines[6].prefix(40)).utf8)
    let events = AgentEventParser.drain(&buf)
    #expect(events.map(\.kind) == [.userPromptSubmit, .postToolUse])
    #expect(String(decoding: buf, as: UTF8.self) == String(AgentsFixtures.lines[6].prefix(40)))
    buf.append(Data((AgentsFixtures.lines[6].dropFirst(40) + "\n").utf8))
    #expect(AgentEventParser.drain(&buf).map(\.kind) == [.stop])
    #expect(buf.isEmpty)
}

@Test func injectedMessagesAreNotUserPrompts() {
    #expect(AgentEventParser.userPrompt("<agent-message from=\"a7236dd03bc14c580\">\n[Subagent report]") == nil)
    #expect(AgentEventParser.userPrompt("<task-notification>\n<task-id>x</task-id>") == nil)
    #expect(AgentEventParser.userPrompt("<cross-session-message from=\"s\">hi") == nil)
    #expect(AgentEventParser.userPrompt("<pasted_content id=\"2a13\"> Secondo me dobbiamo") == "Secondo me dobbiamo")
    #expect(AgentEventParser.userPrompt("  vai\n riprendi ") == "vai riprendi")
    #expect(AgentEventParser.userPrompt("use a <div> here") == "use a here")
    #expect(AgentEventParser.userPrompt("x < y and y > z") == "x < y and y > z")
}

@Test func injectedPromptStartsATurnButKeepsTheUserPrompt() {
    var s = AgentSessionStore()
    s.apply(AgentEventParser.parse(#"{"ts":1000,"event":"UserPromptSubmit","session_id":"a","cwd":"/x/site","prompt":"ship it"}"#)!)
    s.apply(AgentEventParser.parse(#"{"ts":2000,"event":"Stop","session_id":"a","cwd":"/x/site","prompt":""}"#)!)
    s.apply(AgentEventParser.parse(#"{"ts":3000,"event":"UserPromptSubmit","session_id":"a","cwd":"/x/site","prompt":"<agent-message from=\"a1\">done"}"#)!)
    #expect(s.sessions["a"]?.state == .working)
    #expect(s.sessions["a"]?.lastPrompt == "ship it")
}
