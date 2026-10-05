// Windows — the tab. Left: the list of the display's windows, front to back — the way to choose
// exactly which ones (click = only it, ⌘-click = add in order, ⇧-click = a range). Middle: the
// live map of that display (real window rects, the grid, the target in the accent, the preview as
// numbered ghosts). Right: grid, scope + arrangement. Below both: status, Undo, Apply.
// Fits the page of the 640 × 210 panel.

import AppKit
import SwiftUI

struct WindowsTab: View {
    let model: WindowsModel

    var body: some View {
        if !model.trusted {
            PermissionPage()
        } else {
            HStack(alignment: .top, spacing: 12) {
                WindowList(model: model)
                    .frame(width: WindowsLayout.listWidth)
                if model.showDiagnostics {
                    DiagnosticsPane(model: model)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 12) {
                            MapPane(model: model)
                                .frame(width: WindowsLayout.mapWidth)
                            ControlPane(model: model)
                        }
                        .frame(height: WindowsLayout.topHeight)
                        Spacer(minLength: 0)
                        Footer(model: model)
                    }
                }
            }
            .background(ScreenRectReader { model.contentScreenRect = $0 })
        }
    }
}

enum WindowsLayout {
    static let listWidth: CGFloat = 196
    static let mapWidth: CGFloat = 150
    static let topHeight: CGFloat = 112
    static let rowHeight: CGFloat = 22
}

// MARK: - Window list

/// One row per tileable window of the shown display, front to back. Click = only this window;
/// ⌘-click = add / remove, numbered in pick order; ⇧-click = a range. Hover outlines the window
/// on the map and on the real screen.
private struct WindowList: View {
    let model: WindowsModel

    var body: some View {
        let rows = model.listWindows
        VStack(alignment: .leading, spacing: 4) {
            ListHeader(model: model)
                .frame(height: 18)
            if rows.isEmpty {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.card)
                    .overlay {
                        Text(verbatim: WindowsText.t("No windows on this display"))
                            .font(Theme.font(.xs)).foregroundStyle(Theme.tertiary)
                            .multilineTextAlignment(.center)
                            .padding(8)
                    }
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: rows.count > 5) {
                        VStack(spacing: 1) {
                            ForEach(rows) { w in
                                WindowRow(model: model, window: w).id(w.id)
                            }
                        }
                    }
                    .onChange(of: model.activeTargetID) { _, id in
                        // Tab in keyboard mode: keep the target's row in sight.
                        guard model.mode == .keyboard, let id else { return }
                        proxy.scrollTo(id)
                    }
                }
                .onHover { inside in if !inside { model.hoverRow(nil) } }
            }
        }
    }
}

private struct ListHeader: View {
    let model: WindowsModel

    var body: some View {
        HStack(spacing: 4) {
            if model.picks.count >= 2 {
                Text(verbatim: WindowsText.f("%d selected", model.picks.count).uppercased())
                    .font(.system(size: 10, weight: .semibold)).tracking(0.6)
                    .foregroundStyle(WindowsStyle.accent)
                    .lineLimit(1)
                Spacer(minLength: 2)
                IconButton(symbol: model.picks.count == 2 ? "arrow.left.arrow.right" : "arrow.triangle.2.circlepath",
                           help: model.picks.count == 2 ? WindowsText.t("Swap the order (S)") : WindowsText.t("Rotate the order (S)"),
                           on: true) { model.rotatePicks() }
                IconButton(symbol: "xmark", help: WindowsText.t("Clear the selection (Esc)"), on: false) { model.clearPicks() }
            } else {
                SectionLabel(text: WindowsText.t("Windows"))
                Spacer(minLength: 2)
                if model.displays.count > 1, let d = model.display {
                    DisplayPager(name: d.isBuiltIn ? WindowsText.t("Built-in") : d.name) { model.showDisplay(offset: $0) }
                }
            }
        }
    }
}

private struct WindowRow: View {
    let model: WindowsModel
    let window: TrackedWindow

