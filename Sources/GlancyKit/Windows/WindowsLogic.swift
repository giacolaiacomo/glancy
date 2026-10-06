// Windows — the pure decisions behind the tab: map projection, keyboard selection, the
// drag-to-notch state machine, Rectangle-style halves cycling and outcome wording.
// No AppKit, no Accessibility: everything here is unit-tested.

import CoreGraphics
import Foundation

// MARK: - Map projection

/// Fits a display into the mini-map and converts between the two. Screen side: Cocoa coordinates
/// (y up). Map side: SwiftUI local coordinates (origin top-left, y down).
struct MapProjection: Equatable {
    let display: CGRect
    let usable: CGRect
    /// The map's drawing area; the display is fitted inside it, centred.
    let size: CGSize

    var scale: CGFloat {
        guard display.width > 0, display.height > 0 else { return 0 }
        return min(size.width / display.width, size.height / display.height)
    }

    /// Where the whole display sits in the map.
    var displayRect: CGRect {
        let w = display.width * scale, h = display.height * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    /// The map size that shows a display of this aspect inside `bounds` without letterboxing.
    static func fittedSize(display: CGSize, in bounds: CGSize) -> CGSize {
        guard display.width > 0, display.height > 0 else { return bounds }
        let s = min(bounds.width / display.width, bounds.height / display.height)
        return CGSize(width: (display.width * s).rounded(), height: (display.height * s).rounded())
    }

    func toMap(_ r: CGRect) -> CGRect {
        let d = displayRect
        return CGRect(x: d.minX + (r.minX - display.minX) * scale,
                      y: d.minY + (display.maxY - r.maxY) * scale,
                      width: r.width * scale, height: r.height * scale)
    }

    func toScreen(_ p: CGPoint) -> CGPoint {
        let d = displayRect
        guard scale > 0 else { return .zero }
        return CGPoint(x: display.minX + (p.x - d.minX) / scale, y: display.maxY - (p.y - d.minY) / scale)
    }

    /// The grid cell under a map point; nil outside the usable rect.
    func cell(at p: CGPoint, grid: GridSpec) -> GridCoord? {
        Geometry.cell(at: toScreen(p), in: grid, on: usable)
    }

    /// Every cell of the grid, in map coordinates, row by row.
    func cells(of grid: GridSpec) -> [(CellRect, CGRect)] {
        let g = grid.clamped()
        var out: [(CellRect, CGRect)] = []
        for r in 0..<g.rows {
            for c in 0..<g.cols {
                let cell = CellRect(col: c, row: r)
                out.append((cell, toMap(Geometry.frame(for: cell, in: g, on: usable))))
            }
        }
        return out
    }
}

// MARK: - Keyboard selection

enum Direction: Sendable { case left, right, up, down }

/// Arrows move a one-cell cursor; ⇧+arrows extend from where the extension started.
struct KeyboardSelection: Equatable {
    var anchor: GridCoord
    var cursor: GridCoord

    init(at c: GridCoord) { anchor = c; cursor = c }

    var rect: CellRect { .spanning(anchor, cursor) }

    /// The cell of a window frame: the cell holding its centre (a start that makes sense).
    static func start(for frame: CGRect?, grid: GridSpec, usable: CGRect) -> KeyboardSelection {
        let g = grid.clamped()
        if let frame, let c = Geometry.cell(at: CGPoint(x: frame.midX, y: frame.midY), in: g, on: usable) {
            return KeyboardSelection(at: c)
        }
        return KeyboardSelection(at: GridCoord(col: 0, row: 0))
    }

    private static func step(_ c: GridCoord, _ d: Direction, _ g: GridSpec) -> GridCoord {
        switch d {
        case .left: GridCoord(col: max(0, c.col - 1), row: c.row)
        case .right: GridCoord(col: min(g.cols - 1, c.col + 1), row: c.row)
        case .up: GridCoord(col: c.col, row: max(0, c.row - 1))
        case .down: GridCoord(col: c.col, row: min(g.rows - 1, c.row + 1))
        }
    }

