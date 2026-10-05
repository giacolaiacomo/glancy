// Port of Tessera's Tests/GeometryTests.swift to swift-testing. Same checks, same numbers;
// the `needs`/minimums cases are gone with the minimums themselves (RESEARCH A5).
import CoreGraphics
import Foundation
import Testing
@testable import GlancyKit

private let vf = CGRect(x: 0, y: 25, width: 3840, height: 2135)   // a 4K screen minus the menu bar
private let grid = GridSpec(cols: 12, rows: 8, outerGap: 8, innerGap: 8)
private let ultrawide = CGRect(x: 0, y: 0, width: 3440, height: 1410)
private let laptop = CGRect(x: 0, y: 0, width: 1512, height: 892)

@Suite("Tiling geometry")
struct TilingGeometryTests {

    @Test func gridFillsVisibleFrameInsideOuterGap() {
        let topLeft = Geometry.frame(for: CellRect(col: 0, row: 0), in: grid, on: vf)
        let bottomRight = Geometry.frame(for: CellRect(col: 11, row: 7), in: grid, on: vf)
        #expect(abs(topLeft.minX - (vf.minX + 8)) < 1)
        #expect(abs(topLeft.maxY - (vf.maxY - 8)) < 1)
        #expect(abs(bottomRight.maxX - (vf.maxX - 8)) < 1)
        #expect(abs(bottomRight.minY - (vf.minY + 8)) < 1)
    }

    @Test func neighboursAreInnerGapApartAndSpanIsUnion() {
        let a = Geometry.frame(for: CellRect(col: 3, row: 2), in: grid, on: vf)
        let b = Geometry.frame(for: CellRect(col: 4, row: 2), in: grid, on: vf)
        #expect(abs((b.minX - a.maxX) - 8) < 1)
        let span = Geometry.frame(for: CellRect(col: 3, row: 2, w: 2, h: 1), in: grid, on: vf)
        #expect(abs(span.minX - a.minX) < 1 && abs(span.maxX - b.maxX) < 1)
    }

    @Test func hitTestAndNearestCellRoundTrip() {
        for r in 0..<grid.rows {
            for c in 0..<grid.cols {
                let cell = CellRect(col: c, row: r)
                let frame = Geometry.frame(for: cell, in: grid, on: vf)
                let hit = Geometry.cell(at: CGPoint(x: frame.midX, y: frame.midY), in: grid, on: vf)
                #expect(hit == GridCoord(col: c, row: r))
                #expect(Geometry.nearestCell(for: frame, in: grid, on: vf) == cell)
            }
        }
        let big = CellRect(col: 2, row: 1, w: 5, h: 3)
        #expect(Geometry.nearestCell(for: Geometry.frame(for: big, in: grid, on: vf), in: grid, on: vf) == big)
        #expect(Geometry.cell(at: CGPoint(x: -5, y: 100), in: grid, on: vf) == nil)
    }

    @Test(arguments: [GridSpec(cols: 12, rows: 8, outerGap: 8, innerGap: 8),
                      GridSpec(cols: 2, rows: 2, outerGap: 0, innerGap: 0),
                      GridSpec(cols: 3, rows: 2, outerGap: 12, innerGap: 4),
                      GridSpec(cols: 16, rows: 9, outerGap: 2, innerGap: 2)])
    func everyStrategyPartitionsEveryGrid(_ grid: GridSpec) {
        for strategy in ArrangeStrategy.allCases {
            for n in 1...24 {
                let cells = Arrange.partition(count: n, grid: grid, screenAspect: vf.width / vf.height, strategy: strategy)
                #expect(cells.count == n, "\(strategy) n=\(n)")
                guard n <= grid.cols * grid.rows else { continue }
                var cover = Array(repeating: 0, count: grid.cols * grid.rows)
                for cell in cells {
                    for r in cell.row...cell.maxRow { for c in cell.col...cell.maxCol { cover[r * grid.cols + c] += 1 } }
                }
                #expect(!cover.contains { $0 > 1 }, "\(strategy) n=\(n): overlapping tiles")
                if strategy == .cells {
                    #expect(cover.filter { $0 == 1 }.count == n, "\(strategy) n=\(n)")
                } else {
                    #expect(!cover.contains(0), "\(strategy) n=\(n): uncovered cells")
                }
            }
        }
    }

    @Test func roundTripOnOtherGridsAndScreens() {
        for grid in [GridSpec(cols: 3, rows: 2, outerGap: 12, innerGap: 4), GridSpec(cols: 16, rows: 9, outerGap: 0, innerGap: 0)] {
            for screen in [vf, CGRect(x: -1512, y: 300, width: 1512, height: 945)] {
                for r in 0..<grid.rows {
                    for c in 0..<grid.cols {
                        let cell = CellRect(col: c, row: r)
                        let frame = Geometry.frame(for: cell, in: grid, on: screen)
                        #expect(Geometry.nearestCell(for: frame, in: grid, on: screen) == cell)
                        #expect(screen.insetBy(dx: -1, dy: -1).contains(frame))
                    }
                }
            }
        }
    }

    @Test func largestFreeRectangle() {
        var occupied = Array(repeating: Array(repeating: false, count: 6), count: 4)
        for r in 0..<4 { for c in 0..<3 { occupied[r][c] = true } }
        #expect(Arrange.largestRect(free: occupied, cols: 6, rows: 4) == CellRect(col: 3, row: 0, w: 3, h: 4))
        for r in 0..<4 { for c in 0..<6 { occupied[r][c] = true } }
        #expect(Arrange.largestRect(free: occupied, cols: 6, rows: 4) == nil)
    }

