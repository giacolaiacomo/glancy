// Windows — the tab's state. Everything the user does here either changes the *preview* (hover,
// sweep, arrows, grid, strategy, a layout thumbnail) or *commits* one plan (click, ⏎, drop, Apply,
// digits). Only the commit paths call `backend.commit`; the preview path never does (tested).
//
// Two surfaces share this state. The main one: pick windows in the list (or none = the whole
// display), pick a layout thumbnail (Suggested first), Apply. "More" (and the keyboard map, and a
// drag to the notch) shows the full map: cells, grid, scope, strategies.

import AppKit
import Observation

@MainActor @Observable
final class WindowsModel {
    enum Mode: Equatable {
        case browse
        /// Opened by the hotkey: the selection shows at once and ⏎ closes the panel after placing.
        case keyboard
        /// A window is being dragged over the notch; `frame` is where it was before the drag.
        case drag(window: CGWindowID, frame: CGRect)
    }

    enum Key: Equatable {
        case arrow(Direction, shift: Bool)
        case enter, escape, arrangeAll, undo
        case digit(Int)
        /// Tab / ⇧Tab: the next / previous window of the scope becomes the target.
        case cycle(forward: Bool)
        /// Space: the target joins (or leaves) the picked windows.
        case togglePick
        /// S: swap the two picked windows (rotate when more).
        case swapPicks
    }

    /// How a row (or a map window) was clicked. Plain and ⌘ both add / remove; ⇧ adds a range.
    enum Click: Equatable { case plain, toggle, extend }

    enum DragStep: Equatable { case none, cancelled, committed }

    @ObservationIgnored private(set) var backend: WindowsBackend
    private(set) var trusted: Bool
    private(set) var visible = false
    private(set) var mode: Mode = .browse
    private(set) var displays: [Display] = []
    private(set) var displayID: String?
    private(set) var map: ScreenMap?
    /// The window placing acts on. Only ever a window of the shown display (or the dragged one):
    /// nil when the frontmost window is on another screen, until one is picked on the map.
    private(set) var targetID: CGWindowID?
    /// What arrange acts on (and which windows Tab cycles through).
    private(set) var scope: WindowsScope = .screen
    /// The app of the app scope.
    private(set) var scopeApp: pid_t?
    /// The window a click would pick right now (pointer on its icon, or on any window with no target).
    private(set) var pickHover: CGWindowID?
    /// "Exactly these windows", in pick order (click, ⇧-click, Space). Two or more = the
    /// selection scope. Reset whenever the tab opens.
    private(set) var picks = PickedWindows()
    /// "More": the full map (cells, grid, scope, strategies) instead of the layout thumbnails.
    private(set) var showMore = false
    /// The shortcuts card ("?").
    private(set) var showHelp = false
    /// The layout thumbnail chosen (`WindowsAutoLayout.Option.id`); Suggested by default.
    private(set) var layoutChoice = WindowsModel.suggestedID
    /// The thumbnail under the pointer: previewed on the map and on the real screen.
    private(set) var layoutHover: String?
    /// The pointer is on Apply: the result shows on the real screen too.
    private(set) var applyHover = false
    /// What Apply does on the main surface: the shown layout for the windows it acts on.
    private(set) var layoutPlan: ArrangePlan?
    /// The list row under the pointer: outlined on the map and on the real screen.
    private(set) var rowHover: CGWindowID?
    /// Cells under the pointer (hover, or a sweep in progress), or under the dragged window.
    private(set) var hoverCell: CellRect?
    private(set) var selection: KeyboardSelection?
    private(set) var strategy: ArrangeStrategy?
    /// What a commit would do right now; drawn on the map and on the real screen.
    private(set) var preview: ArrangePlan?
    private(set) var outcome: OutcomeReport?
    /// A commit, undo or workspace restore is running (set by the workspace extension too).
    var busy = false
    private(set) var canUndo = false
    var showDiagnostics = false
    private(set) var probeLines: [String] = []
    private(set) var probeRunning = false
    var failedHotkeys: [String] = []

    // Workspaces (WindowsModel+Workspaces.swift)
    /// The saved workspaces (the module's store; in memory until the module hands its own).
    @ObservationIgnored var workspaces = WorkspaceStore(url: nil)
    @ObservationIgnored var restorer = WorkspaceRestorer(launcher: WorkspaceAppLauncher())
    /// The workspaces pane instead of the layout thumbnails.
    var showWorkspaces = false
    /// The name being typed: saving a new workspace (`renaming` nil) or renaming one.
    var naming: String?
    var renaming: UUID?
    /// The workspace card under the pointer: its windows on this display show on the real screen.
    var workspaceHover: UUID?
    var workspacePreview: ArrangePlan?
    /// The workspace being restored (launching apps can take seconds).
    var restoringWorkspace: UUID?
    /// What the pane's status line says after a save or a restore.
    var workspaceStatus: WorkspaceStatus?
    @ObservationIgnored var workspaceStatusTask: Task<Void, Never>?

    /// Reported by the views, in Cocoa screen coordinates (drag mode maps the pointer with them).
    @ObservationIgnored var mapScreenRect: CGRect?
    /// Where the tab is on screen. Its display is the one the panel is on: the map follows it
    /// until the user picks another display with the switcher.
    @ObservationIgnored var contentScreenRect: CGRect? { didSet { panelLaidOut() } }
    /// The user chose the display with the switcher (or a drag/renderer fixed it).
    @ObservationIgnored private var displayChosen = false
    /// The pointer, Cocoa coordinates (tests inject it).
    @ObservationIgnored var pointer: () -> CGPoint = { NSEvent.mouseLocation }
    @ObservationIgnored private(set) var hotZone: CGRect?
    /// The preview changed: draw it on the real screen (nil = nothing to show).
    @ObservationIgnored var onPreview: ((ArrangePlan?, Display?) -> Void)?
    /// A list row is hovered: outline that window on the real screen (nil = none).
    @ObservationIgnored var onHighlight: ((TrackedWindow?, Display?) -> Void)?
    @ObservationIgnored var onRequestClose: (() -> Void)?
    /// A short message for after the panel has closed (non-exact outcomes of keyboard commits).
    @ObservationIgnored var onPeek: ((String) -> Void)?
    @ObservationIgnored var probe: (Bool) async -> [String] = { move in await TilingProbe.run(move: move) }
    /// The last in-flight commit / undo / probe, so callers (and tests) can await it.
    @ObservationIgnored var pending: Task<Void, Never>?
    /// The cell last placed into, per display: "the focused cell" for the Agents link.
    @ObservationIgnored private(set) var lastCell: [String: CellRect] = [:]
    @ObservationIgnored private(set) var lastDirect: HalvesCycle.Last?
    /// What the real-screen overlay was last told (it is only told about changes).
    @ObservationIgnored private var lastOverlay: ArrangePlan?
    /// The shortcuts the "?" card lists (the module keeps them current).
    @ObservationIgnored var hotkeys = WindowsHotkeys()
    @ObservationIgnored private var sweeping = false
    @ObservationIgnored private var observation = 0
    @ObservationIgnored private var outcomeTask: Task<Void, Never>?
    @ObservationIgnored private var closeTask: Task<Void, Never>?
    @ObservationIgnored var outcomeDuration: Duration = .seconds(5)
    @ObservationIgnored var closeDelay: Duration = .milliseconds(900)

