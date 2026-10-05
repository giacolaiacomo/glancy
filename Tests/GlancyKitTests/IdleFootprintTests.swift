import AppKit
import Foundation
import Testing
@testable import GlancyKit

// The idle-memory regression (wave 4): what the app builds and keeps when nothing is on screen.
// - The panel's hosting view is NOT rebuilt on collapse (it flashed and made opens stutter).
// - The Agents launch rebuild folds the log into the session store one line at a time (the
//   2 MB parse used to leave ~10 MB of freed-but-dirty heap at idle).
// - No module builds a window or a hosting view when it starts (scripts/lint.sh checks the
//   sources; this checks the running modules).

private let notched = ScreenInfo(
    uuid: "BUILTIN", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    visibleFrame: CGRect(x: 0, y: 57, width: 1512, height: 892), safeTop: 32,
    auxLeft: CGRect(x: 0, y: 950, width: 665, height: 32), auxRight: CGRect(x: 850, y: 950, width: 662, height: 32),
    isBuiltin: true, scale: 2)

@MainActor
@Suite("Idle footprint")
struct IdleFootprintTests {
    @Test func collapsingKeepsTheSameHostingView() throws {
        // Rebuilding the host on collapse saved 1–3 MB but blanked the notch for a frame (a flash
        // under the menu bar) and made every open cold (stutter): the host lives as long as the panel.
        let h = SurfaceHarness([notched])
        let s = try #require(h.builtinSurface)
        let first = s.hostForTest
        h.manager.open(s)
        h.manager.close(s)
        #expect(s.hostForTest === first)
        let p = NSPoint(x: s.hostBoundsForTest.midX, y: 4)
        #expect(s.clickForTest(p))
        #expect(s.model.expanded)
    }

    @Test func buildingTheModulesAndStartingTheInertOnesOpensNoWindow() {
        // The modules a test can start without touching the user's system (no prompts, taps, AX,
        // child processes): constructing every real module, and starting the inert ones.
        _ = NSApplication.shared
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        let modules = Modules.make()
        let hub = ActivityHub()
        let inert: [any GlancyModule] = [TimerModule(store: TimerStore(url: FileManager.default.temporaryDirectory
                                                         .appendingPathComponent("glancy-idle-\(UUID().uuidString).json")),
                                                     alerts: NoAlerts())]
        for m in inert { m.start(hub: hub) }
        let after = Set(NSApp.windows.map(ObjectIdentifier.init))
        #expect(after.subtracting(before).isEmpty, "a module built a window: \(NSApp.windows.filter { !before.contains(ObjectIdentifier($0)) })")
        for m in inert { m.stop() }
        #expect(modules.count == ModuleID.allCases.count)
    }
}

private final class NoAlerts: TimerAlerting {
    func schedule(at date: Date, title: String, body: String) {}
    func cancel() {}
}

@Test func streamingDrainMatchesTheBatchAndKeepsThePartialLine() {
    let text = AgentsFixtures.lines.joined(separator: "\n") + "\n" + AgentsFixtures.lines[0].prefix(25)
    var a = Data(text.utf8), b = Data(text.utf8)
    let batch = AgentEventParser.drain(&a)
    var streamed: [AgentEvent] = []
    AgentEventParser.drain(&b) { streamed.append($0) }
    #expect(streamed == batch)
    #expect(!batch.isEmpty)
    #expect(a == b)
    #expect(String(decoding: b, as: UTF8.self) == String(AgentsFixtures.lines[0].prefix(25)))
}

@Test func promptsWithoutTagsSkipTheRegularExpressionButReadTheSame() {
    #expect(AgentEventParser.userPrompt("  fix   the\nbuild  ") == "fix the build")
    #expect(AgentEventParser.userPrompt("<pasted_content id=\"1\">hello</pasted_content> world") == "hello world")
    #expect(AgentEventParser.userPrompt("a < b and b > c") == "a < b and b > c")
    #expect(AgentEventParser.userPrompt("<task-notification>done</task-notification>") == nil)
}

@Test func launchRebuildIsFoldedLineByLine() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glancy-fold-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("events.jsonl")
    let lines = (0..<500).map { i in
        #"{"ts":\#(1_791_192_009_742 + i),"event":"PostToolUse","session_id":"s\#(i % 7)","cwd":"/tmp/p","tool_name":"Read","prompt":""}"#
    }
    FileManager.default.createFile(atPath: url.path, contents: Data((lines.joined(separator: "\n") + "\n").utf8))

    final class Box: @unchecked Sendable {
        let lock = NSLock(); var folded = 0; var sessions: Set<String> = []; var batches = 0; var rebuildBatches = 0
    }
    let box = Box()
    let reader = JSONLTailReader(url: url)
    reader.start({ _, rebuild in box.lock.withLock { box.batches += 1; if rebuild { box.rebuildBatches += 1 } } },
                 rebuild: { data in
                     AgentEventParser.drain(&data) { e in box.lock.withLock { box.folded += 1; box.sessions.insert(e.sessionID) } }
                 })
    reader.sync()
    reader.stop()
    #expect(box.folded == 500)
    #expect(box.sessions.count == 7)
    #expect(box.rebuildBatches == 0, "the rebuild goes to the fold, never as one batch")
}