    var body: some View {
        let number = model.number(window.id)
        let isTarget = window.id == model.activeTargetID
        let picked = number != nil
        let hover = model.rowHover == window.id || model.pickHover == window.id
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let quiet = !MapView.inScope(model)(window)
        Button {
            model.click(window.id, Self.click(NSEvent.modifierFlags))
        } label: {
            HStack(spacing: 6) {
                AppGlyph(bundleID: window.bundleID, name: window.appName, size: 15)
                    .opacity(quiet ? 0.55 : 1)
                (Text(verbatim: window.appName).font(Theme.font(.s, .semibold))
                    .foregroundStyle(quiet ? Theme.secondary : Theme.primary)
                 + Text(verbatim: window.title.isEmpty ? "" : "  " + window.title).font(Theme.font(.s))
                    .foregroundStyle(Theme.tertiary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let number {
                    OrderBadge(number: number, size: 15)
                } else if isTarget, model.picks.isEmpty {
                    Circle().fill(WindowsStyle.accent).frame(width: 5, height: 5).padding(.trailing, 5)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: WindowsLayout.rowHeight)
            .background(shape.fill(Self.fill(picked: picked, target: isTarget && model.picks.isEmpty, hover: hover)))
            .overlay(shape.strokeBorder(picked || (isTarget && model.picks.isEmpty) ? WindowsStyle.accent.opacity(0.55) : .clear,
                                        lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { model.hoverRow(window.id) } else if model.rowHover == window.id { model.hoverRow(nil) }
        }
        .help(WindowsText.t("Click: only this window · ⌘-click: add to the selection · ⇧-click: a range"))
    }

    static func click(_ flags: NSEvent.ModifierFlags) -> WindowsModel.Click {
        if flags.contains(.command) { return .toggle }
        if flags.contains(.shift) { return .extend }
        return .plain
    }

    static func fill(picked: Bool, target: Bool, hover: Bool) -> Color {
        if picked { return WindowsStyle.accent.opacity(hover ? 0.30 : 0.22) }
        if target { return WindowsStyle.accent.opacity(hover ? 0.20 : 0.12) }
        return Color.white.opacity(hover ? 0.12 : 0.035)
    }
}

/// The pick-order number: a filled accent disc.
struct OrderBadge: View {
    let number: Int
    var size: CGFloat = 14

    var body: some View {
        Text(verbatim: "\(number)")
            .font(.system(size: size * 0.62, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.black)
            .frame(width: size, height: size)
            .background(Circle().fill(WindowsStyle.accent))
    }
}

// MARK: - Map

private struct MapPane: View {
    let model: WindowsModel

    var body: some View {
        GeometryReader { geo in
            if let map = model.map {
                MapView(model: model, map: map, size: geo.size)
            } else {
                EmptyMap()
            }
        }
    }
}

private struct EmptyMap: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Theme.card)
            .overlay {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(Theme.tertiary)
            }
    }
}

struct MapView: View {
    let model: WindowsModel
    let map: ScreenMap
    let size: CGSize

    var body: some View {
        let d = map.display
        let proj = MapProjection(display: d.frame, usable: d.usableFrame, size: size)
        let screen = proj.displayRect
        let grid = model.grid
        let preview = model.preview
        let moving = Set(preview?.moves.map(\.windowID) ?? [])
        let targetID = model.activeTargetID
        let inScope = Self.inScope(model)
        ZStack(alignment: .topLeading) {
            // The display: a quiet slab with its menu bar and, on the built-in, its notch.
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                .frame(width: screen.width, height: screen.height)
                .offset(x: screen.minX, y: screen.minY)
            let bar = proj.toMap(CGRect(x: d.frame.minX, y: d.visibleFrame.maxY, width: d.frame.width, height: d.frame.maxY - d.visibleFrame.maxY))
            if bar.height > 0.5 {
                UnevenRoundedRectangle(topLeadingRadius: 7, topTrailingRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.07))
                    .frame(width: bar.width, height: max(2, bar.height))
                    .offset(x: bar.minX, y: bar.minY)
            }
            if d.isBuiltIn {
                UnevenRoundedRectangle(bottomLeadingRadius: 3, bottomTrailingRadius: 3, style: .continuous)
                    .fill(Color.black)
                    .frame(width: screen.width * 0.12, height: max(3, bar.height))
                    .offset(x: screen.midX - screen.width * 0.06, y: screen.minY)
            }

            // The grid: faint cells, so the eye reads it as slots.
            ForEach(Array(proj.cells(of: grid).enumerated()), id: \.offset) { _, item in
                let r = item.1
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.white.opacity(0.035))
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
            }

            // Real windows, back to front, at their real frames (never snapped).
            ForEach(map.windows.reversed()) { w in
                let r = proj.toMap(w.frame).intersection(screen)
                if !r.isNull, r.width > 2, r.height > 2 {
                    MapWindow(window: w, rect: r, isTarget: w.id == targetID,
                              dimmed: moving.contains(w.id), outOfScope: !inScope(w),
                              picking: w.id == model.pickHover || w.id == model.rowHover,
                              number: model.number(w.id),
                              badge: model.outcome?.badges[w.id])
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                }
            }

            // The keyboard cursor / pointer cells.
            if let cell = model.hoverCell ?? model.selection?.rect {
                let r = proj.toMap(Geometry.frame(for: cell, in: grid, on: d.usableFrame))
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(WindowsStyle.accent, lineWidth: 1.5)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(WindowsStyle.accent.opacity(preview == nil ? 0.22 : 0.08)))
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
            }

            // What a commit would do.
            if let preview {
                let numbers = model.previewNumbers
                ForEach(Array(preview.moves.enumerated()), id: \.element.windowID) { i, m in
                    let r = proj.toMap(m.to)
                    Ghost(window: model.backend.window(m.windowID), secondary: preview.kind == .swap && i > 0,
                          number: numbers[m.windowID])
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                }
            }

            // The list row under the pointer: that window's outline, on top even when it is behind others.
            if let id = model.rowHover, let w = map.windows.first(where: { $0.id == id }) {
                let r = proj.toMap(w.frame).intersection(screen)
                if !r.isNull {
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .strokeBorder(WindowsStyle.accent, lineWidth: 1.5)
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .animation(Theme.peek, value: preview)
        .animation(Theme.peek, value: model.hoverCell)
        .animation(Theme.peek, value: model.selection)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case let .active(p):
                model.hover(proj.cell(at: p, grid: grid),
                            pick: ScopeRules.pick(at: p, windows: map.windows, projection: proj, target: Self.pickTarget(model)))
            case .ended: model.hover(nil)
            }
        }
        .gesture(
            // A click on a window's icon (on any window, with no target) picks it; a click
            // elsewhere places the target; a drag sweeps cells.
            // ⌘ / ⇧ (or the selection scope): a click anywhere on a window picks it.
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let how = WindowRow.click(NSEvent.modifierFlags)
                    let pick = ScopeRules.pick(at: v.startLocation, windows: map.windows, projection: proj,
                                               target: Self.pickTarget(model, how))
                    if pick != nil, Self.isClick(v) { return }
                    guard how == .plain, let a = proj.cell(at: v.startLocation, grid: grid) else { return }
                    let b = proj.cell(at: v.location, grid: grid) ?? a
                    model.sweep(from: a, to: b)
                }
                .onEnded { v in
                    let how = WindowRow.click(NSEvent.modifierFlags)
                    if Self.isClick(v),
                       let pick = ScopeRules.pick(at: v.startLocation, windows: map.windows, projection: proj,
                                                  target: Self.pickTarget(model, how)) {
                        model.click(pick, how)
                    } else {
                        model.endSweep()
                    }
                }
        )
        .background(ScreenRectReader { model.mapScreenRect = $0 })
    }
}

