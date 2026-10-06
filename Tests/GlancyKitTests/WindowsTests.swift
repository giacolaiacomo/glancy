// The Windows tab's decisions on a synthetic screen: map projection, keyboard selection, the
// drag-to-notch machine, halves cycling, and the rule that previews never commit.
import CoreGraphics
import Foundation
import Testing
@testable import GlancyKit

@MainActor
private func openModel(_ backend: SampleWindowsBackend = SampleWindowsBackend(), keyboard: Bool = false) async -> (WindowsModel, SampleWindowsBackend) {
    let model = WindowsModel(backend: backend)
    model.outcomeDuration = .milliseconds(1)
    model.closeDelay = .milliseconds(1)
    // Keyboard mode shows the pointer's display: pin the pointer to the built-in's notch, not
    // wherever the real mouse happens to be.
    model.pointer = { CGPoint(x: 756, y: 960) }
    model.open(keyboard: keyboard)
    await model.pending?.value
    return (model, backend)
}

private let builtIn = SampleWindowsBackend.builtIn
private let grid32 = GridSpec(cols: 3, rows: 2)

@Suite("Windows map")
@MainActor
struct WindowsMapTests {
    let box = CGSize(width: 236, height: 134)

    @Test func displayIsFittedAndCentred() {
        let p = MapProjection(display: builtIn.frame, usable: builtIn.usableFrame, size: box)
        #expect(abs(p.scale - 134.0 / 982.0) < 1e-9)
        let d = p.displayRect
        #expect(abs(d.height - 134) < 0.01)
        #expect(abs(d.midX - 118) < 0.01)
        // A tall box letterboxes vertically instead.
        let tall = MapProjection(display: builtIn.frame, usable: builtIn.usableFrame, size: CGSize(width: 151.2, height: 200))
        #expect(abs(tall.displayRect.width - 151.2) < 0.01)
        #expect(abs(tall.displayRect.midY - 100) < 0.01)
    }

    @Test func framesMapToMapAndBack() {
        let p = MapProjection(display: builtIn.frame, usable: builtIn.usableFrame, size: box)
        // The top-left corner of the screen is the top-left of the drawn display (y flips).
        let topLeft = p.toMap(CGRect(x: 0, y: 982 - 100, width: 100, height: 100))
        #expect(abs(topLeft.minX - p.displayRect.minX) < 0.01)
        #expect(abs(topLeft.minY - p.displayRect.minY) < 0.01)
        let r = CGRect(x: 96, y: 300, width: 720, height: 500)
        let m = p.toMap(r)
        let back = p.toScreen(CGPoint(x: m.minX, y: m.maxY))
        #expect(abs(back.x - r.minX) < 0.01 && abs(back.y - r.minY) < 0.01)
    }

    @Test func cellUnderPointFollowsTheGrid() {
        let p = MapProjection(display: builtIn.frame, usable: builtIn.usableFrame, size: box)
        let cells = p.cells(of: grid32)
        #expect(cells.count == 6)
        for (cell, rect) in cells {
            let hit = p.cell(at: CGPoint(x: rect.midX, y: rect.midY), grid: grid32)
            #expect(hit == GridCoord(col: cell.col, row: cell.row))
        }
        // The menu bar strip is outside the usable rect: no cell.
        #expect(p.cell(at: CGPoint(x: p.displayRect.midX, y: p.displayRect.minY + 1), grid: grid32) == nil)
    }

    @Test func mapShowsRealFramesOfTheTargetDisplay() async {
        let (model, backend) = await openModel()
        #expect(model.displays.count == 2)
        #expect(model.display?.id == builtIn.id)
        #expect(model.targetID == 11)
        let ids = Set(model.map?.windows.map(\.id) ?? [])
        #expect(ids == [11, 12, 13, 14])
        // Not snapped: exactly the window's frame.
        #expect(model.map?.windows.first { $0.id == 13 }?.frame == backend.window(13)?.frame)
    }

    @Test func pagerShowsTheOtherDisplayAndWraps() async {
        let (model, _) = await openModel()
        model.showDisplay(offset: 1)
        #expect(model.display?.id == SampleWindowsBackend.ultrawide.id)
        #expect(Set(model.map?.windows.map(\.id) ?? []) == [21, 22])
        model.showDisplay(offset: 1)
        #expect(model.display?.id == builtIn.id)
    }

