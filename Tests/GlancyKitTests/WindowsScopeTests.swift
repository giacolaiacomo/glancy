// What the Windows tab acts on: the target only ever on the shown display, picking on the map,
// the Screen / App / Window scopes, and the global arrange shortcuts — on the synthetic two-display
// Mac (built-in 1512×982 below a 3440×1440 ultrawide). Nothing here moves a real window.
import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import GlancyKit

private let builtIn = SampleWindowsBackend.builtIn
private let ultrawide = SampleWindowsBackend.ultrawide
private let onBuiltIn = CGPoint(x: 756, y: 960)          // at the notch
private let onUltrawide = CGPoint(x: 800, y: 2000)

/// A second Safari window on the built-in display (same app as window 12).
private let safari2 = SampleWindowsBackend.window(15, "com.apple.Safari", "Safari", "Apple",
                                                  CGRect(x: 300, y: 420, width: 760, height: 470), z: 2, pid: 1012)

@MainActor
private func open(_ backend: SampleWindowsBackend = SampleWindowsBackend(), pointer: CGPoint = onBuiltIn,
                  keyboard: Bool = false) async -> WindowsModel {
    let model = WindowsModel(backend: backend)
    model.outcomeDuration = .milliseconds(1)
    model.closeDelay = .milliseconds(1)
    model.pointer = { pointer }
    model.open(keyboard: keyboard)
    await model.pending?.value
    return model
}

@Suite("Windows target")
@MainActor
struct WindowsTargetTests {
    @Test func frontmostWindowOnTheShownDisplayIsTheTarget() async {
        let model = await open()
        #expect(model.display?.id == builtIn.id)
        #expect(model.activeTargetID == 11)
        #expect(!model.needsPick)
    }

    /// ⌃⌥Space with the pointer on the ultrawide: work there, its frontmost window is the target.
    @Test func keyboardOpenShowsThePointersDisplay() async {
        let backend = SampleWindowsBackend(target: 21)          // VS Code, on the ultrawide
        let model = await open(backend, pointer: onUltrawide, keyboard: true)
        #expect(model.display?.id == ultrawide.id)
        #expect(model.activeTargetID == 21)
        model.contentScreenRect = CGRect(x: 600, y: 760, width: 300, height: 150)   // panel laid out on the notch
        #expect(model.display?.id == ultrawide.id)
    }

    @Test func frontmostWindowOnTheOtherDisplayIsNotTargeted() async {
        let backend = SampleWindowsBackend(target: 21)          // VS Code, on the ultrawide
        let model = await open(backend)
        #expect(model.display?.id == builtIn.id)
        #expect(model.activeTargetID == nil)
        #expect(model.needsPick)
        // Hover and click on the grid do nothing but ask for a pick.
        model.hover(GridCoord(col: 0, row: 0))
        #expect(model.hoverCell == nil)
        #expect(model.preview == nil)
        model.sweep(from: GridCoord(col: 0, row: 0), to: GridCoord(col: 1, row: 1))
        model.endSweep()
        model.place(CellRect(col: 0, row: 0))
        await model.pending?.value
        #expect(backend.commits.isEmpty)
        #expect(backend.window(21)?.frame == SampleWindowsBackend.standardWindows.first { $0.id == 21 }?.frame)
    }

    @Test func panelDisplayIsTheNotchUnderThePointerElseTheBuiltIn() {
        let all = SampleWindowsBackend.standardDisplays
        #expect(ScopeRules.panelDisplay(pointer: onBuiltIn, displays: all)?.id == builtIn.id)
        // The ultrawide has no notch: the panel opens on the built-in (the surface's fallback).
        #expect(ScopeRules.panelDisplay(pointer: onUltrawide, displays: all)?.id == builtIn.id)
        // Lid closed: only the external one.
        #expect(ScopeRules.panelDisplay(pointer: onUltrawide, displays: [ultrawide])?.id == ultrawide.id)
    }

    @Test func panelLaidOutOnAnExternalPillShowsThatDisplay() async {
        let backend = SampleWindowsBackend(target: 21)
        let model = await open(backend)
        #expect(model.display?.id == builtIn.id)
        model.contentScreenRect = CGRect(x: 400, y: 2200, width: 586, height: 156)   // the pill's panel
        await Task.yield(); await Task.yield()
        #expect(model.display?.id == ultrawide.id)
        #expect(model.activeTargetID == 21)
    }

