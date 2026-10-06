// Tiling — the engine the Windows tab talks to. No AppKit UI here.
//
// Flow for the UI: `targetWindow` → `screenMap(for:)` (real rects) → `plan…` (target frames,
// nothing moves) → draw the preview from `plan.moves[].to` → `commit(plan)` → outcomes in
// `lastResults` → `undo()`.

import AppKit
import Observation

/// What the mini-map draws: one display, its grid, and its windows at their real frames.
public struct ScreenMap: Sendable, Equatable {
    public let display: Display
    public let grid: GridSpec
    /// On-screen, non-popup windows of this display, front to back. Real frames, never snapped.
    public let windows: [TrackedWindow]
    public let targetID: CGWindowID?
}

@MainActor @Observable
public final class TilingEngine {
    public let registry: WindowRegistry
    public let history: TilingHistory
    public var config: TilingConfig {
        didSet { if config != oldValue, let configURL { try? config.save(to: configURL) } }
    }
    /// Outcomes of the last commit or undo, for the panel.
    public private(set) var lastResults: [PlacementResult] = []
    public private(set) var isPlacing = false

    @ObservationIgnored private let placer: Placer
    @ObservationIgnored private let configURL: URL?
    @ObservationIgnored private var pendingExternal = Set<CGWindowID>()
    @ObservationIgnored private var pendingAutoFit: [CGWindowID: Date] = [:]

    /// - Parameter configURL: where the config persists; nil keeps it in memory (tests).
    public init(config: TilingConfig? = nil, configURL: URL? = TilingConfig.defaultURL) {
        self.configURL = configURL
        self.config = config ?? configURL.map { TilingConfig.load(from: $0) } ?? TilingConfig()
        let registry = WindowRegistry()
        self.registry = registry
        self.history = TilingHistory()
        self.placer = Placer(registry: registry)
        registry.onChange = { [weak self] change in self?.registryChanged(change) }
    }

    // MARK: Lifecycle

    /// Accessibility granted to this process (never prompts).
    public var isTrusted: Bool { Lab.accessibilityTrusted() }

    /// Starts the registry. Without Accessibility it does nothing; call again once granted.
    public func start() { registry.start() }
    public func stop() {
        registry.stop()
        pendingExternal.removeAll()
        pendingAutoFit.removeAll()
    }

    // MARK: Reading

    public func displays() -> [Display] { ScreenSpace.displays() }

    public func grid(for display: Display) -> GridSpec { config.grid(for: display.id) }

    public func setGrid(_ grid: GridSpec, for display: Display) { config.grids[display.id] = grid.clamped() }

    /// The window an action applies to: the focused window of the frontmost app when it can be
    /// tiled, else that app's frontmost tileable window.
    public var targetWindow: TrackedWindow? {
        if let id = registry.focusedWindowID, let w = registry.window(id), w.isTileable { return w }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        return registry.windows.first { $0.pid == pid && $0.isTileable }
    }

    public func display(for window: TrackedWindow, in displays: [Display]? = nil) -> Display? {
        ScreenSpace.display(for: window.frame, in: displays ?? self.displays())
    }

    /// The map of the target window's display (or of `display`, for the pager).
    public func screenMap(for windowID: CGWindowID? = nil, display: Display? = nil) -> ScreenMap? {
        let all = displays()
        let target = windowID.flatMap { registry.window($0) } ?? targetWindow
        guard let d = display ?? target.flatMap({ self.display(for: $0, in: all) }) ?? ScreenSpace.displayUnderMouse(in: all)
        else { return nil }
        let windows = registry.windows.filter { w in
            w.isOnScreen && w.kind != .popup && !w.isMinimized
                && ScreenSpace.display(for: w.frame, in: all)?.id == d.id
        }
        return ScreenMap(display: d, grid: grid(for: d), windows: windows, targetID: target?.id)
    }

    /// The frame a cell range maps to, for the preview overlay. Moves nothing.
    public func previewFrame(for cell: CellRect, on display: Display, grid: GridSpec? = nil) -> CGRect {
        Geometry.frame(for: cell, in: grid ?? self.grid(for: display), on: display.usableFrame)
    }