    @Test func registryChangeRefreshesTheMapWhileVisible() async {
        let (model, backend) = await openModel()
        backend.windows.removeAll { $0.id == 14 }
        backend.fireChange()
        await Task.yield(); await Task.yield()
        #expect(model.map?.windows.contains { $0.id == 14 } == false)
    }
}

@Suite("Windows keyboard")
@MainActor
struct WindowsKeyboardTests {
    @Test func arrowsMoveAndShiftExtends() {
        var s = KeyboardSelection(at: GridCoord(col: 0, row: 0))
        s.move(.right, grid: grid32)
        #expect(s.rect == CellRect(col: 1, row: 0))
        s.extend(.right, grid: grid32)
        s.extend(.down, grid: grid32)
        #expect(s.rect == CellRect(col: 1, row: 0, w: 2, h: 2))
        // Extending past the edge stays inside the grid.
        s.extend(.right, grid: grid32)
        #expect(s.rect == CellRect(col: 1, row: 0, w: 2, h: 2))
        // Extending back over the anchor flips the span.
        s.extend(.left, grid: grid32); s.extend(.left, grid: grid32); s.extend(.left, grid: grid32)
        #expect(s.rect == CellRect(col: 0, row: 0, w: 2, h: 2))
        // A plain arrow collapses to one cell.
        s.move(.up, grid: grid32)
        #expect(s.rect == CellRect(col: 0, row: 0))
    }

    @Test func clampAfterSmallerGrid() {
        var s = KeyboardSelection(at: GridCoord(col: 2, row: 1))
        s.clamp(to: GridSpec(cols: 2, rows: 1))
        #expect(s.rect == CellRect(col: 1, row: 0))
    }

    @Test func keyboardModeStartsOnTheTargetsCellAndEnterCommits() async {
        let (model, backend) = await openModel(keyboard: true)
        // Terminal's centre (456, 550) is in the top-left cell of 3×2.
        #expect(model.selection?.rect == CellRect(col: 0, row: 0))
        model.handle(.arrow(.right, shift: true))
        #expect(model.selection?.rect == CellRect(col: 0, row: 0, w: 2, h: 1))
        #expect(model.preview?.moves.first?.windowID == 11)
        #expect(backend.commits.isEmpty)
        model.handle(.enter)
        await model.pending?.value
        #expect(backend.commits.count == 1)
        #expect(backend.commits[0].moves[0].cell == CellRect(col: 0, row: 0, w: 2, h: 1))
        #expect(model.outcome?.allExact == true)
    }

    @Test func digitsApplySavedLayouts() async {
        let backend = SampleWindowsBackend()
        backend.layouts = [SavedLayout(name: "Dev", placements: [
            LayoutPlacement(bundleID: "com.apple.Terminal", cell: CellRect(col: 0, row: 0, w: 1, h: 2)),
            LayoutPlacement(bundleID: "com.apple.Safari", cell: CellRect(col: 1, row: 0, w: 2, h: 2)),
        ])]
        let (model, _) = await openModel(backend)
        model.handle(.digit(2))          // no second layout: nothing
        await model.pending?.value
        #expect(backend.commits.isEmpty)
        model.handle(.digit(1))
        await model.pending?.value
        #expect(backend.commits.count == 1)
        #expect(backend.commits[0].kind == .layout)
        #expect(Set(backend.commits[0].moves.map(\.windowID)) == [11, 12])
    }

    @Test func keyMapping() {
        #expect(WindowsModule.key(for: .keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124)!) == .arrow(.right, shift: true))
        #expect(WindowsModule.key(for: .keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0, context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6)!) == .undo)
        #expect(WindowsModule.key(for: .keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "3", charactersIgnoringModifiers: "3", isARepeat: false, keyCode: 20)!) == .digit(3))
        #expect(WindowsModule.key(for: .keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!) == .arrangeAll)
        // ⌥-arrow is not ours (the user's app keeps it).
        #expect(WindowsModule.key(for: .keyEvent(with: .keyDown, location: .zero, modifierFlags: [.option], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 123)!) == nil)
    }
}

@Suite("Windows drag to the notch")
@MainActor
struct WindowsDragTests {
    let start = CGRect(x: 30, y: 70, width: 640, height: 430)

