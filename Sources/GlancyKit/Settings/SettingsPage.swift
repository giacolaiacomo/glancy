import SwiftUI

/// Settings inside the expanded panel (SPEC §4), two levels: an index of sections, then one
/// section (General, Modules, Permissions, or a module's own settings). The panel scrolls it.
struct SettingsPage: View {
    let context: SurfaceContext

    var body: some View {
        let nav = context.settings.navigation
        Group {
            switch nav.route {
            case .index: SettingsIndex(context: context)
            case .general: GeneralSection(context: context)
            case .modules: ModulesSection(context: context)
            case .permissions: PermissionsSection(context: context, welcome: nav.welcome)
            case .module(let id): ModuleSection(context: context, id: id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear {
            // Opening Settings is a cheap moment to notice a grant made in System Settings.
            context.settings.permissions.refresh()
            context.launchAtLogin.refresh()
        }
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

// MARK: Level 1 — the index

private struct SettingsIndex: View {
    let context: SurfaceContext

    var body: some View {
        let settings = context.settings
        let nav = settings.navigation
        let modules = context.modules.map(\.id)
            .filter { SettingsCatalog.hasSection($0) }
            .sorted { SurfaceContext.order($0) < SurfaceContext.order($1) }
        let missing = PermissionRows.missing(context)
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                IndexTile(symbol: "slider.horizontal.3", title: tr("General"), detail: SettingsCatalog.generalSummary(settings)) {
                    nav.go(.general)
                }
                IndexTile(symbol: "square.grid.2x2", title: tr("Modules"),
                          detail: L10n.tr("%d of %d on", context.enabledModules.count, context.modules.count)) {
                    nav.go(.modules)
                }
                IndexTile(symbol: "lock.shield", title: tr("Permissions"),
                          detail: missing == 0 ? tr("All set") : L10n.tr("%d to allow", missing), warn: missing > 0) {
                    nav.go(.permissions)
                }
                ForEach(modules, id: \.self) { id in
                    IndexTile(symbol: SurfaceContext.symbol(id), title: tr(SurfaceContext.name(id)),
                              detail: settings.isEnabled(id) ? SettingsCatalog.summary(id, context) : tr("Off"),
                              dimmed: !settings.isEnabled(id)) {
                        nav.go(.module(id))
                    }
                }
            }
            HStack {
                Text(verbatim: "Glancy \(SettingsPage.version)")
                    .font(Theme.font(.xs))
                    .foregroundStyle(Theme.tertiary)
                Spacer()
                NotchTextButton(tr("Quit Glancy")) { context.quit() }
            }
        }
    }
}

private struct IndexTile: View {
    let symbol: String
    let title: String
    let detail: String
    var warn = false
    var dimmed = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title)
                        .font(Theme.font(.m, .medium))
                        .foregroundStyle(Theme.primary)
                    Text(verbatim: detail)
                        .font(Theme.font(.xs))
                        .foregroundStyle(warn ? Theme.waiting : Theme.tertiary)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hover ? Color.white.opacity(0.11) : Theme.card))
            .opacity(dimmed ? 0.55 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: Level 2 — General and Modules

private struct GeneralSection: View {
    let context: SurfaceContext

    var body: some View {
        @Bindable var settings = context.settings
        let launch = context.launchAtLogin
        VStack(alignment: .leading, spacing: 6) {
            SettingsHeader(context: context, title: tr("General"))
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    SettingsRow(tr("Open with"),
                                note: settings.openModel == .hover ? tr("Resting on the notch opens it") : tr("Hover peeks, click opens")) {
                        NotchSegments(selection: $settings.openModel,
                                      options: [(.click, tr("Click")), (.hover, tr("Hover"))])
                    }
                    SettingsRow(tr("Language")) {
                        NotchSegments(selection: $settings.language,
                                      options: [(.system, tr("System")), (.en, "English"), (.it, "Italiano")])
                    }
                    SettingsRow(tr("Launch at login"), note: launchNote(launch.state)) {
                        NotchSwitch(isOn: Binding(get: { launch.state == .on }, set: { launch.set($0) }),
                                    enabled: launch.state != .unavailable)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    SettingsRow(tr("Hidden from screen recordings"), note: tr("Screenshots and shared screens skip it")) {
                        NotchSwitch(isOn: $settings.hideFromCapture)
                    }
                    SettingsRow(tr("Pill on external displays"), note: tr("A small notch on screens without one")) {
                        NotchSwitch(isOn: $settings.externalPill)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func launchNote(_ s: LaunchAtLogin.State) -> String? {
        switch s {
        case .needsApproval: tr("Needs approval in System Settings")
        case .unavailable: tr("Available from the installed app")
        default: nil
        }
    }
}

private struct ModulesSection: View {
    let context: SurfaceContext

    var body: some View {
        let modules = context.modules.map(\.id).sorted { SurfaceContext.order($0) < SurfaceContext.order($1) }
        VStack(alignment: .leading, spacing: 4) {
            SettingsHeader(context: context, title: tr("Modules"))
            if modules.isEmpty {
                SettingsNote(tr("No modules yet."))
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 22), GridItem(.flexible())], alignment: .leading, spacing: 2) {
                ForEach(modules, id: \.self) { id in
                    let on = context.settings.isEnabled(id)
                    HStack(spacing: 8) {
                        Image(systemName: SurfaceContext.symbol(id))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(on ? Theme.primary : Theme.tertiary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: tr(SurfaceContext.name(id)))
                                .font(Theme.font(.m))
                                .foregroundStyle(on ? Theme.primary : Theme.secondary)
                            Text(verbatim: tr(SettingsCatalog.purpose(id)))
                                .font(Theme.font(.xs))
                                .foregroundStyle(Theme.tertiary)
                        }
                        .lineLimit(1)
                        Spacer(minLength: 6)
                        NotchSwitch(isOn: Binding(get: { on }, set: { context.setModuleEnabled(id, $0) }))
                    }
                    .frame(height: 28)
                }
            }
        }
    }
}

// MARK: Shared pieces

/// The level-2 header: back to the index, the section's name, an optional control on the right.
struct SettingsHeader<Trailing: View>: View {
    let context: SurfaceContext
    let title: String
    let trailing: Trailing
    @State private var hover = false

    init(context: SurfaceContext, title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.context = context; self.title = title; self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 8) {
            Button { context.settings.navigation.go(.index) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hover ? Theme.primary : Theme.secondary)
                    .frame(width: 22, height: 20)
                    .background(Capsule().fill(hover ? Color.white.opacity(0.12) : Theme.card))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .help(tr("Back"))
            .accessibilityLabel(tr("Back"))
            Text(verbatim: title)
                .font(Theme.font(.l, .semibold))
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
            Spacer(minLength: 6)
            trailing
        }
        .frame(height: 24)
    }
}

/// A label (and an optional note under it) with a control on the right.
struct SettingsRow<Control: View>: View {
    let title: String
    let note: String?
    let noteColor: Color
    let minHeight: CGFloat
    let control: Control

    init(_ title: String, note: String? = nil, noteColor: Color = Theme.tertiary, minHeight: CGFloat = 26,
         @ViewBuilder control: () -> Control) {
        self.title = title; self.note = note; self.noteColor = noteColor; self.minHeight = minHeight; self.control = control()
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title)
                    .font(Theme.font(.m))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                if let note {
                    Text(verbatim: note).font(Theme.font(.xs)).foregroundStyle(noteColor).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            control
        }
        .frame(minHeight: minHeight)
    }
}

/// A quiet explanatory line.
struct SettingsNote: View {
    let text: String
    var color: Color = Theme.tertiary
    init(_ text: String, color: Color = Theme.tertiary) { self.text = text; self.color = color }
    var body: some View {
        Text(verbatim: text)
            .font(Theme.font(.xs))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// An uppercase group label.
struct SettingsGroupTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(verbatim: text.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Theme.tertiary)
            .lineLimit(1)
    }
}

/// − value + for whole minutes.
struct MinutesStepper: View {
    let value: Int
    let range: ClosedRange<Int>
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            step("minus", -1)
            Text(verbatim: L10n.tr("%d min", value))
                .font(Theme.font(.s, .medium).monospacedDigit())
                .foregroundStyle(Theme.primary)
                .frame(minWidth: 44)
            step("plus", 1)
        }
        .padding(2)
        .background(Capsule().fill(Theme.card))
    }

    private func step(_ symbol: String, _ d: Int) -> some View {
        let next = value + d
        return Button { onChange(next) } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(range.contains(next) ? Theme.secondary : Theme.tertiary.opacity(0.5))
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!range.contains(next))
    }
}

/// A destructive action in two clicks: the button turns into "question · Cancel · Confirm".
struct ConfirmButton: View {
    let title: String
    let question: String
    let confirm: String
    var enabled = true
    let action: () -> Void
    @State private var asking = false

    var body: some View {
        if asking {
            HStack(spacing: 4) {
                Text(verbatim: question).font(Theme.font(.xs)).foregroundStyle(Theme.secondary).lineLimit(1)
                NotchTextButton(tr("Cancel")) { asking = false }
                Button { asking = false; action() } label: {
                    Text(verbatim: confirm)
                        .font(Theme.font(.s, .semibold))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(Capsule().fill(Theme.failed))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        } else {
            NotchTextButton(title) { asking = true }
                .opacity(enabled ? 1 : 0.4)
                .disabled(!enabled)
        }
    }
}

extension SurfaceContext {
    /// The registered module of a given type, if any.
    func module<T>(_ type: T.Type) -> T? { modules.lazy.compactMap { $0 as? T }.first }
}
