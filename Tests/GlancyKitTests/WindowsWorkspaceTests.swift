// Workspaces: capture and restore as fractions across display sizes, display matching, window
// matching (bundle + title), launching missing apps with a fake launcher (windows arrive through
// the backend's change callback, or the timeout), one undoable operation, the display-setup
// debounce and auto-apply, and the command bar's commands and results. All on the synthetic
// two-display Mac: nothing here moves a real window or opens a real app.
import CoreGraphics
import Foundation
import Testing
@testable import GlancyKit

private let builtIn = SampleWindowsBackend.builtIn
private let ultrawide = SampleWindowsBackend.ultrawide

/// The same two displays at other sizes (a scaled built-in, a 1440p external), same UUIDs.
private let bigBuiltIn = Display(id: "builtin", displayID: 1, name: "Built-in Retina Display",
                                 frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                                 visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1079),
                                 usableFrame: CGRect(x: 0, y: 0, width: 1728, height: 1079), isBuiltIn: true)
private let qhd = Display(id: "ultrawide", displayID: 2, name: "34-inch Ultrawide",
                          frame: CGRect(x: 1728, y: 0, width: 2560, height: 1440),
                          visibleFrame: CGRect(x: 1728, y: 0, width: 2560, height: 1415),
                          usableFrame: CGRect(x: 1728, y: 0, width: 2560, height: 1415), isBuiltIn: false)

@MainActor
private final class FakeLauncher: AppLauncher {
    var running: Set<String> = []
    var launched: [String] = []
    /// What appears after a launch (nil = the app shows no window).
    var windowsOnLaunch: [String: TrackedWindow] = [:]
    weak var backend: SampleWindowsBackend?

    func isRunning(_ bundleID: String) -> Bool { running.contains(bundleID) }

    func launch(_ bundleID: String) async -> Bool {
        launched.append(bundleID)
        running.insert(bundleID)
        if let w = windowsOnLaunch[bundleID] {
            // The window shows up a moment later, as the registry would report it.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(20))
                self?.backend?.windows.append(w)
                self?.backend?.fireChange()
            }
        }
        return true
    }
}

@MainActor
private func model(_ backend: SampleWindowsBackend = SampleWindowsBackend(), launcher: FakeLauncher = FakeLauncher()) -> WindowsModel {
    let m = WindowsModel(backend: backend)
    m.outcomeDuration = .milliseconds(1)
    m.pointer = { CGPoint(x: 756, y: 960) }
    launcher.backend = backend
    launcher.running = Set(backend.windows.compactMap(\.bundleID))
    m.restorer = WorkspaceRestorer(launcher: launcher)
    m.restorer.settle = .milliseconds(1)
    return m
}

private func approx(_ a: CGRect, _ b: CGRect, _ t: CGFloat = 1.01) -> Bool {
    abs(a.minX - b.minX) <= t && abs(a.minY - b.minY) <= t && abs(a.width - b.width) <= t && abs(a.height - b.height) <= t
}

@Suite("Workspaces: geometry and matching")
@MainActor
struct WorkspaceGeometryTests {
    @Test func fractionsRoundTripOnTheSameDisplay() {
        let usable = builtIn.usableFrame
        for f in [CGRect(x: 96, y: 300, width: 720, height: 500), CGRect(x: 8, y: 65, width: 1496, height: 876),
                  CGRect(x: 760, y: 57, width: 752, height: 446)] {
            let u = UnitRect.from(f, in: usable)
            #expect(approx(u.frame(in: usable), f))
        }
        // Measured from the top-left: a window touching the top has y = 0.
        let top = UnitRect.from(CGRect(x: 0, y: 949 - 200, width: 300, height: 200), in: usable)
        #expect(top.x == 0 && top.y == 0)
    }

