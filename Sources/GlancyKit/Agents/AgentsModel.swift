import SwiftUI

/// One dot in the left wing.
public struct AgentDot: Identifiable, Equatable, Sendable {
    public let id: String          // row id
    public let state: AgentState
    public let fresh: Bool         // done/failed within the last 2'
}

/// What the right wing says.
public struct AgentWingSummary: Equatable, Sendable {
    public var state: AgentState?  // .waiting / .working / .done / .failed, nil = nothing to show
    public var count: Int
}

/// The Agents state on the main actor. Views observe the fine-grained properties below; the
/// collapsed wings read only `dots`, `summary` and `pulse`.
@MainActor @Observable
public final class AgentsModel {
    public private(set) var sessions: [AgentSession] = []    // board order
    public private(set) var dots: [AgentDot] = []            // live sessions, stable order
    public private(set) var summary = AgentWingSummary(state: nil, count: 0)
    /// Working dots pulse only while the panel is open.
    public private(set) var pulse = false
    public private(set) var loaded = false
    /// Last jump result for the row that was clicked (shown in its tooltip / footer).
    public private(set) var jumpNote: (rowID: String, text: String)?

    @ObservationIgnored public private(set) var store = AgentSessionStore()
    @ObservationIgnored weak var hub: ActivityHub?
    @ObservationIgnored var now: () -> Date = { .now }
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    @ObservationIgnored private var wakeAt: Date?
    @ObservationIgnored private var postedKey: ActivityKey?
    /// Turns shorter than this finish without a peek (calm: you were probably watching).
    @ObservationIgnored var minimumPeekTurn: TimeInterval = 10

    // MARK: Windows link state

    /// A layout on screen as a preview, waiting for the second click / ⏎.
    public struct LayoutPreview: Equatable, Sendable {
        public let windowIDs: [CGWindowID]
        public let count: Int
    }
    public private(set) var layoutPreview: LayoutPreview?
    /// Resolving windows or committing: the actions wait.
    public private(set) var tilingBusy = false
    /// The last tiling action can be undone from here (Undo chip, ⌘Z) until the panel closes.
    public private(set) var undoOffered = false
    /// One line about the last tiling action ("3 exact · api kept 800×600", "Undone", …).
    public private(set) var tilingNote: String?

    /// The tiler (the Windows module), wired at construction. nil = Windows is off: actions hidden.
    @ObservationIgnored weak var tiling: (any AgentsTiling)?
    @ObservationIgnored let windowCache = TerminalWindowCache()
    @ObservationIgnored var axTrusted: () -> Bool = { TerminalJumper.isTrusted }
    @ObservationIgnored var jumper: (TerminalJumper.Target) async -> TerminalJumper.Outcome = { await TerminalJumper.jump($0) }
    @ObservationIgnored var resolver: ([TerminalJumper.Target], Set<CGWindowID>) async -> [String: TerminalJumper.ResolvedWindow] = {
        await TerminalJumper.resolveWindows($0, excluding: $1)
    }
    @ObservationIgnored var raiser: (TerminalJumper.ResolvedWindow, TerminalJumper.Target) async -> Void = {
        _ = await TerminalJumper.raise($0, fallback: $1)
    }
    /// Key focus wanted (a preview to confirm with ⏎ / cancel with Esc, or an Undo on offer).
    @ObservationIgnored var onWantsKeys: ((Bool) -> Void)?
    @ObservationIgnored private var wantedKeys = false
    /// The last in-flight tiling task, so tests can await it.
    @ObservationIgnored private(set) var tilingTask: Task<Void, Never>?
    @ObservationIgnored private(set) var jumpTask: Task<Void, Never>?

    public init() {}

    // MARK: Input

