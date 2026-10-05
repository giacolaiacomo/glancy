// The Windows tab's list: pick exactly the windows to arrange (click = only it, ⌘-click = add in
// order, ⇧-click = a range, Space from the keyboard), arrange only those, in pick order — on the
// synthetic two-display Mac. Nothing here moves a real window.
import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import GlancyKit

private let builtIn = SampleWindowsBackend.builtIn
private let onBuiltIn = CGPoint(x: 756, y: 960)

/// Terminal 11 (front), Safari 12, Mail 13, Notes 14 on the built-in; a minimized Preview 16 there too.
@MainActor
private func backend() -> SampleWindowsBackend {
    let b = SampleWindowsBackend()
    var minimized = SampleWindowsBackend.window(16, "com.apple.Preview", "Preview", "scan.pdf",
                                                CGRect(x: 200, y: 200, width: 500, height: 400), z: 6)
    minimized.isMinimized = true
    b.windows.append(minimized)
    return b
}

@MainActor
private func open(_ b: SampleWindowsBackend, keyboard: Bool = false) async -> WindowsModel {
    let model = WindowsModel(backend: b)
    model.outcomeDuration = .milliseconds(1)
    model.closeDelay = .milliseconds(1)
    model.pointer = { onBuiltIn }
    model.open(keyboard: keyboard)
    await model.pending?.value
    return model
}

@Suite("Windows selection")
@MainActor
struct WindowsSelectionTests {
    @Test func listIsTheDisplaysTileableWindowsFrontToBack() async {
        let model = await open(backend())
        #expect(model.listWindows.map(\.id) == [11, 12, 13, 14])     // no minimized, no other display
        #expect(model.picks.isEmpty)
        #expect(model.scope == .screen)
    }

    @Test func plainClickSelectsOnlyThatWindow() async {
        let b = backend()
        let model = await open(b)
        model.click(13, .toggle)
        model.click(14, .toggle)
        #expect(model.scope == .selection)
        model.click(12, .plain)
        #expect(model.picks.isEmpty)
        #expect(model.activeTargetID == 12)
        #expect(model.scope == .screen)
        // The single target keeps the place-in-cell flow.
        model.hover(GridCoord(col: 0, row: 0))
        #expect(model.preview?.moves.map(\.windowID) == [12])
        #expect(b.commits.isEmpty)
    }

    @Test func commandClickBuildsAnOrderedSelection() async {
        let model = await open(backend())
        model.click(14, .toggle)
        #expect(model.picks.ids == [14])
        #expect(model.number(14) == 1)
        #expect(model.scope == .screen)                  // one picked is not yet a selection
        model.click(13, .toggle)
        #expect(model.picks.ids == [14, 13])
        #expect(model.number(14) == 1 && model.number(13) == 2)
        #expect(model.scope == .selection)
        // ⌘-click again removes it; the rest renumber.
        model.click(14, .toggle)
        #expect(model.picks.ids == [13])
        #expect(model.number(13) == 1)
        #expect(model.scope == .screen)
    }

    @Test func commandClickStartsFromAClickedWindowButNotTheOpeningOne() async {
        let model = await open(backend())
        #expect(model.activeTargetID == 11)              // frontmost, by default
        model.click(13, .toggle)
        #expect(model.picks.ids == [13])                 // the default target is not dragged in
        model.click(12, .plain)
        model.click(14, .toggle)
        #expect(model.picks.ids == [12, 14])             // Finder: click A, ⌘-click B = A and B
    }

    @Test func shiftClickAddsARangeInListOrder() async {
        let model = await open(backend())
        model.click(11, .plain)
        model.click(13, .extend)
        #expect(model.picks.ids == [11, 12, 13])
        #expect(model.scope == .selection)
        model.click(14, .extend)
        #expect(model.picks.ids == [11, 12, 13, 14])
        // Upwards from the last ⌘-clicked: in that direction.
        let other = await open(backend())
        other.click(14, .toggle)
        other.click(12, .extend)
        #expect(other.picks.ids == [14, 13, 12])
    }