    @Test func onlyAMoveIntoTheHotZoneOpens() {
        var m = DragMachine()
        m.down(window: 13, frame: start)
        #expect(m.isTracking)
        // Outside the zone the window list is never read.
        var reads = 0
        #expect(m.dragged(to: CGPoint(x: 400, y: 500), inHotZone: false) { reads += 1; return nil } == .none)
        #expect(reads == 0)
        // In the zone but the window has not moved (a text selection): nothing.
        #expect(m.dragged(to: CGPoint(x: 756, y: 975), inHotZone: true) { start } == .none)
        // Moved, same size: the notch takes over.
        let moved = start.offsetBy(dx: 300, dy: 400)
        #expect(m.dragged(to: CGPoint(x: 756, y: 975), inHotZone: true) { moved } == .open(window: 13, frame: start))
        #expect(m.isActive)
        #expect(m.dragged(to: CGPoint(x: 700, y: 900), inHotZone: false) { nil } == .track(CGPoint(x: 700, y: 900)))
        #expect(m.up(at: CGPoint(x: 700, y: 900)) == .drop(CGPoint(x: 700, y: 900)))
        #expect(m.state == .idle)
    }

    @Test func aResizeNeverOpens() {
        var m = DragMachine()
        m.down(window: 13, frame: start)
        let resized = CGRect(x: 30, y: 70, width: 700, height: 600)
        #expect(m.dragged(to: CGPoint(x: 756, y: 975), inHotZone: true) { resized } == .none)
        #expect(m.state == .ignoring)
        #expect(m.dragged(to: CGPoint(x: 756, y: 975), inHotZone: true) { start.offsetBy(dx: 5, dy: 5) } == .none)
        #expect(m.up(at: .zero) == .none)
    }

    @Test func clickOffAWindowAndCancelDoNothing() {
        var m = DragMachine()
        m.down(window: nil, frame: nil)
        #expect(!m.isTracking)
        #expect(m.dragged(to: .zero, inHotZone: true) { start.offsetBy(dx: 9, dy: 9) } == .none)
        m.down(window: 13, frame: start)
        _ = m.dragged(to: .zero, inHotZone: true) { start.offsetBy(dx: 9, dy: 9) }
        m.cancel()
        #expect(m.dragged(to: .zero, inHotZone: true) { nil } == .none)
        #expect(m.up(at: .zero) == .none)
    }

    /// The map at a known place on screen, and the screen point over the centre of a cell.
    private func place(_ model: WindowsModel) -> CGRect {
        let rect = CGRect(x: 640, y: 760, width: 236, height: 134)
        model.mapScreenRect = rect
        model.contentScreenRect = CGRect(x: 627, y: 760, width: 526, height: 156)
        return rect
    }

    private func point(over cell: CellRect, map rect: CGRect) -> CGPoint {
        let p = MapProjection(display: builtIn.frame, usable: builtIn.usableFrame, size: rect.size)
        let r = p.toMap(Geometry.frame(for: cell, in: grid32, on: builtIn.usableFrame))
        return CGPoint(x: rect.minX + r.midX, y: rect.maxY - r.midY)
    }

    @Test func hoverPreviewsAndDropOnAFreeCellPlaces() async {
        let backend = SampleWindowsBackend(windows: SampleWindowsBackend.standardWindows.filter { $0.id == 13 }, target: 13)
        let (model, _) = await openModel(backend)
        model.beginDrag(window: 13, frame: start, display: builtIn, hotZone: CGRect(x: 656, y: 944, width: 201, height: 38))
        let rect = place(model)
        let p = point(over: CellRect(col: 2, row: 1), map: rect)
        #expect(model.dragMoved(to: p) == .none)
        #expect(model.hoverCell == CellRect(col: 2, row: 1))
        #expect(model.preview?.kind == .place)
        #expect(backend.commits.isEmpty)
        #expect(model.dragEnded(at: p) == .committed)
        await model.pending?.value
        #expect(backend.commits.count == 1)
        #expect(backend.commits[0].moves.map(\.windowID) == [13])
        // Undo goes back to where the drag started.
        #expect(backend.commits[0].moves[0].from == start)
        #expect(model.mode == .browse)
    }

