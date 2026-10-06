// The new engine's pure decisions: placement maths, outcomes, classification, history, planner,
// coordinate flip, EUI policy. No Accessibility needed.
import CoreGraphics
import Foundation
import Testing
@testable import GlancyKit

@Suite("Tiling placement maths")
struct TilingPlacementMathTests {
    let usable = CGRect(x: 0, y: 0, width: 1512, height: 900)

    @Test func edgesTouchedWithinTolerance() {
        let left = CGRect(x: 8, y: 8, width: 744, height: 884)
        #expect(PlacementMath.touchedEdges(of: left, in: usable, tolerance: 10) == [.minX, .minY, .maxY])
        let right = CGRect(x: 760, y: 8, width: 744, height: 884)
        #expect(PlacementMath.touchedEdges(of: right, in: usable, tolerance: 10) == [.maxX, .minY, .maxY])
        #expect(PlacementMath.touchedEdges(of: right, in: usable, tolerance: 2) == [])
    }

    @Test func stepSizedWindowOnRightHalfStaysFlushRight() {
        // Terminal keeps 738 instead of 744: it must hug the right edge, not leave the gap there.
        let target = CGRect(x: 760, y: 8, width: 744, height: 884)
        let edges = PlacementMath.touchedEdges(of: target, in: usable, tolerance: 10)
        let f = PlacementMath.anchoredFrame(size: CGSize(width: 738, height: 880), within: target, edges: edges, bounds: usable)
        #expect(f.maxX == target.maxX)
        #expect(f.width == 738)
        // Touches top and bottom: centred vertically.
        #expect(abs(f.midY - target.midY) <= 0.5)
    }

    @Test func stepSizedWindowOnLeftHalfStaysFlushLeft() {
        let target = CGRect(x: 8, y: 8, width: 744, height: 884)
        let edges = PlacementMath.touchedEdges(of: target, in: usable, tolerance: 10)
        let f = PlacementMath.anchoredFrame(size: CGSize(width: 738, height: 884), within: target, edges: edges, bounds: usable)
        #expect(f.minX == target.minX)
    }

    @Test func tooBigWindowIsPushedInside() {
        // An app kept 900 wide in a 744 right-half cell: grows leftwards, stays on screen.
        let target = CGRect(x: 760, y: 8, width: 744, height: 884)
        let edges = PlacementMath.touchedEdges(of: target, in: usable, tolerance: 10)
        let f = PlacementMath.anchoredFrame(size: CGSize(width: 900, height: 884), within: target, edges: edges, bounds: usable)
        #expect(f.width == 900 && f.height == 884)
        #expect(f.maxX == target.maxX)
        #expect(usable.contains(f))
        // Larger than the bounds: the low edge wins.
        let huge = PlacementMath.pushInside(CGRect(x: 100, y: 100, width: 2000, height: 1000), usable)
        #expect(huge.minX == 0 && huge.minY == 0)
    }