extension MapView {
    static func isClick(_ v: DragGesture.Value) -> Bool {
        abs(v.translation.width) < 4 && abs(v.translation.height) < 4
    }

    /// The target the map's hit test protects (its body places): none with ⌘ / ⇧ held or while
    /// a selection is arranged, so any window body picks.
    static func pickTarget(_ model: WindowsModel, _ how: WindowsModel.Click = .plain) -> CGWindowID? {
        how != .plain || model.scope == .selection ? nil : model.activeTargetID
    }

    /// Whether a window belongs to what the tab acts on (others are drawn faded).
    static func inScope(_ model: WindowsModel) -> (TrackedWindow) -> Bool {
        let target = model.activeTargetID
        switch model.scope {
        case .screen: return { _ in true }
        case .app: let app = model.scopeApp; return { $0.pid == app }
        case .window: return { $0.id == target }
        case .selection: let picks = model.picks; return { picks.contains($0.id) }
        }
    }
}

private struct MapWindow: View {
    let window: TrackedWindow
    let rect: CGRect
    let isTarget: Bool
    let dimmed: Bool
    var outOfScope = false
    /// A click here would pick this window (or its list row is hovered): ring it.
    var picking = false
    /// Pick order, when picked.
    var number: Int?
    let badge: PlacementOutcome?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 3.5, style: .continuous)
        let stroke: Color = isTarget || picking ? WindowsStyle.accent : Color.white.opacity(0.20)
        ZStack {
            shape.fill(isTarget ? Color(red: 0.13, green: 0.20, blue: 0.33) : Color(white: picking ? 0.22 : 0.16))
            shape.strokeBorder(stroke.opacity(picking && !isTarget ? 0.75 : 1), lineWidth: isTarget || picking ? 1.5 : 0.75)
            if !dimmed {
                AppGlyph(bundleID: window.bundleID, name: window.appName, size: min(18, rect.height * 0.55, rect.width * 0.5))
                    .opacity(isTarget || picking ? 1 : 0.85)
                    .scaleEffect(picking ? 1.12 : 1)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let badge { OutcomeBadge(outcome: badge).offset(x: 4, y: -4) }
        }
        .overlay(alignment: .topLeading) {
            if let number, !dimmed, rect.width > 14, rect.height > 14 { OrderBadge(number: number, size: 12).offset(x: 2, y: 2) }
        }
        .opacity(dimmed ? 0.28 : outOfScope ? 0.35 : 1)
        .help("\(window.appName) — \(window.title)")
    }
}