    @Test func captureKeepsDisplaysOrderAndApps() {
        let b = SampleWindowsBackend()
        let w = WorkspacePlanner.capture(name: "Dev", windows: b.allWindows(), displays: b.displays())
        #expect(w.displays.map(\.uuid) == ["builtin", "ultrawide"])
        #expect(w.windows.count == 6)
        #expect(w.windows.map(\.order) == Array(0..<6))
        #expect(w.windows.first { $0.bundleID == "com.microsoft.VSCode" }?.display == 1)
        #expect(w.windows.first { $0.bundleID == "com.apple.Terminal" }?.display == 0)
        #expect(w.windows.first { $0.bundleID == "com.apple.Terminal" }?.title == "glancy — zsh")
        #expect(w.usedDisplays == 2)
    }

    @Test func restoreAcrossDisplaySizesKeepsFractions() async {
        // Saved on the standard Mac…
        let saved = WorkspacePlanner.capture(name: "Dev", windows: SampleWindowsBackend().allWindows(),
                                             displays: SampleWindowsBackend.standardDisplays)
        // …restored where both displays are bigger and every window sits somewhere else.
        let b = SampleWindowsBackend(displays: [bigBuiltIn, qhd], windows: SampleWindowsBackend.standardWindows.map { w in
            var w = w
            w.frame = CGRect(x: 40 + CGFloat(w.id), y: 40, width: 500, height: 400)
            return w
        })
        let plan = WorkspacePlanner.plan(saved, windows: b.allWindows(), displays: b.displays(), grid: b.grid(for:))
        #expect(plan.unmatched.isEmpty)
        #expect(plan.plans.count == 2)
        let moves = Dictionary(plan.plans.flatMap(\.moves).map { ($0.windowID, $0.to) }, uniquingKeysWith: { a, _ in a })
        for (i, e) in saved.windows.enumerated() {
            let target = e.display == 0 ? bigBuiltIn : qhd
            let id = plan.matched[i]!
            #expect(approx(moves[id]!, e.frame.frame(in: target.usableFrame)), "window \(id)")
        }
        // Terminal: left edge and top of the built-in kept, scaled to the bigger screen.
        let terminal = moves[11]!
        let original = SampleWindowsBackend.standardWindows[0].frame
        #expect(abs(terminal.width / bigBuiltIn.usableFrame.width - original.width / builtIn.usableFrame.width) < 0.002)
        #expect(abs((bigBuiltIn.usableFrame.maxY - terminal.maxY) / bigBuiltIn.usableFrame.height
                    - (builtIn.usableFrame.maxY - original.maxY) / builtIn.usableFrame.height) < 0.002)
    }

    @Test func displaysMatchByUUIDThenNameAndSize() {
        let saved = SampleWindowsBackend.standardDisplays.map(WorkspaceDisplay.init)
        // A dock handed the ultrawide a new UUID: name + size still find it.
        let moved = Display(id: "NEW-UUID", displayID: 9, name: ultrawide.name, frame: ultrawide.frame,
                            visibleFrame: ultrawide.visibleFrame, usableFrame: ultrawide.usableFrame, isBuiltIn: false)
        let r = WorkspacePlanner.resolve(saved, current: [builtIn, moved])
        #expect(r[0]?.id == "builtin" && r[1]?.id == "NEW-UUID")
        let w = Workspace(name: "x", displays: saved, windows: [])
        #expect(WorkspacePlanner.setupMatches(w, current: [moved, builtIn]))
        #expect(!WorkspacePlanner.setupMatches(w, current: [builtIn]))           // the external is gone
        // Same UUID at another resolution is still the same display.
        #expect(WorkspacePlanner.setupMatches(w, current: [builtIn, qhd]))
        // Only the built-in now: windows of the external keep their own display.
        #expect(WorkspacePlanner.resolve(saved, current: [builtIn])[1] == nil)
        #expect(WorkspacePlanner.setupKey([builtIn, ultrawide]) == WorkspacePlanner.setupKey([ultrawide, builtIn]))
        #expect(WorkspacePlanner.setupKey([builtIn]) != WorkspacePlanner.setupKey([builtIn, ultrawide]))
    }

    @Test func windowsMatchByBundleThenTitle() {
        let entries = [
            WorkspaceWindow(bundleID: "com.apple.Safari", appName: "Safari", title: "Docs — Spec", display: 0,
                            frame: UnitRect(x: 0, y: 0, w: 0.5, h: 1), order: 0),
            WorkspaceWindow(bundleID: "com.apple.Safari", appName: "Safari", title: "Mail — Inbox", display: 0,
                            frame: UnitRect(x: 0.5, y: 0, w: 0.5, h: 1), order: 1),
            WorkspaceWindow(bundleID: "com.apple.Notes", appName: "Notes", title: "Ideas", display: 0,
                            frame: UnitRect(x: 0, y: 0, w: 1, h: 1), order: 2),
        ]
        var notes = SampleWindowsBackend.window(33, "com.apple.Notes", "Notes", "Ideas", CGRect(x: 0, y: 100, width: 300, height: 300), z: 2)
        notes.isMinimized = true
        let live = [
            // Front-most is the Mail one: titles decide, not the stacking.
            SampleWindowsBackend.window(31, "com.apple.Safari", "Safari", "Mail — Inbox (3)", CGRect(x: 0, y: 100, width: 500, height: 500), z: 0),
            SampleWindowsBackend.window(32, "com.apple.Safari", "Safari", "Docs — Spec v2", CGRect(x: 10, y: 100, width: 500, height: 500), z: 1),
            notes,
        ]
        let m = WorkspacePlanner.match(entries, windows: live)
        #expect(m[0] == 32 && m[1] == 31)
        #expect(m[2] == nil)                    // minimised: left alone
        #expect(WorkspacePlanner.similarity("Docs — Spec", "docs  spec") == 1)
        #expect(WorkspacePlanner.similarity("", "anything") == 0.3)
        #expect(WorkspacePlanner.similarity("a b c", "x y z") == 0)
    }

    @Test func fileIsLenientAndRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("glancy-ws-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkspaceStore(url: url)
        #expect(store.workspaces.isEmpty)
        #expect(store.nextDefaultName == "Workspace 1")
        let b = SampleWindowsBackend()
        var w = WorkspacePlanner.capture(name: store.nextDefaultName, windows: b.allWindows(), displays: b.displays())
        w.hotkey = Hotkey(keyCode: 18, modifiers: WindowsHotkeys.ctrlOpt)
        store.add(w)
        #expect(store.nextDefaultName == "Workspace 2")
        let again = WorkspaceStore(url: url)
        #expect(again.workspaces == store.workspaces)
        // Saving under an existing name replaces it, keeping its hotkey.
        let replaced = again.save(WorkspacePlanner.capture(name: "workspace 1", windows: Array(b.allWindows().prefix(2)),
                                                           displays: b.displays()))
        #expect(again.workspaces.count == 1 && replaced.id == w.id && replaced.hotkey == w.hotkey && replaced.windows.count == 2)
        // A file from another version: unknown keys ignored, missing ones defaulted.
        try Data(#"{"workspaces":[{"name":"Old","windows":[{"bundleID":"com.apple.Notes","future":1}]}],"x":true}"#.utf8).write(to: url)
        let old = WorkspaceFile.load(from: url)
        #expect(old.workspaces.count == 1 && old.workspaces[0].name == "Old" && old.workspaces[0].windows[0].bundleID == "com.apple.Notes")
        #expect(old.workspaces[0].hotkey.modifiers == 0 && !old.workspaces[0].applyOnConnect)
    }
}