    @Test func arrangeActsOnTheSelectionOnly() async throws {
        let b = backend()
        let model = await open(b)
        let before = Dictionary(uniqueKeysWithValues: b.windows.map { ($0.id, $0.frame) })
        model.click(12, .toggle)
        model.click(14, .toggle)
        model.choose(.balanced)
        let plan = try #require(model.arrangementPreview)
        #expect(Set(plan.moves.map(\.windowID)) == [12, 14])
        model.apply()
        await model.pending?.value
        let committed = try #require(b.commits.last)
        #expect(Set(committed.moves.map(\.windowID)) == [12, 14])
        for id: CGWindowID in [11, 13, 16, 21, 22] {
            #expect(b.window(id)?.frame == before[id])   // untouched
        }
    }

    @Test func twoPickedIn2x1GoFirstLeftSecondRight() async throws {
        let b = backend()
        let model = await open(b)
        // Notes (right of the desk) first, Mail (left) second: the order wins over position.
        model.click(14, .toggle)
        model.click(13, .toggle)
        model.choosePreset(GridSpec(cols: 2, rows: 1))
        #expect(model.strategy == .cells)
        let plan = try #require(model.arrangementPreview)
        let notes = try #require(plan.moves.first { $0.windowID == 14 })
        let mail = try #require(plan.moves.first { $0.windowID == 13 })
        #expect(notes.to.maxX <= mail.to.minX)           // #1 left, #2 right
        #expect(abs(notes.to.height - builtIn.usableFrame.height) < 40)
        #expect(model.previewNumbers == [14: 1, 13: 2])
        #expect(b.commits.isEmpty)                       // preview only
        model.handle(.enter)
        await model.pending?.value
        #expect(b.commits.count == 1)
        #expect(b.window(14)?.frame == notes.to)
        #expect(b.window(13)?.frame == mail.to)
    }

    @Test func twoPickedIn1x2AreStackedFirstOnTop() async throws {
        let model = await open(backend())
        model.click(13, .toggle)
        model.click(12, .toggle)
        model.choosePreset(GridSpec(cols: 1, rows: 2))
        let plan = try #require(model.arrangementPreview)
        let first = try #require(plan.moves.first { $0.windowID == 13 })
        let second = try #require(plan.moves.first { $0.windowID == 12 })
        #expect(first.to.minY >= second.to.maxY)         // Cocoa: #1 above
    }

    @Test func swapReversesTheTwoAndRotatesMore() async throws {
        let model = await open(backend())
        model.click(14, .toggle)
        model.click(13, .toggle)
        model.choosePreset(GridSpec(cols: 2, rows: 1))
        model.rotatePicks()
        #expect(model.picks.ids == [13, 14])
        let plan = try #require(model.arrangementPreview)
        let mail = try #require(plan.moves.first { $0.windowID == 13 })
        let notes = try #require(plan.moves.first { $0.windowID == 14 })
        #expect(mail.to.maxX <= notes.to.minX)           // swapped in the preview
        model.handle(.swapPicks)
        #expect(model.picks.ids == [14, 13])
        model.click(12, .toggle)
        model.handle(.swapPicks)
        #expect(model.picks.ids == [13, 12, 14])
    }

    @Test func moreThanTheGridHoldsLeavesTheLastPickedAlone() async throws {
        let model = await open(backend())
        for id: CGWindowID in [11, 12, 13] { model.click(id, .toggle) }
        model.choosePreset(GridSpec(cols: 2, rows: 1))
        let plan = try #require(model.arrangementPreview)
        #expect(Set(plan.moves.map(\.windowID)) == [11, 12])
        #expect(plan.untouched == [13])
    }

    @Test func escapeClearsTheSelectionFirstThenCloses() async {
        let model = await open(backend())
        var closes = 0
        model.onRequestClose = { closes += 1 }
        model.click(13, .toggle)
        model.click(14, .toggle)
        model.choose(.columns)
        #expect(model.preview != nil)
        model.handle(.escape)
        #expect(model.picks.isEmpty)
        #expect(model.scope == .screen)
        #expect(model.strategy == nil)
        #expect(model.preview == nil)
        #expect(closes == 0)
        model.handle(.escape)
        #expect(closes == 1)
    }

