// Tiling — the empty part of a screen: the largest rectangle no other window covers. Pure.
//
// Maximal empty rectangle by coordinate compression: every window edge (clipped to the bounds)
// becomes a grid line, so each compressed cell is wholly free or wholly covered; then, row by
// row from the top, the largest rectangle in a histogram whose bars have real widths and heights
// in points (the stack algorithm, O(columns) per row). Windows of a desk are a few dozen, so the
// compressed grid stays under ~100 × 100 cells.

import CoreGraphics
import Foundation

public enum FreeSpace {
    /// The smallest free area worth filling: the smallest tile the layouts make.
    public static let minSize = WindowsAutoLayout.minCell

    /// The largest rectangle inside `bounds` overlapping none of `obstacles` (touching is fine),
    /// at least `minSize` on both axes. Nil when there is none that large.
    public static func largestEmptyRect(in bounds: CGRect, avoiding obstacles: [CGRect],
                                        minSize: CGSize = .zero) -> CGRect? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let blocks = obstacles.map { $0.intersection(bounds) }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
        func lines(_ edges: [CGFloat], _ lo: CGFloat, _ hi: CGFloat) -> [CGFloat] {
            Array(Set([lo, hi] + edges.map { min(max($0, lo), hi) })).sorted()
        }
        let xs = lines(blocks.flatMap { [$0.minX, $0.maxX] }, bounds.minX, bounds.maxX)
        // Top to bottom (Cocoa y grows up): row r spans ys[r + 1] ... ys[r].
        let ys = Array(lines(blocks.flatMap { [$0.minY, $0.maxY] }, bounds.minY, bounds.maxY).reversed())
        let cols = xs.count - 1, rows = ys.count - 1
        guard cols > 0, rows > 0 else { return nil }

        let slack: CGFloat = 0.001
        var heights = [CGFloat](repeating: 0, count: cols)
        var best: CGRect?
        var bestArea: CGFloat = 0
        for r in 0..<rows {
            let top = ys[r], bottom = ys[r + 1]
            let midY = (top + bottom) / 2
            for c in 0..<cols {
                let mid = CGPoint(x: (xs[c] + xs[c + 1]) / 2, y: midY)
                heights[c] = blocks.contains { $0.contains(mid) } ? 0 : heights[c] + (top - bottom)
            }
            // Largest rectangle in the histogram whose bars stand on this row's bottom edge.
            var stack: [(start: Int, height: CGFloat)] = []
            for c in 0...cols {
                let h = c < cols ? heights[c] : 0
                var start = c
                while let last = stack.last, last.height >= h {
                    stack.removeLast()
                    let width = xs[c] - xs[last.start]
                    let area = width * last.height
                    if width + slack >= minSize.width, last.height + slack >= minSize.height, area > bestArea {
                        bestArea = area
                        best = CGRect(x: xs[last.start], y: bottom, width: width, height: last.height)
                    }
                    start = last.start
                }
                if h > 0 { stack.append((start, h)) }
            }
        }
        return best
    }

    /// Where a window goes to fill the empty part of `usable`, with the grid's breathing room:
    /// the outer gap from the screen's edges and the inner gap from the other windows, edges on
    /// whole points. Nil when no free area of `minSize` is left.
    public static func fillFrame(usable: CGRect, others: [CGRect], gaps: GridSpec,
                                 minSize: CGSize = FreeSpace.minSize) -> CGRect? {
        let g = gaps.clamped()
        let bounds = usable.insetBy(dx: g.outerGap, dy: g.outerGap)
        let obstacles = others.map { $0.insetBy(dx: -g.innerGap, dy: -g.innerGap) }
        guard let free = largestEmptyRect(in: bounds, avoiding: obstacles, minSize: minSize) else { return nil }
        let minX = free.minX.rounded(.up), maxX = free.maxX.rounded(.down)
        let minY = free.minY.rounded(.up), maxY = free.maxY.rounded(.down)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Whether a window takes up room on its screen: visible on this Space, not minimised or
    /// fullscreen, not a menu or tooltip.
    public static func occupies(_ w: TrackedWindow) -> Bool {
        w.isOnScreen && !w.isMinimized && !w.isFullscreen && w.kind != .popup
    }
}
