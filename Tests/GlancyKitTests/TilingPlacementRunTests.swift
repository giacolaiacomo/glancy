// The placement algorithm (PlacementRun) driven against a simulated window that answers like an
// AX window on the owner's desk: the built-in 1512×982 (primary, menu bar + Dock) and a 3440×1440
// ultrawide above it (AX y = −1440, its own menu bar). The simulation does what macOS and the
// apps do: an app keeps its minimum size without saying so, the system clamps a window taller
// than the display it is on, a title bar never goes under a menu bar. No real window is touched.
import CoreGraphics
import Foundation
import Testing
@testable import GlancyKit

/// A window as the system and its app treat AX writes. AX coordinates.
final class SimulatedWindow: PlaceableWindow {
    struct Screen { let frame: CGRect; let visible: CGRect }
    enum Write: Equatable { case size(CGSize), position(CGPoint) }

    var current: CGRect
    /// What the app enforces silently (AXMinSize not exposed, as most apps do).
    var appMinimum: CGSize = .zero
    /// The app really cannot be resized: size writes do nothing.
    var fixedSize = false
    var positionSettable: Bool? = true
    var sizeSettable: Bool? = true
    var isMinimized = false
    var isFullscreen = false
    let screens: [Screen]
    private(set) var writes: [Write] = []

    init(_ frame: CGRect, screens: [Screen]) {
        current = frame
        self.screens = screens
    }

    var frame: CGRect? { current }

    /// The screen the window's top-left corner is on (else the nearest).
    private func screen(at p: CGPoint) -> Screen {
        screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(p) }
            ?? screens.min { hypot($0.frame.midX - p.x, $0.frame.midY - p.y) < hypot($1.frame.midX - p.x, $1.frame.midY - p.y) }!
    }

    func setSize(_ size: CGSize) {
        writes.append(.size(size))
        guard !fixedSize else { return }
        var s = CGSize(width: max(size.width, appMinimum.width), height: max(size.height, appMinimum.height))
        // constrainFrameRect: never taller than the visible part of the display it is on.
        let vis = screen(at: current.origin).visible
        s.height = min(s.height, max(appMinimum.height, vis.height))
        current.size = s
    }

    func setPosition(_ origin: CGPoint) {
        writes.append(.position(origin))
        var o = origin
        // The title bar stays below the menu bar of the display it lands on.
        let vis = screen(at: origin).visible
        if o.y < vis.minY { o.y = vis.minY }
        current.origin = o
    }

    func settle(timeout: TimeInterval) {}
}