    /// Plain arrow: the selection collapses to one cell and moves.
    mutating func move(_ d: Direction, grid: GridSpec) {
        let g = grid.clamped()
        let next = Self.step(cursor, d, g)
        anchor = next; cursor = next
    }

    /// ⇧+arrow: the far corner moves, the anchor stays.
    mutating func extend(_ d: Direction, grid: GridSpec) {
        cursor = Self.step(cursor, d, grid.clamped())
    }

    /// After a grid change: keep inside it.
    mutating func clamp(to grid: GridSpec) {
        let g = grid.clamped()
        func c(_ p: GridCoord) -> GridCoord { GridCoord(col: min(p.col, g.cols - 1), row: min(p.row, g.rows - 1)) }
        anchor = c(anchor); cursor = c(cursor)
    }
}

// MARK: - Drag to the notch

/// Watches window drags through the global mouse monitors and decides when the notch takes over.
/// It only reacts to a *move* of a tileable window whose pointer enters the notch hot zone;
/// resizes, text selections and drags elsewhere never open anything (Tessera's "appears on every
/// move" problem, RESEARCH E3).
struct DragMachine: Equatable {
    enum State: Equatable {
        case idle
        /// Button down on a tileable window; its frame at that moment.
        case pressed(window: CGWindowID, frame: CGRect)
        /// The window's size changed: a resize, ignored until the button comes up.
        case ignoring
        /// The notch has taken over the drag.
        case active(window: CGWindowID, frame: CGRect)
    }

    enum Effect: Equatable {
        case none
        /// Open the Windows tab in drag mode for this window (frame = before the drag).
        case open(window: CGWindowID, frame: CGRect)
        /// Pointer moved while active (Cocoa point).
        case track(CGPoint)
        /// Button released while active.
        case drop(CGPoint)
    }

    private(set) var state: State = .idle

    var isTracking: Bool {
        switch state { case .pressed, .active: true; default: false }
    }

    var isActive: Bool { if case .active = state { true } else { false } }

    /// leftMouseDown. `window` is nil unless the click landed on a tileable window we track.
    mutating func down(window: CGWindowID?, frame: CGRect?) {
        if let window, let frame { state = .pressed(window: window, frame: frame) } else { state = .idle }
    }

    /// leftMouseDragged. `currentFrame` is read only when the pointer is in the hot zone.
    mutating func dragged(to p: CGPoint, inHotZone: Bool, currentFrame: () -> CGRect?) -> Effect {
        switch state {
        case .idle, .ignoring:
            return .none
        case .active:
            return .track(p)
        case let .pressed(window, frame):
            guard inHotZone, let now = currentFrame() else { return .none }
            let sameSize = abs(now.width - frame.width) <= 2 && abs(now.height - frame.height) <= 2
            let moved = abs(now.minX - frame.minX) > 2 || abs(now.minY - frame.minY) > 2
            if !sameSize { state = .ignoring; return .none }
            guard moved else { return .none }          // a drag inside the window (text selection)
            state = .active(window: window, frame: frame)
            return .open(window: window, frame: frame)
        }
    }

    /// leftMouseUp.
    mutating func up(at p: CGPoint) -> Effect {
        defer { state = .idle }
        if case .active = state { return .drop(p) }
        return .none
    }

    /// Esc, or the pointer left the panel: the drag goes on as an ordinary move.
    mutating func cancel() {
        if isTracking { state = .ignoring }
    }
}

// MARK: - Direct hotkeys: halves with cycling

enum DirectAction: String, Codable, CaseIterable, Sendable {
    case leftHalf, rightHalf, maximize, restore, fit, undo
}

/// Rectangle's cycling: pressing the same half again steps 1/2 → 2/3 → 1/3 → 1/2, as long as the
/// window is still where the previous press left it (read-back frame); anything else starts over.
enum HalvesCycle {
    struct Last: Equatable {
        let windowID: CGWindowID
        let action: DirectAction
        let step: Int
        /// Where the window landed (read back), or what was asked when nothing came back.
        let frame: CGRect
    }

