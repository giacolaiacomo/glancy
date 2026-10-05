// Tiling — auto-arrange: from "N windows on this display" to one layout, without asking for a grid
// or a strategy. Also the short list of alternatives that make sense for N (the Windows tab's
// thumbnails). Pure: the tab's preview, the ⌃⌥A shortcut and the Agents link all plan here.
//
// Rules (usable rect aspect a = width / height; portrait a < 1, ultrawide a ≥ 2.1):
//   1 → full · 2 → side by side (portrait: stacked) · 3 → main (left half) + 2 stacked
//   (ultrawide: three columns; portrait: main on top + 2 side by side) · 4 → 2×2 (ultrawide: four
//   columns or 2×2, whichever tile is closer to 1.45:1) · 5–6 → 3×2 · 7–8 → 4×2 (portrait: the
//   transpose) · more → the smallest grid whose cells stay ≥ `minCell`; beyond what fits, the
//   rest is left alone. A grid with spare cells never leaves a hole: the leftmost columns hold one
//   window fewer and their tiles are taller.

import CoreGraphics
import Foundation

public enum WindowsAutoLayout {
    /// What a layout is called (the thumbnails' captions).
    public enum Kind: String, Sendable, CaseIterable {
        case full, leftHalf, rightHalf, sideBySide, stacked, twoThirds, mainStack, columns, rows, grid
    }

    /// A layout: cells of a grid, in reading order (top row first, left to right). Cell `i` goes to
    /// window #`i + 1` when the order matters.
    public struct Shape: Equatable, Sendable {
        public let kind: Kind
        /// Grid lines only (gaps are the display's, added by `grid(gaps:)`).
        public let cols: Int
        public let rows: Int
        public let cells: [CellRect]
        /// `kind == .grid`: columns × rows as the eye reads it (for the caption).
        public let label: (cols: Int, rows: Int)?

        public var capacity: Int { cells.count }

        public static func == (a: Shape, b: Shape) -> Bool {
            a.kind == b.kind && a.cols == b.cols && a.rows == b.rows && a.cells == b.cells
                && a.label?.cols == b.label?.cols && a.label?.rows == b.label?.rows
        }

        /// The same cells, whatever the kind (two kinds can draw the same layout).
        func sameCells(as other: Shape) -> Bool {
            normalised == other.normalised
        }

        /// Cells as fractions of the screen (so 2×1 and 4×2-with-spans compare equal).
        private var normalised: [CGRect] {
            cells.map {
                CGRect(x: CGFloat($0.col) / CGFloat(cols), y: CGFloat($0.row) / CGFloat(rows),
                       width: CGFloat($0.w) / CGFloat(cols), height: CGFloat($0.h) / CGFloat(rows))
            }
        }

        public func grid(gaps: GridSpec) -> GridSpec {
            GridSpec(cols: cols, rows: rows, outerGap: gaps.outerGap, innerGap: gaps.innerGap)
        }

        /// Screen frames of the cells on `usable`, in reading order.
        public func frames(on usable: CGRect, gaps: GridSpec) -> [CGRect] {
            let g = grid(gaps: gaps)
            return cells.map { Geometry.frame(for: $0, in: g, on: usable) }
        }

        /// Rows become columns (portrait displays, "stacked" variants).
        func transposed(_ kind: Kind? = nil) -> Shape {
            Shape(kind: kind ?? self.kind, cols: rows, rows: cols,
                  cells: Self.reading(cells.map { CellRect(col: $0.row, row: $0.col, w: $0.h, h: $0.w) }),
                  label: label.map { ($0.rows, $0.cols) })
        }

        static func reading(_ cells: [CellRect]) -> [CellRect] {
            cells.sorted { $0.row == $1.row ? $0.col < $1.col : $0.row < $1.row }
        }
    }

    /// A thumbnail: the suggested layout first, then the alternatives.
    public struct Option: Equatable, Sendable, Identifiable {
        public let id: String
        public let shape: Shape
        public let suggested: Bool
    }

