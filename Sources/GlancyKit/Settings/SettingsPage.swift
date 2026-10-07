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
            case .home: HomeSection(context: context)
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
        VStack(alignment: .leading, spacing: 6.ui) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6.ui), count: 4), spacing: 6.ui) {
                IndexTile(symbol: "slider.horizontal.3", title: tr("General"), detail: SettingsCatalog.generalSummary(settings)) {
                    nav.go(.general)
                }
                IndexTile(symbol: "house", title: tr("Home"), detail: SettingsCatalog.homeSummary(settings)) {
                    nav.go(.home)
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
            HStack(spacing: 8.ui) {
                Text(verbatim: "Glancy \(SettingsPage.version)")
                    .font(Theme.font(.xs))
                    .foregroundStyle(Theme.tertiary)
                if let updates = context.updates, let v = updates.available {
                    UpdateButton(updates: updates, version: v)
                }
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
            HStack(spacing: 7.ui) {
                Image(systemName: symbol)
                    .font(.system(size: 11.ui, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 16.ui)
                VStack(alignment: .leading, spacing: 1.ui) {
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
            .padding(.horizontal, 8.ui)
            .frame(height: 36.ui)
            .background(RoundedRectangle(cornerRadius: 10.ui, style: .continuous)
                .fill(hover ? Color.white.opacity(0.11) : Theme.card))
            .opacity(dimmed ? 0.55 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 10.ui, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: Level 2 — General and Modules

struct GeneralSection: View {
    let context: SurfaceContext

    var body: some View {
        @Bindable var settings = context.settings
        let launch = context.launchAtLogin
        VStack(alignment: .leading, spacing: 6.ui) {
            SettingsHeader(context: context, title: tr("General"))
            HStack(alignment: .top, spacing: 22.ui) {
                VStack(alignment: .leading, spacing: 4.ui) {
                    SettingsRow(tr("Open with"),
                                note: settings.openModel == .hover ? tr("Resting on the notch opens it") : tr("Hover peeks, click opens")) {
                        NotchSegments(selection: $settings.openModel,
                                      options: [(.click, tr("Click")), (.hover, tr("Hover"))])
                    }
                    SettingsRow(tr("Language")) {
                        NotchSegments(selection: $settings.language,
                                      options: [(.system, tr("System")), (.en, "English"), (.it, "Italiano")])
                    }
                    SettingsRow(tr("Size")) {
                        NotchSegments(selection: $settings.size,
                                      options: UISize.allCases.map { ($0, tr(Self.sizeName($0))) })
                            .fixedSize()
                    }
                    // The whole column's width: the segments leave the title little room.
                    if let note = sizeNote(settings.size) {
                        Text(verbatim: note).font(Theme.font(.xs)).foregroundStyle(Theme.waiting).lineLimit(2)
                    }
                    SettingsRow(tr("Launch at login"), note: launchNote(launch.state)) {
                        NotchSwitch(isOn: Binding(get: { launch.state == .on }, set: { launch.set($0) }),
                                    enabled: launch.state != .unavailable)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 4.ui) {
                    SettingsRow(tr("Hidden from screen recordings"), note: tr("Screenshots and shared screens skip it")) {
                        NotchSwitch(isOn: $settings.hideFromCapture)
                    }
                    SettingsRow(tr("Pill on external displays"), note: tr("A small notch on screens without one")) {
                        NotchSwitch(isOn: $settings.externalPill)
                    }
                    UpdatesSettingsRows(updates: context.updates, version: SettingsPage.version)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    static func sizeName(_ s: UISize) -> String {
        switch s {
        case .normal: "Normal"
        case .large: "Large"
        case .extraLarge: "Extra large"
        }
    }

    /// Only when the chosen size would not fit a display: the one in use.
    private func sizeNote(_ chosen: UISize) -> String? {
        let scale = UIScale.shared
        guard scale.isLimited, scale.requested == chosen else { return nil }
        return L10n.tr("Doesn't fit the screen: %@ in use", tr(Self.sizeName(scale.size)))
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
        VStack(alignment: .leading, spacing: 4.ui) {
            SettingsHeader(context: context, title: tr("Modules"))
            if modules.isEmpty {
                SettingsNote(tr("No modules yet."))
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 22.ui), GridItem(.flexible())], alignment: .leading, spacing: 2.ui) {
                ForEach(modules, id: \.self) { id in
                    let on = context.settings.isEnabled(id)
                    HStack(spacing: 8.ui) {
                        Image(systemName: SurfaceContext.symbol(id))
                            .font(.system(size: 11.ui, weight: .medium))
                            .foregroundStyle(on ? Theme.primary : Theme.tertiary)
                            .frame(width: 18.ui)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: tr(SurfaceContext.name(id)))
                                .font(Theme.font(.m))
                                .foregroundStyle(on ? Theme.primary : Theme.secondary)
                            Text(verbatim: tr(SettingsCatalog.purpose(id)))
                                .font(Theme.font(.xs))
                                .foregroundStyle(Theme.tertiary)
                        }
                        .lineLimit(1)
                        Spacer(minLength: 6.ui)
                        NotchSwitch(isOn: Binding(get: { on }, set: { context.setModuleEnabled(id, $0) }))
                    }
                    .frame(height: 28.ui)
                }
            }
        }
    }
}

/// Settings → Home: which widgets Home shows and in what order. Three columns read top to bottom,
/// numbered; ↑ ↓ move a widget, the switch turns it on or off. Everything fits without scrolling.
struct HomeSection: View {
    let context: SurfaceContext

    var body: some View {
        let settings = context.settings
        let order = settings.homeOrder
        let per = (order.count + 2) / 3
        VStack(alignment: .leading, spacing: 4.ui) {
            SettingsHeader(context: context, title: tr("Home")) {
                if settings.homeIsCustomized {
                    NotchTextButton(tr("Reset")) { withAnimation(Theme.peek) { settings.resetHome() } }
                }
            }
            SettingsNote(tr("A card shows only when it has something; if they don't all fit, the most urgent go first."))
            HStack(alignment: .top, spacing: 16.ui) {
                ForEach(0..<3, id: \.self) { c in
                    column(Array(order.dropFirst(c * per).prefix(per)), offset: c * per, count: order.count)
                }
            }
            .padding(.top, 2.ui)
        }
    }

    private func column(_ widgets: [HomeWidget], offset: Int, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 2.ui) {
            ForEach(Array(widgets.enumerated()), id: \.element) { i, w in
                HomeWidgetRow(context: context, widget: w, position: offset + i + 1, count: count)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct HomeWidgetRow: View {
    let context: SurfaceContext
    let widget: HomeWidget
    let position: Int
    let count: Int

    var body: some View {
        let settings = context.settings
        let moduleOn = settings.isEnabled(widget.module)
        let on = settings.isShownOnHome(widget) && moduleOn
        let note = moduleOn ? tr(widget.when) : L10n.tr("%@ is off in Modules", tr(SurfaceContext.name(widget.module)))
        HStack(spacing: 6.ui) {
            Text(verbatim: "\(position)")
                .font(Theme.font(.xs, .semibold).monospacedDigit())
                .foregroundStyle(Theme.tertiary)
                .frame(width: 10.ui, alignment: .trailing)
            Image(systemName: widget.symbol)
                .font(.system(size: 11.ui, weight: .medium))
                .foregroundStyle(on ? Theme.primary : Theme.tertiary)
                .frame(width: 16.ui)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: tr(widget.title))
                    .font(Theme.font(.m))
                    .foregroundStyle(on ? Theme.primary : Theme.secondary)
                // When the card shows lives in the tooltip; a module that is off says so here.
                if !moduleOn {
                    Text(verbatim: note)
                        .font(Theme.font(.xs))
                        .foregroundStyle(Theme.waiting)
                }
            }
            .lineLimit(1)
            .help(tr(widget.title) + " · " + note)
            Spacer(minLength: 2.ui)
            HStack(spacing: 0) {
                arrow("chevron.up", enabled: position > 1, help: tr("Move up")) { settings.moveOnHome(widget, by: -1) }
                arrow("chevron.down", enabled: position < count, help: tr("Move down")) { settings.moveOnHome(widget, by: 1) }
            }
            NotchSwitch(isOn: Binding(get: { on }, set: { settings.setShownOnHome(widget, $0) }), enabled: moduleOn)
        }
        .frame(height: 30.ui)
    }

    private func arrow(_ symbol: String, enabled: Bool, help: String, _ action: @escaping () -> Void) -> some View {
        Button { withAnimation(Theme.peek) { action() } } label: {
            Image(systemName: symbol)
                .font(.system(size: 9.ui, weight: .bold))
                .foregroundStyle(enabled ? Theme.secondary : Theme.tertiary.opacity(0.4))
                .frame(width: 15.ui, height: 20.ui)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel("\(tr(widget.title)), \(help)")
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
        HStack(spacing: 8.ui) {
            Button { context.settings.navigation.go(.index) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10.ui, weight: .semibold))
                    .foregroundStyle(hover ? Theme.primary : Theme.secondary)
                    .frame(width: 22.ui, height: 20.ui)
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
            Spacer(minLength: 6.ui)
            trailing
        }
        .frame(height: 24.ui)
    }
}

/// A label (and an optional note under it) with a control on the right.
struct SettingsRow<Control: View>: View {
    let title: String
    let note: String?
    let noteColor: Color
    let minHeight: CGFloat
    let control: Control

    init(_ title: String, note: String? = nil, noteColor: Color = Theme.tertiary, minHeight: CGFloat = 26.ui,
         @ViewBuilder control: () -> Control) {
        self.title = title; self.note = note; self.noteColor = noteColor; self.minHeight = minHeight; self.control = control()
    }

    var body: some View {
        HStack(spacing: 8.ui) {
            VStack(alignment: .leading, spacing: 1.ui) {
                Text(verbatim: title)
                    .font(Theme.font(.m))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                if let note {
                    Text(verbatim: note).font(Theme.font(.xs)).foregroundStyle(noteColor).lineLimit(1)
                }
            }
            Spacer(minLength: 6.ui)
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
            .font(.system(size: 9.5.ui, weight: .semibold))
            .tracking(0.6.ui)
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
        HStack(spacing: 2.ui) {
            step("minus", -1)
            Text(verbatim: L10n.tr("%d min", value))
                .font(Theme.font(.s, .medium).monospacedDigit())
                .foregroundStyle(Theme.primary)
                .frame(minWidth: 44.ui)
            step("plus", 1)
        }
        .padding(2.ui)
        .background(Capsule().fill(Theme.card))
    }

    private func step(_ symbol: String, _ d: Int) -> some View {
        let next = value + d
        return Button { onChange(next) } label: {
            Image(systemName: symbol)
                .font(.system(size: 9.ui, weight: .bold))
                .foregroundStyle(range.contains(next) ? Theme.secondary : Theme.tertiary.opacity(0.5))
                .frame(width: 20.ui, height: 18.ui)
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
            HStack(spacing: 4.ui) {
                Text(verbatim: question).font(Theme.font(.xs)).foregroundStyle(Theme.secondary).lineLimit(1)
                NotchTextButton(tr("Cancel")) { asking = false }
                Button { asking = false; action() } label: {
                    Text(verbatim: confirm)
                        .font(Theme.font(.s, .semibold))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 9.ui)
                        .frame(height: 22.ui)
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
