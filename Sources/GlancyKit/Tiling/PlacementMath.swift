// Tiling — the pure decisions of a placement: tolerances, edge re-anchoring, pushing inside the
// usable rect, and naming the outcome. Coordinate-system agnostic: every function works the same
// in Cocoa (y up) and AX (y down) coordinates, as long as all its inputs share one system.
//
// Technique from Loop (`anchoredFrame`, `getEdgesTouchingBounds`, `pushInside`) and Rectangle
// (`EdgeAlignmentWindowMover`); re-implemented here, no code copied (Loop is GPL).

import CoreGraphics

/// The edges of a rect that sit on the edges of the usable rect.
public struct TouchedEdges: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let minX = TouchedEdges(rawValue: 1 << 0)
    public static let maxX = TouchedEdges(rawValue: 1 << 1)
    public static let minY = TouchedEdges(rawValue: 1 << 2)
    public static let maxY = TouchedEdges(rawValue: 1 << 3)
}

/// How a placement ended. Shown in the panel; never persisted.
public enum PlacementOutcome: String, Sendable, Equatable {
    /// Landed on the requested frame (±2 pt).
    case exact
    /// The app chose its own size (step-sized terminal, minimum size); the frame was re-anchored
    /// to the edges the target touches and kept inside the usable rect.
    case appSized
    /// The window did not move or resize at all, or its position cannot be set.
    case refused
    /// Fullscreen, minimized, gone, or the app did not answer in time.
    case unreachable
    /// Superseded by a newer request for the same window before it finished.
    case cancelled
}

public enum PlacementMath {
    /// Position tolerance and per-axis size tolerance for "landed".
    public static let tolerance: CGFloat = 2

    public static func approx(_ a: CGRect, _ b: CGRect, _ tol: CGFloat = tolerance) -> Bool {
        abs(a.minX - b.minX) <= tol && abs(a.minY - b.minY) <= tol
            && abs(a.width - b.width) <= tol && abs(a.height - b.height) <= tol
    }

    public static func approxSize(_ a: CGSize, _ b: CGSize, _ tol: CGFloat = tolerance) -> Bool {
        abs(a.width - b.width) <= tol && abs(a.height - b.height) <= tol
    }

    /// The edges of `target` lying within `tolerance` of the matching edge of `bounds`. With a
    /// grid, pass the outer gap plus a point so cells on the border count as touching it.
    public static func touchedEdges(of target: CGRect, in bounds: CGRect, tolerance: CGFloat) -> TouchedEdges {
        var edges: TouchedEdges = []
        if abs(target.minX - bounds.minX) <= tolerance { edges.insert(.minX) }
        if abs(target.maxX - bounds.maxX) <= tolerance { edges.insert(.maxX) }
        if abs(target.minY - bounds.minY) <= tolerance { edges.insert(.minY) }
        if abs(target.maxY - bounds.maxY) <= tolerance { edges.insert(.maxY) }
        return edges
    }

    /// Where a window of `size` should sit so it hugs the edges `target` touches: per axis,
    /// touching only the low edge aligns low, only the high edge aligns high, both or neither
    /// centres. Then pushed inside `bounds`. A Terminal on the right half stays flush right.
    public static func anchoredFrame(size: CGSize, within target: CGRect, edges: TouchedEdges,
                                     bounds: CGRect) -> CGRect {
        var frame = CGRect(origin: target.origin, size: size)
        switch (edges.contains(.minX), edges.contains(.maxX)) {
        case (true, false): frame.origin.x = target.minX
        case (false, true): frame.origin.x = target.maxX - size.width
        default: frame.origin.x = target.midX - size.width / 2
        }
        switch (edges.contains(.minY), edges.contains(.maxY)) {
        case (true, false): frame.origin.y = target.minY
        case (false, true): frame.origin.y = target.maxY - size.height
        default: frame.origin.y = target.midY - size.height / 2
        }
        return pushInside(frame, bounds).integral(keepingSize: size)
    }

    /// Moves (never resizes) `rect` so it lies inside `bounds`; when it is larger than `bounds`
    /// on an axis, its low edge goes to the low edge of `bounds` (in AX coords: the top, so the
    /// title bar stays reachable).
    public static func pushInside(_ rect: CGRect, _ bounds: CGRect) -> CGRect {
        var r = rect
        if r.maxX > bounds.maxX { r.origin.x = bounds.maxX - r.width }
        if r.minX < bounds.minX { r.origin.x = bounds.minX }
        if r.maxY > bounds.maxY { r.origin.y = bounds.maxY - r.height }
        if r.minY < bounds.minY { r.origin.y = bounds.minY }
        return r
    }

    /// Names what happened: on target → exact; nothing changed although something was asked →
    /// refused; anything else → the app sized it (and the frame was re-anchored).
    public static func outcome(requested: CGRect, original: CGRect, landed: CGRect) -> PlacementOutcome {
        if approx(landed, requested) { return .exact }
        if approx(landed, original, 1) && !approx(original, requested) { return .refused }
        return .appSized
    }
}

extension CGRect {
    /// Rounded origin, exact size: AX takes whole points, and rounding the size again would undo
    /// the size the app chose.
    func integral(keepingSize size: CGSize) -> CGRect {
        CGRect(x: origin.x.rounded(), y: origin.y.rounded(), width: size.width, height: size.height)
    }
}
