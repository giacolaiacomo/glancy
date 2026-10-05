// Auto-arrange: the layout chosen per window count (landscape, ultrawide, portrait), how windows
// meet cells (least travel, or pick order), the thumbnails offered per count, the tab's main
// surface (click to pick, Suggested, hover, Apply, Undo, More) and the ⌃⌥A shortcut — on the
// synthetic two-display Mac. Nothing here moves a real window.
import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import GlancyKit

private let builtIn = SampleWindowsBackend.builtIn
private let ultrawide = SampleWindowsBackend.ultrawide
private let onBuiltIn = CGPoint(x: 756, y: 960)
private let onUltrawide = CGPoint(x: 800, y: 2000)
private let gaps = GridSpec(cols: 3, rows: 2)                        // 8 pt outer and inner gaps
private let laptop = CGRect(x: 0, y: 57, width: 1512, height: 892)   // the built-in's usable rect
private let wide = CGRect(x: 0, y: 0, width: 3440, height: 1440)     // 21:9
private let superWide = CGRect(x: 0, y: 0, width: 5120, height: 1440) // 32:9
private let portrait = CGRect(x: 0, y: 0, width: 1080, height: 1920)

private func shape(_ n: Int, _ usable: CGRect) -> WindowsAutoLayout.Shape {
    WindowsAutoLayout.suggested(count: n, usable: usable, gaps: gaps)!
}

/// Frames, in reading order, as (columns, rows) of distinct edges: a quick picture of a layout.
private func frames(_ n: Int, _ usable: CGRect) -> [CGRect] { shape(n, usable).frames(on: usable, gaps: gaps) }

private func windows(_ n: Int, on usable: CGRect) -> [PlanWindow] {
    (0..<n).map { i in
        PlanWindow(id: CGWindowID(100 + i), frame: CGRect(x: usable.minX + CGFloat(i) * 37, y: usable.minY + CGFloat(i % 3) * 29,
                                                          width: 600, height: 400))
    }
}

@Suite("Auto-arrange layouts")
struct WindowsAutoLayoutRuleTests {
    @Test func layoutPerCountOnALaptop() {
        #expect(shape(1, laptop).kind == .full)
        #expect(frames(1, laptop) == [CGRect(x: 8, y: 65, width: 1496, height: 876)])
        #expect(shape(2, laptop).kind == .sideBySide)
        // 3: main = the left half, two stacked on the right.
        let three = frames(3, laptop)
        #expect(shape(3, laptop).kind == .mainStack)
        #expect(three[0].height == 876 && abs(three[0].width - three[1].width) <= 1)
        #expect(three[1].minX > three[0].maxX && three[2].minX == three[1].minX && three[1].minY > three[2].maxY)
        // 4: 2×2; 5–6: 3×2; 7–8: 4×2.
        for (n, cols, rows) in [(4, 2, 2), (5, 3, 2), (6, 3, 2), (7, 4, 2), (8, 4, 2)] {
            let s = shape(n, laptop)
            #expect(s.kind == .grid)
            #expect(s.label?.cols == cols && s.label?.rows == rows, "n = \(n)")
            #expect(s.capacity == n)
        }
        // A grid with a spare cell leaves no hole: the first column holds one tall window.
        let five = frames(5, laptop)
        #expect(five[0].height == 876)
        #expect(Set(five.dropFirst().map(\.height)).count == 1)
    }

    @Test func moreThanEightTakeTheSmallestGridThatKeepsCellsUsable() {
        // 9 on the laptop: 3×3; 10 and 11: 4×3 (the leftmost columns one window shorter).
        let nine = shape(9, laptop)
        #expect(nine.label?.cols == 3 && nine.label?.rows == 3 && nine.capacity == 9)
        let ten = shape(10, laptop)
        #expect(ten.label?.cols == 4 && ten.capacity == 10)
        #expect(ten.cellCountsPerColumn == [2, 2, 3, 3])
        for f in ten.frames(on: laptop, gaps: gaps) {
            #expect(f.width >= WindowsAutoLayout.minCell.width && f.height >= WindowsAutoLayout.minCell.height)
        }
        // 13 do not fit 360×240 cells on a laptop: 12 are arranged, one is left alone.
        let thirteen = shape(13, laptop)
        #expect(thirteen.capacity == 12)
        let plan = WindowsAutoLayout.plan(thirteen, windows: windows(13, on: laptop), order: .minTravel, displayID: "d",
                                          usable: laptop, gaps: gaps)
        #expect(plan.moves.count == 12)
        #expect(plan.untouched == [112])                            // the back-most one
        // The ultrawide holds 10 exactly as 5×2.
        #expect(shape(10, wide).label?.cols == 5 && shape(10, wide).label?.rows == 2)
    }