    // MARK: Planning (pure, nothing moves)

    private func planWindow(_ w: TrackedWindow) -> PlanWindow {
        PlanWindow(id: w.id, frame: w.frame, bundleID: w.bundleID, title: w.title)
    }

    private func tileable(on display: Display, all: [Display]) -> [TrackedWindow] {
        registry.windows.filter { $0.isTileable && ScreenSpace.display(for: $0.frame, in: all)?.id == display.id }
    }

    /// One window into a cell range on a display (default: the window's own display).
    public func planPlace(_ windowID: CGWindowID, in cell: CellRect, on display: Display? = nil,
                          grid: GridSpec? = nil) -> ArrangePlan? {
        guard let w = registry.window(windowID), let d = display ?? self.display(for: w) else { return nil }
        let g = grid ?? self.grid(for: d)
        return ArrangePlan(kind: .place, displayID: d.id, usable: d.usableFrame, grid: g,
                           moves: [ArrangePlanner.place(planWindow(w), in: cell, grid: g, usable: d.usableFrame)])
    }

    /// Arrange the tileable windows of a display (or only `windowIDs`, in that order).
    public func planArrange(on display: Display, strategy: ArrangeStrategy? = nil, grid: GridSpec? = nil,
                            windowIDs: [CGWindowID]? = nil) -> ArrangePlan {
        let all = displays()
        let g = grid ?? self.grid(for: display)
        let candidates = windowIDs.map { ids in ids.compactMap { registry.window($0) }.filter(\.isTileable) }
            ?? tileable(on: display, all: all)
        let result = ArrangePlanner.arrange(candidates.map(planWindow), grid: g,
                                            strategy: strategy ?? config.defaultStrategy,
                                            usable: display.usableFrame, masterFraction: config.masterFraction)
        return ArrangePlan(kind: .arrange, displayID: display.id, usable: display.usableFrame, grid: g,
                           moves: result.moves, untouched: result.untouched)
    }

    /// The grid that shows every tileable window of the display (automatic grid). Not stored.
    public func suggestedGrid(for display: Display) -> GridSpec {
        let n = tileable(on: display, all: displays()).count
        return Arrange.bestGrid(for: max(1, n), fitting: display.usableFrame, like: grid(for: display))
    }

    /// The window into the largest free area of its display.
    public func planFit(_ windowID: CGWindowID) -> ArrangePlan? {
        let all = displays()
        guard let w = registry.window(windowID), let d = display(for: w, in: all) else { return nil }
        let g = grid(for: d)
        let others = registry.windows.filter {
            $0.id != windowID && $0.isOnScreen && !$0.isMinimized && $0.kind == .tile
                && ScreenSpace.display(for: $0.frame, in: all)?.id == d.id
        }.map(\.frame)
        guard let move = ArrangePlanner.fit(planWindow(w), others: others, grid: g, usable: d.usableFrame) else { return nil }
        return ArrangePlan(kind: .fit, displayID: d.id, usable: d.usableFrame, grid: g, moves: [move])
    }

    /// Drop a window on a cell; swaps with the window filling that cell, if any.
    /// - Parameter originalFrame: where the window was before the user started dragging it. The
    ///   registry may already hold a mid-drag frame (it reconciles on kAXMoved during the drag);
    ///   the occupant of a swap must go where the dragged window *was*, and undo must put the
    ///   dragged window back there too.
    public func planDrop(_ windowID: CGWindowID, on cell: CellRect, display: Display, grid: GridSpec? = nil,
                         originalFrame: CGRect? = nil) -> ArrangePlan? {
        guard let w = registry.window(windowID) else { return nil }
        let g = grid ?? self.grid(for: display)
        let others = tileable(on: display, all: displays()).map(planWindow)
        let dragged = PlanWindow(id: w.id, frame: originalFrame ?? w.frame, bundleID: w.bundleID, title: w.title)
        let moves = ArrangePlanner.drop(dragged, on: cell, others: others, grid: g, usable: display.usableFrame)
        return ArrangePlan(kind: moves.count > 1 ? .swap : .place, displayID: display.id,
                           usable: display.usableFrame, grid: g, moves: moves)
    }

