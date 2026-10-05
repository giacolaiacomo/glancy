// Tiling — from (screen, grid, strategy, windows) to target frames. Pure: the preview the UI
// draws and the commit the Placer executes come from the same plan, so what is shown is what
// happens (Rectangle's FootprintWindow principle).

import CoreGraphics
import Foundation

/// A window as the planner needs it. `frame` in Cocoa coordinates.
public struct PlanWindow: Sendable, Equatable {
    public let id: CGWindowID
    public let frame: CGRect
    public let bundleID: String?
    public let title: String
    public init(id: CGWindowID, frame: CGRect, bundleID: String? = nil, title: String = "") {
        self.id = id; self.frame = frame; self.bundleID = bundleID; self.title = title
    }
}

public struct PlannedMove: Sendable, Equatable, Identifiable {
    public var id: CGWindowID { windowID }
    public let windowID: CGWindowID
    public let from: CGRect
    public let to: CGRect
    /// The cells `to` covers, when it is a grid placement (nil for restores and swaps to a frame).
    public let cell: CellRect?
    public init(windowID: CGWindowID, from: CGRect, to: CGRect, cell: CellRect?) {
        self.windowID = windowID; self.from = from; self.to = to; self.cell = cell
    }
}

/// What a commit will do. The UI previews `moves[].to`; `commit` executes exactly these.
public struct ArrangePlan: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case place, arrange, fit, swap, layout, restore }
    public let kind: Kind
    public let displayID: String
    public let usable: CGRect
    public let grid: GridSpec
    public let moves: [PlannedMove]
    /// Windows on the display the plan leaves alone (beyond the grid's capacity).
    public let untouched: [CGWindowID]
    public var isMultiWindow: Bool { moves.count > 1 || kind == .arrange || kind == .layout }

    public init(kind: Kind, displayID: String, usable: CGRect, grid: GridSpec, moves: [PlannedMove],
                untouched: [CGWindowID] = []) {
        self.kind = kind; self.displayID = displayID; self.usable = usable; self.grid = grid
        self.moves = moves; self.untouched = untouched
    }
}

public enum ArrangePlanner {

    /// One window into a cell range.
    public static func place(_ window: PlanWindow, in cell: CellRect, grid: GridSpec, usable: CGRect) -> PlannedMove {
        let c = cell.clamped(to: grid)
        return PlannedMove(windowID: window.id, from: window.frame,
                           to: Geometry.frame(for: c, in: grid, on: usable), cell: c)
    }

    /// Arrange `windows` (front to back) with a strategy. Only the frontmost `cols × rows` are
    /// tiled; the rest are left alone. Cells are paired with windows by minimum travel; under
    /// master + stack the frontmost window takes the master tile.
    public static func arrange(_ windows: [PlanWindow], grid: GridSpec, strategy: ArrangeStrategy,
                               usable: CGRect, masterFraction: CGFloat = 0.6) -> (moves: [PlannedMove], untouched: [CGWindowID]) {
        let g = grid.clamped()
        guard !windows.isEmpty, usable.width > 0, usable.height > 0 else { return ([], windows.map(\.id)) }
        let chosen = Array(windows.prefix(g.cellCount))
        let untouched = windows.dropFirst(g.cellCount).map(\.id)
        let cells = Arrange.partition(count: chosen.count, grid: g, screenAspect: usable.width / usable.height,
                                      strategy: strategy, masterFraction: masterFraction)
        let targets = cells.map { Geometry.frame(for: $0, in: g, on: usable) }

        var assignment: [(PlanWindow, Int)] = []
        var pool = chosen
        var targetIndices = Array(targets.indices)
        if strategy == .masterStack, chosen.count > 1 {
            assignment.append((pool.removeFirst(), 0))
            targetIndices.removeFirst()
        }
        // Reading order first (left to right, top to bottom), so ties resolve predictably.
        pool.sort { a, b in a.frame.minX == b.frame.minX ? a.frame.maxY > b.frame.maxY : a.frame.minX < b.frame.minX }
        let pairs = Arrange.pairing(current: pool.map(\.frame), targets: targetIndices.map { targets[$0] })
        for (i, t) in pairs.enumerated() { assignment.append((pool[i], targetIndices[t])) }

        let moves = assignment.map { window, t in
            PlannedMove(windowID: window.id, from: window.frame, to: targets[t], cell: cells[t])
        }.sorted { a, b in
            (chosen.firstIndex { $0.id == a.windowID } ?? 0) < (chosen.firstIndex { $0.id == b.windowID } ?? 0)
        }
        return (moves, untouched)
    }

    /// The window into the largest free rectangle of cells, ignoring itself. A cell is taken when
    /// another window covers more than half of it. Nil when the grid is full.
    public static func fit(_ window: PlanWindow, others: [CGRect], grid: GridSpec, usable: CGRect) -> PlannedMove? {
        let g = grid.clamped()
        let taken = Geometry.occupancy(of: others, in: g, on: usable)
        guard let cell = Arrange.largestRect(free: taken, cols: g.cols, rows: g.rows) else { return nil }
        return place(window, in: cell, grid: g, usable: usable)
    }

    /// Drop `window` on `cell`. When another window (`others`, front to back) mostly fills that
    /// cell, it swaps: the occupant takes the dropped window's current frame.
    public static func drop(_ window: PlanWindow, on cell: CellRect, others: [PlanWindow], grid: GridSpec,
                            usable: CGRect) -> [PlannedMove] {
        let move = place(window, in: cell, grid: grid, usable: usable)
        let occupant = others.first { other in
            guard other.id != window.id else { return false }
            let i = other.frame.intersection(move.to)
            return !i.isNull && i.width * i.height > move.to.width * move.to.height * 0.5
        }
        guard let occupant else { return [move] }
        return [move, PlannedMove(windowID: occupant.id, from: occupant.frame,
                                  to: pushInside(window.frame, usable), cell: nil)]
    }

    /// Which window each placement of a saved layout applies to: same bundle ID and, when given,
    /// a title containing `titleContains`; one window per placement, front-most first.
    public static func match(_ placements: [LayoutPlacement], windows: [PlanWindow]) -> [(LayoutPlacement, PlanWindow)] {
        var pool = windows
        var out: [(LayoutPlacement, PlanWindow)] = []
        for p in placements {
            guard let i = pool.firstIndex(where: { w in
                w.bundleID == p.bundleID
                    && (p.titleContains.map { $0.isEmpty || w.title.localizedCaseInsensitiveContains($0) } ?? true)
            }) else { continue }
            out.append((p, pool.remove(at: i)))
        }
        return out
    }

    static func pushInside(_ rect: CGRect, _ bounds: CGRect) -> CGRect {
        PlacementMath.pushInside(rect, bounds)
    }
}
