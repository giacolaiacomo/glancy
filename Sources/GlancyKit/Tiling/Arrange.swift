// Tiling — partition strategies, minimum-travel pairing, largest free rectangle, automatic grid.
// Pure arithmetic over a GridSpec. Ported from Tessera (AutoArrange.swift, MIT, same author);
// `bestGrid` no longer takes learned minimum sizes (they drove wrong decisions, RESEARCH A5).

import CoreGraphics
import Foundation

public enum ArrangeStrategy: String, Codable, CaseIterable, Sendable {
    case balanced      // as square as the screen allows
    case cells         // the grid taken literally: one cell per window, empty cells stay empty
    case columns       // one column each
    case rows          // one row each
    case masterStack   // front window large on the left, the rest stacked on the right

    public var title: String {
        switch self {
        case .balanced: String(localized: "Balanced")
        case .cells: String(localized: "One per cell")
        case .columns: String(localized: "Columns")
        case .rows: String(localized: "Rows")
        case .masterStack: String(localized: "Master + stack")
        }
    }
}

public enum Arrange {

    // MARK: Partitioning the grid

    /// Splits `total` grid lines into `parts` contiguous runs, spreading the remainder over the
    /// first runs so no run is ever empty.
    static func split(_ total: Int, into parts: Int) -> [(start: Int, length: Int)] {
        let parts = max(1, min(parts, total))
        let base = total / parts, extra = total % parts
        var result: [(Int, Int)] = []
        var start = 0
        for i in 0..<parts {
            let length = base + (i < extra ? 1 : 0)
            result.append((start, length))
            start += length
        }
        return result
    }

    /// How many columns to use for `n` windows so each tile stays close to `targetAspect`.
    static func columnCount(for n: Int, grid: GridSpec, aspect: CGFloat, targetAspect: CGFloat = 1.45) -> Int {
        var best = 1
        var bestError = CGFloat.greatestFiniteMagnitude
        for k in 1...max(1, min(n, grid.cols)) {
            let rowsUsed = Int(ceil(Double(n) / Double(k)))
            guard rowsUsed <= grid.rows else { continue }
            let tileAspect = (aspect / CGFloat(k)) * CGFloat(rowsUsed)
            let error = abs(log(tileAspect / targetAspect))
            if error < bestError { bestError = error; best = k }
        }
        return best
    }

    /// One cell rect per window, in order. With more windows than cells the extra windows share
    /// the last cell rather than being squeezed into sub-cell slivers (callers normally tile only
    /// the frontmost `cols × rows`).
    public static func partition(count n: Int, grid: GridSpec, screenAspect aspect: CGFloat,
                                 strategy: ArrangeStrategy, masterFraction: CGFloat = 0.6) -> [CellRect] {
        guard n > 0 else { return [] }
        let g = grid.clamped()
        let capacity = g.cols * g.rows
        if n == 1, strategy != .cells { return [CellRect.all(g)] }
        guard n <= capacity else {
            let head = partition(count: capacity, grid: g, screenAspect: aspect, strategy: strategy,
                                 masterFraction: masterFraction)
            return head + Array(repeating: head[capacity - 1], count: n - capacity)
        }

        switch strategy {
        case .cells:
            return (0..<n).map { CellRect(col: $0 % g.cols, row: $0 / g.cols) }

        case .columns:
            guard n <= g.cols else {
                return partition(count: n, grid: g, screenAspect: aspect, strategy: .balanced,
                                 masterFraction: masterFraction)
            }
            return split(g.cols, into: n).map { CellRect(col: $0.start, row: 0, w: $0.length, h: g.rows) }

        case .rows:
            guard n <= g.rows else {
                return partition(count: n, grid: g, screenAspect: aspect, strategy: .balanced,
                                 masterFraction: masterFraction)
            }
            return split(g.rows, into: n).map { CellRect(col: 0, row: $0.start, w: g.cols, h: $0.length) }

        case .masterStack:
            guard g.cols > 1 else {
                return partition(count: n, grid: g, screenAspect: aspect, strategy: .rows,
                                 masterFraction: masterFraction)
            }
            let masterW = max(1, min(g.cols - 1, Int((CGFloat(g.cols) * masterFraction).rounded())))
            let stackCols = g.cols - masterW
            let master = CellRect(col: 0, row: 0, w: masterW, h: g.rows)
            if n - 1 <= g.rows {
                let stack = split(g.rows, into: n - 1).map {
                    CellRect(col: masterW, row: $0.start, w: stackCols, h: $0.length)
                }
                return [master] + stack
            }
            guard n - 1 <= stackCols * g.rows else {
                return partition(count: n, grid: g, screenAspect: aspect, strategy: .balanced,
                                 masterFraction: masterFraction)
            }
            let stackGrid = GridSpec(cols: stackCols, rows: g.rows, outerGap: g.outerGap, innerGap: g.innerGap)
            let stack = partition(count: n - 1, grid: stackGrid,
                                  screenAspect: aspect * CGFloat(stackCols) / CGFloat(g.cols),
                                  strategy: .balanced, masterFraction: masterFraction)
            return [master] + stack.map { CellRect(col: $0.col + masterW, row: $0.row, w: $0.w, h: $0.h) }

        case .balanced:
            let k = columnCount(for: n, grid: g, aspect: aspect)
            let colRuns = split(g.cols, into: k)
            let base = n / k, extra = n % k
            var result: [CellRect] = []
            for (i, run) in colRuns.enumerated() {
                let inThisColumn = base + (i < extra ? 1 : 0)
                guard inThisColumn > 0 else { continue }
                for rowRun in split(g.rows, into: inThisColumn) {
                    result.append(CellRect(col: run.start, row: rowRun.start, w: run.length, h: rowRun.length))
                }
            }
            return result
        }
    }