    @Test func outcomes() {
        let original = CGRect(x: 100, y: 100, width: 800, height: 600)
        let requested = CGRect(x: 8, y: 8, width: 744, height: 884)
        #expect(PlacementMath.outcome(requested: requested, original: original, landed: requested.offsetBy(dx: 1, dy: -2)) == .exact)
        #expect(PlacementMath.outcome(requested: requested, original: original, landed: original) == .refused)
        #expect(PlacementMath.outcome(requested: requested, original: original,
                                      landed: CGRect(x: 8, y: 12, width: 738, height: 880)) == .appSized)
        // Already there: exact, not refused.
        #expect(PlacementMath.outcome(requested: requested, original: requested, landed: requested) == .exact)
    }

    @Test func flipIsItsOwnInverse() {
        let h: CGFloat = 982
        let cocoa = CGRect(x: 10, y: 20, width: 300, height: 200)
        let ax = ScreenSpace.flip(cocoa, primaryHeight: h)
        #expect(ax == CGRect(x: 10, y: 762, width: 300, height: 200))
        #expect(ScreenSpace.flip(ax, primaryHeight: h) == cocoa)
        // A display above the primary has negative AX y.
        let above = CGRect(x: 0, y: 982, width: 3440, height: 1440)
        #expect(ScreenSpace.flip(above, primaryHeight: h).minY == -1440)
    }

    @Test func usableRectSubtractsStageStrip() {
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 945)
        #expect(ScreenSpace.usableRect(visibleFrame: visible, stripWidth: 190, stripOnLeft: true)
                == CGRect(x: 190, y: 0, width: 1322, height: 945))
        #expect(ScreenSpace.usableRect(visibleFrame: visible, stripWidth: 190, stripOnLeft: false)
                == CGRect(x: 0, y: 0, width: 1322, height: 945))
        #expect(ScreenSpace.usableRect(visibleFrame: visible, stripWidth: 0, stripOnLeft: true) == visible)
    }

    @Test func displayForWindow() {
        let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let wide = CGRect(x: -964, y: 982, width: 3440, height: 1440)
        #expect(ScreenSpace.bestIndex(for: CGRect(x: 10, y: 10, width: 100, height: 100), among: [laptop, wide]) == 0)
        // Straddling: the larger overlap wins.
        #expect(ScreenSpace.bestIndex(for: CGRect(x: 0, y: 900, width: 800, height: 600), among: [laptop, wide]) == 1)
        // Fully off every display: the nearest.
        #expect(ScreenSpace.bestIndex(for: CGRect(x: 5000, y: 2000, width: 10, height: 10), among: [laptop, wide]) == 1)
        #expect(ScreenSpace.bestIndex(for: .zero, among: []) == nil)
    }

    @MainActor @Test func euiRestorePolicy() {
        #expect(!Placer.restoresEUI(bundleID: "com.google.Chrome", assistiveTechnologyOn: false))
        #expect(!Placer.restoresEUI(bundleID: "com.google.Chrome.canary", assistiveTechnologyOn: false))
        #expect(Placer.restoresEUI(bundleID: "com.google.Chrome", assistiveTechnologyOn: true))
        #expect(Placer.restoresEUI(bundleID: "com.apple.mail", assistiveTechnologyOn: false))
        #expect(Placer.restoresEUI(bundleID: nil, assistiveTechnologyOn: false))
        #expect(!Placer.isChromium("com.google.Chromecast"))
    }
}

@Suite("Tiling classification")
struct TilingClassifierTests {
    func traits(_ bundle: String?, subrole: String?, fullscreen: Bool? = true, buttons: Bool = true) -> WindowTraits {
        var t = WindowTraits(bundleID: bundle, subrole: subrole)
        t.hasCloseButton = buttons; t.hasMinimizeButton = buttons; t.hasZoomButton = buttons
        t.hasFullscreenButton = fullscreen != nil
        t.fullscreenButtonEnabled = fullscreen
        t.closeButtonEnabled = buttons
        t.minimizeButtonEnabled = buttons
        t.windowLevel = 0
        return t
    }

    @Test func standardWindowIsATile() {
        #expect(WindowClassifier.classify(traits("com.apple.Terminal", subrole: "AXStandardWindow")) == .tile)
    }

    @Test func dialogsAndPopups() {
        #expect(WindowClassifier.classify(traits("com.apple.finder", subrole: "AXDialog")) == .dialog)
        // No fullscreen button: not designed to be big (About This Mac, Calculator).
        #expect(WindowClassifier.classify(traits("com.apple.calculator", subrole: "AXStandardWindow", fullscreen: nil)) == .dialog)
        // ...except apps that hide it legitimately.
        #expect(WindowClassifier.classify(traits("com.googlecode.iterm2", subrole: "AXStandardWindow", fullscreen: false)) == .tile)
        // Buttonless, unfocused, non-standard: a popup, not a window.
        var t = traits("com.tinyspeck.slackmacgap", subrole: "AXUnknown", fullscreen: nil, buttons: false)
        #expect(WindowClassifier.classify(t) == .popup)
        // Above the normal level (Loop's filter): never tiled.
        t = traits("com.apple.Terminal", subrole: "AXStandardWindow")
        t.windowLevel = 101
        #expect(WindowClassifier.classify(t) == .popup)
        var quick = traits("com.mitchellh.ghostty", subrole: "AXStandardWindow")
        quick.identifier = "com.mitchellh.ghostty.quickTerminal"
        #expect(WindowClassifier.classify(quick) == .popup)
    }
}

