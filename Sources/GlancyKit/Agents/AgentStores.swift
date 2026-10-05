import Foundation

/// One `AgentSessionStore` per source, seen as one board. Each source rebuilds and caps its own
/// store (at most `AgentSessionStore.maxSessions` sessions each); the board, the wing dots and the
/// command bar read them merged.
public struct AgentStores: Sendable {
    public private(set) var stores: [AgentKind: AgentSessionStore] = [:]

    public init() {}

    /// Routes an event to its agent's store.
    @discardableResult
    public mutating func apply(_ e: AgentEvent) -> [AgentTransition] {
        stores[e.agent, default: AgentSessionStore()].apply(e)
    }

    /// Takes over a store rebuilt off the main actor.
    public mutating func replace(_ kind: AgentKind, with store: AgentSessionStore) {
        stores[kind] = store
    }

    /// Forgets one source's sessions (the source was turned off).
    public mutating func remove(_ kind: AgentKind) {
        stores[kind] = nil
    }

    @discardableResult
    public mutating func expire(now: Date) -> Bool {
        var changed = false
        for k in stores.keys where stores[k]!.expire(now: now) { changed = true }
        return changed
    }

    public func nextDeadline(after now: Date) -> Date? {
        stores.values.compactMap { $0.nextDeadline(after: now) }.min()
    }

    /// Live sessions of every source, oldest row first (stable wing-dot order).
    public var live: [AgentSession] {
        stores.values.flatMap(\.live).sorted { ($0.startedAt, $0.rowID) < ($1.startedAt, $1.rowID) }
    }

    /// Every session, what needs you first.
    public var board: [AgentSession] {
        stores.values.flatMap(\.sessions.values).sorted(by: AgentSession.attentionOrder)
    }

    public func session(rowID: String) -> AgentSession? {
        for s in stores.values { if let found = s.session(rowID: rowID) { return found } }
        return nil
    }

    @discardableResult
    public mutating func setHost(_ host: AgentHost, rowID: String) -> Bool {
        for k in stores.keys where stores[k]!.session(rowID: rowID) != nil {
            return stores[k]!.setHost(host, rowID: rowID)
        }
        return false
    }

    public var count: Int { stores.values.reduce(0) { $0 + $1.sessions.count } }
}