    // MARK: Pairing windows with cells

    /// Which window goes into which target: `result[window] = target index`.
    ///
    /// The pairing that moves the windows least looks like the screen tidying itself instead of
    /// reshuffling. Reading order is where the search starts; from there any two windows are
    /// swapped while that strictly shortens the total centre-to-centre travel. A window already
    /// sitting on its cell stays.
    public static func pairing(current: [CGRect], targets: [CGRect]) -> [Int] {
        precondition(current.count == targets.count)
        var assignment = Array(current.indices)

        func travel(_ window: Int, _ target: Int) -> CGFloat {
            hypot(current[window].midX - targets[target].midX, current[window].midY - targets[target].midY)
        }

        var improved = true
        while improved {
            improved = false
            for i in assignment.indices {
                for j in assignment.indices where j > i {
                    let now = travel(i, assignment[i]) + travel(j, assignment[j])
                    let swapped = travel(i, assignment[j]) + travel(j, assignment[i])
                    if swapped < now - 0.5 {
                        assignment.swapAt(i, j)
                        improved = true
                    }
                }
            }
        }
        return assignment
    }

    // MARK: Free space

    /// Maximal all-free rectangle (largest rectangle in a histogram, row by row). `occupied` is
    /// indexed `[row][col]`, row 0 at the top. Nil when the grid is full.
    public static func largestRect(free occupied: [[Bool]], cols: Int, rows: Int) -> CellRect? {
        var heights = Array(repeating: 0, count: cols)
        var best: CellRect?
        var bestArea = 0
        for r in 0..<rows {
            for c in 0..<cols { heights[c] = occupied[r][c] ? 0 : heights[c] + 1 }
            var stack: [(startCol: Int, height: Int)] = []
            for c in 0...cols {
                let height = c < cols ? heights[c] : 0
                var start = c
                while let top = stack.last, top.height >= height {
                    stack.removeLast()
                    let area = top.height * (c - top.startCol)
                    if area > bestArea {
                        bestArea = area
                        best = CellRect(col: top.startCol, row: r - top.height + 1, w: c - top.startCol, h: top.height)
                    }
                    start = top.startCol
                }
                if height > 0 { stack.append((start, height)) }
            }
        }
        return bestArea > 0 ? best : nil
    }

    // MARK: Choosing the grid

    /// The grid that shows `n` windows at once on this rect, trading tile aspect (close to
    /// `targetAspect`) against cells nobody asked for. The gaps of `existing` are kept.
    public static func bestGrid(for n: Int, fitting frame: CGRect, like existing: GridSpec,
                                targetAspect: CGFloat = 1.45) -> GridSpec {
        guard n > 0, frame.height > 0 else { return existing }
        let aspect = frame.width / frame.height
        var best = (cols: 1, rows: n)
        var bestScore = CGFloat.greatestFiniteMagnitude
        for cols in 1...max(n, 1) {
            for rows in 1...max(n, 1) {
                let cells = cols * rows
                guard cells >= n else { continue }
                let spare = cells - n
                guard spare <= max(1, n / 3) else { continue }
                let candidate = GridSpec(cols: cols, rows: rows, outerGap: existing.outerGap, innerGap: existing.innerGap)
                let cell = Geometry.cellSize(of: candidate, on: frame)
                guard cell.width > 1, cell.height > 1 else { continue }
                let tileAspect = (aspect / CGFloat(cols)) * CGFloat(rows)
                let score = abs(log(tileAspect / targetAspect)) + CGFloat(spare) * 0.35
                if score < bestScore {
                    bestScore = score
                    best = (cols, rows)
                }
            }
        }
        return GridSpec(cols: best.cols, rows: best.rows, outerGap: existing.outerGap, innerGap: existing.innerGap)
    }
}
