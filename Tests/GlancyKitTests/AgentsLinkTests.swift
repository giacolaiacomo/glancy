// Agents ↔ Windows link: layout order, window resolution and its cache, the preview-then-commit
// flow on the synthetic screen (SampleWindowsBackend: commits recorded, nothing moves), ⌥-click,
// and the disabled states. No real window is touched: resolver, raiser and jumper are fakes.
import AppKit
import Foundation
import Testing
@testable import GlancyKit

private func session(_ row: String, _ state: AgentState, last: TimeInterval, cwd: String? = nil) -> AgentSession {
    let path = cwd ?? "/Users/dev/Projects/\(row)"
    return AgentSession(id: row, rowID: row, projectPath: path, cwd: path, label: row, state: state,
                        stateSince: t0.addingTimeInterval(last), startedAt: t0, lastEventAt: t0.addingTimeInterval(last))
}

/// Four sessions: site waiting, Glancy + web-app working (web-app more recent), Tessera done.
private let linkEvents: [AgentEvent] = [
    ev(.userPromptSubmit, "s-site", 0, cwd: "/Users/dev/Projects/site", prompt: "deploy"),
    ev(.permissionRequest, "s-site", 5, cwd: "/Users/dev/Projects/site", tool: "Bash"),
    ev(.userPromptSubmit, "s-lun", 1, cwd: "/Users/dev/Projects/Glancy", prompt: "tile"),
    ev(.userPromptSubmit, "s-pap", 2, cwd: "/Users/dev/Projects/web-app", prompt: "build"),
    ev(.postToolUse, "s-pap", 8, cwd: "/Users/dev/Projects/web-app", tool: "Edit"),
    ev(.userPromptSubmit, "s-tes", 0, cwd: "/Users/dev/Projects/Tessera", prompt: "port"),
    ev(.stop, "s-tes", 3, cwd: "/Users/dev/Projects/Tessera"),
]

/// The synthetic screen's windows standing in for each session's terminal.
private let windowFor: [String: CGWindowID] = ["site": 13, "Glancy": 11, "web-app": 14, "Tessera": 12]

@MainActor
private final class Harness {
    let model = AgentsModel()
    let windows = WindowsModule(engine: TilingEngine(configURL: nil), hotkeysURL: nil)
    let backend = SampleWindowsBackend()
    var previews: [ArrangePlan?] = []
    var resolveCalls: [[String]] = []
    var log: [String] = []
    var trusted = true

    init() {
        windows.useForTests(backend: backend) { [unowned self] plan, _ in self.previews.append(plan) }
        model.tiling = windows
        model.axTrusted = { [unowned self] in self.trusted }
        model.windowCache.windowAlive = { [unowned self] id in self.backend.window(id) != nil }
        model.resolver = { [unowned self] targets, excluding in
            self.resolveCalls.append(targets.map(\.label))
            var out: [String: TerminalJumper.ResolvedWindow] = [:]
            for t in targets {
                guard let id = windowFor[t.label], !excluding.contains(id), self.backend.window(id) != nil else { continue }
                out[t.rowID] = .init(windowID: id, pid: pid_t(1000 + id))
            }
            return out
        }
        model.raiser = { [unowned self] w, _ in self.log.append("raise \(w.windowID)") }
        model.jumper = { [unowned self] t in self.log.append("jump \(t.label)"); return .activatedApp(app: "Terminal") }
        model.ingest(linkEvents, rebuild: true)
    }

    func row(_ label: String) -> String { model.sessions.first { $0.label == label }!.rowID }
}

@Suite("Agents ↔ Windows link")
@MainActor
struct AgentsLinkTests {

    // MARK: Order

    @Test func layoutOrderIsWaitingWorkingDoneMostRecentFirst() {
        let order = AgentsLayout.order([
            session("done-old", .done, last: 10), session("work-old", .working, last: 20),
            session("wait", .waiting, last: 5), session("ended", .ended, last: 99),
            session("work-new", .working, last: 40), session("done-new", .done, last: 30),
            session("idle", .idle, last: 50),
        ])
        #expect(order.map(\.rowID) == ["wait", "work-new", "work-old", "done-new", "done-old", "idle"])
    }

