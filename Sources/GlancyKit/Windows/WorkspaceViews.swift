// Windows — the workspaces pane (header button "Workspaces" swaps it in for the layout
// thumbnails, so the main flow stays as it is): one card per saved workspace (click = restore,
// hover = its windows on the real screen, right-click = rename / on connect / delete), a status
// line, and "Save current arrangement" with an editable name. Plus the Settings block (hotkey per
// workspace, apply on connect, restore, delete). Fits the 640 × 210 panel.

import AppKit
import SwiftUI

/// The header pill that opens the pane: "Workspaces", or its count when space is short.
struct WorkspacesButton: View {
    let model: WindowsModel
    /// Icon and count only (a crowded header).
    var compact = false
    @State private var hover = false

    var body: some View {
        let on = model.showWorkspaces
        let count = model.workspaces.workspaces.count
        Button { model.setWorkspaces(!on) } label: {
            label(text: compact ? nil : WindowsText.t("Workspaces"), count: count)
            .foregroundStyle(on ? Theme.primary : hover ? Theme.primary : Theme.secondary)
            .padding(.horizontal, 8)
            .frame(height: 18)
            .background(Capsule().fill(on ? WindowsStyle.accent.opacity(0.28) : Color.white.opacity(hover ? 0.12 : 0.06)))
            .overlay(Capsule().strokeBorder(on ? WindowsStyle.accent.opacity(0.7) : .clear, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(WindowsText.t("Saved workspaces: every display's windows, back in one click"))
        .accessibilityLabel(WindowsText.t("Workspaces"))
        .fixedSize()
    }

    private func label(text: String?, count: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 9, weight: .semibold))
            if let text { Text(verbatim: text).font(Theme.font(.xs, .semibold)) }
            if count > 0 {
                Text(verbatim: "\(count)").font(Theme.font(.xs, .semibold)).monospacedDigit()
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .fixedSize()
    }
}

/// "Workspaces · 2 saved", the cards, then the status line with Save.
struct WorkspacesPane: View {
    let model: WindowsModel

    var body: some View {
        let list = model.workspaces.workspaces
        VStack(alignment: .leading, spacing: 0) {
            WorkspacesHeader(model: model)
            if list.isEmpty {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.card)
                    .overlay {
                        VStack(spacing: 3) {
                            Text(verbatim: WindowsText.t("No workspaces yet"))
                                .font(Theme.font(.s, .semibold)).foregroundStyle(Theme.secondary)
                            Text(verbatim: WindowsText.t("Save how your windows sit now, on every display, and bring it back in one click"))
                                .font(Theme.font(.xs)).foregroundStyle(Theme.tertiary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 12)
                    }
                    .frame(height: WorkspaceLayout.cardHeight)
                    .padding(.top, 6)
            } else {
                ScrollView(.horizontal, showsIndicators: list.count > 3) {
                    HStack(spacing: 6) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, w in
                            WorkspaceCard(model: model, workspace: w, number: i + 1)
                        }
                    }
                }
                .frame(height: WorkspaceLayout.cardHeight)
                .padding(.top, 6)
                .onHover { inside in if !inside { model.hoverWorkspace(nil) } }
            }
            Spacer(minLength: 6)
            WorkspaceFooter(model: model)
        }
    }
}

enum WorkspaceLayout {
    static let cardWidth: CGFloat = 124
    static let cardHeight: CGFloat = 96
}

private struct WorkspacesHeader: View {
    let model: WindowsModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(label: WindowsText.t("Saved arrangements"), compact: false)
            row(label: WindowsText.t("Saved arrangements"), compact: true)
            row(label: WindowsText.t("Saved"), compact: true)
        }
        .frame(height: 18)
    }

    private func row(label: String, compact: Bool) -> some View {
        HStack(spacing: 6) {
            SectionLabel(text: label)
                .lineLimit(1)
            Spacer(minLength: 4)
            if model.canUndo {
                TextLink(text: "↶ " + WindowsText.t("Undo"), help: WindowsText.t("Undo the last change") + " (⌘Z)") { model.undo() }
                    .disabled(model.busy)
            }
            IconButton(symbol: "questionmark", help: WindowsText.t("Shortcuts"), on: false) { model.toggleHelp() }
            WorkspacesButton(model: model, compact: compact)
            MoreButton(model: model)
        }
    }
}

