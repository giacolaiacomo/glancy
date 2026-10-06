// Windows — the seam between the tab and the tiling engine. The real conformance is
// `TilingEngine`; tests and the renderer use `SampleWindowsBackend` (a synthetic screen, plans
// from the same pure `ArrangePlanner`, commits recorded instead of executed).

import AppKit

@MainActor
protocol WindowsBackend: AnyObject {
    var isTrusted: Bool { get }
    var isRunning: Bool { get }
    func start()
    func stop()
    /// Re-reads every window (the map opened).
    func refresh() async
    /// Calls `body` once, the next time the window list changes (re-armed by the caller).
    func onWindowsChange(_ body: @escaping @MainActor () -> Void)

    var targetWindowID: CGWindowID? { get }
    func window(_ id: CGWindowID) -> TrackedWindow?
    func displays() -> [Display]
    func screenMap(for windowID: CGWindowID?, display: Display?) -> ScreenMap?
    func grid(for display: Display) -> GridSpec
    func setGrid(_ grid: GridSpec, for display: Display)
    var defaultStrategy: ArrangeStrategy { get }
    var layouts: [SavedLayout] { get }
    func initialFrame(for id: CGWindowID) -> CGRect?

    func planPlace(_ windowID: CGWindowID, in cell: CellRect, on display: Display?, grid: GridSpec?) -> ArrangePlan?
    func planArrange(on display: Display, strategy: ArrangeStrategy?, grid: GridSpec?, windowIDs: [CGWindowID]?) -> ArrangePlan
    func planFit(_ windowID: CGWindowID) -> ArrangePlan?
    func planDrop(_ windowID: CGWindowID, on cell: CellRect, display: Display, grid: GridSpec?,
                  originalFrame: CGRect?) -> ArrangePlan?
    func planLayout(_ layout: SavedLayout) -> [ArrangePlan]

    func commit(_ plan: ArrangePlan, label: String?) async -> [PlacementResult]
    /// Several plans as one undoable operation (a workspace spanning displays).
    func commit(_ plans: [ArrangePlan], label: String) async -> [PlacementResult]
    /// Every known window, minimised, hidden and other-Space ones included, front to back.
    func allWindows() -> [TrackedWindow]
    var canUndo: Bool { get }
    func undo() async -> [PlacementResult]
    /// Above every other window, `windowIDs[0]` frontmost with its app activated, the rest beneath
    /// it in order. Nothing moves; no other window is raised, minimised or hidden.
    func raise(_ windowIDs: [CGWindowID]) async
}

extension TilingEngine: WindowsBackend {
    var isRunning: Bool { registry.isRunning }
    func refresh() async { await registry.refresh() }

    func onWindowsChange(_ body: @escaping @MainActor () -> Void) {
        withObservationTracking { _ = registry.windows } onChange: {
            Task { @MainActor in body() }
        }
    }

    var targetWindowID: CGWindowID? { targetWindow?.id }
    func window(_ id: CGWindowID) -> TrackedWindow? { registry.window(id) }
    var defaultStrategy: ArrangeStrategy { config.defaultStrategy }
    var layouts: [SavedLayout] { config.layouts }
    func initialFrame(for id: CGWindowID) -> CGRect? { history.initialFrame(for: id) }
    func allWindows() -> [TrackedWindow] { registry.windows }
}

// MARK: - Sample (tests, renderer)

/// A synthetic two-display Mac (the built-in 1512×982 and a 3440×1440 ultrawide) with a handful
/// of windows. Plans come from the same pure planner as the engine; `commit` only records.
@MainActor
final class SampleWindowsBackend: WindowsBackend {
    var isTrusted = true
    var isRunning = true
    var sampleDisplays: [Display]
    var windows: [TrackedWindow]
    var grids: [String: GridSpec] = [:]
    var targetWindowID: CGWindowID?
    var defaultStrategy: ArrangeStrategy = .balanced
    var layouts: [SavedLayout] = []
    var initialFrames: [CGWindowID: CGRect] = [:]
    /// Every plan handed to `commit`, in order.
    private(set) var commits: [ArrangePlan] = []
    private(set) var undoCount = 0
    /// What each committed window reports; default `.exact`.
    var outcomes: [CGWindowID: PlacementOutcome] = [:]
    /// Plans committed together through `commit(_ plans:label:)`, one entry per call.
    private(set) var groupCommits: [[ArrangePlan]] = []
    private var changeHandlers: [@MainActor () -> Void] = []

    init(displays: [Display] = SampleWindowsBackend.standardDisplays,
         windows: [TrackedWindow] = SampleWindowsBackend.standardWindows, target: CGWindowID? = 11) {
        sampleDisplays = displays
        self.windows = windows
        targetWindowID = target
    }

