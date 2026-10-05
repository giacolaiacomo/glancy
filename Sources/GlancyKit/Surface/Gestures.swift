import CoreGraphics
import Foundation

/// Hover-to-open intent (SPEC §2, opt-in): open only if the cursor arrived slowly (< 600 pt/s,
/// sampled over the first moments after entry) and is still inside after a 300 ms dwell.
/// No mouse-moved monitor: two samples, the entry event and one read ~40 ms later.
public struct HoverIntent: Equatable, Sendable {
    public static let dwell: TimeInterval = 0.30
    public static let sampleDelay: TimeInterval = 0.04
    public static let maxEntrySpeed: CGFloat = 600

    public var entry: (point: CGPoint, time: TimeInterval)?
    public var entrySpeed: CGFloat?

    public init() {}

    public static func == (a: HoverIntent, b: HoverIntent) -> Bool {
        a.entry?.point == b.entry?.point && a.entry?.time == b.entry?.time && a.entrySpeed == b.entrySpeed
    }

    public mutating func entered(at p: CGPoint, time: TimeInterval) {
        entry = (p, time); entrySpeed = nil
    }

    /// The second sample, taken `sampleDelay` after entry.
    public mutating func sample(at p: CGPoint, time: TimeInterval) {
        guard let e = entry, time > e.time else { return }
        entrySpeed = hypot(p.x - e.point.x, p.y - e.point.y) / CGFloat(time - e.time)
    }

    public mutating func exited() { entry = nil; entrySpeed = nil }

    /// Ask at the end of the dwell.
    public func shouldOpen(stillInside: Bool) -> Bool {
        guard stillInside, entry != nil else { return false }
        return (entrySpeed ?? 0) < Self.maxEntrySpeed
    }
}

/// Two-finger horizontal swipe → one tab step per gesture (Alcove's "one action per swipe").
public struct SwipeTracker: Sendable {
    public static let threshold: CGFloat = 36
    private var accumulated: CGFloat = 0
    private var fired = false

    public init() {}

    public enum Phase: Sendable { case began, changed, ended, momentum }

    /// Feed scroll deltas; returns -1 / +1 once per gesture when it crosses the threshold.
    /// Natural scrolling: fingers moving left (negative deltaX) step forward.
    public mutating func feed(deltaX: CGFloat, deltaY: CGFloat, phase: Phase) -> Int? {
        switch phase {
        case .began:
            accumulated = 0; fired = false
        case .ended:
            accumulated = 0; fired = false
            return nil
        case .momentum:
            return nil
        case .changed:
            break
        }
        guard !fired, abs(deltaX) >= abs(deltaY) else { return nil }
        accumulated += deltaX
        guard abs(accumulated) >= Self.threshold else { return nil }
        fired = true
        return accumulated < 0 ? 1 : -1
    }
}

/// Re-layout by display: which surfaces to create, drop and move after a screen change.
public struct ScreenDiff: Equatable, Sendable {
    public var added: [String] = []
    public var removed: [String] = []
    public var changed: [String] = []

    public var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty }

    public static func between(_ old: [String: NotchGeometry], _ new: [String: NotchGeometry]) -> ScreenDiff {
        var d = ScreenDiff()
        d.added = new.keys.filter { old[$0] == nil }.sorted()
        d.removed = old.keys.filter { new[$0] == nil }.sorted()
        d.changed = new.keys.filter { old[$0] != nil && old[$0] != new[$0] }.sorted()
        return d
    }
}

/// The tab to open on: the last one if the panel closed less than 30 s ago, otherwise Home (nil).
public func tabToOpen(last: ModuleID?, closedAt: Date?, now: Date, available: [ModuleID]) -> ModuleID? {
    guard let last, let closedAt, now.timeIntervalSince(closedAt) < 30, available.contains(last) else { return nil }
    return last
}