private struct Ghost: View {
    let window: TrackedWindow?
    let secondary: Bool
    /// The selection's pick order: which cell #1, #2… take.
    var number: Int?

    var body: some View {
        let tint = secondary ? WindowsStyle.swap : WindowsStyle.accent
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        GeometryReader { geo in
            ZStack {
                shape.fill(tint.opacity(0.20))
                shape.strokeBorder(tint, style: StrokeStyle(lineWidth: 1.25, dash: secondary ? [3, 2] : []))
                if let window {
                    AppGlyph(bundleID: window.bundleID, name: window.appName,
                             size: min(18, geo.size.height * 0.55, geo.size.width * 0.5))
                }
            }
            .overlay(alignment: .topLeading) {
                if let number, geo.size.width > 18, geo.size.height > 18 {
                    OrderBadge(number: number, size: min(16, geo.size.height * 0.4)).offset(x: 3, y: 3)
                }
            }
        }
    }
}

/// An app's icon, or its initial in a soft circle when there is no icon.
struct AppGlyph: View {
    let bundleID: String?
    let name: String
    let size: CGFloat

    var body: some View {
        if size >= 7 {
            if let icon = AppIcons.icon(bundleID) {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size)
            } else {
                Text(verbatim: String(name.prefix(1)))
                    .font(.system(size: max(7, size * 0.55), weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: size, height: size)
                    .background(Circle().fill(Color.white.opacity(0.10)))
            }
        }
    }
}

private struct OutcomeBadge: View {
    let outcome: PlacementOutcome

    var body: some View {
        let (symbol, color): (String, Color) = switch outcome {
        case .exact: ("checkmark", Theme.done)
        case .appSized: ("arrow.down.right.and.arrow.up.left", Theme.waiting)
        case .refused: ("xmark", Theme.failed)
        case .unreachable, .cancelled: ("questionmark", Theme.tertiary)
        }
        Image(systemName: symbol)
            .font(.system(size: 7, weight: .heavy))
            .foregroundStyle(.black)
            .frame(width: 13, height: 13)
            .background(Circle().fill(color))
            .overlay(Circle().strokeBorder(Color.black, lineWidth: 1.5))
    }
}