    init(backend: WindowsBackend) {
        self.backend = backend
        trusted = backend.isTrusted
    }

    /// The renderer swaps in the synthetic screen.
    func replaceBackend(_ b: WindowsBackend) {
        backend = b
        trusted = b.isTrusted
    }

    // MARK: Derived

    var display: Display? { displays.first { $0.id == displayID } ?? map?.display }

    var grid: GridSpec { display.map { backend.grid(for: $0) } ?? map?.grid ?? .default }

    /// The target, only while it is on the shown display (a window moved away by hand stops being
    /// one: placing it would pull it back across screens).
    var target: TrackedWindow? { activeTargetID.flatMap { backend.window($0) } }

    var activeTargetID: CGWindowID? {
        if let d = dragWindowID { return d }
        guard let id = targetID, map?.windows.contains(where: { $0.id == id }) == true else { return nil }
        return id
    }

    /// No window to place: the map asks for one to be picked.
    var needsPick: Bool { dragWindowID == nil && activeTargetID == nil }

    /// Apps with windows on the shown display, frontmost first.
    var scopeApps: [ScopeApp] { ScopeRules.apps(on: map?.windows ?? []) }

    var currentScopeApp: ScopeApp? { scopeApps.first { $0.pid == scopeApp } }

    /// Arrange is off in the window scope.
    var canArrange: Bool { scope != .window }

    /// The list: every tileable window of the shown display, front to back.
    var listWindows: [TrackedWindow] { ScopeRules.list(map?.windows ?? []) }

    /// The pick-order number shown on a row, the map and the preview.
    func number(_ id: CGWindowID) -> Int? { picks.number(of: id) }

    /// Numbers for the preview's windows, when it arranges the picked windows (the map's and the
    /// real screen's ghosts).
    var previewNumbers: [CGWindowID: Int] {
        let plan: ArrangePlan? = showsMap ? (scope == .selection ? preview : nil) : layoutPlan
        guard let p = plan, p.kind == .arrange else { return [:] }
        var out: [CGWindowID: Int] = [:]
        for m in p.moves { if let n = picks.number(of: m.windowID) { out[m.windowID] = n } }
        return out
    }

    // MARK: Main surface: layouts

    nonisolated static let suggestedID = "suggested"

    /// The full map is on screen (More, the keyboard map, a drag, a cell cursor); otherwise the
    /// layout thumbnails are.
    var showsMap: Bool { showMore || dragWindowID != nil || mode == .keyboard || selection != nil }

    /// The windows the layouts act on: the picked ones in pick order, else every tileable window
    /// of the shown display, front to back.
    var layoutWindows: [TrackedWindow] {
        let list = listWindows
        guard !picks.isEmpty else { return list }
        let byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return picks.ids.compactMap { byID[$0] }
    }

    /// The thumbnails for the current windows: Suggested first, then what makes sense for N.
    var layoutOptions: [WindowsAutoLayout.Option] {
        guard let d = display else { return [] }
        return WindowsAutoLayout.options(count: layoutWindows.count, usable: d.usableFrame, gaps: grid)
    }

    /// The thumbnail shown on the map: the hovered one, else the chosen one (Suggested when the
    /// choice no longer fits the count).
    var shownLayout: WindowsAutoLayout.Option? {
        let options = layoutOptions
        if let h = layoutHover, let o = options.first(where: { $0.id == h }) { return o }
        return options.first { $0.id == layoutChoice } ?? options.first
    }

    var chosenLayout: WindowsAutoLayout.Option? {
        let options = layoutOptions
        return options.first { $0.id == layoutChoice } ?? options.first
    }

    /// Every window already sits where the chosen layout would put it.
    var layoutInPlace: Bool {
        guard let p = layoutPlan, !p.moves.isEmpty else { return false }
        return p.moves.allSatisfy { PlacementMath.approx($0.from, $0.to, 2) }
    }

    func planLayout(_ option: WindowsAutoLayout.Option) -> ArrangePlan? {
        guard let d = display else { return nil }
        let windows = layoutWindows.map { PlanWindow(id: $0.id, frame: $0.frame, bundleID: $0.bundleID, title: $0.title) }
        guard !windows.isEmpty else { return nil }
        return WindowsAutoLayout.plan(option.shape, windows: windows, order: picks.isEmpty ? .minTravel : .given,
                                      displayID: d.id, usable: d.usableFrame, gaps: grid)
    }

    /// A thumbnail clicked: it becomes what Apply does. Nothing moves.
    func chooseLayout(_ id: String) {
        guard layoutOptions.contains(where: { $0.id == id }) else { return }
        layoutChoice = id
        recomputePreview()
    }

    /// The pointer is on a thumbnail (nil = left them): the map and the real screen show it.
    func hoverLayout(_ id: String?) {
        guard id != layoutHover else { return }
        layoutHover = id
        recomputePreview()
    }

    func hoverApply(_ on: Bool) {
        guard on != applyHover else { return }
        applyHover = on
        pushOverlay()
    }

