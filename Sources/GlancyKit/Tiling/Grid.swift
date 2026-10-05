// Tiling — grid model and cell geometry. Pure, no AppKit, no Accessibility.
//
// Ported from Tessera (Core.swift, MIT, same author). Everything here speaks Cocoa coordinates
// (origin bottom-left of the primary screen, y growing up), like NSScreen. `ScreenSpace` owns the
// conversion to the top-left coordinates the Accessibility API uses; nothing else does it.

import CoreGraphics
import Foundation

// MARK: - Lenient decoding

extension KeyedDecodingContainer {
    /// A missing, null or malformed field falls back instead of throwing. A throw while decoding
    /// a configuration means the whole file is discarded, silently turning someone's grids back
    /// into the defaults; adding or renaming a field must never cost a user their setup.
    func lenient<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)).flatMap { $0 } ?? fallback
    }
}

// MARK: - Grid

/// A screen's grid: how many cells, and the breathing room around and between them.
public struct GridSpec: Codable, Equatable, Hashable, Sendable {
    public var cols: Int
    public var rows: Int
    public var outerGap: CGFloat
    public var innerGap: CGFloat

    public static let `default` = GridSpec()

    public init(cols: Int = 12, rows: Int = 8, outerGap: CGFloat = 8, innerGap: CGFloat = 8) {
        self.cols = cols
        self.rows = rows
        self.outerGap = outerGap
        self.innerGap = innerGap
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cols = c.lenient(.cols, 12)
        rows = c.lenient(.rows, 8)
        outerGap = c.lenient(.outerGap, 8)
        innerGap = c.lenient(.innerGap, 8)
    }

    /// The grid with every field brought into a sane range (1…32 cells, 0…80 pt gaps).
    public func clamped() -> GridSpec {
        GridSpec(cols: max(1, min(cols, 32)), rows: max(1, min(rows, 32)),
                 outerGap: max(0, min(outerGap, 80)), innerGap: max(0, min(innerGap, 80)))
    }

    public var cellCount: Int { cols * rows }
}

/// One cell of a grid. Row 0 is the TOP row (what people point at).
public struct GridCoord: Hashable, Sendable {
    public var col: Int
    public var row: Int
    public init(col: Int, row: Int) { self.col = col; self.row = row }
}

/// A rectangle of cells. `col`/`row` are 0-based, row 0 is the top row.
public struct CellRect: Codable, Equatable, Hashable, Sendable {
    public var col: Int
    public var row: Int
    public var w: Int
    public var h: Int

    public init(col: Int, row: Int, w: Int = 1, h: Int = 1) {
        self.col = col; self.row = row; self.w = w; self.h = h
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        col = c.lenient(.col, 0)
        row = c.lenient(.row, 0)
        w = c.lenient(.w, 1)
        h = c.lenient(.h, 1)
    }

    public var maxCol: Int { col + w - 1 }
    public var maxRow: Int { row + h - 1 }

    /// The whole grid as one rect.
    public static func all(_ grid: GridSpec) -> CellRect {
        let g = grid.clamped()
        return CellRect(col: 0, row: 0, w: g.cols, h: g.rows)
    }

    /// The rect covering both corners of a drag or a keyboard sweep.
    public static func spanning(_ a: GridCoord, _ b: GridCoord) -> CellRect {
        let c0 = min(a.col, b.col), r0 = min(a.row, b.row)
        return CellRect(col: c0, row: r0, w: abs(a.col - b.col) + 1, h: abs(a.row - b.row) + 1)
    }

    public func contains(col: Int, row: Int) -> Bool {
        col >= self.col && col <= maxCol && row >= self.row && row <= maxRow
    }

    /// Whether two rectangles of cells share any cell at all.
    public func intersects(_ other: CellRect) -> Bool {
        col <= other.maxCol && other.col <= maxCol && row <= other.maxRow && other.row <= maxRow
    }

    public func clamped(to grid: GridSpec) -> CellRect {
        let g = grid.clamped()
        let c = max(0, min(col, g.cols - 1))
        let r = max(0, min(row, g.rows - 1))
        return CellRect(col: c, row: r, w: max(1, min(w, g.cols - c)), h: max(1, min(h, g.rows - r)))
    }
}