    @Test func switcherRetargetsToTheFrontmostWindowThere() async throws {
        let backend = SampleWindowsBackend()
        let model = await open(backend)
        #expect(model.activeTargetID == 11)
        model.showDisplay(offset: 1)
        #expect(model.display?.id == ultrawide.id)
        #expect(model.activeTargetID == 21)
        // Placing acts on the ultrawide's window, on the ultrawide.
        model.place(CellRect(col: 0, row: 0))
        await model.pending?.value
        let plan = try #require(backend.commits.last)
        #expect(plan.displayID == ultrawide.id)
        #expect(plan.moves.map(\.windowID) == [21])
        // The layout no longer follows the panel once the user chose a display.
        model.contentScreenRect = CGRect(x: 400, y: 800, width: 586, height: 156)
        await Task.yield()
        #expect(model.display?.id == ultrawide.id)
    }

    @Test func noWindowCrossesDisplaysByDefault() async throws {
        // The frontmost window is on the ultrawide; the built-in map is shown.
        let backend = SampleWindowsBackend(target: 21)
        let model = await open(backend)
        model.choose(.balanced)
        let plan = try #require(model.arrangementPreview)
        #expect(plan.displayID == builtIn.id)
        #expect(Set(plan.moves.map(\.windowID)) == [11, 12, 13, 14])
        model.apply()
        await model.pending?.value
        for p in backend.commits {
            #expect(p.displayID == builtIn.id)
            #expect(!p.moves.contains { $0.windowID == 21 || $0.windowID == 22 })
        }
        // A window moved to the other display by hand stops being the target.
        model.select(12)
        #expect(model.activeTargetID == 12)
        if let i = backend.windows.firstIndex(where: { $0.id == 12 }) {
            backend.windows[i].frame = CGRect(x: 0, y: 1200, width: 900, height: 700)
        }
        backend.fireChange()
        #expect(model.activeTargetID == nil)
        let before = backend.commits.count
        model.place(CellRect(col: 0, row: 0))
        await model.pending?.value
        #expect(backend.commits.count == before)
    }

    @Test func clickingAWindowOnTheMapSelectsItWithoutMovingIt() async {
        let backend = SampleWindowsBackend(target: 21)
        let model = await open(backend)
        let frames = backend.windows.map(\.frame)
        model.select(13)
        #expect(model.activeTargetID == 13)
        #expect(!model.needsPick)
        #expect(backend.commits.isEmpty)
        #expect(backend.windows.map(\.frame) == frames)
        #expect(model.preview == nil)
        // Now hovering a cell previews the picked window.
        model.hover(GridCoord(col: 2, row: 0))
        #expect(model.preview?.moves.map(\.windowID) == [13])
        // A window of the other display cannot be picked here.
        model.select(21)
        #expect(model.activeTargetID == 13)
    }

    @Test func mapHitTestPicksAnyWindowWithoutTargetElseOnlyAnotherWindowsIcon() {
        let size = CGSize(width: 236, height: 134)
        let proj = MapProjection(display: builtIn.frame, usable: builtIn.usableFrame, size: size)
        let windows = SampleWindowsBackend.standardWindows.filter { $0.id < 20 }
        func centre(_ id: CGWindowID) -> CGPoint {
            let r = proj.toMap(windows.first { $0.id == id }!.frame).intersection(proj.displayRect)
            return CGPoint(x: r.midX, y: r.midY)
        }
        // No target: anywhere on a window picks the topmost one there.
        #expect(ScopeRules.pick(at: centre(11), windows: windows, projection: proj, target: nil) == 11)
        let r12 = proj.toMap(windows.first { $0.id == 12 }!.frame)
        let edgeOf12 = CGPoint(x: r12.maxX - 3, y: r12.maxY - 3)
        #expect(ScopeRules.pick(at: edgeOf12, windows: windows, projection: proj, target: nil) == 12)
        // With a target: another window's icon picks it; its edge, or the target itself, place instead.
        #expect(ScopeRules.pick(at: centre(13), windows: windows, projection: proj, target: 11) == 13)
        // Notes' centre lies under Safari (in front): the click is on Safari's body, so it places.
        #expect(ScopeRules.pick(at: centre(14), windows: windows, projection: proj, target: 11) == nil)
        #expect(ScopeRules.pick(at: edgeOf12, windows: windows, projection: proj, target: 11) == nil)
        #expect(ScopeRules.pick(at: centre(11), windows: windows, projection: proj, target: 11) == nil)
        // Off every window: nothing.
        #expect(ScopeRules.pick(at: CGPoint(x: 1, y: 1), windows: windows, projection: proj, target: nil) == nil)
    }

    @Test func hoveringAnIconShowsThePickNotACellPreview() async {
        let model = await open()
        model.hover(GridCoord(col: 2, row: 1), pick: 14)
        #expect(model.pickHover == 14)
        #expect(model.hoverCell == nil)
        #expect(model.preview == nil)
        model.hover(GridCoord(col: 2, row: 1))
        #expect(model.pickHover == nil)
        #expect(model.preview?.moves.map(\.windowID) == [11])
    }