    /// Apply on the main surface: the chosen layout. Undoable.
    func applyLayout(closeAfter: Bool = false) {
        guard let o = chosenLayout, let plan = planLayout(o), !layoutInPlace else { return }
        commit(plan, label: WindowsText.layout(o), closeAfter: closeAfter)
    }

    /// "More": the full map with cells, grid, scope and strategies.
    func setMore(_ on: Bool) {
        if on {
            guard !showMore else { return }
            showMore = true
            showHelp = false
            showWorkspaces = false
            naming = nil
            renaming = nil
            hoverWorkspace(nil)
            layoutHover = nil
            applyHover = false
            recomputePreview()
        } else {
            showLayouts()
        }
    }

    /// Back to the thumbnails: whatever the map was previewing goes (the picks stay).
    func showLayouts() {
        showMore = false
        if mode == .keyboard { mode = .browse }
        strategy = nil
        hoverCell = nil
        selection = nil
        sweeping = false
        if scope == .app || scope == .window { scope = picks.count >= 2 ? .selection : .screen }
        recomputePreview()
    }

    func toggleHelp() {
        showHelp.toggle()
        if showHelp { showWorkspaces = false; naming = nil; renaming = nil; hoverWorkspace(nil) }
    }

    var dragWindowID: CGWindowID? { if case let .drag(id, _) = mode { id } else { nil } }

    func name(_ id: CGWindowID) -> String { backend.window(id)?.appName ?? WindowsText.t("Windows") }

    /// The window a swap would displace (drag mode).
    var swapPartner: CGWindowID? {
        guard let p = preview, p.kind == .swap, p.moves.count > 1 else { return nil }
        return p.moves[1].windowID
    }

    // MARK: Open / close

    /// The Windows tab came on screen. `keyboard`: opened by the hotkey.
    func open(keyboard: Bool) {
        visible = true
        trusted = backend.isTrusted
        guard trusted else { return }
        if !backend.isRunning { backend.start() }
        let dragging = dragWindowID != nil
        if !dragging {
            mode = keyboard ? .keyboard : .browse
            scope = .screen
            scopeApp = nil
            displayChosen = false
        }
        pickHover = nil
        picks.clear()
        resetLayouts()
        if scope == .selection { scope = .screen }
        setRowHover(nil)
        reloadDisplays()
        reloadMap()
        if !dragging {
            targetID = openingTarget()
            reloadMap()
        }
        if mode == .keyboard { startSelection() }
        observeWindows()
        recomputePreview()
        // Fresh frames; the target stays the one captured above.
        pending = Task { [weak self] in
            guard let self else { return }
            await self.backend.refresh()
            guard self.visible else { return }
            self.reloadMap()
            if self.dragWindowID == nil, self.activeTargetID == nil, self.selection == nil {
                self.targetID = self.openingTarget()
            }
            if self.mode == .keyboard, self.selection == nil { self.startSelection() }
            self.recomputePreview()
        }
    }

    /// The tab left the screen (other tab, collapse, sleep).
    func close() {
        visible = false
        mode = .browse
        hoverCell = nil
        pickHover = nil
        selection = nil
        strategy = nil
        picks.clear()
        resetLayouts()
        layoutPlan = nil
        if scope == .selection { scope = .screen }
        setRowHover(nil)
        sweeping = false
        hotZone = nil
        mapScreenRect = nil
        contentScreenRect = nil
        outcomeTask?.cancel(); outcomeTask = nil
        closeTask?.cancel(); closeTask = nil
        // Drop the handle only: a commit or undo in flight still finishes (and resets `busy`).
        pending = nil
        outcome = nil
        setPreview(nil)
    }

    private func resetLayouts() {
        showMore = false
        showHelp = false
        showWorkspaces = false
        naming = nil
        renaming = nil
        workspaceHover = nil
        workspacePreview = nil
        layoutChoice = Self.suggestedID
        layoutHover = nil
        applyHover = false
    }

    /// Accessibility was granted while the app runs.
    func trustChanged() {
        trusted = backend.isTrusted
        if trusted, visible { open(keyboard: mode == .keyboard) }
    }

    private func reloadDisplays() {
        displays = backend.displays()
        // A drag shows the display whose notch it reached; otherwise the panel's display.
        if dragWindowID != nil || displayChosen, let id = displayID, displays.contains(where: { $0.id == id }) { return }
        // From the keyboard (⌃⌥Space) the panel opens on the notch, but the work is where the
        // pointer is: show that display, so the ultrawide stays the target when working there.
        let p = pointer()
        let chosen = mode == .keyboard ? ScopeRules.display(containing: p, in: displays) : nil
        displayID = (chosen ?? ScopeRules.panelDisplay(pointer: p, displays: displays))?.id ?? displays.first?.id
    }

    /// The frontmost window, only when it is on the shown display.
    private func openingTarget() -> CGWindowID? {
        guard let d = display else { return nil }
        return ScopeRules.openingTarget(frontmost: backend.targetWindowID,
                                        on: backend.screenMap(for: nil, display: d)?.windows ?? [])
    }

    /// The panel was laid out on a display other than the one guessed at opening (an external
    /// pill): show that one. Deferred: this arrives during layout.
    private func panelLaidOut() {
        guard visible, !displayChosen, mode != .keyboard, dragWindowID == nil, let r = contentScreenRect,
              let d = ScopeRules.display(containing: CGPoint(x: r.midX, y: r.midY), in: displays),
              d.id != displayID else { return }
        Task { @MainActor [weak self] in
            guard let self, self.visible, !self.displayChosen, self.dragWindowID == nil else { return }
            self.switchDisplay(to: d.id, opening: true)
        }
    }

    func reloadMap() {
        map = backend.screenMap(for: targetID, display: display)
        if displayID == nil { displayID = map?.display.id }
        canUndo = backend.canUndo
        // Picked windows that closed or left the display drop out.
        let present = Set(listWindows.map(\.id))
        if picks.ids.contains(where: { !present.contains($0) }) {
            picks.keep(only: present)
            syncSelectionScope()
        }
        if let r = rowHover, !present.contains(r) { setRowHover(nil) }
    }