    /// A saved layout, as one plan per display it touches.
    public func planLayout(_ layout: SavedLayout) -> [ArrangePlan] {
        let all = displays()
        let windows = registry.windows.filter(\.isTileable)
        var moves: [String: [PlannedMove]] = [:]
        for (placement, pw) in ArrangePlanner.match(layout.placements, windows: windows.map(planWindow)) {
            guard let d = placement.displayID.flatMap({ id in all.first { $0.id == id } })
                    ?? ScreenSpace.display(for: pw.frame, in: all) else { continue }
            moves[d.id, default: []].append(ArrangePlanner.place(pw, in: placement.cell, grid: grid(for: d), usable: d.usableFrame))
        }
        return moves.compactMap { id, m in
            all.first { $0.id == id }.map {
                ArrangePlan(kind: .layout, displayID: id, usable: $0.usableFrame, grid: grid(for: $0), moves: m)
            }
        }
    }

    /// Captures the tileable windows as they sit now into a layout (nearest cells).
    public func captureLayout(named name: String) -> SavedLayout {
        let all = displays()
        let placements: [LayoutPlacement] = registry.windows.filter(\.isTileable).compactMap { w in
            guard let bundleID = w.bundleID, let d = ScreenSpace.display(for: w.frame, in: all) else { return nil }
            return LayoutPlacement(bundleID: bundleID, cell: Geometry.nearestCell(for: w.frame, in: grid(for: d), on: d.usableFrame),
                                   displayID: d.id)
        }
        return SavedLayout(name: name, placements: placements)
    }

    // MARK: Committing

    /// Executes a plan: snapshot for undo, every job dispatched at once (grouped per app on the
    /// app threads), outcomes awaited, history recorded. Main never blocks.
    @discardableResult
    public func commit(_ plan: ArrangePlan, label: String? = nil) async -> [PlacementResult] {
        await commit([plan], label: label ?? Self.defaultLabel(plan.kind))
    }

    /// Several plans (a workspace spans displays) as one operation: one undo puts every window back.
    @discardableResult
    public func commit(_ plans: [ArrangePlan], label: String) async -> [PlacementResult] {
        let plans = plans.filter { !$0.moves.isEmpty }
        guard !plans.isEmpty else { return [] }
        let all = displays()
        // The frames the plan was made from (planned right before the commit). For a drop that is
        // the pre-drag frame, which the registry no longer holds; undo must go back there.
        var before: [CGWindowID: CGRect] = [:]
        var snapshot: [CGWindowID: CGRect] = [:]
        var requests: [PlacementRequest] = []
        for plan in plans {
            for m in plan.moves { before[m.windowID] = m.from }
            if plan.isMultiWindow || plans.count > 1 {
                for w in registry.windows where w.isOnScreen && ScreenSpace.display(for: w.frame, in: all)?.id == plan.displayID {
                    if snapshot[w.id] == nil { snapshot[w.id] = w.frame }
                }
            }
            let tolerance = plan.grid.clamped().outerGap + 2
            requests += plan.moves.map {
                PlacementRequest(windowID: $0.windowID, target: $0.to, usable: plan.usable, edgeTolerance: tolerance)
            }
        }
        isPlacing = true
        let results = await placer.place(requests)
        isPlacing = false
        lastResults = results
        var requested: [CGWindowID: CGRect] = [:]
        var landed: [CGWindowID: CGRect] = [:]
        for r in results where r.outcome == .exact || r.outcome == .appSized {
            requested[r.windowID] = r.requested
            landed[r.windowID] = r.landed
        }
        history.record(label: label, before: before, requested: requested, landed: landed, screenSnapshot: snapshot)
        return results
    }

    /// Plans and commits in one go: the target window into a cell range of its display.
    @discardableResult
    public func place(_ windowID: CGWindowID, in cell: CellRect) async -> PlacementResult? {
        guard let plan = planPlace(windowID, in: cell) else { return nil }
        return await commit(plan).first
    }

    public var canUndo: Bool { history.canUndo }