    /// Sixths: 1/2 = 3, 2/3 = 4, 1/3 = 2.
    static let widths = [3, 4, 2]
    static let columns = 6

    static func nextStep(after last: Last?, windowID: CGWindowID, action: DirectAction, current: CGRect) -> Int {
        guard let last, last.windowID == windowID, last.action == action,
              PlacementMath.approx(last.frame, current, 4) else { return 0 }
        return (last.step + 1) % widths.count
    }

    /// The cells of a 6×1 grid for a half at a cycle step.
    static func cell(for action: DirectAction, step: Int) -> CellRect {
        let w = widths[step % widths.count]
        return action == .rightHalf ? CellRect(col: columns - w, row: 0, w: w, h: 1) : CellRect(col: 0, row: 0, w: w, h: 1)
    }

    /// The 6×1 grid with the display grid's gaps.
    static func grid(like g: GridSpec) -> GridSpec {
        GridSpec(cols: columns, rows: 1, outerGap: g.outerGap, innerGap: g.innerGap)
    }
}

// MARK: - Outcomes

/// What the panel says after a commit: a short line plus a badge per window.
struct OutcomeReport: Equatable {
    let badges: [CGWindowID: PlacementOutcome]
    let line: String
    let allExact: Bool

    @MainActor
    init(results: [PlacementResult], name: (CGWindowID) -> String) {
        var b: [CGWindowID: PlacementOutcome] = [:]
        for r in results { b[r.windowID] = r.outcome }
        badges = b
        let exact = results.filter { $0.outcome == .exact }.count
        allExact = exact == results.count
        let notable = results.filter { $0.outcome != .exact }
        var parts: [String] = []
        if exact > 0 {
            parts.append(exact == results.count && results.count == 1 ? WindowsText.t("Placed exactly")
                         : WindowsText.f("%d exact", exact))
        }
        for r in notable.prefix(2) { parts.append(Self.describe(r, name(r.windowID))) }
        if notable.count > 2 { parts.append(WindowsText.f("+%d more", notable.count - 2)) }
        line = results.isEmpty ? WindowsText.t("Nothing moved") : parts.joined(separator: " · ")
    }

    @MainActor
    static func describe(_ r: PlacementResult, _ name: String) -> String {
        switch r.outcome {
        case .exact: return WindowsText.f("%@ exact", name)
        case .appSized:
            if let s = r.landed?.size {
                // Larger than asked: the app's minimum, not a choice Glancy made.
                if PlacementRun.keptLarger(s, than: r.requested.size) {
                    return WindowsText.f("%@ can't be smaller than %d×%d", name, Int(s.width), Int(s.height))
                }
                return WindowsText.f("%@ kept %d×%d", name, Int(s.width), Int(s.height))
            }
            return WindowsText.f("%@ chose its size", name)
        case .refused: return WindowsText.f("%@ refused", name)
        case .unreachable: return WindowsText.f("%@ unreachable", name)
        case .cancelled: return WindowsText.f("%@ cancelled", name)
        }
    }
}

// MARK: - Reading order (Agents link)

enum ReadingOrder {
    /// Keeps the plan's target frames but hands them out in reading order (top row first, left to
    /// right; Cocoa frames, so a higher top edge reads first) to the windows in `order`. Used when
    /// the order means something (the session that needs you gets the first cell).
    static func assign(_ plan: ArrangePlan, order: [CGWindowID]) -> ArrangePlan {
        let slots: [PlannedMove] = plan.moves.sorted { (a: PlannedMove, b: PlannedMove) -> Bool in
            let dy: CGFloat = a.to.maxY - b.to.maxY
            if abs(dy) > 1 { return dy > 0 }
            return a.to.minX < b.to.minX
        }
        let byID = Dictionary(plan.moves.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<CGWindowID>()
        let ids = order.filter { byID[$0] != nil && seen.insert($0).inserted }
        // Windows of the plan the order does not name keep their place after the named ones.
        let rest = plan.moves.map(\.windowID).filter { !seen.contains($0) }
        var moves: [PlannedMove] = []
        for (id, slot) in zip(ids + rest, slots) {
            guard let m = byID[id] else { continue }
            moves.append(PlannedMove(windowID: id, from: m.from, to: slot.to, cell: slot.cell))
        }
        return ArrangePlan(kind: plan.kind, displayID: plan.displayID, usable: plan.usable, grid: plan.grid,
                           moves: moves, untouched: plan.untouched)
    }
}

// MARK: - Scope: what the tab acts on

/// What arrange (and the target) is limited to on the shown display.
enum WindowsScope: String, CaseIterable, Sendable {
    /// Every tileable window of the display.
    case screen
    /// Only one app's windows on the display.
    case app
    /// One window: arrange is off, only placing.
    case window
    /// The windows picked in the list (⌘-click, ⇧-click, Space), in pick order: two or more.
    case selection
}

/// The windows picked for "exactly these", in the order they were picked: #1 takes the first
/// cell in reading order, #2 the next. A plain click is not a pick (it only sets the target).
struct PickedWindows: Equatable {
    private(set) var ids: [CGWindowID] = []
    /// Where a ⇧-click range starts: the last window toggled.
    private(set) var anchor: CGWindowID?