    /// One observation chain per opening: a chain from an earlier opening stops at its next fire.
    private func observeWindows(generation: Int? = nil) {
        if generation == nil { observation += 1 }
        let gen = generation ?? observation
        backend.onWindowsChange { [weak self] in
            guard let self, self.visible, gen == self.observation else { return }
            self.reloadMap()
            // Plans carry the windows' current frames: a preview must not go stale before Apply.
            self.recomputePreview()
            self.observeWindows(generation: gen)
        }
    }

    // MARK: Display pager

    /// The switcher: show the next / previous display and target its frontmost window.
    func showDisplay(offset: Int) {
        guard displays.count > 1, let i = displays.firstIndex(where: { $0.id == displayID }) else { return }
        displayChosen = true
        switchDisplay(to: displays[(i + offset + displays.count) % displays.count].id, opening: false)
    }

    /// `opening`: the frontmost window only if it is there (as when the tab opens); otherwise the
    /// frontmost window of that display.
    private func switchDisplay(to id: String, opening: Bool) {
        displayID = id
        hoverCell = nil
        pickHover = nil
        selection = nil
        clearPicks(recompute: false)
        reloadMap()
        if opening {
            targetID = openingTarget()
        } else {
            targetID = ScopeRules.frontmost(preferring: backend.targetWindowID, on: map?.windows ?? [])
        }
        if scope == .app { pickScopeApp(keepCurrent: true) }
        reloadMap()
        if mode == .keyboard { startSelection() }
        recomputePreview()
    }

    // MARK: Scope

    /// Picking the app scope again moves on to the next app.
    func setScope(_ s: WindowsScope) {
        if s == .selection {
            guard picks.count >= 2 else { return }
            scope = .selection
            hoverCell = nil
            recomputePreview()
            return
        }
        if s == .app, scope == .app { nextApp(); return }
        // Another scope: the picked windows are let go (numbers only mean something in the selection).
        clearPicks(recompute: false)
        scope = s
        if s == .app { pickScopeApp(keepCurrent: false) }
        if s == .window { strategy = nil }
        hoverCell = nil
        recomputePreview()
    }

    func nextApp() {
        let apps = scopeApps
        guard scope == .app, !apps.isEmpty else { return }
        let i = apps.firstIndex { $0.pid == scopeApp } ?? -1
        setScopeApp(apps[(i + 1) % apps.count].pid)
    }

    func setScopeApp(_ pid: pid_t) {
        clearPicks(recompute: false)
        scope = .app
        scopeApp = pid
        if target?.pid != pid { targetID = ScopeRules.frontmost(preferring: nil, on: map?.windows ?? [], pid: pid) }
        hoverCell = nil
        if selection != nil || mode == .keyboard { startSelection() }
        recomputePreview()
    }

    /// The target's app, else the frontmost app's when it has windows here, else the first app here.
    private func pickScopeApp(keepCurrent: Bool) {
        let apps = scopeApps
        if keepCurrent, let a = scopeApp, apps.contains(where: { $0.pid == a }) {
            // Same app on the new display.
        } else if let t = target, apps.contains(where: { $0.pid == t.pid }) {
            scopeApp = t.pid
        } else if let f = backend.targetWindowID.flatMap({ backend.window($0) }), apps.contains(where: { $0.pid == f.pid }) {
            scopeApp = f.pid
        } else {
            scopeApp = apps.first?.pid
        }
        if let a = scopeApp, target?.pid != a {
            targetID = ScopeRules.frontmost(preferring: nil, on: map?.windows ?? [], pid: a)
        }
    }

    /// A click on a window of the map (or its row): it becomes the target, and the only window
    /// acted on — the picked ones are let go. Nothing moves. `keepPicks`: Tab, which only moves
    /// the target (Space then picks it).
    func select(_ id: CGWindowID, keepPicks: Bool = false) {
        guard dragWindowID == nil, let w = map?.windows.first(where: { $0.id == id }), w.isTileable else { return }
        if !keepPicks { clearPicks(recompute: false) }
        targetID = id
        if scope == .app { scopeApp = w.pid }
        pickHover = nil
        hoverCell = nil
        if selection != nil || mode == .keyboard { startSelection() }
        recomputePreview()
    }

    // MARK: Picking (the list)

    /// A row (or a map window) clicked: plain or ⌘ = add / remove (numbered in pick order);
    /// ⇧ = a range from the last one picked.
    func click(_ id: CGWindowID, _ how: Click) {
        switch how {
        case .plain, .toggle: togglePick(id)
        case .extend: extendPick(to: id)
        }
    }

    /// Click / Space. Nothing moves.
    func togglePick(_ id: CGWindowID) {
        guard dragWindowID == nil, listWindows.contains(where: { $0.id == id }) else { return }
        picks.toggle(id)
        pickChanged(focus: picks.contains(id) ? id : picks.ids.last)
    }

    /// ⇧-click: from the last picked to this row, in list order.
    func extendPick(to id: CGWindowID) {
        guard dragWindowID == nil, listWindows.contains(where: { $0.id == id }) else { return }
        picks.extend(to: id, in: listWindows.map(\.id))
        pickChanged(focus: id)
    }

    /// Swap the two picked windows (with more, #1 goes last and the rest move up).
    func rotatePicks() {
        guard picks.count >= 2 else { return }
        picks.rotate()
        recomputePreview()
    }

    func clearPicks() { clearPicks(recompute: true) }

    private func clearPicks(recompute: Bool) {
        guard !picks.isEmpty else { return }
        picks.clear()
        layoutChoice = Self.suggestedID
        syncSelectionScope()
        if recompute { recomputePreview() }
    }

    private func pickChanged(focus: CGWindowID?) {
        if let focus { targetID = focus }
        // Another count, another set of layouts: back to the suggestion.
        layoutChoice = Self.suggestedID
        pickHover = nil
        hoverCell = nil
        syncSelectionScope()
        if mode == .keyboard || selection != nil { startSelection() }
        recomputePreview()
    }

    /// Two or more picked ⇔ the selection scope. Leaving it drops its arrangement preview.
    private func syncSelectionScope() {
        if picks.count >= 2 {
            if scope != .selection { scope = .selection; selection = nil }
        } else if scope == .selection {
            scope = .screen
            strategy = nil
        }
    }