    @Test func readingOrderGivesTheFirstWindowTheTopLeftCell() {
        let backend = SampleWindowsBackend()
        let plan = backend.planArrange(on: SampleWindowsBackend.builtIn, strategy: .balanced,
                                       grid: GridSpec(cols: 2, rows: 2), windowIDs: [11, 12, 13, 14])
        let ordered = ReadingOrder.assign(plan, order: [14, 13, 12, 11])
        func readingSorted(_ moves: [PlannedMove]) -> [PlannedMove] {
            moves.sorted { (a: PlannedMove, b: PlannedMove) -> Bool in
                let dy: CGFloat = a.to.maxY - b.to.maxY
                return abs(dy) > 1 ? dy > 0 : a.to.minX < b.to.minX
            }
        }
        // Same cells, handed out top-left → right → next row in the given order.
        #expect(readingSorted(ordered.moves).map(\.to) == readingSorted(plan.moves).map(\.to))
        #expect(readingSorted(ordered.moves).map(\.windowID) == [14, 13, 12, 11])
        // Each window keeps its own "from".
        for m in ordered.moves {
            #expect(m.from == backend.window(m.windowID)?.frame)
        }
    }

    // MARK: Resolution

    @Test func resolutionPairsOneWindowPerSessionBestFirst() {
        let w1 = TerminalJumper.ResolvedWindow(windowID: 1, pid: 10)
        let w2 = TerminalJumper.ResolvedWindow(windowID: 2, pid: 10)
        let out = TerminalJumper.assign([
            .init(rowID: "a", window: w1, score: 50),
            .init(rowID: "b", window: w1, score: 125),   // b matches w1 best (document) and takes it
            .init(rowID: "a", window: w2, score: 30),
            .init(rowID: "b", window: w2, score: 80),
        ])
        #expect(out == ["b": w1, "a": w2])
    }

    @Test func resolutionScoresLikeJump() {
        let w = TerminalJumper.AXWindow(element: AXUIElementCreateSystemWide(), title: "site — claude",
                                        document: "file:///Users/dev/Projects/site/")
        let t = TerminalJumper.Target(projectPath: "/Users/dev/Projects/site", cwd: "/Users/dev/Projects/site", label: "site")
        #expect(TerminalJumper.windowScore(w, windowCount: 3, target: t, isHost: true) == 125)
        #expect(TerminalJumper.windowScore(w, windowCount: 3, target: t, isHost: false) == 100)
    }

    // MARK: Cache

    @Test func cacheDropsEndedMovedAndDestroyed() {
        let cache = TerminalWindowCache()
        var alive: Set<CGWindowID> = [1, 2, 3]
        cache.windowAlive = { alive.contains($0) }
        let a = session("a", .working, last: 1), b = session("b", .waiting, last: 2), c = session("c", .done, last: 3)
        cache.store(.init(windowID: 1, pid: 9), for: a)
        cache.store(.init(windowID: 2, pid: 9), for: b)
        cache.store(.init(windowID: 3, pid: 9), for: c)
        #expect(cache.window(for: a)?.windowID == 1)

        // a ended (gone from live), b moved to another folder.
        let bMoved = session("b", .waiting, last: 2, cwd: "/Users/dev/Projects/elsewhere")
        #expect(cache.retain(live: [bMoved, c]))
        #expect(cache.entries["a"] == nil && cache.entries["b"] == nil)
        // c's window destroyed: caught at lookup.
        alive.remove(3)
        #expect(cache.window(for: c) == nil)
        #expect(cache.entries.isEmpty)
        // A window claimed by a new session leaves the old one.
        cache.store(.init(windowID: 1, pid: 9), for: a)
        cache.store(.init(windowID: 1, pid: 9), for: c)
        #expect(cache.entries.keys.sorted() == ["c"])
        cache.remove(windowIDs: [1])
        #expect(cache.entries.isEmpty)
    }