@Suite("Tiling placement run (simulated windows, two displays)")
struct TilingPlacementRunTests {
    /// The owner's desk, Cocoa coordinates (NSScreen), the built-in being the primary.
    static let primaryHeight: CGFloat = 982
    static let builtIn = Display(
        id: "builtin", displayID: 1, name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 57, width: 1512, height: 892),
        usableFrame: CGRect(x: 0, y: 57, width: 1512, height: 892), isBuiltIn: true)
    static let ultrawide = Display(
        id: "ultrawide", displayID: 2, name: "X34", frame: CGRect(x: -928, y: 982, width: 3440, height: 1440),
        visibleFrame: CGRect(x: -928, y: 982, width: 3440, height: 1410),
        usableFrame: CGRect(x: -928, y: 982, width: 3440, height: 1410), isBuiltIn: false)
    static let displays = [builtIn, ultrawide]

    static func ax(_ r: CGRect) -> CGRect { ScreenSpace.flip(r, primaryHeight: primaryHeight) }
    static let screens = displays.map { SimulatedWindow.Screen(frame: ax($0.frame), visible: ax($0.visibleFrame)) }

    /// Plans a cell (Cocoa), places it in AX on `window`, returns the result back in Cocoa.
    static func place(_ cell: CellRect, grid: GridSpec, on d: Display, window: SimulatedWindow,
                      allowRetry: Bool = true) -> (target: CGRect, result: PlacementRun.Result, landed: CGRect?) {
        let target = Geometry.frame(for: cell, in: grid, on: d.usableFrame)
        let p = AXPlacement(windowID: 1, target: ax(target), usable: ax(d.usableFrame),
                            edgeTolerance: grid.clamped().outerGap + 2, restoreEUI: true, allowRetry: allowRetry)
        let r = PlacementRun.run(p, on: window, isCancelled: { false })
        return (target, r, r.landed.map(ax))
    }

    @Test func theUltrawideAboveHasNegativeAXCoordinates() {
        #expect(Self.ax(Self.ultrawide.frame) == CGRect(x: -928, y: -1440, width: 3440, height: 1440))
        #expect(Self.ax(Self.ultrawide.visibleFrame) == CGRect(x: -928, y: -1410, width: 3440, height: 1410))
        #expect(Self.ax(Self.builtIn.visibleFrame) == CGRect(x: 0, y: 33, width: 1512, height: 892))
    }

    @Test func everyCellOfBothDisplaysLandsExactlyFromEitherDisplay() {
        // The owner's grids (built-in 3×1, ultrawide 4×2), plus full-height columns on the
        // ultrawide (taller than the built-in: the size → position → size order matters).
        let cases: [(Display, GridSpec)] = [
            (Self.builtIn, GridSpec(cols: 3, rows: 1)), (Self.ultrawide, GridSpec(cols: 4, rows: 2)),
            (Self.ultrawide, GridSpec(cols: 4, rows: 1)), (Self.builtIn, GridSpec(cols: 12, rows: 8)),
        ]
        let starts = [CGRect(x: 200, y: 300, width: 700, height: 500),        // on the built-in
                      CGRect(x: 100, y: -1300, width: 1600, height: 1200),    // on the ultrawide
                      CGRect(x: 0, y: 33, width: 1512, height: 892)]          // filling the built-in
        for (d, g) in cases {
            for r in 0..<g.rows {
                for c in 0..<g.cols {
                    for s in starts {
                        let w = SimulatedWindow(s, screens: Self.screens)
                        let out = Self.place(CellRect(col: c, row: r), grid: g, on: d, window: w)
                        #expect(out.result.outcome == .exact, "\(d.id) \(g.cols)×\(g.rows) cell \(c),\(r) from \(s)")
                        #expect(out.landed == out.target)
                        #expect(d.visibleFrame.contains(out.landed ?? .null))
                    }
                }
            }
        }
    }

    @Test func writesSizeThenPositionThenSize() {
        let w = SimulatedWindow(CGRect(x: 200, y: 300, width: 700, height: 500), screens: Self.screens)
        let out = Self.place(CellRect(col: 0, row: 0), grid: GridSpec(cols: 4, rows: 1), on: Self.ultrawide, window: w)
        let t = Self.ax(out.target)
        #expect(w.writes == [.size(t.size), .position(t.origin), .size(t.size)])
        #expect(out.result.attempts == 1)
    }

    @Test func anAppWiderThanItsCellStaysOnItsCellsEdgesAndOnScreen() {
        // Built-in 3×1: cells are 493 pt wide; the app will not go below 600.
        let g = GridSpec(cols: 3, rows: 1)
        for col in 0..<3 {
            let w = SimulatedWindow(CGRect(x: 400, y: 200, width: 800, height: 600), screens: Self.screens)
            w.appMinimum = CGSize(width: 600, height: 300)
            let out = Self.place(CellRect(col: col, row: 0), grid: g, on: Self.builtIn, window: w)
            guard let landed = out.landed else { Issue.record("no landing"); continue }
            #expect(out.result.outcome == .appSized)
            #expect(landed.width == 600 && landed.height == out.target.height)
            #expect(Self.builtIn.usableFrame.contains(landed))
            switch col {
            case 0: #expect(landed.minX == out.target.minX)          // flush with the screen's left cell edge
            case 2: #expect(landed.maxX == out.target.maxX)          // flush right
            default: #expect(abs(landed.midX - out.target.midX) <= 0.5)   // centred on its cell
            }
            // Writing again cannot beat a minimum: no second attempt.
            #expect(out.result.attempts == 1)
        }
    }

    @Test func anAppTallerAndWiderThanAnUltrawideCellKeepsTheCellsCorner() {
        let g = GridSpec(cols: 4, rows: 2)
        let w = SimulatedWindow(CGRect(x: 200, y: 300, width: 700, height: 500), screens: Self.screens)
        w.appMinimum = CGSize(width: 900, height: 720)
        let out = Self.place(CellRect(col: 3, row: 1), grid: g, on: Self.ultrawide, window: w)
        guard let landed = out.landed else { Issue.record("no landing"); return }
        #expect(out.result.outcome == .appSized)
        #expect(landed.size == CGSize(width: 900, height: 720))
        #expect(landed.maxX == out.target.maxX && landed.minY == out.target.minY)   // bottom-right corner held
        #expect(Self.ultrawide.visibleFrame.contains(landed))
    }

    @Test func anUnansweredSettableQuestionStillResizes() {
        // A busy app times out on AXUIElementIsAttributeSettable: that is not a "no".
        let w = SimulatedWindow(CGRect(x: 100, y: 100, width: 1200, height: 800), screens: Self.screens)
        w.sizeSettable = nil
        w.positionSettable = nil
        let out = Self.place(CellRect(col: 1, row: 0), grid: GridSpec(cols: 3, rows: 1), on: Self.builtIn, window: w)
        #expect(out.result.outcome == .exact)
        #expect(out.landed == out.target)
    }

    @Test func aWindowThatCannotBeResizedIsCentredInItsCellAtItsSize() {
        let w = SimulatedWindow(CGRect(x: 100, y: 100, width: 400, height: 300), screens: Self.screens)
        w.sizeSettable = false
        w.fixedSize = true
        let out = Self.place(CellRect(col: 1, row: 0), grid: GridSpec(cols: 3, rows: 1), on: Self.builtIn, window: w)
        guard let landed = out.landed else { Issue.record("no landing"); return }
        #expect(landed.size == CGSize(width: 400, height: 300))
        #expect(abs(landed.midX - out.target.midX) <= 0.5 && abs(landed.midY - out.target.midY) <= 0.5)
        #expect(!w.writes.contains { if case .size = $0 { true } else { false } })
    }

    @Test func positionNotSettableIsRefusedWithoutWriting() {
        let w = SimulatedWindow(CGRect(x: 100, y: 100, width: 400, height: 300), screens: Self.screens)
        w.positionSettable = false
        let out = Self.place(CellRect(col: 0, row: 0), grid: GridSpec(cols: 3, rows: 1), on: Self.builtIn, window: w)
        #expect(out.result.outcome == .refused)
        #expect(w.writes.isEmpty)
    }

    @Test func minimizedAndFullscreenAreUnreachable() {
        let w = SimulatedWindow(CGRect(x: 100, y: 100, width: 400, height: 300), screens: Self.screens)
        w.isMinimized = true
        #expect(Self.place(CellRect(col: 0, row: 0), grid: GridSpec(cols: 3, rows: 1), on: Self.builtIn, window: w).result.outcome == .unreachable)
        w.isMinimized = false
        w.isFullscreen = true
        #expect(Self.place(CellRect(col: 0, row: 0), grid: GridSpec(cols: 3, rows: 1), on: Self.builtIn, window: w).result.outcome == .unreachable)
        #expect(w.writes.isEmpty)
    }

    @Test func cancelledBeforeStartingWritesNothing() {
        let w = SimulatedWindow(CGRect(x: 100, y: 100, width: 400, height: 300), screens: Self.screens)
        let p = AXPlacement(windowID: 1, target: CGRect(x: 8, y: 41, width: 493, height: 876), usable: Self.ax(Self.builtIn.usableFrame),
                            edgeTolerance: 10, restoreEUI: true, allowRetry: true)
        #expect(PlacementRun.run(p, on: w, isCancelled: { true }).outcome == .cancelled)
        #expect(w.writes.isEmpty)
    }

    @MainActor @Test func theLineSaysWhenAnAppCannotBeAsSmallAsItsCell() {
        WindowsText.register()
        let requested = CGRect(x: 8, y: 65, width: 493, height: 876)
        let bigger = PlacementResult(windowID: 1, outcome: .appSized, requested: requested, original: nil,
                                     landed: CGRect(x: 0, y: 65, width: 600, height: 876), attempts: 1, euiWasOn: false,
                                     note: nil, elapsed: 0)
        #expect(OutcomeReport.describe(bigger, "Chrome") == "Chrome can't be smaller than 600×876")
        let stepped = PlacementResult(windowID: 1, outcome: .appSized, requested: requested, original: nil,
                                      landed: CGRect(x: 8, y: 65, width: 488, height: 870), attempts: 1, euiWasOn: false,
                                      note: nil, elapsed: 0)
        #expect(OutcomeReport.describe(stepped, "Terminal") == "Terminal kept 488×870")
    }
}