    @Test func tabCyclesTheTargetThroughTheScope() async {
        let backend = SampleWindowsBackend()
        backend.windows.append(safari2)
        let model = await open(backend, keyboard: true)
        #expect(model.activeTargetID == 11)
        model.handle(.cycle(forward: true))
        #expect(model.activeTargetID == 12)
        #expect(model.selection != nil)              // the cursor follows the new target
        model.handle(.cycle(forward: false))
        model.handle(.cycle(forward: false))
        #expect(model.activeTargetID == 15)          // wrapped to the last window of the display
        model.setScope(.app)                          // Safari (the target's app)
        model.handle(.cycle(forward: true))
        #expect(model.activeTargetID == 12)
        model.handle(.cycle(forward: true))
        #expect(model.activeTargetID == 15)
        #expect(backend.commits.isEmpty)
    }

    @Test func tabKeyMapsToCycle() throws {
        func key(_ mods: NSEvent.ModifierFlags) throws -> WindowsModel.Key? {
            let e = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0,
                                                  context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
                                                  isARepeat: false, keyCode: 48))
            return WindowsModule.key(for: e)
        }
        #expect(try key([]) == .cycle(forward: true))
        #expect(try key([.shift]) == .cycle(forward: false))
    }
}

@Suite("Windows scope")
@MainActor
struct WindowsScopeTests {
    @Test func screenScopeArrangesEveryWindowOfTheDisplay() async {
        let backend = SampleWindowsBackend()
        backend.windows.append(safari2)
        let model = await open(backend)
        #expect(model.scope == .screen)
        model.choose(.columns)
        #expect(Set(model.arrangementPreview?.moves.map(\.windowID) ?? []) == [11, 12, 13, 14, 15])
    }

    @Test func appScopeArrangesOnlyThatAppsWindowsThere() async throws {
        let backend = SampleWindowsBackend(target: 12)
        backend.windows.append(safari2)
        let model = await open(backend)
        model.setScope(.app)
        #expect(model.scopeApp == 1012)
        #expect(model.currentScopeApp?.name == "Safari")
        model.choose(.columns)
        let plan = try #require(model.arrangementPreview)
        #expect(Set(plan.moves.map(\.windowID)) == [12, 15])
        #expect(plan.displayID == builtIn.id)
        model.apply()
        await model.pending?.value
        #expect(backend.commits.count == 1)
        #expect(Set(backend.commits[0].moves.map(\.windowID)) == [12, 15])
    }

    @Test func appScopeDefaultsToTheFrontAppAndCyclesApps() async {
        let backend = SampleWindowsBackend(target: 21)      // front app on the other display
        let model = await open(backend)
        model.setScope(.app)
        // No target, front app not here: the first app with windows on this display.
        #expect(model.scopeApp == 1011)
        #expect(model.activeTargetID == 11)
        model.setScope(.app)                                 // again: the next app
        #expect(model.scopeApp == 1012)
        #expect(model.activeTargetID == 12)
        // Picking a window of another app on the map switches the app.
        model.select(14)
        #expect(model.scopeApp == 1014)
        model.choose(.balanced)
        #expect(model.arrangementPreview?.moves.map(\.windowID) == [14])
        #expect(backend.commits.isEmpty)
    }

    @Test func windowScopeTurnsArrangeOff() async {
        let backend = SampleWindowsBackend()
        let model = await open(backend)
        model.choose(.balanced)
        #expect(model.arrangementPreview != nil)
        model.setScope(.window)
        #expect(!model.canArrange)
        #expect(model.strategy == nil)
        #expect(model.preview == nil)
        model.choose(.rows)
        #expect(model.strategy == nil)
        model.handle(.arrangeAll)
        #expect(model.strategy == nil)
        // Placing still works.
        model.hover(GridCoord(col: 0, row: 0))
        #expect(model.preview?.moves.map(\.windowID) == [11])
        #expect(backend.commits.isEmpty)
    }

    @Test func scopeRulesArePure() {
        let ws = SampleWindowsBackend.standardWindows.filter { $0.id < 20 } + [safari2]
        #expect(ScopeRules.arrangeIDs(.screen, app: nil, on: ws) == nil)
        #expect(ScopeRules.arrangeIDs(.window, app: 1011, on: ws) == [])
        #expect(ScopeRules.arrangeIDs(.app, app: 1012, on: ws) == [12, 15])
        #expect(ScopeRules.arrangeIDs(.app, app: nil, on: ws) == [])
        #expect(ScopeRules.apps(on: ws).map(\.pid) == [1011, 1012, 1013, 1014])
        #expect(ScopeRules.openingTarget(frontmost: 21, on: ws) == nil)
        #expect(ScopeRules.openingTarget(frontmost: 13, on: ws) == 13)
        #expect(ScopeRules.frontmost(preferring: 21, on: ws) == 11)
        #expect(ScopeRules.cycle(from: nil, in: [1, 2, 3], forward: false) == 3)
        #expect(ScopeRules.cycle(from: 3, in: [1, 2, 3], forward: true) == 1)
    }
}