    @Test func spaceTogglesTheTargetFromTheKeyboard() async throws {
        let model = await open(backend(), keyboard: true)
        #expect(model.activeTargetID == 11)
        model.handle(.togglePick)
        #expect(model.picks.ids == [11])
        model.handle(.cycle(forward: true))              // Tab moves the target, keeps the picks
        #expect(model.activeTargetID == 12)
        #expect(model.picks.ids == [11])
        model.handle(.togglePick)
        #expect(model.picks.ids == [11, 12])
        #expect(model.scope == .selection)
        model.handle(.togglePick)
        #expect(model.picks.ids == [11])

        func key(_ chars: String, _ code: UInt16) throws -> WindowsModel.Key? {
            let e = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                  context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                                  isARepeat: false, keyCode: code))
            return WindowsModule.key(for: e)
        }
        #expect(try key(" ", 49) == .togglePick)
        #expect(try key("s", 1) == .swapPicks)
    }

    @Test func selectionResetsWhenTheTabOpens() async {
        let model = await open(backend())
        model.click(13, .toggle)
        model.click(14, .toggle)
        model.close()
        model.open(keyboard: false)
        await model.pending?.value
        #expect(model.picks.isEmpty)
        #expect(model.scope == .screen)
    }

    @Test func otherScopesLetTheSelectionGo() async {
        let model = await open(backend())
        model.click(13, .toggle)
        model.click(14, .toggle)
        model.setScope(.screen)
        #expect(model.picks.isEmpty)
        model.click(13, .toggle)
        model.click(14, .toggle)
        model.setScope(.selection)
        #expect(model.scope == .selection)
        model.showDisplay(offset: 1)                     // another display: nothing picked there
        #expect(model.picks.isEmpty)
        #expect(model.scope == .screen)
    }

    @Test func aClosedWindowLeavesTheSelection() async {
        let b = backend()
        let model = await open(b)
        model.click(13, .toggle)
        model.click(14, .toggle)
        b.windows.removeAll { $0.id == 14 }
        b.fireChange()
        #expect(model.picks.ids == [13])
        #expect(model.scope == .screen)
    }

    @Test func theSelectionIsNotPlacedCellByCell() async {
        let model = await open(backend())
        model.click(13, .toggle)
        model.click(14, .toggle)
        model.hover(GridCoord(col: 0, row: 0))
        #expect(model.hoverCell == nil)
        #expect(model.preview == nil)
        // On the map, ⌘ / ⇧ (or the selection scope) let any window body pick.
        #expect(MapView.pickTarget(model, .plain) == nil)
        model.clearPicks()
        #expect(MapView.pickTarget(model, .plain) == model.activeTargetID)
        #expect(MapView.pickTarget(model, .toggle) == nil)
    }

    @Test func hoveringARowOutlinesThatWindow() async {
        let model = await open(backend())
        var shown: [CGWindowID?] = []
        model.onHighlight = { w, d in
            shown.append(w?.id)
            if w != nil { #expect(d?.id == builtIn.id) }
        }
        model.hoverRow(14)
        model.hoverRow(12)
        model.hoverRow(nil)
        #expect(shown == [14, 12, nil])
        #expect(model.preview == nil)                    // an outline, not a plan
    }

    @Test func pickedWindowsArePure() {
        var p = PickedWindows()
        p.toggle(3, seed: 1)
        #expect(p.ids == [1, 3])
        p.toggle(1)
        #expect(p.ids == [3])
        p.extend(to: 6, in: [1, 2, 3, 4, 5, 6])
        #expect(p.ids == [3, 4, 5, 6])
        p.rotate()
        #expect(p.ids == [4, 5, 6, 3])
        p.keep(only: [3, 5])
        #expect(p.ids == [5, 3])
        #expect(p.number(of: 3) == 2)
        #expect(ScopeRules.arrangeIDs(.selection, app: nil, on: SampleWindowsBackend.standardWindows, picked: [14, 99, 13]) == [14, 13])
    }
}