    /// How windows meet cells: by least total movement, or in the given order (#1 → first cell).
    public enum Order: Sendable { case minTravel, given }

    public static let ultrawideAspect: CGFloat = 2.1
    /// The smallest tile worth making (points). Below it a grid is not offered (more windows than
    /// fit are left alone instead).
    public static let minCell = CGSize(width: 360, height: 240)
    /// The tile shape the eye reads as a comfortable window.
    static let targetAspect: CGFloat = 1.45

    // MARK: Building blocks

    /// Columns left to right, column `i` split into `counts[i]` equal tiles and `widths[i]` grid
    /// columns wide. Rows = the least common multiple of the counts, so every column's tiles are
    /// equal and line up with the gaps.
    static func columns(_ counts: [Int], widths: [Int]? = nil, kind: Kind) -> Shape {
        let counts = counts.map { max(1, $0) }
        let widths = widths ?? Array(repeating: 1, count: counts.count)
        let rows = Set(counts).reduce(1) { lcm($0, $1) }
        var cells: [CellRect] = []
        var col = 0
        for (i, n) in counts.enumerated() {
            let w = widths[i], h = rows / n
            for k in 0..<n { cells.append(CellRect(col: col, row: k * h, w: w, h: h)) }
            col += w
        }
        return Shape(kind: kind, cols: col, rows: rows, cells: Shape.reading(cells), label: nil)
    }

    /// `n` windows over `cols` columns, the leftmost columns holding one fewer when it does not divide.
    static func grid(_ n: Int, cols: Int) -> Shape {
        let cols = max(1, min(cols, n))
        let base = n / cols, extra = n % cols
        let counts = (0..<cols).map { $0 < cols - extra ? base : base + 1 }
        let s = columns(counts, kind: .grid)
        return Shape(kind: .grid, cols: s.cols, rows: s.rows, cells: s.cells, label: (cols, counts.max() ?? 1))
    }

    static func shape(_ kind: Kind, _ n: Int) -> Shape {
        switch kind {
        case .full: return columns([1], kind: .full)
        case .leftHalf: return Shape(kind: .leftHalf, cols: 2, rows: 1, cells: [CellRect(col: 0, row: 0)], label: nil)
        case .rightHalf: return Shape(kind: .rightHalf, cols: 2, rows: 1, cells: [CellRect(col: 1, row: 0)], label: nil)
        case .sideBySide: return columns([1, 1], kind: .sideBySide)
        case .stacked: return columns([1, 1], kind: .stacked).transposed()
        case .twoThirds: return columns([1, 1], widths: [2, 1], kind: .twoThirds)
        case .mainStack:
            // Main = the left half; up to three stacked beside it, more in two columns.
            let rest = max(1, n - 1)
            return rest <= 3 ? columns([1, rest], kind: .mainStack)
                : columns([1] + grid(rest, cols: 2).cellCountsPerColumn, widths: [2, 1, 1], kind: .mainStack)
        case .columns: return columns(Array(repeating: 1, count: max(1, n)), kind: .columns)
        case .rows: return columns(Array(repeating: 1, count: max(1, n)), kind: .rows).transposed()
        case .grid: return grid(n, cols: 2)
        }
    }

    // MARK: Choosing

    /// The layout for `n` windows on `usable` (nil when there is nothing to arrange). Its
    /// capacity may be below `n` (too many windows for `minCell`): the rest stay where they are.
    public static func suggested(count n: Int, usable: CGRect, gaps: GridSpec = GridSpec(cols: 1, rows: 1)) -> Shape? {
        guard n > 0, usable.width > 0, usable.height > 0 else { return nil }
        let a = usable.width / usable.height
        let portrait = a < 1, ultrawide = a >= ultrawideAspect
        func turn(_ s: Shape) -> Shape { portrait ? s.transposed() : s }
        switch n {
        case 1: return shape(.full, 1)
        case 2: return shape(portrait ? .stacked : .sideBySide, 2)
        case 3: return ultrawide ? shape(.columns, 3) : turn(shape(.mainStack, 3))
        case 4:
            guard ultrawide else { return shape(.grid, 4) }
            let cols = shape(.columns, 4), square = shape(.grid, 4)
            return tileError(cols, usable, gaps) <= tileError(square, usable, gaps) ? cols : square
        case 5, 6: return turn(grid(n, cols: 3))
        case 7, 8: return turn(grid(n, cols: 4))
        default: return turn(largeGrid(n, usable: portrait ? usable.transposedSize : usable, gaps: gaps))
        }
    }