@Suite("Tiling history")
@MainActor
struct TilingHistoryTests {
    let a: CGWindowID = 11, b: CGWindowID = 22
    let fa = CGRect(x: 100, y: 100, width: 800, height: 600)
    let fb = CGRect(x: 300, y: 200, width: 700, height: 500)
    let la = CGRect(x: 8, y: 8, width: 744, height: 884)
    let lb = CGRect(x: 760, y: 8, width: 744, height: 884)

    @Test func undoRestoresWindowsStillWhereWeLeftThem() {
        let h = TilingHistory()
        h.record(label: "Arrange", before: [a: fa, b: fb], requested: [a: la, b: lb], landed: [a: la, b: lb])
        #expect(h.canUndo)
        #expect(h.initialFrame(for: a) == fa)
        // b was moved by the user since: only a is restored.
        let plan = h.undoPlan(current: [a: la, b: lb.offsetBy(dx: 0, dy: 40)])
        #expect(plan?.restore == [a: fa])
        h.didUndo(plan!.operation.id)
        #expect(!h.canUndo)
        #expect(h.records.isEmpty)
    }

    @Test func externalMoveResetsHistory() {
        let h = TilingHistory()
        h.record(label: "Place", before: [a: fa], requested: [a: la], landed: [a: la])
        #expect(!h.noteExternalChange(a, current: la.offsetBy(dx: 1, dy: 1)))   // within tolerance
        #expect(h.noteExternalChange(a, current: la.offsetBy(dx: 50, dy: 0)))
        #expect(h.records[a] == nil)
        #expect(!h.canUndo)
    }

    @Test func stackKeepsInitialFrameAcrossOperations() {
        let h = TilingHistory()
        h.record(label: "1", before: [a: fa], requested: [a: la], landed: [a: la])
        h.record(label: "2", before: [a: la], requested: [a: lb], landed: [a: lb])
        #expect(h.initialFrame(for: a) == fa)
        #expect(h.records[a]?.stack.count == 2)
        let plan = h.undoPlan(current: [a: lb])
        #expect(plan?.restore == [a: la])
        h.didUndo(plan!.operation.id)
        #expect(h.records[a]?.lastLanded == la)
        #expect(h.undoPlan(current: [a: la])?.restore == [a: fa])
    }

    @Test func closedWindowIsForgotten() {
        let h = TilingHistory()
        h.record(label: "Arrange", before: [a: fa, b: fb], requested: [a: la, b: lb], landed: [a: la, b: lb])
        h.forget(a)
        #expect(h.operations.first?.landed.keys.sorted() == [b])
        h.forget(b)
        #expect(!h.canUndo)
    }

    @Test func nothingLandedRecordsNothing() {
        let h = TilingHistory()
        #expect(h.record(label: "x", before: [a: fa], requested: [:], landed: [:]) == nil)
        #expect(!h.canUndo)
    }
}

@Suite("Tiling planner")
struct TilingPlannerTests {
    let usable = CGRect(x: 0, y: 0, width: 3440, height: 1410)
    let grid = GridSpec(cols: 2, rows: 2, outerGap: 8, innerGap: 8)

    @Test func arrangeIsAPreviewOfExactCellFrames() {
        let windows = (1...4).map { PlanWindow(id: CGWindowID($0), frame: CGRect(x: CGFloat($0) * 50, y: 100, width: 600, height: 400)) }
        let plan = ArrangePlanner.arrange(windows, grid: grid, strategy: .cells, usable: usable)
        #expect(plan.moves.count == 4)
        #expect(plan.untouched.isEmpty)
        let expected = (0..<4).map { Geometry.frame(for: CellRect(col: $0 % 2, row: $0 / 2), in: grid, on: usable) }
        #expect(expected.allSatisfy { e in plan.moves.contains { $0.to == e } })
        #expect(Set(plan.moves.map(\.windowID)).count == 4)
    }

    @Test func onlyTheFrontmostCapacityIsTiled() {
        let windows = (1...6).map { PlanWindow(id: CGWindowID($0), frame: CGRect(x: 10, y: 10, width: 400, height: 300)) }
        let plan = ArrangePlanner.arrange(windows, grid: grid, strategy: .balanced, usable: usable)
        #expect(plan.moves.map(\.windowID).sorted() == [1, 2, 3, 4])
        #expect(plan.untouched == [5, 6])
    }

