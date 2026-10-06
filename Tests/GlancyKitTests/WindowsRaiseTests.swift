// After a commit that places chosen windows, they go above every other window: the plan's
// first window frontmost (the user's first pick, else the frontmost of them), the rest beneath
// it in plan order; failed placements, windows left out of the plan and undo never raise. On the
// synthetic two-display Mac: `SampleWindowsBackend.raise` only records, nothing real moves or rises.
import CoreGraphics
import Foundation
import Testing
@testable import GlancyKit

private let onBuiltIn = CGPoint(x: 756, y: 960)

@MainActor
private func open(_ b: SampleWindowsBackend) async -> WindowsModel {
    let model = WindowsModel(backend: b)
    model.outcomeDuration = .milliseconds(1)
    model.closeDelay = .milliseconds(1)
    model.pointer = { onBuiltIn }
    model.open(keyboard: false)
    await model.pending?.value
    return model
}

@Suite("Windows: placed windows are raised")
@MainActor
struct WindowsRaiseTests {
    /// The tester's case: four windows open, two picked into a layout. Both go on top, the first
    /// pick frontmost; the other two neither move nor rise.
    @Test func layoutApplyRaisesThePickedWindowsFirstPickFrontmost() async throws {
        let b = SampleWindowsBackend()
        let model = await open(b)
        let before = Dictionary(uniqueKeysWithValues: b.windows.map { ($0.id, $0.frame) })
        model.click(14, .toggle)                       // Notes first (at the back of the desk)
        model.click(13, .toggle)                       // then Mail
        let plan = try #require(model.layoutPlan)
        #expect(plan.moves.map(\.windowID) == [14, 13])
        #expect(b.raises.isEmpty)                      // choosing previews only
        model.applyLayout()
        await model.pending?.value
        #expect(b.commits == [plan])
        #expect(b.raises == [[14, 13]])
        for id: CGWindowID in [11, 12, 21, 22] {
            #expect(b.window(id)?.frame == before[id])
            #expect(!b.raises.joined().contains(id))
        }
    }

    @Test func failedPlacementIsNotRaised() async throws {
        let b = SampleWindowsBackend()
        b.outcomes[13] = .refused
        b.outcomes[12] = .appSized                     // landed, at the app's own size: still placed
        let model = await open(b)
        model.click(14, .toggle)
        model.click(13, .toggle)
        model.click(12, .toggle)
        model.applyLayout()
        await model.pending?.value
        #expect(b.commits.count == 1)
        #expect(b.raises == [[14, 12]])
    }

    @Test func nothingPlacedNothingRaised() async {
        let b = SampleWindowsBackend()
        b.outcomes = [13: .unreachable, 14: .refused]
        let model = await open(b)
        model.click(14, .toggle)
        model.click(13, .toggle)
        model.applyLayout()
        await model.pending?.value
        #expect(b.commits.count == 1)
        #expect(b.raises.isEmpty)
    }

    /// More → a strategy → Apply: every window it placed, the frontmost of them on top, the
    /// display's stacking otherwise kept; the other display's windows are not raised.
    @Test func moreMapStrategyApplyRaisesInFrontToBackOrder() async throws {
        let b = SampleWindowsBackend()
        let model = await open(b)
        model.setMore(true)
        model.choose(.balanced)
        let plan = try #require(model.arrangementPreview)
        model.apply()
        await model.pending?.value
        #expect(b.raises.count == 1)
        #expect(b.raises[0] == plan.moves.map(\.windowID))
        #expect(b.raises[0] == [11, 12, 13, 14])
    }

    @Test func undoNeverRaises() async {
        let b = SampleWindowsBackend()
        let model = await open(b)
        model.click(14, .toggle)
        model.click(13, .toggle)
        model.applyLayout()
        await model.pending?.value
        #expect(b.raises.count == 1)
        model.handle(.undo)
        await model.pending?.value
        #expect(b.undoCount == 1)
        _ = await model.direct(.undo)
        #expect(b.raises.count == 1)
    }