    @Test func dropOnAnOccupiedCellSwapsWithThePreDragFrame() async {
        let (model, backend) = await openModel()
        model.beginDrag(window: 13, frame: start, display: builtIn, hotZone: .zero)
        let rect = place(model)
        // Safari (in front) and Notes both cover most of it: the frontmost one is the occupant.
        let p = point(over: CellRect(col: 2, row: 0), map: rect)
        model.dragMoved(to: p)
        #expect(model.preview?.kind == .swap)
        #expect(model.swapPartner == 12)
        model.dragEnded(at: p)
        await model.pending?.value
        let plan = backend.commits.last
        #expect(plan?.kind == .swap)
        #expect(plan?.moves[1].windowID == 12)
        #expect(plan?.moves[1].to == start)
    }

    @Test func leavingThePanelCancelsWithoutCommitting() async {
        var previews: [ArrangePlan?] = []
        let (model, backend) = await openModel()
        model.onPreview = { p, _ in previews.append(p) }
        model.beginDrag(window: 13, frame: start, display: builtIn, hotZone: CGRect(x: 656, y: 944, width: 201, height: 38))
        let rect = place(model)
        model.dragMoved(to: point(over: CellRect(col: 0, row: 0), map: rect))
        #expect(model.preview != nil)
        // Inside the panel but off the map: clears, keeps going.
        #expect(model.dragMoved(to: CGPoint(x: 1000, y: 800)) == .none)
        #expect(model.hoverCell == nil)
        // Far below the panel: cancelled.
        #expect(model.dragMoved(to: CGPoint(x: 900, y: 300)) == .cancelled)
        #expect(model.mode == .browse)
        #expect(model.preview == nil)
        #expect(previews.last! == nil)
        #expect(model.dragEnded(at: CGPoint(x: 900, y: 300)) == .none)
        #expect(backend.commits.isEmpty)
    }

    @Test func releaseOffTheMapCancels() async {
        let (model, backend) = await openModel()
        model.beginDrag(window: 13, frame: start, display: builtIn, hotZone: .zero)
        _ = place(model)
        #expect(model.dragEnded(at: CGPoint(x: 1000, y: 800)) == .cancelled)
        #expect(backend.commits.isEmpty)
    }

    @Test func escCancels() async {
        let (model, backend) = await openModel()
        model.beginDrag(window: 13, frame: start, display: builtIn, hotZone: .zero)
        let rect = place(model)
        model.dragMoved(to: point(over: CellRect(col: 1, row: 0), map: rect))
        model.cancelDrag()
        #expect(model.preview == nil && model.mode == .browse)
        #expect(backend.commits.isEmpty)
    }
}

@Suite("Windows halves cycling")
@MainActor
struct WindowsCyclingTests {
    @Test func stepsOnlyWhileTheWindowStaysPut() {
        let f = CGRect(x: 8, y: 65, width: 744, height: 876)
        let last = HalvesCycle.Last(windowID: 11, action: .leftHalf, step: 0, frame: f)
        #expect(HalvesCycle.nextStep(after: nil, windowID: 11, action: .leftHalf, current: f) == 0)
        #expect(HalvesCycle.nextStep(after: last, windowID: 11, action: .leftHalf, current: f.offsetBy(dx: 1, dy: 0)) == 1)
        #expect(HalvesCycle.nextStep(after: last, windowID: 11, action: .rightHalf, current: f) == 0)
        #expect(HalvesCycle.nextStep(after: last, windowID: 12, action: .leftHalf, current: f) == 0)
        #expect(HalvesCycle.nextStep(after: last, windowID: 11, action: .leftHalf, current: f.offsetBy(dx: 40, dy: 0)) == 0)
        let third = HalvesCycle.Last(windowID: 11, action: .leftHalf, step: 2, frame: f)
        #expect(HalvesCycle.nextStep(after: third, windowID: 11, action: .leftHalf, current: f) == 0)
    }

    @Test func cellsAreHalfTwoThirdsOneThird() {
        #expect(HalvesCycle.cell(for: .leftHalf, step: 0) == CellRect(col: 0, row: 0, w: 3, h: 1))
        #expect(HalvesCycle.cell(for: .leftHalf, step: 1) == CellRect(col: 0, row: 0, w: 4, h: 1))
        #expect(HalvesCycle.cell(for: .leftHalf, step: 2) == CellRect(col: 0, row: 0, w: 2, h: 1))
        #expect(HalvesCycle.cell(for: .rightHalf, step: 0) == CellRect(col: 3, row: 0, w: 3, h: 1))
        #expect(HalvesCycle.cell(for: .rightHalf, step: 1) == CellRect(col: 2, row: 0, w: 4, h: 1))
        #expect(HalvesCycle.cell(for: .rightHalf, step: 2) == CellRect(col: 4, row: 0, w: 2, h: 1))
    }

