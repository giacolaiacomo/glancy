import Foundation
import Testing
@testable import GlancyKit

@Test func labelIsTheLastPathComponent() {
    var s = AgentSessionStore()
    s.apply(ev(.sessionStart, "a", 0, cwd: "/Users/dev/Projects/web-app"))
    s.apply(ev(.sessionStart, "b", 1, cwd: "/Users/dev/Projects/site"))
    #expect(s.sessions["a"]?.label == "web-app")
    #expect(s.sessions["b"]?.label == "site")
}

@Test func sameNameInDifferentFoldersGetsTheParent() {
    var s = AgentSessionStore()
    s.apply(ev(.sessionStart, "a", 0, cwd: "/Users/dev/work/api"))
    s.apply(ev(.sessionStart, "b", 1, cwd: "/Users/dev/side/api"))
    #expect(s.sessions["a"]?.label == "work/api")
    #expect(s.sessions["b"]?.label == "side/api")
    // When one goes away the other is plain again.
    s.apply(ev(.sessionEnd, "b", 2, cwd: "/Users/dev/side/api", reason: "other"))
    s.expire(now: t0.addingTimeInterval(2 + AgentSessionStore.endedRemovedAfter))
    #expect(s.sessions["a"]?.label == "api")
}

@Test func sameParentTooClimbsFurther() {
    let l = AgentSessionStore.labels(for: [
        ("a", "/one/x/app", t0, true),
        ("b", "/two/x/app", t0, true),
        ("c", "/two/y/app", t0, true),
    ])
    #expect(l["a"] == "one/x/app")
    #expect(l["b"] == "two/x/app")
    #expect(l["c"] == "y/app")
}

@Test func twoLiveSessionsInTheSameFolderAreNumbered() {
    var s = AgentSessionStore()
    s.apply(ev(.sessionStart, "a", 0, cwd: "/x/site"))
    s.apply(ev(.sessionStart, "b", 5, cwd: "/x/site", source: "startup"))
    #expect(s.sessions["a"]?.label == "site")
    #expect(s.sessions["b"]?.label == "site 2")
}

@Test func worktreeSessionIsLabelledByItsFolder() {
    var s = AgentSessionStore()
    s.apply(ev(.sessionStart, "a", 0, cwd: "/x/website/.claude/worktrees/fix-header-v2"))
    #expect(s.sessions["a"]?.label == "fix-header-v2")
}

@Test func windowScoring() {
    let p = "/Users/dev/Projects/site"
    #expect(TerminalJumper.score(title: "", document: "file:///Users/dev/Projects/site/", projectPath: p, cwd: p, label: "site") == 100)
    #expect(TerminalJumper.score(title: "dev@mac: ~/Projects/site — zsh", document: nil, projectPath: p, cwd: p, label: "site") == 50)
    #expect(TerminalJumper.score(title: "/Users/dev/Projects/site — claude", document: nil, projectPath: p, cwd: p, label: "site") == 80)
    #expect(TerminalJumper.score(title: "main.swift — site", document: nil, projectPath: p, cwd: p, label: "site") == 50)
    #expect(TerminalJumper.score(title: "sitemap notes", document: nil, projectPath: p, cwd: p, label: "site") == 0)
    #expect(TerminalJumper.score(title: "✳ Fix the build", document: nil, projectPath: p, cwd: p, label: "site") == 0)
}

/// Evidence: the real log through the real pipeline. Prints the sessions table.
@Test func realLogSnapshot() throws {
    guard FileManager.default.fileExists(atPath: AgentsModule.defaultLogURL.path) else { return }
    let text = AgentsModule.debugSnapshot()
    print("----- AgentsModule.debugSnapshot() -----\n" + text)
    #expect(text.contains("events parsed:"))
}