@Suite("Windows arrange shortcuts")
@MainActor
struct WindowsArrangeShortcutTests {
    private func model(_ backend: SampleWindowsBackend, pointer: CGPoint) -> WindowsModel {
        let m = WindowsModel(backend: backend)
        m.pointer = { pointer }
        return m
    }

    @Test func arrangesTheDisplayUnderThePointerOnly() async {
        let backend = SampleWindowsBackend()                 // front window on the built-in
        let m = model(backend, pointer: onUltrawide)
        let line = await m.arrangeShortcut(.columns, appOnly: false)
        #expect(backend.commits.count == 1)
        let plan = backend.commits[0]
        #expect(plan.kind == .arrange)
        #expect(plan.displayID == ultrawide.id)
        #expect(Set(plan.moves.map(\.windowID)) == [21, 22])
        #expect(line.hasPrefix(WindowsText.strategy(.columns)))
        #expect(m.canUndo)
        // ⌃⌥Z undoes it.
        _ = await m.direct(.undo)
        #expect(backend.undoCount == 1)
    }

    @Test func shiftVariantTakesOnlyTheFrontAppsWindowsThere() async {
        let backend = SampleWindowsBackend(target: 12)
        backend.windows.append(safari2)
        let m = model(backend, pointer: onBuiltIn)
        _ = await m.arrangeShortcut(.balanced, appOnly: true)
        #expect(Set(backend.commits.last?.moves.map(\.windowID) ?? []) == [12, 15])
        // The front app has no window under the pointer: nothing moves, the peek says so.
        let m2 = model(backend, pointer: onUltrawide)
        let before = backend.commits.count
        let line = await m2.arrangeShortcut(.balanced, appOnly: true)
        #expect(backend.commits.count == before)
        #expect(line.contains("Safari"))
    }

    @Test func withoutAccessibilityNothingMoves() async {
        let backend = SampleWindowsBackend()
        backend.isTrusted = false
        let m = model(backend, pointer: onBuiltIn)
        let line = await m.arrangeShortcut(.rows, appOnly: false)
        #expect(backend.commits.isEmpty)
        #expect(line == WindowsText.t("Windows needs Accessibility"))
    }

    @Test func bindingsRoundTripAndDefaultsDoNotCollide() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("glancy-hotkeys-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var h = WindowsHotkeys()
        h.arrangeRows = Hotkey(keyCode: 15, modifiers: WindowsHotkeys.ctrlOpt | 0x0100)   // ⌃⌥⌘R
        h.arrangeCells = Hotkey(keyCode: 5, modifiers: 0)                                  // cleared
        try h.save(to: url)
        #expect(WindowsHotkeys.load(from: url) == h)
        // A file from before the arrange shortcuts gets their defaults.
        try Data(#"{"fit":{"keyCode":3,"modifiers":6144},"enabled":true}"#.utf8).write(to: url)
        let old = WindowsHotkeys.load(from: url)
        #expect(old.arrangeBalanced == WindowsHotkeys().arrangeBalanced)
        #expect(old.arrangeMaster.description == "⌃⌥M")
        // Defaults: ⌃⌥B C R M G, all distinct from each other and from the other Windows keys.
        let d = WindowsHotkeys()
        #expect(d.arrangeBindings.map(\.1.description) == ["⌃⌥B", "⌃⌥C", "⌃⌥R", "⌃⌥M", "⌃⌥G"])
        #expect(d.allCombos.count == d.bindings.count + d.arrangeBindings.count)
        // The ⇧ variant adds ⇧, never doubles it, and is nil for a cleared binding.
        #expect(WindowsHotkeys.appVariant(d.arrangeBalanced)?.description == "⌃⌥⇧B")
        #expect(WindowsHotkeys.appVariant(Hotkey(keyCode: 11, modifiers: WindowsHotkeys.ctrlOpt | 0x0200)) == nil)
        #expect(WindowsHotkeys.appVariant(Hotkey(keyCode: 11, modifiers: 0)) == nil)
        #expect(d.allCombos.isDisjoint(with: d.arrangeBindings.compactMap { WindowsHotkeys.appVariant($0.1) }))
    }
}