/// One saved workspace: its displays and windows drawn small, its name, what it holds.
private struct WorkspaceCard: View {
    let model: WindowsModel
    let workspace: Workspace
    let number: Int
    @State private var hover = false

    var body: some View {
        let restoring = model.restoringWorkspace == workspace.id
        let lit = hover || restoring || model.workspaceHover == workspace.id
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Button { model.restoreFromTab(workspace.id) } label: {
            VStack(alignment: .leading, spacing: 3) {
                ZStack(alignment: .topLeading) {
                    MiniWorkspace(workspace: workspace, highlighted: lit)
                        .frame(height: 48)
                    if number <= 9 {
                        Text(verbatim: "\(number)")
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .foregroundStyle(lit ? Color.black : Theme.secondary)
                            .frame(width: 13, height: 13)
                            .background(Circle().fill(lit ? WindowsStyle.accent : Color.white.opacity(0.12)))
                            .offset(x: -3, y: -3)
                    }
                }
                HStack(spacing: 4) {
                    Text(verbatim: workspace.name)
                        .font(Theme.font(.s, .semibold))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                    if workspace.applyOnConnect {
                        Image(systemName: "display.2").font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(WindowsStyle.accent)
                            .help(WindowsText.t("Applied when this display setup connects"))
                    }
                }
                Text(verbatim: restoring ? WindowsText.t("Restoring…") : Self.detail(workspace))
                    .font(Theme.font(.xs))
                    .foregroundStyle(restoring ? WindowsStyle.accent : Theme.tertiary)
                    .lineLimit(1)
                    .monospacedDigit()
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .frame(width: WorkspaceLayout.cardWidth, height: WorkspaceLayout.cardHeight, alignment: .topLeading)
            .background(shape.fill(lit ? WindowsStyle.accent.opacity(0.14) : Color.white.opacity(0.05)))
            .overlay(shape.strokeBorder(lit ? WindowsStyle.accent.opacity(0.7) : .clear, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(model.busy)
        .onHover { inside in
            hover = inside
            if inside { model.hoverWorkspace(workspace.id) } else if model.workspaceHover == workspace.id { model.hoverWorkspace(nil) }
        }
        .help(WindowsText.f("Restore %@", workspace.name) + (number <= 9 ? " (\(number))" : ""))
        .contextMenu {
            Button(WindowsText.t("Restore")) { model.restoreFromTab(workspace.id) }
            Button(WindowsText.t("Rename…")) { model.beginRename(workspace.id) }
            Toggle(WindowsText.t("Apply when this display setup connects"), isOn: Binding(
                get: { workspace.applyOnConnect },
                set: { on in model.workspaces.update(workspace.id) { $0.applyOnConnect = on } }))
            Divider()
            Button(WindowsText.t("Delete"), role: .destructive) { model.deleteWorkspace(workspace.id) }
        }
    }

    /// The displays are drawn above: windows and the hotkey only.
    @MainActor static func detail(_ w: Workspace) -> String {
        var parts = [w.windows.count == 1 ? WindowsText.t("1 window") : WindowsText.f("%d windows", w.windows.count)]
        if w.hotkey.modifiers != 0 { parts.append(w.hotkey.description) }
        return parts.joined(separator: " · ")
    }
}

/// The displays a workspace uses, side by side at their real proportions, with its windows.
struct MiniWorkspace: View {
    let workspace: Workspace
    let highlighted: Bool

    var body: some View {
        GeometryReader { geo in
            let used = Array(Set(workspace.windows.map(\.display))).sorted()
                .filter { workspace.displays.indices.contains($0) }
            let screens = used.map { workspace.displays[$0] }
            let gap: CGFloat = 4
            let totalW = screens.reduce(0) { $0 + CGFloat($1.width) }
            let maxH = screens.map { CGFloat($0.height) }.max() ?? 1
            let scale = screens.isEmpty ? 0 : min((geo.size.width - gap * CGFloat(screens.count - 1)) / max(1, totalW),
                                                  geo.size.height / max(1, maxH))
            let drawnW = totalW * scale + gap * CGFloat(max(0, screens.count - 1))
            ZStack(alignment: .topLeading) {
                ForEach(Array(zip(used.indices, used)), id: \.1) { k, index in
                    let s = workspace.displays[index]
                    let x0 = (geo.size.width - drawnW) / 2
                        + used.prefix(k).reduce(0) { $0 + CGFloat(workspace.displays[$1].width) * scale + gap }
                    let w = CGFloat(s.width) * scale, h = CGFloat(s.height) * scale
                    let y0 = (geo.size.height - h) / 2
                    let frame = CGRect(x: x0, y: y0, width: w, height: h)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
                        .frame(width: max(1, w), height: max(1, h))
                        .offset(x: x0, y: y0)
                    // Back to front, so the front window is drawn last.
                    ForEach(workspace.windows.filter { $0.display == index }.sorted { $0.order > $1.order }, id: \.self) { win in
                        let r = CGRect(x: frame.minX + 1.5 + CGFloat(win.frame.x) * (w - 3), y: frame.minY + 1.5 + CGFloat(win.frame.y) * (h - 3),
                                       width: max(2, CGFloat(win.frame.w) * (w - 3)), height: max(2, CGFloat(win.frame.h) * (h - 3)))
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(highlighted ? WindowsStyle.accent.opacity(0.42) : Color(white: 0.28))
                            .overlay(RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                .strokeBorder(Color.black.opacity(0.45), lineWidth: 0.5))
                            .overlay {
                                let g = min(r.width, r.height) - 3
                                if g >= 7 { AppGlyph(bundleID: win.bundleID, name: win.appName, size: min(10, g)) }
                            }
                            .frame(width: r.width, height: r.height)
                            .offset(x: r.minX, y: r.minY)
                    }
                }
            }
        }
    }
}

/// The name field while saving / renaming; otherwise the last outcome (or a hint) and Save.
private struct WorkspaceFooter: View {
    let model: WindowsModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let text = model.naming {
                Image(systemName: model.renaming == nil ? "square.and.arrow.down" : "pencil")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(WindowsStyle.accent)
                TextField("", text: Binding(get: { text }, set: { model.naming = String($0.prefix(40)) }),
                          prompt: Text(WindowsText.t("Name")).foregroundColor(Theme.tertiary))
                    .textFieldStyle(.plain)
                    .font(Theme.font(.m, .medium))
                    .foregroundStyle(Theme.primary)
                    .focused($focused)
                    .onSubmit { model.confirmNaming() }
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(WindowsStyle.accent.opacity(0.6), lineWidth: 1))
                    .onAppear { focused = true }
                TextLink(text: WindowsText.t("Cancel"), help: "Esc") { model.cancelNaming() }
                WindowsPillButton(text: model.renaming == nil ? WindowsText.t("Save") : WindowsText.t("Rename"), symbol: nil,
                                  prominent: true, enabled: true) { model.confirmNaming() }
                    .help("⏎")
            } else {
                status
                    .font(Theme.font(.xs))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                WindowsPillButton(text: WindowsText.t("Save current"), symbol: "plus",
                                  prominent: model.workspaces.workspaces.isEmpty, enabled: !model.busy) { model.beginSave() }
                    .help(WindowsText.t("Save every window on every display as a workspace"))
            }
        }
        .frame(height: 28)
    }

    @ViewBuilder private var status: some View {
        switch model.workspaceStatus {
        case let .saved(name, windows, displays)?:
            Text(verbatim: WindowsText.f("Saved %@", name) + " · "
                 + (windows == 1 ? WindowsText.t("1 window") : WindowsText.f("%d windows", windows))
                 + (displays > 1 ? " · " + WindowsText.f("%d displays", displays) : ""))
                .foregroundStyle(Theme.done)
        case let .launching(name, apps)?:
            Text(verbatim: name + " · " + WindowsText.f("Opening %@…", ListFormatter.localizedString(byJoining: apps)))
                .foregroundStyle(WindowsStyle.accent)
        case let .restored(o)?:
            Text(verbatim: o.name + " · " + o.line).foregroundStyle(o.clean ? Theme.secondary : Theme.waiting).monospacedDigit()
        case let .deleted(name)?:
            Text(verbatim: WindowsText.f("Deleted %@", name)).foregroundStyle(Theme.tertiary)
        case nil:
            if model.workspaces.workspaces.isEmpty {
                Text(verbatim: WindowsText.t("Missing apps open when you restore")).foregroundStyle(Theme.tertiary)
            } else {
                Text(verbatim: WindowsText.t("Click to restore · hover to preview · right-click for more")).foregroundStyle(Theme.tertiary)
            }
        }
    }
}

// MARK: - Settings

/// Settings → Windows → Workspaces: per workspace a hotkey (none by default), restore, delete,
/// and "apply when this display setup connects".
struct WorkspacesSettings: View {
    let module: WindowsModule
    let conflict: (String, Hotkey) -> HotkeyConflict?
    @State private var tick = 0