    /// The pointer is over a list row (nil = left the list).
    func hoverRow(_ id: CGWindowID?) {
        guard id != rowHover else { return }
        setRowHover(id)
    }

    /// Also clears (open / close / the window left): tells the overlay only when something changed.
    private func setRowHover(_ id: CGWindowID?) {
        guard id != rowHover else { return }
        rowHover = id
        onHighlight?(id.flatMap { backend.window($0) }, id == nil ? nil : display)
    }

    // MARK: Grid and strategy (preview only)

    /// A grid preset. With windows picked it also previews them in it at once (one per cell when
    /// they fill it exactly: two picked + 2×1 = side by side, + 1×2 = stacked).
    func choosePreset(_ g: GridSpec) {
        setGrid(g)
        guard scope == .selection, canArrange else { return }
        if strategy == nil { strategy = picks.count == grid.cellCount ? .cells : backend.defaultStrategy }
        hoverCell = nil
        selection = nil
        recomputePreview()
    }

    func setGrid(_ g: GridSpec) {
        guard let d = display, g.clamped() != grid else { return }
        backend.setGrid(g, for: d)
        selection?.clamp(to: grid)
        hoverCell = nil
        reloadMap()
        recomputePreview()
    }

    func adjustGrid(cols: Int = 0, rows: Int = 0) {
        var g = grid
        g.cols = max(1, min(12, g.cols + cols))
        g.rows = max(1, min(8, g.rows + rows))
        setGrid(g)
    }

    /// Picking a chip previews; picking it again clears. Apply commits.
    func choose(_ s: ArrangeStrategy?) {
        guard canArrange || s == nil else { return }
        strategy = strategy == s ? nil : s
        hoverCell = nil
        recomputePreview()
    }

    var arrangementPreview: ArrangePlan? {
        guard strategy != nil, hoverCell == nil, let p = preview, p.kind == .arrange else { return nil }
        return p
    }

    func apply() {
        guard let p = arrangementPreview else { return }
        commit(p, label: strategy.map(WindowsText.strategy))
    }

    // MARK: Pointer

    /// `pick`: the window a click would pick there (no cell preview over it).
    func hover(_ c: GridCoord?, pick: CGWindowID? = nil) {
        guard !sweeping, dragWindowID == nil else { return }
        if pickHover != pick { pickHover = pick }
        // Nothing to place (or the pointer is on a window to pick, or a selection is being
        // arranged): no cell preview.
        let cell = pick != nil || needsPick || scope == .selection ? nil : c.map { CellRect(col: $0.col, row: $0.row) }
        guard cell != hoverCell else { return }
        hoverCell = cell
        recomputePreview()
    }

    func sweep(from a: GridCoord, to b: GridCoord) {
        guard dragWindowID == nil, !needsPick, scope != .selection else { return }
        pickHover = nil
        sweeping = true
        let cell = CellRect.spanning(a, b)
        guard cell != hoverCell else { return }
        hoverCell = cell
        recomputePreview()
    }

    /// Button up after a click or a sweep: place the target there.
    func endSweep() {
        sweeping = false
        guard let cell = hoverCell else { return }
        place(cell)
    }

    // MARK: Keyboard

    /// Returns true when the key was ours.
    @discardableResult
    func handle(_ key: Key) -> Bool {
        guard trusted else { return false }
        // Typing a workspace name: the field gets every key; Esc stops typing.
        if naming != nil {
            if key == .escape { cancelNaming(); return true }
            return false
        }
        switch key {
        case let .arrow(d, shift):
            guard map != nil else { return true }
            strategy = nil
            hoverCell = nil
            if selection == nil {
                startSelection()
            } else if shift {
                selection?.extend(d, grid: grid)
            } else {
                selection?.move(d, grid: grid)
            }
            recomputePreview()
            return true
        case .enter:
            if let p = arrangementPreview {
                commit(p, label: strategy.map(WindowsText.strategy), closeAfter: true)
            } else if let s = selection {
                place(s.rect, closeAfter: true)
            } else if !showsMap {
                applyLayout()
            }
            return true
        case .escape:
            // The picked windows go first, then the preview, then More, then the panel.
            if showHelp {
                showHelp = false
            } else if showWorkspaces {
                setWorkspaces(false)
            } else if !picks.isEmpty {
                clearPicks()
            } else if strategy != nil || selection != nil || hoverCell != nil {
                strategy = nil; selection = nil; hoverCell = nil
                recomputePreview()
            } else if showMore {
                showLayouts()
            } else {
                onRequestClose?()
            }
            return true
        case let .cycle(forward):
            let ids = ScopeRules.candidates(scope, app: scopeApp, on: map?.windows ?? [])
            if let id = ScopeRules.cycle(from: activeTargetID, in: ids, forward: forward) { select(id, keepPicks: true) }
            return true
        case .togglePick:
            if let id = activeTargetID { togglePick(id) }
            return true
        case .swapPicks:
            rotatePicks()
            return true
        case .arrangeAll:
            guard showsMap else { chooseLayout(Self.suggestedID); return true }
            guard canArrange else { return true }
            selection = nil
            if strategy == nil { choose(backend.defaultStrategy) }
            return true
        case .undo:
            undo()
            return true
        case let .digit(n):
            // Digits restore the saved workspaces (the older saved layouts when there are none).
            let saved = workspaces.workspaces
            if !saved.isEmpty {
                guard n <= saved.count else { return true }
                restoreFromTab(saved[n - 1].id)
                return true
            }
            let layouts = backend.layouts
            guard n >= 1, n <= layouts.count else { return true }
            let plans = backend.planLayout(layouts[n - 1])
            commitAll(plans, label: layouts[n - 1].name)
            return true
        }
    }

    private func startSelection() {
        // Nothing to place: Tab picks a window first.
        guard let d = display, let t = target else { selection = nil; return }
        let frame: CGRect? = t.frame
        selection = KeyboardSelection.start(for: frame, grid: grid, usable: d.usableFrame)
    }

    // MARK: Drag mode