    @Test func ultrawidePrefersColumns() {
        #expect(shape(2, wide).kind == .sideBySide)
        #expect(shape(3, wide).kind == .columns)
        #expect(Set(frames(3, wide).map(\.height)) == [1424])
        // 4 on 21:9: a column would be 850×1424 (0.6:1), a 2×2 tile 1708×704 (2.4:1); 2×2 is closer
        // to a window's 1.45:1. On 32:9 four columns win (1270×1424 against 2550×704).
        #expect(shape(4, wide).kind == .grid)
        #expect(shape(4, superWide).kind == .columns)
        #expect(shape(6, wide).label?.cols == 3)
    }

    @Test func portraitStacks() {
        #expect(shape(2, portrait).kind == .stacked)
        let two = frames(2, portrait)
        #expect(two[0].minY > two[1].maxY && two[0].width == 1064)
        // 3: the main window on top (full width), two side by side below.
        let three = frames(3, portrait)
        #expect(three[0].width == 1064 && three[1].maxY < three[0].minY && three[1].minY == three[2].minY)
        // 6: two columns of three.
        let six = shape(6, portrait)
        #expect(six.cols == 2 && six.rows == 3)
    }

    @Test func leastTravelLeavesWindowsThatAlreadyFitWhereTheyAre() {
        // Four windows sitting in the 2×2 cells, listed front to back in a scrambled order.
        let cells = frames(4, laptop)
        let ws = [PlanWindow(id: 4, frame: cells[3]), PlanWindow(id: 1, frame: cells[0]),
                  PlanWindow(id: 3, frame: cells[2]), PlanWindow(id: 2, frame: cells[1])]
        let plan = WindowsAutoLayout.plan(shape(4, laptop), windows: ws, order: .minTravel, displayID: "d", usable: laptop, gaps: gaps)
        for m in plan.moves { #expect(m.from == m.to) }
        #expect(plan.moves.map(\.windowID) == [4, 1, 3, 2])        // front-to-back order kept
        // Two windows, left one on the left: they stay on their side.
        let left = PlanWindow(id: 7, frame: CGRect(x: 40, y: 200, width: 500, height: 500))
        let right = PlanWindow(id: 8, frame: CGRect(x: 900, y: 200, width: 500, height: 500))
        let pair = WindowsAutoLayout.plan(shape(2, laptop), windows: [right, left], order: .minTravel, displayID: "d",
                                          usable: laptop, gaps: gaps)
        #expect(pair.moves.first { $0.windowID == 7 }!.to.minX < pair.moves.first { $0.windowID == 8 }!.to.minX)
    }

    @Test func pickOrderFillsCellsInReadingOrder() {
        let left = PlanWindow(id: 7, frame: CGRect(x: 40, y: 200, width: 500, height: 500))
        let right = PlanWindow(id: 8, frame: CGRect(x: 900, y: 200, width: 500, height: 500))
        // #1 = the window on the right: it goes to the left cell anyway.
        let pair = WindowsAutoLayout.plan(shape(2, laptop), windows: [right, left], order: .given, displayID: "d",
                                          usable: laptop, gaps: gaps)
        #expect(pair.moves.map(\.windowID) == [8, 7])
        #expect(pair.moves[0].to.maxX < pair.moves[1].to.minX)
        // Main + 2: #1 takes the main tile, #2 the top right, #3 the bottom right.
        let three = WindowsAutoLayout.plan(shape(3, laptop), windows: windows(3, on: laptop).reversed(), order: .given,
                                           displayID: "d", usable: laptop, gaps: gaps)
        #expect(three.moves.map(\.windowID) == [102, 101, 100])
        #expect(three.moves[0].to.height == 876)
        #expect(three.moves[1].to.minY > three.moves[2].to.maxY)
    }

    @Test func thumbnailsPerCountSuggestedFirst() {
        func ids(_ n: Int, _ usable: CGRect = laptop) -> [String] {
            WindowsAutoLayout.options(count: n, usable: usable, gaps: gaps).map(\.id)
        }
        func kinds(_ n: Int, _ usable: CGRect = laptop) -> [WindowsAutoLayout.Kind] {
            WindowsAutoLayout.options(count: n, usable: usable, gaps: gaps).map(\.shape.kind)
        }
        #expect(WindowsAutoLayout.options(count: 0, usable: laptop, gaps: gaps).isEmpty)
        #expect(kinds(1) == [.full, .leftHalf, .rightHalf])
        #expect(kinds(2) == [.sideBySide, .stacked, .twoThirds])
        #expect(kinds(3) == [.mainStack, .columns, .rows])
        #expect(kinds(4) == [.grid, .columns, .mainStack])
        #expect(kinds(3, wide) == [.columns, .mainStack, .rows])     // the suggestion is not repeated
        #expect(kinds(2, portrait).first == .stacked)
        for n in 1...12 {
            let options = WindowsAutoLayout.options(count: n, usable: laptop, gaps: gaps)
            #expect(options.first?.suggested == true && options.first?.id == WindowsModel.suggestedID)
            #expect(options.dropFirst().allSatisfy { !$0.suggested })
            #expect(Set(options.map(\.id)).count == options.count, "n = \(n)")
            #expect(options.count <= 4)
            // Alternatives never squeeze a window under the minimum.
            for o in options.dropFirst() {
                #expect(o.shape.frames(on: laptop, gaps: gaps).allSatisfy {
                    $0.width >= WindowsAutoLayout.minCell.width && $0.height >= WindowsAutoLayout.minCell.height
                }, "n = \(n) \(o.id)")
            }
        }
        // Five columns would be 296 pt wide on a laptop: not offered.
        #expect(!ids(5).contains("columns"))
    }
}