    /// Applies a batch of events from the tail reader. During the launch rebuild no peeks fire.
    public func ingest(_ events: [AgentEvent], rebuild: Bool) {
        var finished: [String] = []
        var needsYou: [String] = []
        var needsYouRows: [String] = []
        for e in events {
            for t in store.apply(e) where !rebuild {
                switch t {
                case let .finished(_, label, duration, _):
                    if (duration ?? 0) >= minimumPeekTurn, !finished.contains(label) { finished.append(label) }
                case let .needsYou(row, label, _):
                    if !needsYou.contains(label) { needsYou.append(label) }
                    needsYouRows.removeAll { $0 == row }
                    needsYouRows.append(row)
                }
            }
        }
        // A session that finished and then asked again in the same batch only needs the second.
        finished.removeAll { needsYou.contains($0) }
        if rebuild { loaded = true }
        refresh()
        if !needsYou.isEmpty {
            // "Show" jumps to the terminal of the most recent one (no tiling).
            var show: (@MainActor () -> Void)?
            if let row = needsYouRows.last {
                show = { [weak self] in self?.jump(to: row) }
            }
            peek(AgentsText.needsYou(needsYou), state: .waiting, show: show)
        }
        if !finished.isEmpty {
            let detail = finished.count == 1 ? store.live.first { $0.label == finished[0] }?.lastTurnDuration : nil
            let text = finished.count == 1 ? AgentsText.finished(finished[0]) : AgentsText.finishedMany(finished)
            peek(text, state: .done, detail: detail.map(AgentsText.duration))
        }
    }

    /// Takes over a store rebuilt off the main actor (launch). No peeks.
    public func adopt(_ rebuilt: AgentSessionStore) {
        store = rebuilt
        loaded = true
        refresh()
    }

    func visibilityChanged(_ v: SurfaceVisibility) {
        // Only while the panel is open: a repeating animation in the collapsed wings keeps
        // SwiftUI and WindowServer compositing forever (measured ~6% CPU). Collapsed dots are still.
        let on: Bool
        if case .expanded = v { on = true } else { on = false }
        if pulse != on { pulse = on }
    }

    func reset() {
        wakeTask?.cancel(); wakeTask = nil; wakeAt = nil
        store = AgentSessionStore()
        postedKey = nil
        endTiling()
        windowCache.removeAll()
        tiling?.watchWindowRemovals([], { _ in })
        sessions = []; dots = []; summary = .init(state: nil, count: 0); loaded = false
    }

    // MARK: Clock + publishing

    /// Applies time-based transitions, republishes, re-posts the live activity, reschedules.
    func refresh() {
        let t = now()
        store.expire(now: t)
        publish(at: t)
        schedule(after: t)
    }

    private func publish(at t: Date) {
        let board = store.board
        let live = store.live
        if board != sessions {
            sessions = board
            if windowCache.retain(live: live) { watchCachedWindows() }
        }
        let newDots = live.map { AgentDot(id: $0.rowID, state: $0.state, fresh: $0.isFresh(at: t)) }
        if newDots != dots { dots = newDots }

        let waiting = live.filter { $0.state == .waiting }.count
        let working = live.filter { $0.state == .working }.count
        let freshDone = live.filter { $0.state == .done && $0.isFresh(at: t) }
        let freshFailed = live.filter { $0.state == .failed && $0.isFresh(at: t) }
        let s: AgentWingSummary =
            waiting > 0 ? .init(state: .waiting, count: waiting)
            : working > 0 ? .init(state: .working, count: working)
            : !freshFailed.isEmpty ? .init(state: .failed, count: freshFailed.count)
            : !freshDone.isEmpty ? .init(state: .done, count: freshDone.count)
            : .init(state: nil, count: 0)
        if s != summary { summary = s }

        // The live activity (SPEC §2): waiting 90, working 50, a fresh done/failed for 2'.
        let key: ActivityKey? = switch s.state {
        case .waiting: ActivityKey(priority: 90, expires: nil)
        case .working: ActivityKey(priority: 50, expires: nil)
        case .done, .failed:
            ActivityKey(priority: 50, expires: (freshDone + freshFailed).map { $0.stateSince.addingTimeInterval(AgentSessionStore.freshFor) }.max())
        default: nil
        }
        guard key != postedKey, let hub else { return }
        postedKey = key
        if let key {
            hub.post(LiveActivity(id: "agents", module: .agents, priority: key.priority, expires: key.expires,
                                  left: AnyView(AgentsWingLeft(model: self)),
                                  right: AnyView(AgentsWingRight(model: self))))
        } else {
            hub.clear("agents")
        }
    }