    init(_ ids: [CGWindowID] = []) {
        var seen = Set<CGWindowID>()
        self.ids = ids.filter { seen.insert($0).inserted }
        anchor = self.ids.last
    }

    var count: Int { ids.count }
    var isEmpty: Bool { ids.isEmpty }
    func contains(_ id: CGWindowID) -> Bool { ids.contains(id) }

    /// 1-based position in the pick order.
    func number(of id: CGWindowID) -> Int? { ids.firstIndex(of: id).map { $0 + 1 } }

    /// ⌘-click / Space: adds at the end, or removes (the rest renumber). `seed`: a window the
    /// user had already clicked, which becomes #1 when this starts a selection (Finder's rule).
    mutating func toggle(_ id: CGWindowID, seed: CGWindowID? = nil) {
        if ids.isEmpty, let seed, seed != id { ids = [seed] }
        if let i = ids.firstIndex(of: id) {
            ids.remove(at: i)
            anchor = ids.last
        } else {
            ids.append(id)
            anchor = id
        }
    }

    /// ⇧-click: every window from the anchor (else `seed`) to `id` in list order joins, in that
    /// direction, after the ones already picked. Without a start it is a toggle.
    mutating func extend(to id: CGWindowID, in list: [CGWindowID], seed: CGWindowID? = nil) {
        guard let from = anchor ?? seed, let a = list.firstIndex(of: from), let b = list.firstIndex(of: id) else {
            toggle(id); return
        }
        let span = a <= b ? Array(list[a...b]) : Array(list[b...a].reversed())
        for x in span where !ids.contains(x) { ids.append(x) }
        if anchor == nil { anchor = from }
    }

    /// Swap (two) / rotate (more): #1 goes last, everyone else moves up one.
    mutating func rotate() {
        guard ids.count > 1 else { return }
        ids.append(ids.removeFirst())
    }

    /// Windows gone from the display drop out (the order of the rest is kept).
    mutating func keep(only present: Set<CGWindowID>) {
        ids.removeAll { !present.contains($0) }
        if let a = anchor, !present.contains(a) { anchor = ids.last }
    }

    mutating func clear() { ids = []; anchor = nil }
}

/// An app with tileable windows on the shown display.
struct ScopeApp: Equatable, Sendable {
    let pid: pid_t
    let name: String
    let bundleID: String?
}

/// The pure rules behind the scope selector and the target. `windows` is a display's map, front
/// to back. Nothing here ever looks at another display: that is what keeps a window from being
/// pulled across screens.
enum ScopeRules {
    /// The target when the tab opens: the frontmost window only if it is on the shown display.
    static func openingTarget(frontmost: CGWindowID?, on windows: [TrackedWindow]) -> CGWindowID? {
        guard let f = frontmost, windows.contains(where: { $0.id == f && $0.isTileable }) else { return nil }
        return f
    }

