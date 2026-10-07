import SwiftUI

// The Settings window's own pages (General, Home) and the pieces every section is built from
// (SPEC §4). Window scale: system type and colours (`SettingsStyle`), never `.ui`.

// MARK: General

struct GeneralSection: View {
    let context: SurfaceContext

    var body: some View {
        @Bindable var settings = context.settings
        let launch = context.launchAtLogin
        let limited = sizeNote(settings.size)
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection(tr("Notch")) {
                SettingsRow(tr("Open with"),
                            note: settings.openModel == .hover ? tr("Resting on the notch opens it") : tr("Hover peeks, click opens")) {
                    NotchSegments(selection: $settings.openModel,
                                  options: [(.click, tr("Click")), (.hover, tr("Hover"))])
                }
                SettingsRow(tr("Size"), note: limited ?? tr("Text, symbols and the panel, on every display"),
                            noteColor: limited == nil ? SettingsStyle.tertiary : SettingsStyle.waiting) {
                    // A pop-up: three long names side by side would squeeze the note at the minimum width.
                    NotchSegments(selection: $settings.size,
                                  options: UISize.allCases.map { ($0, tr(Self.sizeName($0))) }, windowMenu: true)
                }
                SettingsRow(tr("Hidden from screen recordings"), note: tr("Screenshots and shared screens skip it")) {
                    NotchSwitch(isOn: $settings.hideFromCapture)
                }
                SettingsRow(tr("Pill on external displays"), note: tr("A small notch on screens without one")) {
                    NotchSwitch(isOn: $settings.externalPill)
                }
            }
            SettingsSection(tr("Language and startup")) {
                SettingsRow(tr("Language")) {
                    NotchSegments(selection: $settings.language,
                                  options: [(.system, tr("System")), (.en, "English"), (.it, "Italiano")])
                }
                SettingsRow(tr("Launch at login"), note: launchNote(launch.state)) {
                    NotchSwitch(isOn: Binding(get: { launch.state == .on }, set: { launch.set($0) }),
                                enabled: launch.state != .unavailable)
                }
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
        default: tr("Glancy starts with your Mac")
        }
    }
}

// MARK: Home

/// Settings → Home: which widgets Home shows, in what order, and when (Always / Only when needed).
struct HomeSection: View {
    let context: SurfaceContext