    @Test func repeatedHotkeyCyclesThroughWidths() async {
        let backend = SampleWindowsBackend()
        let model = WindowsModel(backend: backend)
        let usable = builtIn.usableFrame
        var widths: [CGFloat] = []
        for _ in 0..<4 {
            await model.direct(.leftHalf)
            widths.append(backend.commits.last!.moves[0].to.width / usable.width)
        }
        #expect(widths.map { ($0 * 6).rounded() } == [3, 4, 2, 3])
        // Every one hugs the left edge.
        #expect(backend.commits.allSatisfy { $0.moves[0].to.minX == usable.minX + 8 })
        // The other side starts over at one half.
        await model.direct(.rightHalf)
        #expect(((backend.commits.last!.moves[0].to.width / usable.width) * 6).rounded() == 3)
        #expect(backend.commits.last!.moves[0].to.maxX == usable.maxX - 8)
    }

    @Test func maximiseFitRestoreAndUndo() async {
        let backend = SampleWindowsBackend()
        let model = WindowsModel(backend: backend)
        await model.direct(.maximize)
        #expect(backend.commits.last?.moves[0].to == Geometry.frame(for: .all(grid32), in: grid32, on: builtIn.usableFrame))
        #expect(await model.direct(.restore) == WindowsText.t("Nothing to restore"))
        backend.initialFrames[11] = CGRect(x: 96, y: 300, width: 720, height: 500)
        await model.direct(.restore)
        #expect(backend.commits.last?.kind == .restore)
        #expect(backend.commits.last?.moves[0].to == CGRect(x: 96, y: 300, width: 720, height: 500))
        await model.direct(.undo)
        #expect(backend.undoCount == 1)
    }

    @Test func fitFillsTheLargestFreeAreaAndReportsANonExactLanding() async {
        let backend = SampleWindowsBackend(windows: SampleWindowsBackend.standardWindows.filter { $0.id == 11 || $0.id == 13 })
        backend.outcomes[11] = .appSized
        let model = WindowsModel(backend: backend)
        let line = await model.direct(.fit)
        #expect(backend.commits.last?.kind == .fit)
        // Mail holds the bottom-left; the window goes where nothing is, clear of Mail.
        let mail = SampleWindowsBackend.standardWindows.first { $0.id == 13 }!.frame
        #expect(backend.commits.last.map { !$0.moves[0].to.intersects(mail) } == true)
        #expect(line?.hasPrefix("Terminal kept") == true)
    }
}

@Suite("Windows preview never commits")
@MainActor
struct WindowsPreviewTests {
    @Test func everyPreviewPathLeavesWindowsAlone() async {
        var previews = 0
        let (model, backend) = await openModel()
        model.onPreview = { p, _ in if p != nil { previews += 1 } }
        model.hover(GridCoord(col: 1, row: 0))
        #expect(model.preview?.kind == .place)
        model.hover(GridCoord(col: 2, row: 1))
        model.hover(nil)
        model.sweep(from: GridCoord(col: 0, row: 0), to: GridCoord(col: 1, row: 1))
        #expect(model.preview?.moves.first?.cell == CellRect(col: 0, row: 0, w: 2, h: 2))
        model.hover(GridCoord(col: 2, row: 1))   // ignored mid-sweep
        #expect(model.hoverCell == CellRect(col: 0, row: 0, w: 2, h: 2))
        // (No endSweep: that is the click that commits.)
        let m2 = await openModel(backend).0
        m2.onPreview = { p, _ in if p != nil { previews += 1 } }
        for s in ArrangeStrategy.allCases {
            m2.choose(s)
            #expect(m2.arrangementPreview?.kind == .arrange)
        }
        m2.adjustGrid(cols: 1)
        #expect(m2.grid.cols == 4)
        #expect(m2.arrangementPreview?.grid.cols == 4)
        m2.setGrid(GridSpec(cols: 2, rows: 2))
        m2.handle(.arrangeAll)
        m2.handle(.arrow(.left, shift: false))
        m2.handle(.arrow(.down, shift: true))
        m2.showDisplay(offset: 1)
        m2.handle(.escape)
        #expect(previews > 8)
        #expect(backend.commits.isEmpty)
    }