    @Test func configFromAnotherVersionStillLoads() throws {
        // Unknown keys are ignored, missing ones fall back.
        let legacy = """
        { "grids": { "ABC-UUID": { "cols": 3, "rows": 2, "outerGap": 8, "innerGap": 8 } },
          "showOverlayOnDrag": true, "autoFitNewWindows": false,
          "defaultStrategy": "balanced", "masterFraction": 0.6 }
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(TilingConfig.self, from: legacy)
        #expect(config.grid(for: "ABC-UUID") == GridSpec(cols: 3, rows: 2, outerGap: 8, innerGap: 8))
        #expect(config.restoreSizeOnDragAway)
        let future = """
        { "grids": { "D9": { "cols": 4, "rows": 3, "outerGap": 0, "innerGap": 0 } },
          "somethingNew": 42, "defaultStrategy": "cells" }
        """.data(using: .utf8)!
        let f = try JSONDecoder().decode(TilingConfig.self, from: future)
        #expect(f.grid(for: "D9").cols == 4)
        #expect(f.defaultStrategy == .cells)
        // A malformed field falls back instead of losing the file; a partial grid keeps its parts.
        let broken = """
        { "grids": { "X": { "cols": 5 } }, "defaultStrategy": "nonsense", "masterFraction": "wide" }
        """.data(using: .utf8)!
        let b = try JSONDecoder().decode(TilingConfig.self, from: broken)
        #expect(b.grid(for: "X") == GridSpec(cols: 5, rows: 8, outerGap: 8, innerGap: 8))
        #expect(b.defaultStrategy == .balanced)
        #expect(b.masterFraction == 0.6)
    }

    @Test func automaticGridShowsEveryWindow() {
        for (frame, name) in [(ultrawide, "ultrawide"), (laptop, "laptop")] {
            for n in 1...12 {
                let g = Arrange.bestGrid(for: n, fitting: frame, like: .default)
                #expect(g.cols * g.rows >= n, "\(name) n=\(n)")
                #expect(g.cols * g.rows - n <= max(1, n / 3), "\(name) n=\(n) wastes cells")
                let cells = Arrange.partition(count: n, grid: g, screenAspect: frame.width / frame.height, strategy: .cells)
                #expect(Set(cells).count == n)
            }
        }
        #expect(Arrange.bestGrid(for: 4, fitting: ultrawide, like: .default) == GridSpec(cols: 2, rows: 2))
        #expect(Arrange.bestGrid(for: 6, fitting: ultrawide, like: .default) == GridSpec(cols: 3, rows: 2))
        #expect(Arrange.bestGrid(for: 2, fitting: laptop, like: .default) == GridSpec(cols: 2, rows: 1))
        let derived = Arrange.bestGrid(for: 5, fitting: ultrawide, like: GridSpec(cols: 12, rows: 8, outerGap: 20, innerGap: 4))
        #expect(derived.outerGap == 20 && derived.innerGap == 4)
    }

    @Test func windowsAlreadyOnTheirCellsStay() {
        let grid = GridSpec(cols: 3, rows: 2)
        let targets = (0..<6).map { Geometry.frame(for: CellRect(col: $0 % 3, row: $0 / 3), in: grid, on: ultrawide) }
        let shuffled = [4, 0, 5, 2, 1, 3]
        #expect(Arrange.pairing(current: shuffled.map { targets[$0] }, targets: targets) == shuffled)
    }

    @Test func pairingNeverTravelsFurtherThanReadingOrder() {
        let grid = GridSpec(cols: 4, rows: 2)
        let targets = (0..<8).map { Geometry.frame(for: CellRect(col: $0 % 4, row: $0 / 4), in: grid, on: ultrawide) }
        var seed: UInt64 = 12345
        func random(_ limit: CGFloat) -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(seed >> 33) / CGFloat(UInt32.max) * limit
        }
        func travel(_ p: [Int], _ current: [CGRect]) -> CGFloat {
            zip(current.indices, p).reduce(0) { t, pair in
                t + hypot(current[pair.0].midX - targets[pair.1].midX, current[pair.0].midY - targets[pair.1].midY)
            }
        }
        for _ in 0..<200 {
            let current = (0..<8).map { _ in
                CGRect(x: random(ultrawide.width - 400), y: random(ultrawide.height - 300), width: 400, height: 300)
            }
            let p = Arrange.pairing(current: current, targets: targets)
            #expect(Set(p).count == 8)
            #expect(travel(p, current) <= travel(Array(0..<8), current) + 0.001)
        }
    }

    @Test func cellsThatGetInTheWay() {
        let tall = CellRect(col: 2, row: 0, w: 1, h: 2)
        #expect(tall.intersects(CellRect(col: 2, row: 1)))
        #expect(CellRect(col: 2, row: 1).intersects(tall))
        #expect(!tall.intersects(CellRect(col: 1, row: 0)))
        #expect(!tall.intersects(CellRect(col: 2, row: 2)))
        #expect(CellRect(col: 0, row: 0, w: 3, h: 2).intersects(CellRect(col: 1, row: 1)))
        #expect(CellRect(col: 0, row: 0).intersects(CellRect(col: 0, row: 0)))
        #expect(CellRect.spanning(GridCoord(col: 3, row: 1), GridCoord(col: 1, row: 2)) == CellRect(col: 1, row: 1, w: 3, h: 2))
    }

    @Test func masterStackOnOneColumnGridHasNoEmptyTiles() {
        let cells = Arrange.partition(count: 3, grid: GridSpec(cols: 1, rows: 4), screenAspect: 1, strategy: .masterStack)
        #expect(cells.count == 3)
        #expect(cells.allSatisfy { $0.w >= 1 && $0.h >= 1 })
    }
}
