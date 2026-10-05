import Foundation
import Testing
@testable import GlancyKit

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [AgentEvent] = []
    private var _rebuilds = 0
    var events: [AgentEvent] { lock.withLock { _events } }
    var rebuilds: Int { lock.withLock { _rebuilds } }
    var handler: JSONLTailReader.Handler {
        { [self] evs, rebuild in lock.withLock { _events += evs; if rebuild { _rebuilds += 1 } } }
    }
    var ids: [String] { events.map(\.sessionID) }
}

private func line(_ sid: String, _ ms: Int = 1_791_192_009_742, tool: String = "Read") -> String {
    #"{"ts":\#(ms),"event":"PostToolUse","session_id":"\#(sid)","cwd":"/Users/dev/Projects/web-app","tool_name":"\#(tool)","agent_type":"executor","prompt":""}"# + "\n"
}

private func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("glancy-agents-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func append(_ s: String, to url: URL) {
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(Data(s.utf8)); try? h.close()
    } else {
        FileManager.default.createFile(atPath: url.path, contents: Data(s.utf8))
    }
}

/// Waits (bounded) for file events to arrive; the reader itself never polls.
private func eventually(isolation: isolated (any Actor)? = #isolation, _ timeout: Double = 3, _ cond: () -> Bool) async -> Bool {
    let end = Date.now.addingTimeInterval(timeout)
    while Date.now < end {
        if cond() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return cond()
}

@Test func rebuildSkipsTheCutLineThenFollowsPartialAppends() async {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("events.jsonl")
    append((0..<10).map { line("s\($0)") }.joined(), to: url)
    let one = line("s0").utf8.count
    let reader = JSONLTailReader(url: url, rebuildBytes: one * 2 + 20)   // cuts inside line 7
    let c = Collector()
    reader.start(c.handler)
    #expect(await eventually { c.rebuilds == 1 })
    #expect(c.ids == ["s8", "s9"])

    let next = line("live")
    append(String(next.prefix(30)), to: url)
    try? await Task.sleep(for: .milliseconds(150))
    #expect(c.ids == ["s8", "s9"])                      // partial line: nothing yet
    append(String(next.dropFirst(30)), to: url)
    #expect(await eventually { c.ids.last == "live" })
    reader.stop()
}

@Test func rotationDrainsTheOldFileAndFollowsTheNewOne() async throws {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("events.jsonl")
    let rotated = dir.appendingPathComponent("events.jsonl.1")
    append(line("before"), to: url)
    let reader = JSONLTailReader(url: url)
    let c = Collector()
    reader.start(c.handler)
    #expect(await eventually { c.rebuilds == 1 })

    // Exactly what the producer does at 5 MB: append, mv to .1, next append creates the file.
    append(line("a"), to: url)
    try FileManager.default.moveItem(at: url, to: rotated)
    append(line("late-in-old"), to: rotated)            // a writer that had the old file open
    append(line("b"), to: url)
    #expect(await eventually { Set(c.ids) == ["before", "a", "late-in-old", "b"] })
    #expect(c.ids.filter { $0 == "a" }.count == 1)      // nothing read twice

    // And again: .1 is replaced by the next rotation.
    try? FileManager.default.removeItem(at: rotated)
    try FileManager.default.moveItem(at: url, to: rotated)
    append(line("c"), to: url)
    append(line("d"), to: url)
    #expect(await eventually { c.ids.suffix(2) == ["c", "d"] })
    #expect(c.ids.count == 6)
    reader.stop()
}

@Test func rebuildBorrowsTheTailOfTheRotatedFile() async {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("events.jsonl")
    append((0..<5).map { line("old\($0)") }.joined(), to: dir.appendingPathComponent("events.jsonl.1"))
    append(line("new0"), to: url)
    let one = line("old0").utf8.count
    let reader = JSONLTailReader(url: url, rebuildBytes: one * 3 + 10)
    let c = Collector()
    reader.start(c.handler)
    #expect(await eventually { c.rebuilds == 1 })
    #expect(c.ids == ["old3", "old4", "new0"])
    reader.stop()
}

@Test func waitsForTheLogToBeCreated() async {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("data/cc-dashboard/events.jsonl")   // folders missing too
    let reader = JSONLTailReader(url: url)
    let c = Collector()
    reader.start(c.handler)
    #expect(await eventually { c.rebuilds == 1 })
    #expect(c.ids.isEmpty)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? await Task.sleep(for: .milliseconds(100))
    append(line("first"), to: url)
    #expect(await eventually { c.ids == ["first"] })
    append(line("second"), to: url)
    #expect(await eventually { c.ids == ["first", "second"] })
    reader.stop()
}

@Test func stopLeavesNothingDelivering() async {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("events.jsonl")
    append(line("x"), to: url)
    let reader = JSONLTailReader(url: url)
    let c = Collector()
    reader.start(c.handler)
    #expect(await eventually { c.rebuilds == 1 })
    reader.stop()
    append(line("after-stop"), to: url)
    try? await Task.sleep(for: .milliseconds(150))
    #expect(c.ids == ["x"])
}

@MainActor @Test func moduleFollowsALiveLogEndToEnd() async {
    let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("events.jsonl")
    let ms = Int(Date.now.timeIntervalSince1970 * 1000)
    func l(_ event: String, _ dt: Int, _ extra: String = "") -> String {
        #"{"ts":\#(ms + dt),"event":"\#(event)","session_id":"s1","cwd":"/Users/dev/Projects/site","prompt":""\#(extra)}"# + "\n"
    }
    append(l("SessionStart", 0, #","source":"startup""#), to: url)
    let module = AgentsModule(logURL: url)
    let hub = ActivityHub()
    module.start(hub: hub)
    #expect(await eventually { module.model.loaded })
    #expect(module.model.sessions.first?.state == .idle)
    #expect(hub.top == nil)
    #expect(module.homeCard() == nil)

    append(l("UserPromptSubmit", 1000).replacingOccurrences(of: #""prompt":"""#, with: #""prompt":"run the evals""#), to: url)
    #expect(await eventually { module.model.summary.state == .working })
    #expect(hub.top?.priority == 50)
    #expect(module.homeCard() != nil)

    append(l("PermissionRequest", 2000, #","tool_name":"Bash""#), to: url)
    #expect(await eventually { hub.top?.priority == 90 })
    #expect(hub.peek != nil)                              // "site needs you"

    append(l("PostToolUse", 3000, #","tool_name":"Bash""#) + l("Stop", 30_000), to: url)
    #expect(await eventually { module.model.summary.state == .done })
    #expect(module.model.sessions.first?.lastPrompt == "run the evals")

    module.stop()
    #expect(hub.top == nil)
    #expect(module.model.sessions.isEmpty)
}