private struct DisplayPager: View {
    let name: String
    let step: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            PagerArrow(symbol: "chevron.left", help: WindowsText.t("Previous display")) { step(-1) }
            Text(verbatim: name)
                .font(Theme.font(.xs, .medium))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .frame(maxWidth: 70)
            PagerArrow(symbol: "chevron.right", help: WindowsText.t("Next display")) { step(1) }
        }
        .fixedSize()
    }
}

private struct PagerArrow: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(hover ? Theme.primary : Theme.secondary)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.white.opacity(hover ? 0.12 : 0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

// MARK: - Controls

private struct ControlPane: View {
    let model: WindowsModel

    /// 1×2 is here for "these two, stacked" (2×1 = side by side).
    static let presets: [(Int, Int)] = [(2, 1), (1, 2), (3, 1), (2, 2), (3, 2), (4, 2)]

    var body: some View {
        let g = model.grid
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                SectionLabel(text: WindowsText.t("Grid"))
                Spacer(minLength: 2)
                MiniStepper(value: g.cols, label: WindowsText.t("columns")) { model.adjustGrid(cols: $0) }
                Text(verbatim: "×").font(Theme.font(.xs)).foregroundStyle(Theme.tertiary)
                MiniStepper(value: g.rows, label: WindowsText.t("rows")) { model.adjustGrid(rows: $0) }
                IconButton(symbol: "stethoscope", help: WindowsText.t("Diagnostics"), on: false) {
                    model.showDiagnostics = true
                }
            }
            HStack(spacing: 3) {
                ForEach(Self.presets.indices, id: \.self) { i in
                    let (c, r) = Self.presets[i]
                    Chip(text: "\(c)×\(r)", selected: g.cols == c && g.rows == r, mono: true) {
                        model.choosePreset(GridSpec(cols: c, rows: r, outerGap: g.outerGap, innerGap: g.innerGap))
                    }
                    .help(model.scope == .selection ? WindowsText.t("Arrange the selected windows in this grid")
                          : WindowsText.f("%d×%d grid", c, r))
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    SectionLabel(text: WindowsText.t("Arrange"))
                    Spacer(minLength: 2)
                    ScopePicker(model: model)
                }
                HStack(spacing: 0) {
                    ScopePicker(model: model)
                    Spacer(minLength: 0)
                }
            }
            ViewThatFits(in: .horizontal) {
                StrategyChips(model: model, labelSelected: true)
                StrategyChips(model: model, labelSelected: false)
            }
            .opacity(model.canArrange ? 1 : 0.35)
            .disabled(!model.canArrange)
            Spacer(minLength: 0)
        }
    }
}

/// One chip per strategy, as icons; the chosen one also shows its name.
private struct StrategyChips: View {
    let model: WindowsModel
    let labelSelected: Bool

    var body: some View {
        HStack(spacing: 3) {
            ForEach(ArrangeStrategy.allCases, id: \.self) { s in
                let on = model.strategy == s
                Chip(text: on && labelSelected ? WindowsText.strategy(s) : "", selected: on, symbol: Self.symbol(s)) { model.choose(s) }
                    .help(WindowsText.strategy(s))
                    .accessibilityLabel(WindowsText.strategy(s))
            }
        }
        .fixedSize()
    }

    static func symbol(_ s: ArrangeStrategy) -> String {
        switch s {
        case .balanced: "square.grid.2x2"
        case .cells: "square.grid.3x2"
        case .columns: "rectangle.split.3x1"
        case .rows: "rectangle.split.1x2"
        case .masterStack: "rectangle.leadingthird.inset.filled"
        }
    }
}

private struct Footer: View {
    let model: WindowsModel