// MARK: - Geometry

public enum Geometry {
    /// Screen rect (Cocoa coords) for a cell rect on a usable rect, honouring the gaps.
    public static func frame(for cell: CellRect, in grid: GridSpec, on usable: CGRect) -> CGRect {
        let g = grid.clamped()
        let cell = cell.clamped(to: g)
        let cellW = (usable.width - 2 * g.outerGap - CGFloat(g.cols - 1) * g.innerGap) / CGFloat(g.cols)
        let cellH = (usable.height - 2 * g.outerGap - CGFloat(g.rows - 1) * g.innerGap) / CGFloat(g.rows)
        // Round the edges, not the sizes: rounding a width independently makes a 2-cell span
        // disagree with the two cells it covers by a pixel.
        let left = usable.minX + g.outerGap + CGFloat(cell.col) * (cellW + g.innerGap)
        let right = left + CGFloat(cell.w) * cellW + CGFloat(cell.w - 1) * g.innerGap
        let top = usable.maxY - g.outerGap - CGFloat(cell.row) * (cellH + g.innerGap)
        let bottom = top - (CGFloat(cell.h) * cellH + CGFloat(cell.h - 1) * g.innerGap)
        return CGRect(x: left.rounded(), y: bottom.rounded(),
                      width: right.rounded() - left.rounded(),
                      height: top.rounded() - bottom.rounded())
    }

    /// The size of one cell of this grid on this rect.
    public static func cellSize(of grid: GridSpec, on usable: CGRect) -> CGSize {
        frame(for: CellRect(col: 0, row: 0), in: grid, on: usable).size
    }

    /// The cell under a point (Cocoa coords). Nil when the point is outside the rect.
    public static func cell(at point: CGPoint, in grid: GridSpec, on usable: CGRect) -> GridCoord? {
        guard usable.contains(point) else { return nil }
        let g = grid.clamped()
        let colW = usable.width / CGFloat(g.cols)
        let rowH = usable.height / CGFloat(g.rows)
        let col = Int((point.x - usable.minX) / colW)
        let row = Int((usable.maxY - point.y) / rowH)   // row 0 is the top one
        return GridCoord(col: max(0, min(col, g.cols - 1)), row: max(0, min(row, g.rows - 1)))
    }

    /// The cell rect a window frame occupies, rounded to the nearest cell boundaries. Used when
    /// capturing a layout; never to draw the map (the map shows real rects, not snapped ones).
    public static func nearestCell(for frame: CGRect, in grid: GridSpec, on usable: CGRect) -> CellRect {
        let g = grid.clamped()
        let colW = usable.width / CGFloat(g.cols)
        let rowH = usable.height / CGFloat(g.rows)
        let c0 = Int(((frame.minX - usable.minX) / colW).rounded())
        let c1 = Int(((frame.maxX - usable.minX) / colW).rounded()) - 1
        let r0 = Int(((usable.maxY - frame.maxY) / rowH).rounded())
        let r1 = Int(((usable.maxY - frame.minY) / rowH).rounded()) - 1
        return CellRect(col: c0, row: r0, w: max(1, c1 - c0 + 1), h: max(1, r1 - r0 + 1)).clamped(to: g)
    }

    /// Which cells a frame covers for the purpose of "is this cell free?": a cell counts as taken
    /// when the frame covers more than `threshold` of its area.
    public static func occupancy(of frames: [CGRect], in grid: GridSpec, on usable: CGRect,
                                 threshold: CGFloat = 0.5) -> [[Bool]] {
        let g = grid.clamped()
        var taken = Array(repeating: Array(repeating: false, count: g.cols), count: g.rows)
        for r in 0..<g.rows {
            for c in 0..<g.cols {
                let cell = frame(for: CellRect(col: c, row: r), in: g, on: usable)
                let area = cell.width * cell.height
                guard area > 0 else { continue }
                for f in frames {
                    let i = cell.intersection(f)
                    if !i.isNull, i.width * i.height > area * threshold { taken[r][c] = true; break }
                }
            }
        }
        return taken
    }
}