    /// The notch took over a window drag (DragMachine said `.open`).
    func beginDrag(window: CGWindowID, frame: CGRect, display: Display?, hotZone: CGRect) {
        mode = .drag(window: window, frame: frame)
        targetID = window
        if let display { displayID = display.id }
        self.hotZone = hotZone
        hoverCell = nil
        strategy = nil
        selection = nil
        mapScreenRect = nil
        contentScreenRect = nil
    }

    /// The cell under a screen point, when the point is on the map.
    func cell(atScreen p: CGPoint) -> GridCoord? {
        guard let rect = mapScreenRect, rect.contains(p), let d = display else { return nil }
        let proj = MapProjection(display: d.frame, usable: d.usableFrame, size: rect.size)
        return proj.cell(at: CGPoint(x: p.x - rect.minX, y: rect.maxY - p.y), grid: grid)
    }

    /// Pointer moved during an active drag (Cocoa point).
    @discardableResult
    func dragMoved(to p: CGPoint) -> DragStep {
        guard dragWindowID != nil else { return .none }
        if let c = cell(atScreen: p) {
            let cell = CellRect(col: c.col, row: c.row)
            if cell != hoverCell { hoverCell = cell; recomputePreview() }
            return .none
        }
        // Off the map: inside the panel (or still at the notch) just clears; beyond it cancels.
        if let content = contentScreenRect {
            let zone = content.union(hotZone ?? content).insetBy(dx: -24, dy: -24)
            if !zone.contains(p) { cancelDrag(); return .cancelled }
        }
        if hoverCell != nil { hoverCell = nil; recomputePreview() }
        return .none
    }

    /// Button released during an active drag.
    @discardableResult
    func dragEnded(at p: CGPoint) -> DragStep {
        guard case let .drag(id, frame) = mode else { return .none }
        if dragMoved(to: p) == .cancelled { return .cancelled }
        guard let cell = hoverCell, let d = display,
              let plan = backend.planDrop(id, on: cell, display: d, grid: grid, originalFrame: frame) else {
            cancelDrag()
            return .cancelled
        }
        mode = .browse
        lastCell[d.id] = cell
        commit(plan, closeAfterIfExact: true)
        return .committed
    }

    func cancelDrag() {
        guard dragWindowID != nil else { return }
        mode = .browse
        hoverCell = nil
        hotZone = nil
        setPreview(nil)
    }

    // MARK: Preview

    func recomputePreview() {
        guard visible, trusted, let d = display else { layoutPlan = nil; setPreview(nil); return }
        let shown = showsMap ? nil : shownLayout.flatMap(planLayout)
        if shown != layoutPlan { layoutPlan = shown }
        let g = grid
        var plan: ArrangePlan?
        if case let .drag(id, frame) = mode {
            plan = hoverCell.flatMap { backend.planDrop(id, on: $0, display: d, grid: g, originalFrame: frame) }
        } else if let cell = hoverCell {
            plan = activeTargetID.flatMap { backend.planPlace($0, in: cell, on: d, grid: g) }
        } else if let s = strategy, canArrange {
            let ids = ScopeRules.arrangeIDs(scope, app: scopeApp, on: map?.windows ?? [], picked: picks.ids)
            plan = ids?.isEmpty == true ? nil : backend.planArrange(on: d, strategy: s, grid: g, windowIDs: ids)
            // The selection goes in pick order: #1 takes the first cell in reading order.
            if scope == .selection, let p = plan, let ids { plan = ReadingOrder.assign(p, order: ids) }
        } else if let sel = selection {
            plan = activeTargetID.flatMap { backend.planPlace($0, in: sel.rect, on: d, grid: g) }
        }
        setPreview(plan)
    }

    private func setPreview(_ p: ArrangePlan?) {
        if p != preview { preview = p }
        pushOverlay()
    }

    /// The real screen shows the map's preview; on the main surface only while a thumbnail (or
    /// Apply) is under the pointer, so opening the tab never covers the screen with boxes.
    func pushOverlay() {
        let onScreen = preview ?? workspacePreview ?? (layoutHover != nil || applyHover ? layoutPlan : nil)
        guard onScreen != lastOverlay else { return }
        lastOverlay = onScreen
        onPreview?(onScreen, onScreen == nil ? nil : display)
    }

    // MARK: Commit

    func place(_ cell: CellRect, closeAfter: Bool = false) {
        guard let t = activeTargetID, let d = display, let plan = backend.planPlace(t, in: cell, on: d, grid: grid) else { return }
        lastCell[d.id] = cell
        commit(plan, closeAfter: closeAfter)
    }

    func commit(_ plan: ArrangePlan, label: String? = nil, closeAfter: Bool = false, closeAfterIfExact: Bool = false) {
        commitAll([plan], label: label, closeAfter: closeAfter, closeAfterIfExact: closeAfterIfExact)
    }

    private func commitAll(_ plans: [ArrangePlan], label: String?, closeAfter: Bool = false, closeAfterIfExact: Bool = false) {
        let plans = plans.filter { !$0.moves.isEmpty }
        guard !busy, !plans.isEmpty else { return }
        busy = true
        hoverCell = nil
        strategy = nil
        sweeping = false
        layoutHover = nil
        applyHover = false
        setPreview(nil)
        pending = Task { [weak self] in
            guard let self else { return }
            var results: [PlacementResult] = []
            for p in plans { results += await self.backend.commit(p, label: label) }
            self.finish(results, closeAfter: closeAfter, closeAfterIfExact: closeAfterIfExact)
        }
    }