    var body: some View {
        let settings = context.settings
        let order = settings.homeOrder
        SettingsSection(tr("Widgets"),
                        footer: tr("Always: shown even at rest. Only when needed: just when it has something. Up to 4 cards fit (3 with Media): the ones with something first, the most urgent first, then this order.")) {
            VStack(alignment: .leading, spacing: SettingsStyle.rowSpacing) {
                ForEach(Array(order.enumerated()), id: \.element) { i, w in
                    HomeWidgetRow(context: context, widget: w, position: i + 1, count: order.count)
                }
            }
        } trailing: {
            if settings.homeIsCustomized {
                Button(tr("Reset")) { withAnimation(Theme.peek) { settings.resetHome() } }
                    .controlSize(.small)
            }
        }
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
        HStack(spacing: 10) {
            Text(verbatim: "\(position)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(SettingsStyle.faint)
                .frame(width: 14, alignment: .trailing)
            SettingsIcon(symbol: widget.symbol, tint: SettingsCatalog.tint(widget.module), size: 22, dimmed: !on)
            label(on: on, moduleOn: moduleOn)
            modePicker(moduleOn: moduleOn)
            HStack(spacing: 0) {
                arrow("chevron.up", enabled: position > 1, help: tr("Move up")) { settings.moveOnHome(widget, by: -1) }
                arrow("chevron.down", enabled: position < count, help: tr("Move down")) { settings.moveOnHome(widget, by: 1) }
            }
            NotchSwitch(isOn: Binding(get: { on }, set: { settings.setShownOnHome(widget, $0) }), enabled: moduleOn)
        }
        .padding(.vertical, 5)
        .settingsRow()
    }

    /// The widget's name, and what it shows in the chosen mode (or a link to its module when off).
    private func label(on: Bool, moduleOn: Bool) -> some View {
        let mode = context.settings.homeMode(widget)
        let name = tr(SurfaceContext.name(widget.module))
        return VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: tr(widget.title))
                .font(SettingsStyle.font(.m))
                .foregroundStyle(on ? SettingsStyle.primary : SettingsStyle.secondary)
                .lineLimit(1)
            if moduleOn {
                // Wraps rather than truncates (longer in Italian).
                Text(verbatim: tr(mode == .always ? widget.idle : widget.when))
                    .font(SettingsStyle.font(.xs))
                    .foregroundStyle(SettingsStyle.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button(L10n.tr("%@ is off", name)) { context.settings.navigation.go(.module(widget.module)) }
                    .buttonStyle(.link)
                    .font(SettingsStyle.font(.xs))
                    .help(L10n.tr("Open %@ settings", name))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func modePicker(moduleOn: Bool) -> some View {
        let settings = context.settings
        let always = tr(HomeWidgetMode.always.title) + ": " + tr(widget.idle)
        let needed = tr(HomeWidgetMode.whenNeeded.title) + ": " + tr(widget.when)
        let selection = Binding<HomeWidgetMode>(get: { settings.homeMode(widget) }, set: { settings.setHomeMode(widget, $0) })
        return Picker("", selection: selection) {
            ForEach([HomeWidgetMode.always, .whenNeeded], id: \.self) { m in
                Text(verbatim: tr(m.title)).tag(m)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .disabled(!moduleOn)
        .help(always + "\n" + needed)
    }

    private func arrow(_ symbol: String, enabled: Bool, help: String, _ action: @escaping () -> Void) -> some View {
        Button { withAnimation(Theme.peek) { action() } } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(enabled ? SettingsStyle.secondary : SettingsStyle.faint.opacity(0.5))
                .frame(width: 20, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel("\(tr(widget.title)), \(help)")
    }
}

// MARK: Shared pieces

/// A label (and an optional note under it) with a control on the right: one row of a box.
struct SettingsRow<Control: View>: View {
    let title: String
    let note: String?
    let noteColor: Color
    let minHeight: CGFloat
    let control: Control

    init(_ title: String, note: String? = nil, noteColor: Color = SettingsStyle.tertiary, minHeight: CGFloat = 22,
         @ViewBuilder control: () -> Control) {
        self.title = title; self.note = note; self.noteColor = noteColor; self.minHeight = minHeight; self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(SettingsStyle.font(.m))
                    .foregroundStyle(SettingsStyle.primary)
                if let note {
                    Text(verbatim: note).font(SettingsStyle.font(.xs)).foregroundStyle(noteColor)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            control
                .fixedSize()
        }
        .frame(minHeight: minHeight)
        .padding(.vertical, 6)
        .settingsRow()
    }
}

/// A quiet explanatory line.
struct SettingsNote: View {
    let text: String
    var color: Color = SettingsStyle.tertiary
    init(_ text: String, color: Color = SettingsStyle.tertiary) { self.text = text; self.color = color }
    var body: some View {
        Text(verbatim: text)
            .font(SettingsStyle.font(.xs))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
    }
}

/// A group's name inside a box (the rows under it follow without a separator).
struct SettingsGroupTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(SettingsStyle.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
            .padding(.bottom, 1)
            .settingsRow(title: true)
    }
}

/// A whole number of minutes with a stepper.
struct MinutesStepper: View {
    let value: Int
    let range: ClosedRange<Int>
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: L10n.tr("%d min", value))
                .font(SettingsStyle.font(.m).monospacedDigit())
                .foregroundStyle(SettingsStyle.primary)
                .frame(minWidth: 52, alignment: .trailing)
            Stepper("", value: Binding(get: { value }, set: { onChange(min(max($0, range.lowerBound), range.upperBound)) }), in: range)
                .labelsHidden()
        }
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
            HStack(spacing: 6) {
                Text(verbatim: question).font(SettingsStyle.font(.s)).foregroundStyle(SettingsStyle.secondary).lineLimit(1)
                Button(tr("Cancel")) { asking = false }
                Button(confirm, role: .destructive) { asking = false; action() }
                    .buttonStyle(.borderedProminent)
                    .tint(SettingsStyle.failed)
            }
        } else {
            Button(title) { asking = true }
                .disabled(!enabled)
        }
    }
}

extension SurfaceContext {
    /// The registered module of a given type, if any.
    func module<T>(_ type: T.Type) -> T? { modules.lazy.compactMap { $0 as? T }.first }
}