    /// Rolls back the last operation for the windows still where it left them.
    @discardableResult
    public func undo() async -> [PlacementResult] {
        let current = Dictionary(registry.windows.map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
        guard let undo = history.undoPlan(current: current) else { return [] }
        let restore = undo.restore
        history.didUndo(undo.operation.id)
        guard !restore.isEmpty else { return [] }
        // A restore goes back exactly where it was, even partly off-screen: no push inside.
        let requests = restore.map { id, frame in
            PlacementRequest(windowID: id, target: frame, usable: frame.insetBy(dx: -100_000, dy: -100_000), edgeTolerance: 0)
        }
        isPlacing = true
        let results = await placer.place(requests)
        isPlacing = false
        lastResults = results
        return results
    }

    static func defaultLabel(_ kind: ArrangePlan.Kind) -> String {
        switch kind {
        case .place: String(localized: "Place")
        case .arrange: String(localized: "Arrange")
        case .fit: String(localized: "Fit")
        case .swap: String(localized: "Swap")
        case .layout: String(localized: "Layout")
        case .restore: String(localized: "Restore")
        }
    }

    // MARK: Reacting to the registry

    private func registryChanged(_ change: RegistryChange) {
        for id in change.removed {
            history.forget(id)
            pendingExternal.remove(id)
            pendingAutoFit[id] = nil
        }
        for id in change.movedExternally.keys where history.records[id] != nil { pendingExternal.insert(id) }
        if config.autoFitNewWindows { for id in change.added { pendingAutoFit[id] = .now } }

        // While the button is down the user is still dragging: decide on release (AeroSpace
        // defers new-window handling the same way, tab drag-out #1001).
        guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
        handleExternalMoves(afterMouseUp: change.afterMouseUp)
        handleAutoFit()
    }

    private func handleExternalMoves(afterMouseUp: Bool) {
        let ids = pendingExternal
        pendingExternal.removeAll()
        for id in ids {
            // A placement of ours is in flight (a drop on the notch commits on mouse-up, before
            // this reconcile): it is not the user dragging a tiled window away. Restoring its
            // pre-tile size here would cancel that placement.
            guard !registry.hasPlacementInFlight(id) else { continue }
            guard let w = registry.window(id), let record = history.records[id], let last = record.lastLanded,
                  !history.isWhereWeLeftIt(id, current: w.frame) else { continue }
            // Same size, new place, right after a click: the user dragged a tiled window away.
            // It gets its pre-tile size back, keeping its top-left corner (Rectangle, Loop).
            let dragged = afterMouseUp && PlacementMath.approxSize(w.frame.size, last.size, TilingHistory.tolerance)
            history.reset(id)
            guard dragged, config.restoreSizeOnDragAway, w.canResize,
                  !PlacementMath.approxSize(record.initialFrame.size, w.frame.size, TilingHistory.tolerance),
                  let d = display(for: w) else { continue }
            let size = record.initialFrame.size
            let target = CGRect(x: w.frame.minX, y: w.frame.maxY - size.height, width: size.width, height: size.height)
            Task { [weak self] in
                guard let self else { return }
                _ = await self.placer.place([PlacementRequest(windowID: id, target: PlacementMath.pushInside(target, d.usableFrame),
                                                              usable: d.usableFrame, edgeTolerance: 0)])
            }
        }
    }

    /// RESEARCH §3.3: only once the window has a title and is a tile, ~300 ms after it appeared
    /// (so the app has restored its own frame first). Never from polling.
    private func handleAutoFit() {
        guard config.autoFitNewWindows else { pendingAutoFit.removeAll(); return }
        for (id, seen) in pendingAutoFit {
            guard let w = registry.window(id), Date().timeIntervalSince(seen) < 3 else { pendingAutoFit[id] = nil; continue }
            guard w.isTileable, !w.isProvisional else { continue }
            pendingAutoFit[id] = nil
            Task { [weak self] in
                try? await Delay.sleep(for: .milliseconds(300))
                guard let self, self.config.autoFitNewWindows, let plan = self.planFit(id) else { return }
                await self.commit(plan, label: String(localized: "Auto-fit"))
            }
        }
    }
}