    var body: some View {
        let _ = tick
        let list = module.workspaces.workspaces
        VStack(alignment: .leading, spacing: 4) {
            SettingsGroupTitle(WindowsText.t("Workspaces"))
                .padding(.top, 8)
            SettingsNote(list.isEmpty
                         ? WindowsText.t("None saved yet: use Workspaces on the Windows tab, or “Save workspace” in the command bar.")
                         : WindowsText.t("Restoring opens apps that are not running; minimised and hidden windows are left alone. Undo puts everything back."))
            ForEach(list) { w in
                let id = "windows.workspace.\(w.id.uuidString)"
                SettingsRow(w.name, note: WorkspaceCardText.detail(w), minHeight: 26) {
                    HStack(spacing: 6) {
                        HotkeyField(id: id, hotkey: w.hotkey, conflict: conflict(id, w.hotkey)) { new in
                            module.workspaces.update(w.id) { $0.hotkey = new }
                            tick += 1
                        }
                        NotchTextButton(WindowsText.t("Restore")) { module.restoreWorkspace(w.id) }
                        Button {
                            module.model.deleteWorkspace(w.id)
                            tick += 1
                        } label: {
                            Image(systemName: "trash").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.tertiary)
                                .frame(width: 20, height: 20).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(WindowsText.t("Delete"))
                    }
                }
                SettingsRow(WindowsText.t("Apply when this display setup connects"),
                            note: WorkspaceCardText.setup(w), minHeight: 22) {
                    NotchSwitch(isOn: Binding(get: { w.applyOnConnect }, set: { on in
                        module.workspaces.update(w.id) { $0.applyOnConnect = on }
                        tick += 1
                    }))
                }
                .padding(.leading, 12)
            }
        }
    }
}

@MainActor
enum WorkspaceCardText {
    static func detail(_ w: Workspace) -> String {
        var parts = [w.windows.count == 1 ? WindowsText.t("1 window") : WindowsText.f("%d windows", w.windows.count),
                     w.bundleIDs.count == 1 ? WindowsText.t("1 app") : WindowsText.f("%d apps", w.bundleIDs.count)]
        if w.usedDisplays > 1 { parts.append(WindowsText.f("%d displays", w.usedDisplays)) }
        return parts.joined(separator: " · ")
    }

    /// "Built-in + 34-inch Ultrawide · places only, opens nothing".
    static func setup(_ w: Workspace) -> String {
        let names = w.displays.map { $0.builtIn ? WindowsText.t("Built-in") : $0.name }
        return names.joined(separator: " + ") + " · " + WindowsText.t("places running apps only")
    }
}