@Suite("Workspaces: restore")
@MainActor
struct WorkspaceRestoreTests {
    /// The standard desk saved, then the windows shuffled.
    private func savedAndShuffled() -> (Workspace, SampleWindowsBackend) {
        let saved = WorkspacePlanner.capture(name: "Dev", windows: SampleWindowsBackend().allWindows(),
                                             displays: SampleWindowsBackend.standardDisplays)
        let b = SampleWindowsBackend()
        for i in b.windows.indices { b.windows[i].frame = b.windows[i].frame.offsetBy(dx: 37, dy: -11) }
        return (saved, b)
    }

    @Test func restoreIsOneUndoableOperation() async {
        let (saved, b) = savedAndShuffled()
        let m = model(b)
        m.workspaces.add(saved)
        let o = await m.restoreWorkspace(saved.id)
        #expect(o?.placed == 6 && o?.launched == 0 && o?.notFound == 0 && o?.leftAlone == 0)
        // Both displays, one commit: one undo puts all six back.
        #expect(b.groupCommits.count == 1 && b.groupCommits[0].count == 2)
        #expect(b.commits.count == 1)
        for w in SampleWindowsBackend.standardWindows { #expect(approx(b.window(w.id)!.frame, w.frame, 1.5), "\(w.appName)") }
        #expect(m.canUndo)
        _ = await m.direct(.undo)
        #expect(b.undoCount == 1)
        if case .restored(let r)? = m.workspaceStatus { #expect(r.line == "Placed 6") } else { Issue.record("no status") }
    }

    @Test func missingAppIsLaunchedAndPlacedWhenItsWindowArrives() async {
        var (saved, b) = savedAndShuffled()
        saved.windows.append(WorkspaceWindow(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", title: "general", display: 0,
                                             frame: UnitRect(x: 0.25, y: 0.25, w: 0.5, h: 0.5), order: 6))
        let launcher = FakeLauncher()
        launcher.windowsOnLaunch["com.tinyspeck.slackmacgap"] = SampleWindowsBackend.window(
            41, "com.tinyspeck.slackmacgap", "Slack", "general", CGRect(x: 200, y: 200, width: 800, height: 600), z: 0)
        let m = model(b, launcher: launcher)
        m.workspaces.add(saved)
        var opening: [String] = []
        let o = await m.restoreWorkspace(saved.id) { opening = $0 }
        #expect(opening == ["Slack"])
        #expect(launcher.launched == ["com.tinyspeck.slackmacgap"])
        #expect(o?.launched == 1 && o?.placed == 7 && o?.notFound == 0)
        #expect(o.map { $0.line } == "Placed 7, launched 1")
        #expect(b.groupCommits.count == 1)
        #expect(approx(b.window(41)!.frame, UnitRect(x: 0.25, y: 0.25, w: 0.5, h: 0.5).frame(in: builtIn.usableFrame)))
    }

    @Test func launchTimesOutWhenNoWindowComes() async {
        var (saved, b) = savedAndShuffled()
        saved.windows.append(WorkspaceWindow(bundleID: "com.example.Quiet", appName: "Quiet", title: "", display: 0,
                                             frame: UnitRect(x: 0, y: 0, w: 0.5, h: 0.5), order: 6))
        let launcher = FakeLauncher()   // launches, never shows a window
        let m = model(b, launcher: launcher)
        m.restorer.launchTimeout = .milliseconds(80)
        m.workspaces.add(saved)
        let start = ContinuousClock.now
        let o = await m.restoreWorkspace(saved.id)
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(launcher.launched == ["com.example.Quiet"])
        #expect(o?.launched == 1 && o?.placed == 6 && o?.notFound == 1)
        #expect(o.map { $0.line } == "Placed 6, launched 1, 1 not found")
        #expect(!m.busy && m.restoringWorkspace == nil)
    }

    @Test func minimisedWindowsAreLeftAloneAndNotRelaunched() async {
        let (saved, b) = savedAndShuffled()
        let i = b.windows.firstIndex { $0.bundleID == "com.apple.Notes" }!
        b.windows[i].isMinimized = true
        let launcher = FakeLauncher()
        let m = model(b, launcher: launcher)
        m.workspaces.add(saved)
        let o = await m.restoreWorkspace(saved.id)
        #expect(launcher.launched.isEmpty)
        #expect(o?.leftAlone == 1 && o?.placed == 5)
        #expect(b.groupCommits[0].allSatisfy { p in !p.moves.contains { $0.windowID == b.windows[i].id } })
    }

    @Test func withoutAccessibilityNothingMoves() async {
        let (saved, b) = savedAndShuffled()
        b.isTrusted = false
        let m = model(b)
        m.workspaces.add(saved)
        let o = await m.restoreWorkspace(saved.id)
        #expect(o?.needsAccess == true)
        #expect(b.commits.isEmpty)
    }

    @Test func saveFromTheTabNamesItAndCaptures() {
        let b = SampleWindowsBackend()
        let m = model(b)
        m.open(keyboard: false)
        m.beginSave()
        #expect(m.showWorkspaces && m.naming == "Workspace 1")
        // Keys go to the name field while typing; Esc stops typing.
        #expect(m.handle(.arrangeAll) == false)
        #expect(m.handle(.digit(1)) == false)
        m.naming = "Deep work"
        m.confirmNaming()
        #expect(m.naming == nil)
        #expect(m.workspaces.workspaces.map(\.name) == ["Deep work"])
        #expect(m.workspaces.workspaces[0].windows.count == 6)
        m.beginRename(m.workspaces.workspaces[0].id)
        #expect(m.handle(.escape) && m.naming == nil)
        #expect(b.commits.isEmpty)
    }

    @Test func hoverPreviewsWithoutMoving() async {
        let (saved, b) = savedAndShuffled()
        let m = model(b)
        var shown: [ArrangePlan?] = []
        m.onPreview = { p, _ in shown.append(p) }
        m.workspaces.add(saved)
        m.open(keyboard: false)
        await m.pending?.value
        m.setWorkspaces(true)
        m.hoverWorkspace(saved.id)
        #expect(m.workspacePreview?.displayID == "builtin")
        #expect(m.workspacePreview?.moves.count == 4)
        #expect(shown.last??.moves.count == 4)
        m.hoverWorkspace(nil)
        #expect(m.workspacePreview == nil)
        #expect(b.commits.isEmpty)
    }

    @Test func digitsRestoreWorkspaces() async {
        let (saved, b) = savedAndShuffled()
        let m = model(b)
        m.workspaces.add(saved)
        m.open(keyboard: false)
        await m.pending?.value
        #expect(m.handle(.digit(1)))
        await m.pending?.value
        #expect(b.groupCommits.count == 1)
    }
}

@Suite("Workspaces: display setup")
@MainActor
struct WorkspaceDisplaySetupTests {
    @Test func reconfigurationsAreDebouncedAndOnlyRealChangesCount() async throws {
        var current = [builtIn]
        let watcher = DisplaySetupWatcher()
        watcher.debounce = .milliseconds(60)
        watcher.displays = { current }
        var calls: [[Display]] = []
        watcher.onSetupChange = { calls.append($0) }
        watcher.noteChange()                     // baseline: built-in only
        try await Task.sleep(for: .milliseconds(150))
        #expect(calls.isEmpty)                   // nothing came or went
        current = [builtIn, ultrawide]           // a dock: three reconfigurations in a burst
        watcher.noteChange()
        try await Task.sleep(for: .milliseconds(20))
        watcher.noteChange()
        try await Task.sleep(for: .milliseconds(20))
        watcher.noteChange()
        #expect(watcher.isWaiting)
        #expect(calls.isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        #expect(calls.count == 1 && calls[0].count == 2)
        #expect(!watcher.isWaiting)
        watcher.noteChange()                     // same setup again (the Dock resized)
        try await Task.sleep(for: .milliseconds(150))
        #expect(calls.count == 1)
        watcher.stop()
    }

    @Test func matchingWorkspaceIsAppliedWithoutLaunching() async throws {
        let windows = WindowsModule(engine: TilingEngine(configURL: nil), hotkeysURL: nil)
        let b = SampleWindowsBackend()
        windows.useForTests(backend: b) { _, _ in }
        let launcher = FakeLauncher()
        launcher.backend = b
        launcher.running = Set(b.windows.compactMap(\.bundleID))
        windows.model.restorer = WorkspaceRestorer(launcher: launcher)
        var w = WorkspacePlanner.capture(name: "Desk", windows: b.allWindows(), displays: b.displays())
        w.windows.append(WorkspaceWindow(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", title: "", display: 0,
                                         frame: UnitRect(x: 0, y: 0, w: 0.5, h: 0.5), order: 6))
        for i in b.windows.indices { b.windows[i].frame = b.windows[i].frame.offsetBy(dx: 20, dy: 0) }
        windows.workspaces.add(w)
        // Not opted in: nothing happens.
        windows.displaySetupChanged(b.displays())
        try await Task.sleep(for: .milliseconds(50))
        #expect(b.commits.isEmpty)
        windows.workspaces.update(w.id) { $0.applyOnConnect = true }
        // Another setup: not this workspace's.
        windows.displaySetupChanged([builtIn])
        try await Task.sleep(for: .milliseconds(50))
        #expect(b.commits.isEmpty)
        windows.displaySetupChanged(b.displays())
        for _ in 0..<100 where b.groupCommits.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(b.groupCommits.count == 1)
        #expect(launcher.launched.isEmpty)       // auto-apply never opens apps
        #expect(windows.canUndoTiling)
    }
}

@Suite("Workspaces: command bar")
@MainActor
struct WindowsCommandTests {
    private func module() -> (WindowsModule, SampleWindowsBackend) {
        let windows = WindowsModule(engine: TilingEngine(configURL: nil), hotkeysURL: nil)
        let b = SampleWindowsBackend()
        windows.useForTests(backend: b) { _, _ in }
        windows.model.pointer = { CGPoint(x: 756, y: 960) }
        return (windows, b)
    }

    @Test func commandsCoverLayoutsUndoAndWorkspaces() {
        let (m, b) = module()
        let dev = WorkspacePlanner.capture(name: "Dev", windows: b.allWindows(), displays: b.displays())
        m.workspaces.add(dev)
        let ids = Set(m.commands().map(\.id))
        for id in ["windows.autoArrange", "windows.layout.halves", "windows.layout.thirds", "windows.layout.grid",
                   "windows.layout.left", "windows.layout.right", "windows.layout.maximize", "windows.layout.center",
                   "windows.undo", "windows.saveWorkspace", "windows.workspace.\(dev.id.uuidString)"] {
            #expect(ids.contains(id), "\(id)")
        }
        let auto = m.commands().first { $0.id == "windows.autoArrange" }!
        #expect(auto.keywords.contains("arrange") && auto.keywords.contains("disponi"))
        #expect(m.commands().allSatisfy { $0.module == .windows })
        #expect(b.commits.isEmpty)                // building them runs nothing
    }

    @Test func resultsAnswerNamesLayoutsAndSaveAs() {
        let (m, b) = module()
        let dev = WorkspacePlanner.capture(name: "Dev setup", windows: b.allWindows(), displays: b.displays())
        m.workspaces.add(dev)
        #expect(m.results(for: "dev").first?.id == "windows.workspace.\(dev.id.uuidString)")
        #expect(m.results(for: "restore dev setup").first?.rank == 95)
        #expect(m.results(for: "setup").first?.rank == 70)
        #expect(m.results(for: "layout 2x2").map(\.id) == ["windows.layout.grid"])
        #expect(m.results(for: "griglia 2×2").map(\.id) == ["windows.layout.grid"])
        #expect(m.results(for: "metà").map(\.id) == ["windows.layout.halves"])
        let save = m.results(for: "salva workspace Focus")
        #expect(save.map(\.id) == ["windows.saveWorkspace.named"] && save[0].title.contains("Focus"))
        #expect(m.results(for: "zz").isEmpty)
        #expect(m.results(for: "x").isEmpty)
        #expect(b.commits.isEmpty)
    }

    @Test func saveAsRunsAndHalvesPlaceTheTwoFrontWindows() async {
        let (m, b) = module()
        m.results(for: "save workspace Focus").first?.run()
        #expect(m.workspaces.workspaces.map(\.name) == ["Focus"])
        let line = await m.model.layoutCommand(.sideBySide, count: 2)
        #expect(line.hasPrefix("Side by side"))
        let moves = b.commits.last!.moves
        // Terminal (front) left, Safari right, on the built-in under the pointer.
        #expect(moves.map(\.windowID) == [11, 12])
        #expect(moves[0].to.minX < moves[1].to.minX)
        #expect(moves.allSatisfy { builtIn.usableFrame.contains($0.to) })
        let centred = WindowsModel.centred(CGRect(x: 0, y: 100, width: 720, height: 500), in: builtIn.usableFrame)
        #expect(centred.midX == builtIn.usableFrame.midX && centred.size == CGSize(width: 720, height: 500))
    }
}