    @Test func registryRemovalInvalidatesAndNextActionResolvesAgain() async {
        let h = Harness()
        h.model.layOutSessions()
        await h.model.tilingTask?.value
        #expect(h.resolveCalls.count == 1)
        #expect(h.model.windowCache.entries.count == 4)
        h.model.cancelLayoutPreview()

        // The registry reports Notes (web-app's stand-in) closed.
        h.backend.windows.removeAll { $0.id == 14 }
        h.backend.fireChange()
        await Task.yield()
        #expect(h.model.windowCache.windowIDs == [11, 12, 13])

        // Cached sessions are not resolved again; only the one that lost its window is.
        h.model.layOutSessions()
        await h.model.tilingTask?.value
        #expect(h.resolveCalls.last == ["web-app"])
        #expect(h.model.layoutPreview?.count == 3)
    }

    @Test func sessionEndInvalidatesItsWindow() {
        let h = Harness()
        let s = h.model.store.session(rowID: h.row("Tessera"))!
        h.model.windowCache.store(.init(windowID: 12, pid: 1012), for: s)
        h.model.ingest([ev(.sessionEnd, "s-tes", 20, cwd: "/Users/dev/Projects/Tessera", reason: "exit")], rebuild: false)
        #expect(h.model.windowCache.entries.isEmpty)
    }

    // MARK: Preview → commit → undo

    @Test func layOutPreviewsFirstThenCommitsOnSecondClick() async throws {
        let h = Harness()
        h.model.layOutSessions()
        await h.model.tilingTask?.value

        let preview = try #require(h.model.layoutPreview)
        #expect(preview.count == 4)
        #expect(h.backend.commits.isEmpty)                    // a preview never commits
        let shown = try #require(h.previews.last ?? nil)
        // Waiting first, then working (most recent first), then done.
        #expect(preview.windowIDs == [13, 14, 11, 12])
        let first = try #require(shown.moves.first { $0.windowID == 13 })
        let topEdge: CGFloat = shown.moves.map(\.to.maxY).max() ?? 0
        let leftOnTop: CGFloat = shown.moves.filter { abs($0.to.maxY - topEdge) <= 1 }.map(\.to.minX).min() ?? 0
        #expect(abs(first.to.maxY - topEdge) <= 1 && first.to.minX == leftOnTop)   // site: top-left

        h.model.layOutSessions()                              // second click
        await h.model.tilingTask?.value
        #expect(h.model.layoutPreview == nil)
        #expect(h.backend.commits.count == 1)
        #expect(h.backend.commits[0].moves.map(\.to) == shown.moves.map(\.to))
        #expect(h.previews.last! == nil)                      // overlay hidden on commit
        #expect(h.model.undoOffered)
        #expect(h.model.tilingNote != nil)

        #expect(h.model.handleKey(.undo))
        await h.model.tilingTask?.value
        #expect(h.backend.undoCount == 1)
        #expect(!h.model.undoOffered)
    }

    @Test func enterCommitsAndEscapeCancels() async {
        let h = Harness()
        #expect(!h.model.handleKey(.enter))                   // nothing previewed: not ours
        h.model.layOutSessions()
        await h.model.tilingTask?.value
        #expect(h.model.handleKey(.escape))
        #expect(h.model.layoutPreview == nil)
        #expect(h.previews.last! == nil)
        #expect(h.backend.commits.isEmpty)

        h.model.layOutSessions()
        await h.model.tilingTask?.value
        #expect(h.model.handleKey(.enter))
        await h.model.tilingTask?.value
        #expect(h.backend.commits.count == 1)
    }