    @Test func masterGoesToTheFrontWindow() {
        let g = GridSpec(cols: 4, rows: 2)
        // The front window sits far right; reading order would never pick it for the master.
        let windows = [PlanWindow(id: 9, frame: CGRect(x: 3000, y: 900, width: 300, height: 300)),
                       PlanWindow(id: 1, frame: CGRect(x: 0, y: 900, width: 300, height: 300)),
                       PlanWindow(id: 2, frame: CGRect(x: 0, y: 0, width: 300, height: 300))]
        let plan = ArrangePlanner.arrange(windows, grid: g, strategy: .masterStack, usable: usable)
        let master = plan.moves.first { $0.windowID == 9 }
        #expect(master?.cell?.col == 0 && master?.cell?.h == 2)
    }

    @Test func fitFindsTheHole() {
        let left = Geometry.frame(for: CellRect(col: 0, row: 0, w: 1, h: 2), in: grid, on: usable)
        let move = ArrangePlanner.fit(PlanWindow(id: 1, frame: left.insetBy(dx: 40, dy: 40)), others: [left], grid: grid, usable: usable)
        #expect(move?.cell == CellRect(col: 1, row: 0, w: 1, h: 2))
        let full = Geometry.frame(for: .all(grid), in: grid, on: usable)
        #expect(ArrangePlanner.fit(PlanWindow(id: 1, frame: .zero), others: [full], grid: grid, usable: usable) == nil)
    }

    @Test func dropOnOccupiedCellSwaps() {
        let leftFrame = Geometry.frame(for: CellRect(col: 0, row: 0, w: 1, h: 2), in: grid, on: usable)
        let rightFrame = Geometry.frame(for: CellRect(col: 1, row: 0, w: 1, h: 2), in: grid, on: usable)
        let dragged = PlanWindow(id: 1, frame: leftFrame)
        let occupant = PlanWindow(id: 2, frame: rightFrame)
        let moves = ArrangePlanner.drop(dragged, on: CellRect(col: 1, row: 0, w: 1, h: 2), others: [dragged, occupant],
                                        grid: grid, usable: usable)
        #expect(moves.count == 2)
        #expect(moves[0].windowID == 1 && moves[0].to == rightFrame)
        #expect(moves[1].windowID == 2 && moves[1].to == leftFrame)
        // An empty cell: no swap.
        #expect(ArrangePlanner.drop(dragged, on: CellRect(col: 1, row: 0), others: [dragged], grid: grid, usable: usable).count == 1)
    }

    @Test func layoutMatchingIsOneWindowPerPlacement() {
        let windows = [PlanWindow(id: 1, frame: .zero, bundleID: "com.apple.Terminal", title: "glancy — zsh"),
                       PlanWindow(id: 2, frame: .zero, bundleID: "com.apple.Terminal", title: "tessera — zsh"),
                       PlanWindow(id: 3, frame: .zero, bundleID: "com.apple.mail", title: "Inbox")]
        let placements = [LayoutPlacement(bundleID: "com.apple.Terminal", titleContains: "tessera", cell: CellRect(col: 0, row: 0)),
                          LayoutPlacement(bundleID: "com.apple.Terminal", cell: CellRect(col: 1, row: 0)),
                          LayoutPlacement(bundleID: "com.apple.Terminal", cell: CellRect(col: 1, row: 1)),
                          LayoutPlacement(bundleID: "com.apple.mail", titleContains: "", cell: CellRect(col: 0, row: 1))]
        let matched = ArrangePlanner.match(placements, windows: windows)
        #expect(matched.map(\.1.id) == [2, 1, 3])
    }
}

@Suite("Tiling hotkeys")
struct TilingHotkeyTests {
    @Test func description() {
        // ⌃⌥ + left arrow (Carbon: controlKey 0x1000, optionKey 0x800).
        #expect(Hotkey(keyCode: 123, modifiers: 0x1000 | 0x800).description == "⌃⌥←")
        #expect(Hotkey(keyCode: 6, modifiers: 0x100 | 0x200).description == "⇧⌘Z")
    }
}