// MARK: - The tab's main surface

@MainActor
private func open(_ b: SampleWindowsBackend = SampleWindowsBackend()) async -> WindowsModel {
    let model = WindowsModel(backend: b)
    model.outcomeDuration = .milliseconds(1)
    model.closeDelay = .milliseconds(1)
    model.pointer = { onBuiltIn }
    model.open(keyboard: false)
    await model.pending?.value
    return model
}

@Suite("Windows tab layouts")
@MainActor
struct WindowsLayoutSurfaceTests {
    @Test func nothingPickedMeansEveryWindowOfTheDisplay() async throws {
        let b = SampleWindowsBackend()
        let model = await open(b)
        #expect(!model.showsMap)
        #expect(model.layoutWindows.map(\.id) == [11, 12, 13, 14])
        #expect(model.layoutOptions.first?.suggested == true)
        #expect(model.chosenLayout?.shape.kind == .grid)            // 2×2
        let plan = try #require(model.layoutPlan)
        #expect(Set(plan.moves.map(\.windowID)) == [11, 12, 13, 14])
        #expect(plan.displayID == builtIn.id)
        #expect(model.preview == nil)                               // the full map's preview stays empty
        #expect(b.commits.isEmpty)
    }

    @Test func pickingChangesTheCountTheThumbnailsAndTheOrder() async throws {
        let model = await open()
        model.click(14, .plain)
        model.click(13, .plain)
        #expect(model.layoutWindows.map(\.id) == [14, 13])
        #expect(model.layoutOptions.map(\.shape.kind) == [.sideBySide, .stacked, .twoThirds])
        let plan = try #require(model.layoutPlan)
        let notes = try #require(plan.moves.first { $0.windowID == 14 })
        let mail = try #require(plan.moves.first { $0.windowID == 13 })
        #expect(notes.to.maxX < mail.to.minX)                       // #1 left, #2 right
        #expect(model.previewNumbers == [14: 1, 13: 2])
        // A third pick: back to the suggestion for three.
        model.chooseLayout("stacked")
        model.click(12, .plain)
        #expect(model.chosenLayout?.suggested == true)
        #expect(model.layoutOptions.map(\.shape.kind) == [.mainStack, .columns, .rows])
        model.clearPicks()
        #expect(model.layoutWindows.count == 4)
    }