    @Test func applyCommitsExactlyThePreview() async {
        let (model, backend) = await openModel()
        model.choose(.columns)
        let shown = model.preview
        model.apply()
        await model.pending?.value
        #expect(backend.commits.count == 1)
        #expect(backend.commits[0] == shown)
        #expect(model.strategy == nil && model.preview == nil)
        #expect(model.canUndo)
        // A second chip press toggles the preview off; Apply then does nothing.
        model.choose(.rows); model.choose(.rows)
        model.apply()
        await model.pending?.value
        #expect(backend.commits.count == 1)
    }

    @Test func clickCommitsAndOutcomesAreNamed() async {
        let backend = SampleWindowsBackend()
        backend.outcomes = [11: .appSized]
        let (model, _) = await openModel(backend)
        model.sweep(from: GridCoord(col: 0, row: 0), to: GridCoord(col: 0, row: 1))
        model.endSweep()
        await model.pending?.value
        #expect(backend.commits.count == 1)
        #expect(model.outcome?.badges[11] == .appSized)
        #expect(model.outcome?.line.hasPrefix("Terminal kept") == true)
        model.undo()
        await model.pending?.value
        #expect(backend.undoCount == 1)
    }

    @Test func outcomeWording() {
        func r(_ id: CGWindowID, _ o: PlacementOutcome, landed: CGRect? = CGRect(x: 0, y: 0, width: 700, height: 412)) -> PlacementResult {
            PlacementResult(windowID: id, outcome: o, requested: CGRect(x: 0, y: 0, width: 744, height: 420), original: nil,
                            landed: landed, attempts: 1,
                            euiWasOn: false, note: nil, elapsed: 0)
        }
        let names: (CGWindowID) -> String = { ["", "Terminal", "Mail", "Chrome"][Int($0)] }
        #expect(OutcomeReport(results: [r(1, .exact)], name: names).line == "Placed exactly")
        let mixed = OutcomeReport(results: [r(1, .appSized), r(2, .exact), r(3, .refused)], name: names)
        #expect(mixed.line == "1 exact · Terminal kept 700×412 · Chrome refused")
        #expect(!mixed.allExact)
        #expect(OutcomeReport(results: [r(2, .unreachable, landed: nil)], name: names).line == "Mail unreachable")
    }

    @Test func untrustedShowsNoPreviewAndIgnoresKeys() async {
        let backend = SampleWindowsBackend()
        backend.isTrusted = false
        let (model, _) = await openModel(backend)
        #expect(!model.trusted)
        #expect(model.handle(.enter) == false)
        model.hover(GridCoord(col: 0, row: 0))
        #expect(model.preview == nil)
        backend.isTrusted = true
        model.trustChanged()
        #expect(model.trusted && model.map != nil)
    }

    @Test func layOutAndFocusedCellForTheAgentsLink() async {
        let backend = SampleWindowsBackend()
        let model = WindowsModel(backend: backend)
        let r = await model.layOut(windowIDs: [11, 13])
        #expect(r.count == 2)
        #expect(backend.commits.last?.kind == .arrange)
        #expect(Set(backend.commits.last!.moves.map(\.windowID)) == [11, 13])
        // No cell placed yet: the focused window's cells, and the focused window swaps out.
        let target = backend.window(11)!.frame
        _ = await model.place(windowID: 14)
        #expect(backend.commits.last?.moves.first?.windowID == 14)
        #expect(backend.commits.last?.moves.first?.cell == Geometry.nearestCell(for: target, in: grid32, on: builtIn.usableFrame))
    }

    @Test func hotkeySettingsRoundTripLeniently() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("glancy-windows-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var h = WindowsHotkeys()
        h.fit = Hotkey(keyCode: 3, modifiers: WindowsHotkeys.ctrlOpt | 0x0200)
        try h.save(to: url)
        #expect(WindowsHotkeys.load(from: url) == h)
        try Data(#"{"leftHalf": {"keyCode": "bad"}, "enabled": false}"#.utf8).write(to: url)
        let partial = WindowsHotkeys.load(from: url)
        #expect(partial.enabled == false)
        #expect(partial.open == WindowsHotkeys().open)
        #expect(WindowsHotkeys().bindings.count == 7)
    }
}