    /// After switching display: the frontmost window there (the app's own front one if it is there).
    static func frontmost(preferring id: CGWindowID?, on windows: [TrackedWindow], pid: pid_t? = nil) -> CGWindowID? {
        let pool = windows.filter { $0.isTileable && (pid == nil || $0.pid == pid) }
        if let id, pool.contains(where: { $0.id == id }) { return id }
        return pool.first?.id
    }

    /// Apps with tileable windows on the display, front-most first.
    static func apps(on windows: [TrackedWindow]) -> [ScopeApp] {
        var seen = Set<pid_t>()
        return windows.filter { $0.isTileable && seen.insert($0.pid).inserted }
            .map { ScopeApp(pid: $0.pid, name: $0.appName, bundleID: $0.bundleID) }
    }

    /// The windows an arrangement takes: nil = every tileable window of the display (the
    /// backend's own pick), [] = none (window scope, or an app with no windows here).
    static func arrangeIDs(_ scope: WindowsScope, app: pid_t?, on windows: [TrackedWindow],
                           picked: [CGWindowID] = []) -> [CGWindowID]? {
        switch scope {
        case .screen: return nil
        case .window: return []
        case .selection:
            // Pick order, only the ones still on this display.
            let here = Set(windows.filter(\.isTileable).map(\.id))
            return picked.filter { here.contains($0) }
        case .app:
            guard let app else { return [] }
            return windows.filter { $0.isTileable && $0.pid == app }.map(\.id)
        }
    }

    /// The list: every tileable window of the display, front to back.
    static func list(_ windows: [TrackedWindow]) -> [TrackedWindow] {
        windows.filter(\.isTileable)
    }

    /// The windows Tab cycles through (front to back), limited to the app in app scope.
    static func candidates(_ scope: WindowsScope, app: pid_t?, on windows: [TrackedWindow]) -> [CGWindowID] {
        windows.filter { $0.isTileable && (scope != .app || app == nil || $0.pid == app) }.map(\.id)
    }

    static func cycle(from id: CGWindowID?, in ids: [CGWindowID], forward: Bool) -> CGWindowID? {
        guard !ids.isEmpty else { return nil }
        guard let id, let i = ids.firstIndex(of: id) else { return forward ? ids.first : ids.last }
        return ids[(i + (forward ? 1 : ids.count - 1)) % ids.count]
    }

    /// The window a click at a map point picks, or nil (the click places instead). With no target
    /// any window picks; with one, only another window's icon handle does, so hovering and
    /// clicking cells over windows keeps placing.
    static func pick(at p: CGPoint, windows: [TrackedWindow], projection: MapProjection, target: CGWindowID?) -> CGWindowID? {
        // (⌘-click and the selection scope pass target nil: any window body picks.)
        let screen = projection.displayRect
        for w in windows {                                   // front to back: the first hit is on top
            let r = projection.toMap(w.frame).intersection(screen)
            guard !r.isNull, r.width > 2, r.height > 2, r.contains(p) else { continue }
            if target == nil { return w.isTileable ? w.id : nil }
            guard w.id != target, w.isTileable else { return nil }
            return handle(of: r).contains(p) ? w.id : nil
        }
        return nil
    }

    /// The clickable icon area of a window drawn at `r` on the map (at least 22 pt, inside it).
    static func handle(of r: CGRect) -> CGRect {
        let side = min(max(22, min(18, r.height * 0.55, r.width * 0.5) + 8), r.width, r.height)
        return CGRect(x: r.midX - side / 2, y: r.midY - side / 2, width: side, height: side)
    }

    /// The display the panel opens on, as far as the module can tell before it is laid out: the
    /// notch under the pointer, else the built-in one (the surface's own fallback), else the
    /// pointer's display. The view's real frame corrects it once laid out.
    static func panelDisplay(pointer: CGPoint, displays: [Display]) -> Display? {
        let under = displays.first { $0.frame.contains(pointer) }
        if let under, under.isBuiltIn { return under }
        return displays.first(where: \.isBuiltIn) ?? under ?? displays.first
    }

    static func display(containing p: CGPoint, in displays: [Display]) -> Display? {
        displays.first { $0.frame.contains(p) }
    }
}