    @Test func hoverPreviewsOnTheScreenOnlyWhileOverAThumbnail() async throws {
        let b = SampleWindowsBackend()
        let model = await open(b)
        var shown: [ArrangePlan?] = []
        model.onPreview = { p, _ in shown.append(p) }
        model.click(13, .plain)
        model.click(14, .plain)
        #expect(shown.allSatisfy { $0 == nil })                     // picking never covers the screen
        model.hoverLayout("stacked")
        let stacked = try #require(shown.last ?? nil)
        #expect(model.layoutPlan == stacked)
        #expect(stacked.moves[0].to.minY > stacked.moves[1].to.maxY)
        #expect(model.chosenLayout?.suggested == true)              // hover is not a choice
        model.hoverLayout(nil)
        #expect(shown.last! == nil)
        #expect(model.layoutPlan?.moves[0].to.maxX ?? 0 < model.layoutPlan?.moves[1].to.minX ?? 0)
        model.hoverApply(true)
        #expect(shown.last! == model.layoutPlan)
        model.hoverApply(false)
        #expect(b.commits.isEmpty)
    }

    @Test func applyCommitsTheChosenLayoutAndUndoTakesItBack() async throws {
        let b = SampleWindowsBackend()
        let model = await open(b)
        model.click(13, .plain)
        model.click(14, .plain)
        model.chooseLayout("twoThirds")
        let shown = try #require(model.layoutPlan)
        model.applyLayout()
        await model.pending?.value
        #expect(b.commits == [shown])
        #expect(b.window(13)?.frame.width ?? 0 > b.window(14)?.frame.width ?? 0)   // #1 takes ⅔
        #expect(model.canUndo)
        #expect(model.layoutInPlace)                                // nothing left to do
        model.applyLayout()
        await model.pending?.value
        #expect(b.commits.count == 1)
        model.handle(.undo)                                         // ⌘Z
        await model.pending?.value
        #expect(b.undoCount == 1)
    }

    @Test func enterAppliesAndEscClearsThenCloses() async {
        let b = SampleWindowsBackend()
        let model = await open(b)
        var closes = 0
        model.onRequestClose = { closes += 1 }
        model.handle(.enter)                                        // Suggested, all four windows
        await model.pending?.value
        #expect(b.commits.count == 1)
        #expect(Set(b.commits[0].moves.map(\.windowID)) == [11, 12, 13, 14])
        #expect(closes == 0)                                        // stays open: Undo is right there
        model.click(12, .plain)
        model.handle(.escape)
        #expect(model.picks.isEmpty && closes == 0)
        model.handle(.escape)
        #expect(closes == 1)
    }

    @Test func moreShowsTheFullMapAndComesBack() async {
        let b = SampleWindowsBackend()
        let model = await open(b)
        model.click(13, .plain)
        model.click(14, .plain)
        model.setMore(true)
        #expect(model.showsMap && model.layoutPlan == nil)
        model.setScope(.app)
        model.choose(.columns)
        #expect(model.arrangementPreview != nil)
        #expect(model.picks.isEmpty)                                // the app scope let the picks go
        model.handle(.escape)                                       // the strategy preview first…
        #expect(model.showMore && model.strategy == nil)
        model.handle(.escape)                                       // …then back to the layouts
        #expect(!model.showsMap && model.scope == .screen && model.strategy == nil)
        #expect(model.layoutPlan != nil)
        // Arrows from the layouts start the keyboard cell cursor (the full map).
        model.handle(.arrow(.left, shift: false))
        #expect(model.showsMap && model.selection != nil)
        model.showLayouts()
        #expect(!model.showsMap)
        #expect(b.commits.isEmpty)
    }

    @Test func clickingAWindowOnThePreviewMapPicksIt() async {
        let model = await open()
        let proj = MapProjection(display: builtIn.frame, usable: builtIn.usableFrame, size: WindowsLayout.previewSize)
        // Notes' top-right corner (Safari covers its middle).
        let corner = proj.toMap(CGRect(x: 1460, y: 900, width: 1, height: 1))
        let id = ScopeRules.pick(at: CGPoint(x: corner.midX, y: corner.midY), windows: model.map?.windows ?? [], projection: proj, target: nil)
        #expect(id == 14)
        model.click(id!, .plain)
        #expect(model.number(14) == 1)
    }
}