    /// Nine or more: the fewest cells that hold `n` with every cell ≥ `minCell`, tiles closest
    /// to `targetAspect` on a tie; when nothing holds `n`, the biggest grid that still keeps cells
    /// ≥ `minCell` (its capacity says how many are arranged).
    static func largeGrid(_ n: Int, usable: CGRect, gaps: GridSpec) -> Shape {
        var best: (cells: Int, error: CGFloat, cols: Int, rows: Int)?
        var biggest: (cells: Int, error: CGFloat, cols: Int, rows: Int)?
        for cols in 1...12 {
            for rows in 1...8 {
                let g = GridSpec(cols: cols, rows: rows, outerGap: gaps.outerGap, innerGap: gaps.innerGap)
                let size = Geometry.cellSize(of: g, on: usable)
                guard size.width >= minCell.width, size.height >= minCell.height else { continue }
                let error = abs(log((size.width / max(1, size.height)) / targetAspect))
                let c = cols * rows
                if c >= n, best.map({ c < $0.cells || (c == $0.cells && error < $0.error) }) ?? true {
                    best = (c, error, cols, rows)
                }
                if biggest.map({ c > $0.cells || (c == $0.cells && error < $0.error) }) ?? true {
                    biggest = (c, error, cols, rows)
                }
            }
        }
        if let best { return grid(n, cols: best.cols) }
        guard let biggest else { return shape(.full, 1) }
        return grid(biggest.cells, cols: biggest.cols)
    }

    /// The thumbnails for `n` windows: the suggestion, then up to three alternatives that differ
    /// from it and keep every cell ≥ `minCell`.
    public static func options(count n: Int, usable: CGRect, gaps: GridSpec = GridSpec(cols: 1, rows: 1)) -> [Option] {
        guard let s = suggested(count: n, usable: usable, gaps: gaps) else { return [] }
        let portrait = usable.width < usable.height
        var candidates: [Shape]
        switch n {
        case 1: candidates = [shape(.leftHalf, 1), shape(.rightHalf, 1)]
        case 2: candidates = [shape(.sideBySide, 2), shape(.stacked, 2), shape(.twoThirds, 2)]
        case 3: candidates = [shape(.mainStack, 3), shape(.columns, 3), shape(.rows, 3)]
        case 4: candidates = [shape(.grid, 4), shape(.columns, 4), shape(.mainStack, 4)]
        case 5: candidates = [grid(5, cols: 3), shape(.mainStack, 5), grid(5, cols: 3).transposed(), shape(.columns, 5)]
        case 6: candidates = [grid(6, cols: 3), grid(6, cols: 3).transposed(), grid(6, cols: 2), shape(.columns, 6)]
        case 7, 8: candidates = [grid(n, cols: 4), grid(n, cols: 4).transposed(), grid(n, cols: 3)]
        default: candidates = [s.transposed()]
        }
        if portrait, n > 2 { candidates = candidates.map { $0.kind == .columns || $0.kind == .rows ? $0 : $0.transposed() } }
        var out = [Option(id: "suggested", shape: s, suggested: true)]
        for c in candidates where out.count < 4 {
            guard !out.contains(where: { $0.shape.sameCells(as: c) }), c.capacity >= min(n, s.capacity),
                  fits(c, usable, gaps) else { continue }
            out.append(Option(id: id(of: c), shape: c, suggested: false))
        }
        return out
    }