    var body: some View {
        HStack(spacing: 6) {
            status
                .font(Theme.font(.xs))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if model.canUndo {
                WindowsPillButton(text: WindowsText.t("Undo"), symbol: "arrow.uturn.backward", prominent: false, enabled: !model.busy) {
                    model.undo()
                }
                .help("⌘Z")
                .transition(.opacity)
            }
            if model.arrangementPreview != nil {
                WindowsPillButton(text: WindowsText.t("Apply"), symbol: "checkmark", prominent: true, enabled: !model.busy) { model.apply() }
                    .help("⏎")
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .frame(height: 22)
        .animation(Theme.peek, value: model.canUndo)
        .animation(Theme.peek, value: model.arrangementPreview != nil)
    }

    @ViewBuilder private var status: some View {
        if let o = model.outcome {
            Text(verbatim: o.line).foregroundStyle(o.allExact ? Theme.secondary : Theme.waiting).help(o.line)
        } else if model.dragWindowID != nil {
            if let partner = model.swapPartner {
                Text(verbatim: WindowsText.f("Swap with %@", model.name(partner))).foregroundStyle(WindowsStyle.swap)
            } else {
                Text(verbatim: WindowsText.t("Drop on a cell · on a window to swap · Esc cancels")).foregroundStyle(Theme.tertiary)
            }
        } else if let p = model.arrangementPreview {
            let n = p.moves.count == 1 ? WindowsText.t("1 window") : WindowsText.f("%d windows", p.moves.count)
            let head = model.strategy.map { WindowsText.strategy($0) + " · " } ?? ""
            let order = model.scope == .selection ? " · " + WindowsText.t("in pick order") : ""
            Text(verbatim: head + (p.untouched.isEmpty ? n : n + " · " + WindowsText.f("%d left as they are", p.untouched.count)) + order)
                .foregroundStyle(Theme.secondary).monospacedDigit()
        } else if model.scope == .selection {
            Text(verbatim: WindowsText.f("%d selected · pick a grid or an arrangement", model.picks.count))
                .foregroundStyle(WindowsStyle.accent)
        } else if model.needsPick {
            Text(verbatim: model.mode == .keyboard ? WindowsText.t("Tab picks a window · or click one in the list")
                 : WindowsText.t("Pick a window in the list to place it")).foregroundStyle(Theme.waiting)
        } else if let id = model.pickHover {
            Text(verbatim: WindowsText.f("Click to pick %@", model.name(id))).foregroundStyle(Theme.secondary)
        } else if model.mode == .keyboard || model.selection != nil {
            Text(verbatim: model.canArrange ? WindowsText.t("←→↑↓ select · ⏎ place · ⇥ window · Space pick · A arrange")
                 : WindowsText.t("←→↑↓ select · ⏎ place · ⇥ window · Space pick")).foregroundStyle(Theme.tertiary)
        } else if !model.picks.isEmpty {
            Text(verbatim: WindowsText.t("⌘-click another window to pick it too")).foregroundStyle(Theme.tertiary)
        } else {
            Text(verbatim: WindowsText.t("Hover a cell, click to place · ⌘-click windows to pick several")).foregroundStyle(Theme.tertiary)
        }
    }
}

// MARK: - Scope

/// Screen · App · Window (· N selected), as one capsule. Only the chosen segment shows its name;
/// the others are icons (help says what they are). The app segment shows the app; a second click
/// moves on to the next app with windows on this display. "N selected" appears only while two or
/// more windows are picked.
private struct ScopePicker: View {
    let model: WindowsModel

    var body: some View {
        HStack(spacing: 1) {
            Segment(selected: model.scope == .screen, help: WindowsText.t("Every window on this display")) {
                model.setScope(.screen)
            } label: {
                Image(systemName: "display").font(.system(size: 9, weight: .medium))
                if model.scope == .screen { Text(verbatim: WindowsText.t("Screen")) }
            }
            Segment(selected: model.scope == .app,
                    help: model.scope == .app && model.scopeApps.count > 1 ? WindowsText.t("Click again for the next app")
                        : WindowsText.t("Only one app's windows on this display"),
                    enabled: !model.scopeApps.isEmpty) {
                model.setScope(.app)
            } label: {
                if model.scope == .app, let app = model.currentScopeApp {
                    AppGlyph(bundleID: app.bundleID, name: app.name, size: 12)
                    Text(verbatim: app.name).lineLimit(1).frame(maxWidth: 60)
                    if model.scopeApps.count > 1 {
                        Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold)).foregroundStyle(Theme.tertiary)
                    }
                } else {
                    Image(systemName: "app").font(.system(size: 9, weight: .medium))
                }
            }
            Segment(selected: model.scope == .window, help: WindowsText.t("One window: place it, no arranging")) {
                model.setScope(.window)
            } label: {
                Image(systemName: "macwindow").font(.system(size: 9, weight: .medium))
                if model.scope == .window { Text(verbatim: WindowsText.t("Window")) }
            }
            if model.picks.count >= 2 {
                Segment(selected: model.scope == .selection, help: WindowsText.t("Only the windows picked in the list, in pick order")) {
                    model.setScope(.selection)
                } label: {
                    Image(systemName: "checklist").font(.system(size: 9, weight: .medium))
                    Text(verbatim: WindowsText.f("%d selected", model.picks.count))
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .padding(1.5)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .fixedSize()
        .animation(Theme.peek, value: model.picks.count >= 2)
    }
}

private struct Segment<Label: View>: View {
    let selected: Bool
    let help: String
    var enabled = true
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) { label() }
                .font(Theme.font(.xs, selected ? .semibold : .medium))
                .foregroundStyle(!enabled ? Theme.tertiary : selected || hover ? Theme.primary : Theme.secondary)
                .padding(.horizontal, 6)
                .frame(minWidth: 22)
                .frame(height: 18)
                .background(Capsule().fill(selected ? WindowsStyle.accent.opacity(0.30) : Color.white.opacity(hover ? 0.08 : 0)))
                .overlay(Capsule().strokeBorder(selected ? WindowsStyle.accent.opacity(0.7) : .clear, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hover = $0 }
        .help(help)
    }
}

// MARK: - Diagnostics

private struct DiagnosticsPane: View {
    let model: WindowsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                SectionLabel(text: WindowsText.t("Diagnostics"))
                Spacer(minLength: 4)
                IconButton(symbol: "xmark", help: WindowsText.t("Done"), on: false) { model.showDiagnostics = false }
            }
            HStack(spacing: 6) {
                WindowsPillButton(text: WindowsText.t("Run probe"), symbol: "waveform.path.ecg", prominent: false, enabled: !model.probeRunning) {
                    model.runProbe(move: false)
                }
                .help(WindowsText.t("Read-only: logs Accessibility state for Mail, Chrome and Terminal."))
                WindowsPillButton(text: WindowsText.t("Test placement"), symbol: "exclamationmark.triangle", prominent: false,
                           enabled: !model.probeRunning, tint: Theme.waiting) {
                    model.runProbe(move: true)
                }
                .help(WindowsText.t("Moves the front window of Mail, Chrome and Terminal, then puts it back."))
                if model.probeRunning {
                    Text(verbatim: WindowsText.t("Running…")).font(Theme.font(.xs)).foregroundStyle(Theme.tertiary)
                }
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    if !model.failedHotkeys.isEmpty {
                        Text(verbatim: WindowsText.f("Hotkeys not registered: %@", model.failedHotkeys.joined(separator: " ")))
                            .foregroundStyle(Theme.waiting)
                    }
                    ForEach(Array(model.probeLines.enumerated()), id: \.offset) { _, line in
                        Text(verbatim: line).foregroundStyle(Theme.secondary)
                    }
                    if model.probeLines.isEmpty, model.failedHotkeys.isEmpty {
                        Text(verbatim: WindowsText.t("Read-only: logs Accessibility state for Mail, Chrome and Terminal."))
                            .foregroundStyle(Theme.tertiary)
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.card))
        }
    }
}