// MARK: - ⌃⌥A

@Suite("Auto-arrange shortcut")
@MainActor
struct WindowsAutoArrangeShortcutTests {
    private func model(_ backend: SampleWindowsBackend, pointer: CGPoint) -> WindowsModel {
        let m = WindowsModel(backend: backend)
        m.pointer = { pointer }
        return m
    }

    @Test func arrangesThePointersDisplayAtOnceAndUndoes() async throws {
        let b = SampleWindowsBackend()
        let m = model(b, pointer: onBuiltIn)
        let line = await m.autoArrangeShortcut(appOnly: false)
        let plan = try #require(b.commits.first)
        #expect(plan.displayID == builtIn.id)
        #expect(Set(plan.moves.map(\.windowID)) == [11, 12, 13, 14])   // never the ultrawide's 21, 22
        #expect(plan.moves.allSatisfy { $0.to.size == plan.moves[0].to.size })   // 2×2: four equal tiles
        #expect(line.hasPrefix("2×2"))
        #expect(m.canUndo)
        _ = await m.direct(.undo)                                       // ⌃⌥Z
        #expect(b.undoCount == 1)
        // On the ultrawide: its two windows, side by side.
        let m2 = model(b, pointer: onUltrawide)
        _ = await m2.autoArrangeShortcut(appOnly: false)
        #expect(b.commits.last?.displayID == ultrawide.id)
        #expect(Set(b.commits.last?.moves.map(\.windowID) ?? []) == [21, 22])
    }

    @Test func shiftVariantTakesOnlyTheFrontAppsWindows() async throws {
        let b = SampleWindowsBackend(target: 12)
        b.windows.append(SampleWindowsBackend.window(15, "com.apple.Safari", "Safari", "Apple",
                                                     CGRect(x: 300, y: 420, width: 760, height: 470), z: 2, pid: 1012))
        let m = model(b, pointer: onBuiltIn)
        let line = await m.autoArrangeShortcut(appOnly: true)
        let plan = try #require(b.commits.last)
        #expect(Set(plan.moves.map(\.windowID)) == [12, 15])
        #expect(line.hasPrefix(WindowsText.t("Side by side")))
        let m2 = model(b, pointer: onUltrawide)                         // no Safari there
        let refused = await m2.autoArrangeShortcut(appOnly: true)
        #expect(b.commits.count == 1)
        #expect(refused.contains("Safari"))
    }

    @Test func withoutAccessibilityNothingMoves() async {
        let b = SampleWindowsBackend()
        b.isTrusted = false
        let m = model(b, pointer: onBuiltIn)
        #expect(m.planAutoArrange(appOnly: false) == nil)
        let line = await m.autoArrangeShortcut(appOnly: false)
        #expect(b.commits.isEmpty)
        #expect(line == WindowsText.t("Windows needs Accessibility"))
    }

    @Test func agentsLinkPlansThroughTheSameLayout() throws {
        let b = SampleWindowsBackend()
        let m = model(b, pointer: onBuiltIn)
        // Three sessions, the waiting one (Notes) first: it takes the main tile.
        let plan = try #require(m.planLayOut(windowIDs: [14, 11, 13], readingOrder: true))
        #expect(plan.moves.map(\.windowID) == [14, 11, 13])
        let main = plan.moves[0].to
        #expect(abs(main.height - (builtIn.usableFrame.height - 16)) <= 1)
        #expect(main.minX < plan.moves[1].to.minX)
        let suggested = WindowsAutoLayout.suggested(count: 3, usable: builtIn.usableFrame, gaps: b.grid(for: builtIn))!
        let byTop: (CGRect, CGRect) -> Bool = { $0.maxY == $1.maxY ? $0.minX < $1.minX : $0.maxY > $1.maxY }
        #expect(plan.moves.map(\.to).sorted(by: byTop) == suggested.frames(on: builtIn.usableFrame, gaps: b.grid(for: builtIn)).sorted(by: byTop))
    }
}