    /// One wake-up at the next deadline (stale, fresh colour ends, ended row removal). Never a tick.
    private func schedule(after t: Date) {
        guard let next = store.nextDeadline(after: t) else {
            wakeTask?.cancel(); wakeTask = nil; wakeAt = nil
            return
        }
        // Keep an earlier (or equal) pending wake-up: firing early is harmless, it reschedules.
        if let at = wakeAt, at <= next, wakeTask != nil, at > t { return }
        wakeTask?.cancel()
        wakeAt = next
        wakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.05, next.timeIntervalSince(t)) + 0.05))
            guard !Task.isCancelled, let self else { return }
            self.wakeTask = nil
            self.wakeAt = nil
            self.refresh()
        }
    }

    var scheduledWake: Date? { wakeAt }

    private func peek(_ text: String, state: AgentState, detail: String? = nil, show: (@MainActor () -> Void)? = nil) {
        // A peek with an action stays a little longer, so there is time to reach it.
        hub?.show(PeekEvent(module: .agents, duration: show == nil ? 2.5 : 4,
                            content: AnyView(AgentsPeekView(text: text, detail: detail, state: state, show: show))))
    }

    // MARK: Actions

    /// - Parameter note: what to say afterwards instead of the jump's own note (⌥-click fallbacks).
    public func jump(to rowID: String, note override: String? = nil) {
        guard let s = store.session(rowID: rowID) else { return }
        let target = TerminalJumper.Target(projectPath: s.projectPath, cwd: s.cwd, label: s.label)
        jumpTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.jumper(target)
            let note: String? = switch outcome {
            case .raisedWindow: nil
            case .activatedApp:
                TerminalJumper.isTrusted ? nil
                    : AgentsText.t("Accessibility is off: Glancy can bring the terminal app forward, not the exact window.")
            case .notFound: AgentsText.t("No terminal window found for this session.")
            }
            self.jumpNote = (override ?? note).map { (rowID, $0) }
        }
    }

    // MARK: Windows link

    var tilingAvailability: AgentsTilingAvailability {
        guard tiling != nil else { return .unavailable }
        return axTrusted() ? .ready : .needsAccessibility
    }

    /// ⌥-click: bring the session's terminal forward and put it in the focused cell — the cell last
    /// placed into from the Windows grid on the display of the window you were working in, else
    /// the cells that window covers (it swaps to the terminal's old place). Undoable.
    /// Without Accessibility (or with no window found) it only jumps, and says why.
    public func jumpAndTile(rowID: String) {
        guard let s = store.session(rowID: rowID) else { return }
        guard tilingAvailability == .ready, let tiling, tiling.tilingReady else {
            jump(to: rowID, note: tilingAvailability.reason)
            return
        }
        guard !tilingBusy else { return }
        cancelLayoutPreview()
        tilingBusy = true
        tilingTask = Task { [weak self] in
            guard let self else { return }
            let windows = await self.resolveWindows(for: self.store.live)
            defer { self.tilingBusy = false }
            guard let w = windows[rowID] else {
                self.jump(to: rowID, note: AgentsText.t("No terminal window found to tile."))
                return
            }
            // Place first: "the focused cell" is read from the window you were working in.
            let result = await tiling.place(windowID: w.windowID, inFocusedCell: nil)
            await self.raiser(w, Self.target(s))
            self.jumpNote = nil
            if let result {
                self.report([result], names: [w.windowID: s.label])
            }
        }
    }

    /// "Lay out sessions": the first call previews every live session's terminal on the target
    /// display (Balanced; waiting first, then working, then done, most recent first), the second
    /// commits it. Esc / leaving the tab cancels.
    public func layOutSessions() {
        if layoutPreview != nil { commitLayout(); return }
        guard tilingAvailability == .ready, let tiling, tiling.tilingReady, !tilingBusy else { return }
        tilingBusy = true
        tilingNote = nil
        tilingTask = Task { [weak self] in
            guard let self else { return }
            let order = AgentsLayout.order(self.store.live)
            let windows = await self.resolveWindows(for: order)
            self.tilingBusy = false
            var ids: [CGWindowID] = []
            var titles: [CGWindowID: String] = [:]
            for s in order {
                guard let w = windows[s.rowID], titles[w.windowID] == nil else { continue }
                ids.append(w.windowID)
                titles[w.windowID] = "\(s.label) · \(AgentsText.state(s.state))"
            }
            let n = ids.isEmpty ? 0 : tiling.previewLayOut(windowIDs: ids, titles: titles)
            if n == 0 {
                self.tilingNote = AgentsText.t("No terminal windows found for the live sessions.")
            } else {
                self.layoutPreview = LayoutPreview(windowIDs: ids, count: n)
            }
            self.updateKeys()
        }
    }

    public func commitLayout() {
        guard let p = layoutPreview, let tiling, !tilingBusy else { return }
        layoutPreview = nil
        tilingBusy = true
        tilingTask = Task { [weak self] in
            guard let self else { return }
            let results = await tiling.commitLayOut(windowIDs: p.windowIDs)
            self.tilingBusy = false
            let names = Dictionary(self.store.live.compactMap { s in self.windowCache.entries[s.rowID].map { ($0.window.windowID, s.label) } },
                                   uniquingKeysWith: { a, _ in a })
            self.report(results, names: names)
        }
    }

    public func cancelLayoutPreview() {
        guard layoutPreview != nil else { return }
        layoutPreview = nil
        tiling?.cancelLayOutPreview()
        updateKeys()
    }

    public func undoTiling() {
        guard undoOffered, let tiling, !tilingBusy else { return }
        tilingBusy = true
        tilingTask = Task { [weak self] in
            guard let self else { return }
            _ = await tiling.undoTiling()
            self.tilingBusy = false
            self.undoOffered = false
            self.tilingNote = AgentsText.t("Undone")
            self.updateKeys()
        }
    }

    /// The panel closed or left Agents/Home: no preview survives, the Undo offer ends.
    func endTiling() {
        cancelLayoutPreview()
        undoOffered = false
        tilingNote = nil
        updateKeys()
    }

    private func report(_ results: [PlacementResult], names: [CGWindowID: String]) {
        if !results.isEmpty {
            let report = OutcomeReport(results: results, name: { names[$0] ?? WindowsText.t("Windows") })
            tilingNote = report.line
        }
        undoOffered = tiling?.canUndoTiling ?? false
        updateKeys()
    }

    private func updateKeys() {
        let want = layoutPreview != nil || undoOffered
        guard want != wantedKeys else { return }
        wantedKeys = want
        onWantsKeys?(want)
    }

    /// ⏎ / Esc / ⌘Z while a preview or an Undo is on offer. Returns true when consumed.
    func handleKey(_ key: TilingKey) -> Bool {
        switch key {
        case .enter:
            guard layoutPreview != nil else { return false }
            commitLayout()
        case .escape:
            guard layoutPreview != nil else { return false }
            cancelLayoutPreview()
        case .undo:
            guard undoOffered else { return false }
            undoTiling()
        }
        return true
    }

    enum TilingKey { case enter, escape, undo }

    /// Each session's terminal window: cached ones (still alive, same folder) plus a resolution of
    /// the rest, one window per session.
    func resolveWindows(for sessions: [AgentSession]) async -> [String: TerminalJumper.ResolvedWindow] {
        var out: [String: TerminalJumper.ResolvedWindow] = [:]
        var missing: [AgentSession] = []
        for s in sessions {
            if let w = windowCache.window(for: s) { out[s.rowID] = w } else { missing.append(s) }
        }
        guard !missing.isEmpty else { return out }
        let found = await resolver(missing.map(Self.target), windowCache.windowIDs)
        for s in missing {
            guard let w = found[s.rowID], store.session(rowID: s.rowID) != nil else { continue }
            windowCache.store(w, for: s)
            out[s.rowID] = w
        }
        watchCachedWindows()
        return out
    }

    private func watchCachedWindows() {
        tiling?.watchWindowRemovals(windowCache.windowIDs) { [weak self] gone in
            self?.windowCache.remove(windowIDs: gone)
        }
    }

    /// Renderer: shows a tiling state without touching any window.
    func prepareTilingForRender(trusted: Bool, preview: LayoutPreview?, undo: Bool, note: String?) {
        axTrusted = { trusted }
        layoutPreview = preview
        undoOffered = undo
        tilingNote = note
    }

    func showWaitingPeekForRender() {
        let label = store.live.first { $0.state == .waiting }?.label ?? "api"
        peek(AgentsText.needsYou([label]), state: .waiting, show: {})
    }

    static func target(_ s: AgentSession) -> TerminalJumper.Target {
        TerminalJumper.Target(projectPath: s.projectPath, cwd: s.cwd, label: s.label, rowID: s.rowID)
    }

    /// The sessions worth a glance on Home: waiting first, then working, then a fresh done/failed.
    public func highlights(limit: Int = 2) -> [AgentSession] {
        let t = now()
        return Array(store.live.filter { $0.state == .waiting || $0.state == .working || $0.isFresh(at: t) }
            .sorted { $0.state != $1.state ? $0.state < $1.state : $0.stateSince > $1.stateSince }
            .prefix(limit))
    }
}

private struct ActivityKey: Equatable {
    let priority: Int
    let expires: Date?
}
