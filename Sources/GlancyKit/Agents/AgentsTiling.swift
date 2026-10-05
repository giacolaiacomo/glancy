import CoreGraphics

// Agents ↔ Windows link (SPEC §3 Agents "⌥-click → jump and tile", RESEARCH Product §5b 3–4).
// The Agents module knows which terminal window hosts each session; the Windows module knows how
// to preview, place and undo. `AgentsTiling` is what Agents needs from Windows; `WindowsModule`
// conforms (App/Modules.swift wires the two at construction). Tests use a fake.

/// What the Agents module asks of the tiler. All plans are previewed or undoable there.
@MainActor
protocol AgentsTiling: AnyObject {
    /// Accessibility granted and the window registry running.
    var tilingReady: Bool { get }
    var canUndoTiling: Bool { get }
    /// Draws, on the real screen, how these windows would be laid out (Balanced, the first ID in
    /// the first cell in reading order). Moves nothing. Returns how many windows it covers.
    /// `titles` label the boxes on screen (the session names).
    func previewLayOut(windowIDs: [CGWindowID], titles: [CGWindowID: String]) -> Int
    /// Hides that preview (no-op when none is shown).
    func cancelLayOutPreview()
    /// Re-plans and commits the same arrangement. One undoable operation.
    func commitLayOut(windowIDs: [CGWindowID]) async -> [PlacementResult]
    /// Puts a window into the focused cell (see `WindowsModel.place(windowID:inFocusedCell:)`).
    func place(windowID: CGWindowID, inFocusedCell cell: CellRect?) async -> PlacementResult?
    /// Undoes the last tiling operation. False when there was nothing to undo.
    func undoTiling() async -> Bool
    /// Calls `body` with those of `ids` that the registry saw disappear. One watch at a time
    /// (a new call replaces it); empty `ids` stops watching. Event-driven, never polls.
    func watchWindowRemovals(_ ids: Set<CGWindowID>, _ body: @escaping @MainActor (Set<CGWindowID>) -> Void)
}

/// Whether the tiling actions can run, and if not, the one-line reason shown next to them.
enum AgentsTilingAvailability: Equatable {
    case ready
    case needsAccessibility
    /// The Windows module is not running (turned off): the actions are hidden.
    case unavailable

    var reason: String? {
        switch self {
        case .ready, .unavailable: nil
        case .needsAccessibility: AgentsText.t("Tiling needs Accessibility (System Settings → Privacy & Security).")
        }
    }
}

/// Each live session's terminal window. Filled on demand (an action needs it), never by polling.
/// An entry dies when its session ends or changes folder, when the registry reports the window
/// gone, or when WindowServer no longer knows the window at lookup time.
@MainActor
final class TerminalWindowCache {
    struct Entry: Equatable {
        let window: TerminalJumper.ResolvedWindow
        let projectPath: String
        let cwd: String
    }

    private(set) var entries: [String: Entry] = [:]
    /// WindowServer check, injectable for tests.
    var windowAlive: (CGWindowID) -> Bool = { TerminalJumper.windowExists($0) }

    var windowIDs: Set<CGWindowID> { Set(entries.values.map(\.window.windowID)) }

    /// The cached window for this session, or nil (missing, folder changed, or window destroyed).
    func window(for s: AgentSession) -> TerminalJumper.ResolvedWindow? {
        guard let e = entries[s.rowID] else { return nil }
        guard e.projectPath == s.projectPath, e.cwd == s.cwd, windowAlive(e.window.windowID) else {
            entries[s.rowID] = nil
            return nil
        }
        return e.window
    }

    func store(_ w: TerminalJumper.ResolvedWindow, for s: AgentSession) {
        // One window, one session.
        entries = entries.filter { $0.value.window.windowID != w.windowID }
        entries[s.rowID] = Entry(window: w, projectPath: s.projectPath, cwd: s.cwd)
    }

    /// The session registry changed: keep only live sessions still in the same folder.
    /// Returns true when something was dropped.
    @discardableResult
    func retain(live: [AgentSession]) -> Bool {
        let byRow = Dictionary(live.map { ($0.rowID, $0) }, uniquingKeysWith: { a, _ in a })
        let kept = entries.filter { row, e in
            guard let s = byRow[row] else { return false }
            return s.projectPath == e.projectPath && s.cwd == e.cwd
        }
        guard kept.count != entries.count else { return false }
        entries = kept
        return true
    }

    /// The registry saw these windows go.
    func remove(windowIDs gone: Set<CGWindowID>) {
        entries = entries.filter { !gone.contains($0.value.window.windowID) }
    }

    func removeAll() { entries = [:] }
}

enum AgentsLayout {
    /// The order sessions are laid out in (first = first cell in reading order): waiting, then
    /// working, then done (then failed, idle); within a state the most recent activity first.
    static func order(_ sessions: [AgentSession]) -> [AgentSession] {
        sessions.filter(\.isLive).sorted { a, b in
            if a.state != b.state { return a.state < b.state }
            if a.lastEventAt != b.lastEventAt { return a.lastEventAt > b.lastEventAt }
            return a.rowID < b.rowID
        }
    }
}