    @Test func arrangeShortcutRaisesWhatItPlaced() async {
        let b = SampleWindowsBackend()
        let model = WindowsModel(backend: b)
        model.pointer = { onBuiltIn }
        _ = await model.arrangeShortcut(.balanced, appOnly: false)
        #expect(b.commits.count == 1)
        #expect(b.raises == [b.commits[0].moves.map(\.windowID)])
        #expect(!b.raises.joined().contains(21) && !b.raises.joined().contains(22))
    }

    /// Agents "Lay out sessions": the sessions' windows on top, the first one frontmost.
    @Test func agentsLayOutRaisesInTheGivenOrder() async {
        let b = SampleWindowsBackend()
        let model = WindowsModel(backend: b)
        model.pointer = { onBuiltIn }
        let plan = model.planLayOut(windowIDs: [13, 11], readingOrder: true)
        #expect(plan?.moves.map(\.windowID) == [13, 11])
        let module = WindowsModule(engine: TilingEngine(configURL: nil), hotkeysURL: nil)
        module.useForTests(backend: b) { _, _ in }
        _ = await module.commitLayOut(windowIDs: [13, 11])
        #expect(b.raises == [[13, 11]])
    }

    /// Agents ⌥-click brings its terminal forward itself: the focused-cell placement never raises.
    @Test func focusedCellPlacementDoesNotRaise() async {
        let b = SampleWindowsBackend()
        let model = WindowsModel(backend: b)
        _ = await model.place(windowID: 13, inFocusedCell: nil)
        #expect(b.commits.count == 1)
        #expect(b.raises.isEmpty)
    }

    @Test func raiseOrderIsPlanOrderPlacedOnlyOnce() {
        let usable = SampleWindowsBackend.builtIn.usableFrame
        func move(_ id: CGWindowID) -> PlannedMove { PlannedMove(windowID: id, from: .zero, to: usable, cell: nil) }
        func plan(_ ids: [CGWindowID]) -> ArrangePlan {
            ArrangePlan(kind: .layout, displayID: "builtin", usable: usable, grid: GridSpec(cols: 2, rows: 1), moves: ids.map(move))
        }
        func result(_ id: CGWindowID, _ o: PlacementOutcome) -> PlacementResult {
            PlacementResult(windowID: id, outcome: o, requested: usable, original: nil, landed: nil, attempts: 1,
                            euiWasOn: false, note: nil, elapsed: 0)
        }
        let order = WindowsModel.raiseOrder([plan([3, 1]), plan([2, 1, 4])],
                                            [result(3, .exact), result(1, .appSized), result(2, .cancelled),
                                             result(4, .exact)])
        #expect(order == [3, 1, 4])
    }
}

@Suite("Workspaces: restored windows are raised")
@MainActor
struct WorkspaceRaiseTests {
    @Test func restoreRaisesInTheSavedStackingOrder() async {
        let saved = WorkspacePlanner.capture(name: "Dev", windows: SampleWindowsBackend().allWindows(),
                                             displays: SampleWindowsBackend.standardDisplays)
        let b = SampleWindowsBackend()
        for i in b.windows.indices { b.windows[i].frame = b.windows[i].frame.offsetBy(dx: 37, dy: -11) }
        b.outcomes[12] = .refused
        let m = WindowsModel(backend: b)
        m.outcomeDuration = .milliseconds(1)
        m.restorer.settle = .milliseconds(1)
        m.workspaces.add(saved)
        _ = await m.restoreWorkspace(saved.id)
        // Saved front to back 11, 12, 13, 14, 21, 22; Safari's placement failed.
        #expect(b.raises == [[11, 13, 14, 21, 22]])
    }

    @Test func automaticDisplaySetupApplyDoesNotRaise() async throws {
        let windows = WindowsModule(engine: TilingEngine(configURL: nil), hotkeysURL: nil)
        let b = SampleWindowsBackend()
        windows.useForTests(backend: b) { _, _ in }
        var w = WorkspacePlanner.capture(name: "Desk", windows: b.allWindows(), displays: b.displays())
        w.applyOnConnect = true
        for i in b.windows.indices { b.windows[i].frame = b.windows[i].frame.offsetBy(dx: 20, dy: 0) }
        windows.workspaces.add(w)
        windows.displaySetupChanged(b.displays())
        for _ in 0..<100 where b.groupCommits.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(b.groupCommits.count == 1)
        #expect(b.raises.isEmpty)
    }
}