// MARK: - Permission

private struct PermissionPage: View {
    var body: some View {
        HStack(spacing: 18) {
            // A quiet picture of what is waiting behind the permission.
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                Grid(horizontalSpacing: 5, verticalSpacing: 5) {
                    ForEach(0..<2, id: \.self) { _ in
                        GridRow {
                            ForEach(0..<3, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color.white.opacity(0.05))
                            }
                        }
                    }
                }
                .padding(8)
                Image(systemName: "lock.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.black.opacity(0.85)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            }
            .frame(width: 168, height: 110)

            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: WindowsText.t("Windows needs Accessibility"))
                    .font(Theme.font(.xl, .semibold))
                    .foregroundStyle(Theme.primary)
                Text(verbatim: WindowsText.t("Glancy moves and resizes your windows through Accessibility. Nothing leaves this Mac."))
                    .font(Theme.font(.m))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    WindowsPillButton(text: WindowsText.t("Allow…"), symbol: "hand.raised", prominent: true, enabled: true) {
                        Permission.prompt()
                    }
                    WindowsPillButton(text: WindowsText.t("Open Settings"), symbol: nil, prominent: false, enabled: true) {
                        Permission.openSettings()
                    }
                }
                .padding(.top, 2)
                Text(verbatim: WindowsText.t("The map appears as soon as access is granted."))
                    .font(Theme.font(.xs))
                    .foregroundStyle(Theme.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
enum Permission {
    static func prompt() {
        let key = "AXTrustedCheckOptionPrompt" as CFString   // kAXTrustedCheckOptionPrompt
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        openSettings()
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Small controls

private struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(verbatim: text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Theme.tertiary)
    }
}

private struct Chip: View {
    let text: String
    let selected: Bool
    var mono = false
    var symbol: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 10, weight: .medium))
                }
                if !text.isEmpty {
                    Text(verbatim: text)
                        .font(Theme.font(.s, selected ? .semibold : .medium))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(selected ? Theme.primary : hover ? Theme.primary : Theme.secondary)
            .padding(.horizontal, mono ? 6 : text.isEmpty ? 7 : 8)
            .frame(height: 21)
            .background(Capsule().fill(selected ? WindowsStyle.accent.opacity(0.28) : Color.white.opacity(hover ? 0.11 : 0.06)))
            .overlay(Capsule().strokeBorder(selected ? WindowsStyle.accent.opacity(0.7) : .clear, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .fixedSize()
    }
}

private struct MiniStepper: View {
    let value: Int
    let label: String
    let step: (Int) -> Void

    var body: some View {
        HStack(spacing: 1) {
            StepButton(symbol: "minus") { step(-1) }
            Text(verbatim: "\(value)")
                .font(Theme.font(.s, .semibold)).monospacedDigit()
                .foregroundStyle(Theme.primary)
                .frame(minWidth: 14)
            StepButton(symbol: "plus") { step(1) }
        }
        .padding(.horizontal, 2)
        .frame(height: 19)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct StepButton: View {
    let symbol: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(hover ? Theme.primary : Theme.secondary)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.white.opacity(hover ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    let on: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(hover || on ? Theme.primary : Theme.tertiary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.white.opacity(hover ? 0.10 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

struct WindowsPillButton: View {
    let text: String
    let symbol: String?
    let prominent: Bool
    let enabled: Bool
    var tint: Color? = nil
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)) }
                Text(verbatim: text).font(Theme.font(.s, .semibold))
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(Capsule().fill(background))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hover = $0 }
        .fixedSize()
    }

    private var foreground: Color {
        if !enabled { return Theme.tertiary }
        if prominent { return .black }
        return tint ?? (hover ? Theme.primary : Theme.secondary)
    }

    private var background: Color {
        if !enabled { return Color.white.opacity(0.05) }
        if prominent { return hover ? WindowsStyle.accent.opacity(0.85) : WindowsStyle.accent }
        return Color.white.opacity(hover ? 0.12 : 0.07)
    }
}

// MARK: - Screen rect reporting

/// Reports the view's frame in Cocoa screen coordinates whenever it is laid out (drag mode maps
/// the global pointer onto the map with it). Zero cost otherwise.
struct ScreenRectReader: NSViewRepresentable {
    let onChange: @MainActor (CGRect) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let v = ReaderView()
        v.onChange = onChange
        return v
    }

    func updateNSView(_ v: ReaderView, context: Context) {
        v.onChange = onChange
        v.report()
    }

    final class ReaderView: NSView {
        var onChange: (@MainActor (CGRect) -> Void)?
        private var last: CGRect?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() { super.layout(); report() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); report() }

        func report() {
            guard let window else { return }
            let r = window.convertToScreen(convert(bounds, to: nil))
            guard r != last else { return }
            last = r
            onChange?(r)
        }
    }
}