    @Test func leavingTheTabCancelsThePreviewAndTheUndoOffer() async {
        let h = Harness()
        var keys: [Bool] = []
        h.model.onWantsKeys = { keys.append($0) }
        h.model.layOutSessions()
        await h.model.tilingTask?.value
        #expect(keys == [true])
        h.model.endTiling()
        #expect(h.model.layoutPreview == nil && !h.model.undoOffered)
        #expect(h.previews.last! == nil)
        #expect(keys == [true, false])
        #expect(h.backend.commits.isEmpty)
    }

    // MARK: ⌥-click

    @Test func optionClickPlacesInTheFocusedCellThenRaises() async throws {
        let h = Harness()
        // The focused window (Terminal 11) sits on the left; the last Windows-grid cell wins over it.
        h.model.jumpAndTile(rowID: h.row("site"))
        await h.model.tilingTask?.value
        let plan = try #require(h.backend.commits.first)
        #expect(plan.moves.first?.windowID == 13)
        #expect(h.log == ["raise 13"])                        // placed first, then brought forward
        #expect(h.model.undoOffered)
    }

    @Test func optionClickWithoutAWindowJustJumpsAndSays() async {
        let h = Harness()
        h.backend.windows.removeAll { $0.id == 12 }
        h.model.jumpAndTile(rowID: h.row("Tessera"))
        await h.model.tilingTask?.value
        await h.model.jumpTask?.value
        #expect(h.backend.commits.isEmpty)
        #expect(h.log == ["jump Tessera"])
        #expect(h.model.jumpNote?.text == AgentsText.t("No terminal window found to tile."))
    }

    // MARK: Disabled states

    @Test func withoutAccessibilityActionsAreDisabledAndNeverResolve() async {
        let h = Harness()
        h.trusted = false
        #expect(h.model.tilingAvailability == .needsAccessibility)
        #expect(h.model.tilingAvailability.reason != nil)
        h.model.layOutSessions()
        await h.model.tilingTask?.value
        #expect(h.model.layoutPreview == nil)
        #expect(h.resolveCalls.isEmpty)
        h.model.jumpAndTile(rowID: h.row("site"))             // falls back to a plain jump
        await h.model.jumpTask?.value
        #expect(h.log == ["jump site"])
        #expect(h.model.jumpNote?.text == AgentsTilingAvailability.needsAccessibility.reason)
        #expect(h.backend.commits.isEmpty)
    }

    @Test func withoutWindowsModuleActionsAreHidden() {
        let model = AgentsModel()
        #expect(model.tilingAvailability == .unavailable)
        #expect(model.tilingAvailability.reason == nil)
    }

    @Test func untrustedTilerPreviewsNothing() {
        let windows = WindowsModule(engine: TilingEngine(configURL: nil), hotkeysURL: nil)
        let backend = SampleWindowsBackend()
        backend.isTrusted = false
        var previews = 0
        windows.useForTests(backend: backend) { _, _ in previews += 1 }
        #expect(!windows.tilingReady)
        #expect(windows.previewLayOut(windowIDs: [11, 12]) == 0)
        #expect(previews == 0)
    }

    @Test func peekForWaitingCarriesShow() {
        let hub = ActivityHub()
        let model = AgentsModel()
        model.hub = hub
        model.jumper = { _ in .notFound }
        model.ingest([ev(.userPromptSubmit, "a", 0, prompt: "go")], rebuild: true)
        model.ingest([ev(.permissionRequest, "a", 5, tool: "Bash")], rebuild: false)
        #expect(hub.peek?.duration == 4)                      // longer: there is an action to reach
    }

    @Test func tilingKeysAreDecoded() throws {
        func key(_ code: UInt16, _ chars: String, _ mods: NSEvent.ModifierFlags = []) throws -> AgentsModel.TilingKey? {
            let e = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
                                                  windowNumber: 0, context: nil, characters: chars,
                                                  charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
            return AgentsModule.tilingKey(for: e)
        }
        #expect(try key(36, "\r") == .enter)
        #expect(try key(53, "\u{1b}") == .escape)
        #expect(try key(6, "z", .command) == .undo)
        #expect(try key(6, "z") == nil)
        #expect(try key(36, "\r", .option) == nil)
    }
}