    private func finish(_ results: [PlacementResult], closeAfter: Bool, closeAfterIfExact: Bool) {
        busy = false
        let report = OutcomeReport(results: results, name: name)
        canUndo = backend.canUndo
        reloadMap()
        recomputePreview()
        show(report)
        if closeAfter || (closeAfterIfExact && report.allExact) {
            if !report.allExact { onPeek?(report.line) }
            closeTask?.cancel()
            let delay = closeDelay
            closeTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled, self.visible else { return }
                self.onRequestClose?()
            }
        }
    }

    private func show(_ report: OutcomeReport) {
        outcome = report
        outcomeTask?.cancel()
        guard visible else { return }
        let d = outcomeDuration
        outcomeTask = Task { [weak self] in
            try? await Task.sleep(for: d)
            guard let self, !Task.isCancelled else { return }
            self.outcome = nil
        }
    }

    func undo() {
        guard backend.canUndo, !busy else { return }
        busy = true
        setPreview(nil)
        pending = Task { [weak self] in
            guard let self else { return }
            let results = await self.backend.undo()
            self.busy = false
            self.canUndo = self.backend.canUndo
            self.reloadMap()
            self.recomputePreview()
            let report = OutcomeReport(results: results, name: self.name)
            self.show(results.isEmpty || report.allExact
                      ? OutcomeReport(results: [], name: self.name).with(line: WindowsText.t("Undone"))
                      : report)
        }
    }

    // MARK: Direct hotkeys (no surface)

    /// Acts on the frontmost window; returns the line to show when it did not land exactly.
    @discardableResult
    func direct(_ action: DirectAction) async -> String? {
        if action == .undo {
            guard backend.canUndo else { return nil }
            let r = await backend.undo()
            canUndo = backend.canUndo
            let report = OutcomeReport(results: r, name: name)
            return report.allExact ? nil : report.line
        }
        guard let id = backend.targetWindowID, let w = backend.window(id),
              let d = ScreenSpace.bestIndex(for: w.frame, among: backend.displays().map(\.frame)).map({ backend.displays()[$0] })
        else { return nil }
        let g = backend.grid(for: d)
        var plan: ArrangePlan?
        var step = 0
        switch action {
        case .leftHalf, .rightHalf:
            step = HalvesCycle.nextStep(after: lastDirect, windowID: id, action: action, current: w.frame)
            plan = backend.planPlace(id, in: HalvesCycle.cell(for: action, step: step), on: d, grid: HalvesCycle.grid(like: g))
        case .maximize:
            plan = backend.planPlace(id, in: .all(g), on: d, grid: g)
        case .restore:
            guard let initial = backend.initialFrame(for: id) else { return WindowsText.t("Nothing to restore") }
            plan = ArrangePlan(kind: .restore, displayID: d.id, usable: d.usableFrame, grid: g,
                               moves: [PlannedMove(windowID: id, from: w.frame, to: initial, cell: nil)])
        case .fit:
            plan = backend.planFit(id)
        case .undo:
            break
        }
        guard let plan else { return nil }
        let results = await backend.commit(plan, label: nil)
        if action == .leftHalf || action == .rightHalf, let r = results.first {
            lastDirect = HalvesCycle.Last(windowID: id, action: action, step: step, frame: r.landed ?? r.requested)
        } else {
            lastDirect = nil
        }
        canUndo = backend.canUndo
        let report = OutcomeReport(results: results, name: name)
        return report.allExact ? nil : report.line
    }

    // MARK: Arrange shortcuts (no surface)

    /// Arranges the display under the pointer with `strategy` and commits at once (undoable with
    /// the undo hotkey). `appOnly`: only the front app's windows there. Never touches another
    /// display. Returns the line for the peek.
    func arrangeShortcut(_ strategy: ArrangeStrategy, appOnly: Bool) async -> String {
        guard backend.isTrusted, backend.isRunning else { return WindowsText.t("Windows needs Accessibility") }
        guard !busy else { return WindowsText.t("Busy — try again") }
        let all = backend.displays()
        guard let d = ScopeRules.display(containing: pointer(), in: all) ?? all.first,
              let screen = backend.screenMap(for: nil, display: d) else { return WindowsText.t("Nothing to arrange here") }
        var ids: [CGWindowID]?
        if appOnly {
            guard let front = backend.targetWindowID.flatMap({ backend.window($0) }) else {
                return WindowsText.t("No app in front")
            }
            ids = ScopeRules.arrangeIDs(.app, app: front.pid, on: screen.windows)
            if ids?.isEmpty == true { return WindowsText.f("No %@ windows on this display", front.appName) }
        }
        let plan = backend.planArrange(on: d, strategy: strategy, grid: backend.grid(for: d), windowIDs: ids)
        guard !plan.moves.isEmpty else { return WindowsText.t("Nothing to arrange here") }
        busy = true
        let results = await backend.commit(plan, label: WindowsText.strategy(strategy))
        busy = false
        canUndo = backend.canUndo
        if visible { reloadMap(); recomputePreview() }
        var line = WindowsText.strategy(strategy) + " · " + OutcomeReport(results: results, name: name).line
        if !plan.untouched.isEmpty { line += " · " + WindowsText.f("%d left", plan.untouched.count) }
        return line
    }

    // MARK: Auto-arrange shortcut (no surface)

    /// ⌃⌥A: the suggested layout for every tileable window of the display under the pointer,
    /// committed at once (undo with the undo hotkey), windows paired with cells by least travel.
    /// `appOnly` (⇧): only the front app's windows there. Never touches another display. Returns
    /// the line for the peek.
    func autoArrangeShortcut(appOnly: Bool) async -> String {
        guard let (plan, shape) = planAutoArrange(appOnly: appOnly) else { return autoArrangeRefusal(appOnly: appOnly) }
        busy = true
        let results = await backend.commit(plan, label: WindowsText.t("Auto-arrange"))
        busy = false
        canUndo = backend.canUndo
        if visible { reloadMap(); recomputePreview() }
        var line = WindowsText.layoutTitle(shape) + " · " + OutcomeReport(results: results, name: name).line
        if !plan.untouched.isEmpty { line += " · " + WindowsText.f("%d left as they are", plan.untouched.count) }
        return line
    }

    /// What ⌃⌥A would do right now (nil: nothing to do, or not allowed; `autoArrangeRefusal` says why).
    func planAutoArrange(appOnly: Bool) -> (ArrangePlan, WindowsAutoLayout.Shape)? {
        guard backend.isTrusted, backend.isRunning, !busy else { return nil }
        let all = backend.displays()
        guard let d = ScopeRules.display(containing: pointer(), in: all) ?? all.first,
              let screen = backend.screenMap(for: nil, display: d) else { return nil }
        var windows = screen.windows.filter(\.isTileable)
        if appOnly {
            guard let front = backend.targetWindowID.flatMap({ backend.window($0) }) else { return nil }
            windows = windows.filter { $0.pid == front.pid }
        }
        let pws = windows.map { PlanWindow(id: $0.id, frame: $0.frame, bundleID: $0.bundleID, title: $0.title) }
        guard let r = WindowsAutoLayout.plan(windows: pws, order: .minTravel, displayID: d.id, usable: d.usableFrame,
                                             gaps: backend.grid(for: d)), !r.plan.moves.isEmpty else { return nil }
        return (r.plan, r.shape)
    }

    private func autoArrangeRefusal(appOnly: Bool) -> String {
        guard backend.isTrusted, backend.isRunning else { return WindowsText.t("Windows needs Accessibility") }
        guard !busy else { return WindowsText.t("Busy — try again") }
        if appOnly {
            guard let front = backend.targetWindowID.flatMap({ backend.window($0) }) else { return WindowsText.t("No app in front") }
            return WindowsText.f("No %@ windows on this display", front.appName)
        }
        return WindowsText.t("Nothing to arrange here")
    }

    // MARK: Agents link

    /// Arranges exactly these windows on the target window's display (else the first window's).
    @discardableResult
    func layOut(windowIDs: [CGWindowID]) async -> [PlacementResult] {
        guard let plan = planLayOut(windowIDs: windowIDs) else { return [] }
        let r = await backend.commit(plan, label: WindowsText.t("Arrange"))
        canUndo = backend.canUndo
        return r
    }

    /// The plan behind `layOut`: these windows (unknown or untileable ones dropped — minimized,
    /// another Space — duplicates once) on the target window's display (else the first
    /// window's), in the auto-arrange layout for their count (the same planner as ⌃⌥A and the
    /// tab's Suggested). `readingOrder`: the first ID gets the first cell, and so on; otherwise
    /// the windows move as little as possible.
    func planLayOut(windowIDs: [CGWindowID], readingOrder: Bool = false) -> ArrangePlan? {
        var seen = Set<CGWindowID>()
        let windows = windowIDs.compactMap { id -> TrackedWindow? in
            guard let w = backend.window(id), w.isTileable, seen.insert(id).inserted else { return nil }
            return w
        }
        let all = backend.displays()
        let anchor = backend.targetWindowID.flatMap { backend.window($0) } ?? windows.first
        guard !windows.isEmpty, let a = anchor,
              let d = ScreenSpace.bestIndex(for: a.frame, among: all.map(\.frame)).map({ all[$0] }) else { return nil }
        let pws = windows.map { PlanWindow(id: $0.id, frame: $0.frame, bundleID: $0.bundleID, title: $0.title) }
        guard let r = WindowsAutoLayout.plan(windows: pws, order: readingOrder ? .given : .minTravel, displayID: d.id,
                                             usable: d.usableFrame, gaps: backend.grid(for: d)),
              !r.plan.moves.isEmpty else { return nil }
        return r.plan
    }

    /// Another module committed or undid through the backend: refresh the Undo state.
    func backendChanged() { canUndo = backend.canUndo }

    /// Puts a window into "the focused cell": the cell last placed into on the target window's
    /// display, else the cells the focused window covers (which then swaps out).
    @discardableResult
    func place(windowID: CGWindowID, inFocusedCell cell: CellRect? = nil) async -> PlacementResult? {
        let all = backend.displays()
        let focused = backend.targetWindowID.flatMap { backend.window($0) }
        guard let anchor = focused ?? backend.window(windowID),
              let d = ScreenSpace.bestIndex(for: anchor.frame, among: all.map(\.frame)).map({ all[$0] }) else { return nil }
        let g = backend.grid(for: d)
        let target = cell ?? lastCell[d.id]
            ?? focused.map { Geometry.nearestCell(for: $0.frame, in: g, on: d.usableFrame) }
            ?? CellRect.all(g)
        guard let plan = backend.planDrop(windowID, on: target, display: d, grid: g, originalFrame: nil) else { return nil }
        let r = await backend.commit(plan, label: nil)
        canUndo = backend.canUndo
        return r.first { $0.windowID == windowID }
    }

    // MARK: Diagnostics

    func runProbe(move: Bool) {
        guard !probeRunning else { return }
        probeRunning = true
        probeLines = []
        pending = Task { [weak self] in
            guard let self else { return }
            let lines = await self.probe(move)
            self.probeLines = lines
            self.probeRunning = false
        }
    }

    // MARK: Renderer

    func setProbeLines(_ lines: [String]) { probeLines = lines }

    func prepare(mode: Mode, display: String?, hover: CellRect?, selection: KeyboardSelection?,
                 strategy: ArrangeStrategy?, outcome: [PlacementResult]?, scope: WindowsScope = .screen,
                 switched: Bool = false, pick: CGWindowID? = nil, picked: [CGWindowID] = [], rowHover: CGWindowID? = nil,
                 more: Bool = false, layout: String? = nil, help: Bool = false) {
        visible = true
        trusted = backend.isTrusted
        self.mode = mode
        displayChosen = true
        displays = backend.displays()
        displayID = display ?? displays.first?.id
        reloadMap()
        // As the tab would: the frontmost window only on its own display; `switched` = as after the switcher.
        targetID = dragWindowID ?? (switched ? ScopeRules.frontmost(preferring: backend.targetWindowID, on: map?.windows ?? [])
                                    : openingTarget())
        self.scope = .screen
        scopeApp = nil
        picks = PickedWindows()
        if scope != .screen { setScope(scope) }
        reloadMap()
        if !picked.isEmpty {
            picks = PickedWindows(picked)
            targetID = picked.last
            syncSelectionScope()
        }
        self.rowHover = rowHover
        pickHover = pick
        hoverCell = hover
        self.selection = selection
        self.strategy = strategy
        showMore = more
        showHelp = help
        layoutChoice = layout ?? Self.suggestedID
        layoutHover = nil
        recomputePreview()
        self.outcome = outcome.map { OutcomeReport(results: $0, name: name) }
        if outcome != nil { canUndo = true }
    }
}

extension OutcomeReport {
    func with(line: String) -> OutcomeReport { OutcomeReport(badges: badges, line: line, allExact: allExact) }

    init(badges: [CGWindowID: PlacementOutcome], line: String, allExact: Bool) {
        self.badges = badges; self.line = line; self.allExact = allExact
    }
}
