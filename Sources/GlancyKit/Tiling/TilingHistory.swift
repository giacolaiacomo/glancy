// Tiling — undo. Per window: the frame it had before it was first tiled and a stack of what was
// asked and where it landed; per operation: the frames before it (a whole-screen snapshot for
// multi-window operations). Rectangle/Loop's rule: when a window's current frame is not where
// we last put it, the user moved it, and its history is reset.

import CoreGraphics
import Foundation
import Observation

@MainActor @Observable
public final class TilingHistory {
    public struct Entry: Sendable, Equatable {
        public let operation: UUID
        public let requested: CGRect
        public let landed: CGRect
    }

    public struct WindowRecord: Sendable, Equatable {
        /// The frame before the first operation in this history.
        public let initialFrame: CGRect
        public var stack: [Entry]
        public var lastLanded: CGRect? { stack.last?.landed }
    }

    public struct Operation: Identifiable, Sendable, Equatable {
        public let id: UUID
        public let label: String
        public let date: Date
        /// Frames of the moved windows before the operation.
        public var before: [CGWindowID: CGRect]
        /// Where each moved window landed.
        public var landed: [CGWindowID: CGRect]
        /// Every window on the display before a multi-window operation (empty for single moves).
        public let screenSnapshot: [CGWindowID: CGRect]
    }

    public private(set) var operations: [Operation] = []
    @ObservationIgnored public private(set) var records: [CGWindowID: WindowRecord] = [:]
    public var canUndo: Bool { !operations.isEmpty }
    public static let limit = 50
    /// Frames within this distance of where we put a window still count as "ours".
    public static let tolerance: CGFloat = 3

    public init() {}

    /// Records a finished operation. `before` holds the frames prior to it, `landed` the read-backs.
    @discardableResult
    public func record(label: String, before: [CGWindowID: CGRect], requested: [CGWindowID: CGRect],
                       landed: [CGWindowID: CGRect], screenSnapshot: [CGWindowID: CGRect] = [:]) -> UUID? {
        let moved = landed.filter { before[$0.key] != nil }
        guard !moved.isEmpty else { return nil }
        let op = Operation(id: UUID(), label: label, date: .now, before: before.filter { moved[$0.key] != nil },
                           landed: moved, screenSnapshot: screenSnapshot)
        for (id, frame) in moved {
            var record = records[id] ?? WindowRecord(initialFrame: before[id]!, stack: [])
            record.stack.append(Entry(operation: op.id, requested: requested[id] ?? frame, landed: frame))
            records[id] = record
        }
        operations.append(op)
        if operations.count > Self.limit {
            let dropped = operations.removeFirst()
            for id in dropped.landed.keys { records[id]?.stack.removeAll { $0.operation == dropped.id } }
        }
        return op.id
    }

    public func initialFrame(for id: CGWindowID) -> CGRect? { records[id]?.initialFrame }

    /// Whether `id` is sitting where we last put it.
    public func isWhereWeLeftIt(_ id: CGWindowID, current: CGRect) -> Bool {
        guard let last = records[id]?.lastLanded else { return false }
        return PlacementMath.approx(last, current, Self.tolerance)
    }

    /// The user moved or resized `id`: forget its history, and drop it from every operation.
    public func reset(_ id: CGWindowID) {
        guard records.removeValue(forKey: id) != nil else { return }
        removeFromOperations(id)
    }

    /// Called with a window's new frame when it changed without us: resets when it is not where
    /// we left it. Returns whether it reset.
    @discardableResult
    public func noteExternalChange(_ id: CGWindowID, current: CGRect) -> Bool {
        guard records[id] != nil, !isWhereWeLeftIt(id, current: current) else { return false }
        reset(id)
        return true
    }

    /// The window is gone.
    public func forget(_ id: CGWindowID) {
        records[id] = nil
        removeFromOperations(id)
    }

    private func removeFromOperations(_ id: CGWindowID) {
        for i in operations.indices.reversed() {
            operations[i].before[id] = nil
            operations[i].landed[id] = nil
            if operations[i].landed.isEmpty { operations.remove(at: i) }
        }
    }

    /// What undoing the last operation would do: for each of its windows still where we left
    /// it, the frame to restore. Windows moved since by the user are skipped.
    public func undoPlan(current: [CGWindowID: CGRect]) -> (operation: Operation, restore: [CGWindowID: CGRect])? {
        guard let op = operations.last else { return nil }
        var restore: [CGWindowID: CGRect] = [:]
        for (id, landed) in op.landed {
            guard let now = current[id], let before = op.before[id],
                  PlacementMath.approx(now, landed, Self.tolerance) else { continue }
            restore[id] = before
        }
        return (op, restore)
    }

    /// Pops the operation once its restore has been dispatched.
    public func didUndo(_ operation: UUID) {
        operations.removeAll { $0.id == operation }
        for id in Array(records.keys) {
            records[id]?.stack.removeAll { $0.operation == operation }
            if records[id]?.stack.isEmpty == true { records[id] = nil }
        }
    }
}