    static func id(of s: Shape) -> String {
        if let l = s.label { return "\(s.kind.rawValue)-\(l.cols)x\(l.rows)" }
        return s.kind.rawValue
    }

    static func fits(_ s: Shape, _ usable: CGRect, _ gaps: GridSpec) -> Bool {
        s.frames(on: usable, gaps: gaps).allSatisfy { $0.width >= minCell.width && $0.height >= minCell.height }
    }

    /// How far a layout's average tile is from `targetAspect` (log distance; 0 = spot on).
    static func tileError(_ s: Shape, _ usable: CGRect, _ gaps: GridSpec) -> CGFloat {
        let frames = s.frames(on: usable, gaps: gaps)
        guard !frames.isEmpty else { return .greatestFiniteMagnitude }
        return frames.map { abs(log(($0.width / max(1, $0.height)) / targetAspect)) }.reduce(0, +) / CGFloat(frames.count)
    }

    // MARK: Planning

    /// The plan: the first `shape.capacity` windows (front to back, or the given order) into its
    /// cells, the rest untouched. `.minTravel` pairs them by least total travel (Arrange.pairing,
    /// as Balanced does); `.given` hands cells out in reading order to the windows in order.
    public static func plan(_ shape: Shape, windows: [PlanWindow], order: Order, displayID: String,
                            usable: CGRect, gaps: GridSpec) -> ArrangePlan {
        let g = shape.grid(gaps: gaps)
        let chosen = Array(windows.prefix(shape.capacity))
        let untouched = windows.dropFirst(shape.capacity).map(\.id)
        let cells = Array(shape.cells.prefix(chosen.count))
        let targets = cells.map { Geometry.frame(for: $0, in: g, on: usable) }
        var moves: [PlannedMove] = []
        switch order {
        case .given:
            for (w, i) in zip(chosen, targets.indices) {
                moves.append(PlannedMove(windowID: w.id, from: w.frame, to: targets[i], cell: cells[i]))
            }
        case .minTravel:
            // Reading order first (left to right, top to bottom), so ties resolve predictably.
            let pool = chosen.sorted { a, b in a.frame.minX == b.frame.minX ? a.frame.maxY > b.frame.maxY : a.frame.minX < b.frame.minX }
            let pairs = Arrange.pairing(current: pool.map(\.frame), targets: targets)
            for (i, t) in pairs.enumerated() {
                moves.append(PlannedMove(windowID: pool[i].id, from: pool[i].frame, to: targets[t], cell: cells[t]))
            }
            let rank = Dictionary(chosen.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
            moves.sort { (rank[$0.windowID] ?? 0) < (rank[$1.windowID] ?? 0) }
        }
        return ArrangePlan(kind: .arrange, displayID: displayID, usable: usable, grid: g, moves: moves, untouched: untouched)
    }

    /// Suggested layout + plan in one step (the shortcut and the Agents link).
    public static func plan(windows: [PlanWindow], order: Order, displayID: String, usable: CGRect,
                            gaps: GridSpec) -> (shape: Shape, plan: ArrangePlan)? {
        guard let s = suggested(count: windows.count, usable: usable, gaps: gaps) else { return nil }
        return (s, plan(s, windows: windows, order: order, displayID: displayID, usable: usable, gaps: gaps))
    }

    private static func lcm(_ a: Int, _ b: Int) -> Int {
        func gcd(_ x: Int, _ y: Int) -> Int { y == 0 ? x : gcd(y, x % y) }
        return a / gcd(a, b) * b
    }
}

extension WindowsAutoLayout.Shape {
    /// Windows per column, left to right (a `columns` shape read back).
    var cellCountsPerColumn: [Int] {
        var counts: [Int: Int] = [:]
        for c in cells { counts[c.col, default: 0] += 1 }
        return counts.keys.sorted().map { counts[$0]! }
    }
}

private extension CGRect {
    /// Same origin, width and height swapped (plan a portrait display as its landscape twin).
    var transposedSize: CGRect { CGRect(x: minX, y: minY, width: height, height: width) }
}