    nonisolated static let builtIn = Display(
        id: "builtin", displayID: 1, name: "Built-in Retina Display",
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 57, width: 1512, height: 892),
        usableFrame: CGRect(x: 0, y: 57, width: 1512, height: 892), isBuiltIn: true)
    nonisolated static let ultrawide = Display(
        id: "ultrawide", displayID: 2, name: "34-inch Ultrawide",
        frame: CGRect(x: -928, y: 982, width: 3440, height: 1440),
        visibleFrame: CGRect(x: -928, y: 982, width: 3440, height: 1440),
        usableFrame: CGRect(x: -928, y: 982, width: 3440, height: 1440), isBuiltIn: false)
    nonisolated static let standardDisplays = [builtIn, ultrawide]

    nonisolated static func window(_ id: CGWindowID, _ bundleID: String, _ app: String, _ title: String, _ frame: CGRect,
                       z: Int, canResize: Bool = true, pid: pid_t? = nil) -> TrackedWindow {
        TrackedWindow(id: id, pid: pid ?? pid_t(1000 + id), bundleID: bundleID, appName: app, title: title, frame: frame,
                      isMinimized: false, isFullscreen: false, isOnScreen: true, isFocused: z == 0, kind: .tile,
                      isProvisional: false, canMove: true, canResize: canResize, minSize: nil, zIndex: z)
    }

    /// Loose, overlapping windows, like a real desk (Cocoa frames on the built-in display).
    nonisolated static let standardWindows: [TrackedWindow] = [
        window(11, "com.apple.Terminal", "Terminal", "glancy — zsh", CGRect(x: 96, y: 300, width: 720, height: 500), z: 0),
        window(12, "com.apple.Safari", "Safari", "Glancy — spec", CGRect(x: 520, y: 150, width: 900, height: 740), z: 1),
        window(13, "com.apple.mail", "Mail", "Inbox", CGRect(x: 30, y: 70, width: 640, height: 430), z: 2),
        window(14, "com.apple.Notes", "Notes", "Ideas", CGRect(x: 1080, y: 500, width: 400, height: 420), z: 3),
        window(21, "com.microsoft.VSCode", "Code", "TilingEngine.swift", CGRect(x: -860, y: 1040, width: 1680, height: 1320), z: 4),
        window(22, "com.google.Chrome", "Chrome", "Docs", CGRect(x: 880, y: 1100, width: 1500, height: 1100), z: 5),
    ]

    func start() { isRunning = true }
    func stop() { isRunning = false }
    func refresh() async {}
    func onWindowsChange(_ body: @escaping @MainActor () -> Void) { changeHandlers.append(body) }
    /// Tests: simulate the registry changing (every armed handler fires once, as the engine's do).
    func fireChange() { let hs = changeHandlers; changeHandlers = []; for h in hs { h() } }
    func allWindows() -> [TrackedWindow] { windows }

    func window(_ id: CGWindowID) -> TrackedWindow? { windows.first { $0.id == id } }
    func displays() -> [Display] { sampleDisplays }

    private func display(of w: TrackedWindow) -> Display? { ScreenSpace.bestIndex(for: w.frame, among: sampleDisplays.map(\.frame)).map { sampleDisplays[$0] } }

    func screenMap(for windowID: CGWindowID?, display: Display?) -> ScreenMap? {
        let target = (windowID ?? targetWindowID).flatMap(window)
        guard let d = display ?? target.flatMap(self.display(of:)) ?? sampleDisplays.first else { return nil }
        let ws = windows.filter { $0.isOnScreen && self.display(of: $0)?.id == d.id }
        return ScreenMap(display: d, grid: grid(for: d), windows: ws, targetID: target?.id)
    }

    func grid(for display: Display) -> GridSpec { (grids[display.id] ?? GridSpec(cols: 3, rows: 2)).clamped() }
    func setGrid(_ grid: GridSpec, for display: Display) { grids[display.id] = grid.clamped() }
    func initialFrame(for id: CGWindowID) -> CGRect? { initialFrames[id] }

    private func pw(_ w: TrackedWindow, frame: CGRect? = nil) -> PlanWindow {
        PlanWindow(id: w.id, frame: frame ?? w.frame, bundleID: w.bundleID, title: w.title)
    }

    func planPlace(_ windowID: CGWindowID, in cell: CellRect, on display: Display?, grid: GridSpec?) -> ArrangePlan? {
        guard let w = window(windowID), let d = display ?? self.display(of: w) else { return nil }
        let g = grid ?? self.grid(for: d)
        return ArrangePlan(kind: .place, displayID: d.id, usable: d.usableFrame, grid: g,
                           moves: [ArrangePlanner.place(pw(w), in: cell, grid: g, usable: d.usableFrame)])
    }

    func planArrange(on display: Display, strategy: ArrangeStrategy?, grid: GridSpec?, windowIDs: [CGWindowID]?) -> ArrangePlan {
        let g = grid ?? self.grid(for: display)
        let candidates = windowIDs.map { $0.compactMap(window) }
            ?? windows.filter { $0.isTileable && self.display(of: $0)?.id == display.id }
        let r = ArrangePlanner.arrange(candidates.map { pw($0) }, grid: g, strategy: strategy ?? defaultStrategy,
                                       usable: display.usableFrame)
        return ArrangePlan(kind: .arrange, displayID: display.id, usable: display.usableFrame, grid: g,
                           moves: r.moves, untouched: r.untouched)
    }

    func planFit(_ windowID: CGWindowID) -> ArrangePlan? {
        guard let w = window(windowID), let d = display(of: w) else { return nil }
        let g = grid(for: d)
        let others = windows.filter { $0.id != windowID && FreeSpace.occupies($0) && self.display(of: $0)?.id == d.id }.map(\.frame)
        guard let m = ArrangePlanner.fit(pw(w), others: others, grid: g, usable: d.usableFrame) else { return nil }
        return ArrangePlan(kind: .fit, displayID: d.id, usable: d.usableFrame, grid: g, moves: [m])
    }

    func planDrop(_ windowID: CGWindowID, on cell: CellRect, display: Display, grid: GridSpec?,
                  originalFrame: CGRect?) -> ArrangePlan? {
        guard let w = window(windowID) else { return nil }
        let g = grid ?? self.grid(for: display)
        let others = windows.filter { $0.isTileable && self.display(of: $0)?.id == display.id }.map { pw($0) }
        let moves = ArrangePlanner.drop(pw(w, frame: originalFrame), on: cell, others: others, grid: g, usable: display.usableFrame)
        return ArrangePlan(kind: moves.count > 1 ? .swap : .place, displayID: display.id, usable: display.usableFrame,
                           grid: g, moves: moves)
    }

    func planLayout(_ layout: SavedLayout) -> [ArrangePlan] {
        let pairs = ArrangePlanner.match(layout.placements, windows: windows.filter(\.isTileable).map { pw($0) })
        guard let d = sampleDisplays.first, !pairs.isEmpty else { return [] }
        let g = grid(for: d)
        return [ArrangePlan(kind: .layout, displayID: d.id, usable: d.usableFrame, grid: g,
                            moves: pairs.map { ArrangePlanner.place($0.1, in: $0.0.cell, grid: g, usable: d.usableFrame) })]
    }

    func commit(_ plan: ArrangePlan, label: String?) async -> [PlacementResult] {
        commits.append(plan)
        return plan.moves.map { m in
            let outcome = outcomes[m.windowID] ?? .exact
            let landed = outcome == .appSized ? CGRect(origin: m.to.origin, size: CGSize(width: m.to.width - 6, height: m.to.height - 4))
                : outcome == .exact ? m.to : m.from
            if let i = windows.firstIndex(where: { $0.id == m.windowID }), outcome == .exact || outcome == .appSized {
                windows[i].frame = landed
            }
            return PlacementResult(windowID: m.windowID, outcome: outcome, requested: m.to, original: m.from,
                                   landed: outcome == .unreachable ? nil : landed, attempts: 1, euiWasOn: false,
                                   note: nil, elapsed: 0.04)
        }
    }

    func commit(_ plans: [ArrangePlan], label: String) async -> [PlacementResult] {
        let plans = plans.filter { !$0.moves.isEmpty }
        guard !plans.isEmpty else { return [] }
        groupCommits.append(plans)
        var out: [PlacementResult] = []
        for p in plans { out += await commit(p, label: label) }
        // One operation: `commit` counted each plan.
        commits.removeLast(plans.count)
        commits.append(ArrangePlan(kind: .layout, displayID: plans[0].displayID, usable: plans[0].usable, grid: plans[0].grid,
                                   moves: plans.flatMap(\.moves)))
        return out
    }

    var canUndo: Bool { !commits.isEmpty && undoCount < commits.count }
    func undo() async -> [PlacementResult] { undoCount += 1; return [] }

    /// Every `raise` call, in order (front first within each); nothing is raised for real.
    private(set) var raises: [[CGWindowID]] = []
    func raise(_ windowIDs: [CGWindowID]) async { raises.append(windowIDs) }
}
