import AppKit
import SwiftUI

/// What the Settings window says about each module (purpose, a one-line state for the sidebar's
/// tooltip, tint, search words), and which modules have settings of their own.
@MainActor
enum SettingsCatalog {
    static func hasSection(_ id: ModuleID) -> Bool {
        [.agents, .calendar, .media, .timer, .shelf, .clipboard, .windows, .hud, .power, .notes, .command, .control, .monitor, .meetings].contains(id)
    }

    static func generalSummary(_ s: AppSettings) -> String {
        let open = s.openModel == .click ? tr("Click") : tr("Hover")
        let lang = switch s.language { case .system: tr("System"); case .en: "English"; case .it: "Italiano" }
        // The size only once it is not the normal one (the tile has room for three words).
        guard s.size != .normal else { return "\(open) · \(lang)" }
        return "\(open) · \(lang) · \(tr(GeneralSection.sizeName(s.size)))"
    }

    /// The colour of a module's icon in the sidebar and on its page. A module not listed (a new
    /// one) is gray: lookups, not switches, so a new ModuleID needs nothing here.
    static func tint(_ id: ModuleID) -> Color {
        Color(nsColor: tints[id] ?? .systemGray)
    }

    private static let tints: [ModuleID: NSColor] = [
        .agents: .systemPurple, .calendar: .systemRed, .media: .systemPink, .timer: .systemOrange,
        .notes: .systemYellow, .shelf: .systemTeal, .clipboard: .systemIndigo, .windows: .systemBlue,
        .control: .systemCyan, .monitor: .systemGreen, .notifications: .systemRed, .hud: .systemGray,
        .power: .systemGreen, .command: .darkGray,
    ]

    /// Row names the sidebar's search finds a module by (its name and purpose always match).
    static func keywords(_ id: ModuleID) -> [String] {
        keywordTable[id]?() ?? []
    }

    private static let keywordTable: [ModuleID: @MainActor () -> [String]] = [
        .agents: { ["Claude Code", "Codex", "OpenCode", LimitsText.t("Plan limits")] },
        .calendar: { [CalL10n.focusSwitch, CalL10n.endWarning, CalL10n.joinShortcut, CalL10n.calendarsTitle] },
        .media: { [tr("Source in use"), tr("Lyrics")] },
        .hud: { [tr("Volume"), tr("Brightness"), tr("Keyboard backlight"), tr("Mute microphone")] },
        .power: { [tr("Battery in the notch"), tr("Low battery peek"), tr("Headphones peek"), tr("Full charge peek")] },
        .timer: { [tr("Focus"), tr("Short break"), tr("Long break"), "Pomodoro"] },
        .shelf: { [tr("Drop targets"), tr("Finished downloads")] },
        .clipboard: { [tr("Pause history"), tr("Paste after choosing"), tr("Excluded apps"), tr("Shortcut")] },
        .windows: { [tr("Shortcuts"), WindowsText.t("Auto-arrange"), WindowsText.t("Workspaces")] },
        .notes: { [tr("Quick note"), tr("Voice notes")] },
        .command: { [tr("Shortcut"), CommandText.t("Calculator"), CommandText.t("Web search")] },
        .control: { [ControlText.t("Keep awake by default"), ControlText.t("Tiles")] },
        .monitor: { [MonitorText.t("Sparklines"), MonitorText.t("Refresh")] },
    ]

    /// Settings → Home's tile: how many widgets are on.
    @MainActor static func homeSummary(_ s: AppSettings) -> String {
        let on = HomeWidget.allCases.filter { s.isShownOnHome($0) && s.isEnabled($0.module) }.count
        return L10n.tr("%d widgets on", on)
    }

    /// One line for a module's state (the sidebar row's tooltip).
    static func summary(_ id: ModuleID, _ context: SurfaceContext) -> String {
        switch id {
        case .calendar:
            guard let m = context.module(CalendarModule.self) else { return "" }
            if m.model.access != .granted { return tr("No access") }
            let all = m.settings.availableCalendars.count
            guard let ids = m.settings.selectedCalendarIDs else { return tr("All calendars") }
            return L10n.tr("%d of %d calendars", ids.count, all)
        case .hud:
            guard let m = context.module(HUDModule.self) else { return "" }
            if !m.settings.enabled || m.settings.kinds.isEmpty { return tr("Off") }
            if m.needsAccessibility { return tr("No access") }
            let n = m.settings.kinds.count
            return n == HUDKind.allCases.count ? tr("All keys") : L10n.tr("%d of %d keys", n, HUDKind.allCases.count)
        case .power:
            guard let m = context.module(PowerModule.self) else { return "" }
            switch (m.settings.batteryActivities, m.settings.bluetoothPeeks) {
            case (true, true): return tr("All on")
            case (true, false): return tr("Battery only")
            case (false, true): return tr("Headphones only")
            case (false, false): return tr("Quiet")
            }
        case .media:
            guard let m = context.module(MediaModule.self) else { return "" }
            return MediaSection.sourceShort(m.model.source)
        case .timer:
            let l = Pomodoro.lengths
            return L10n.tr("%d / %d / %d min", l.focus, l.shortBreak, l.longBreak)
        case .shelf:
            guard let m = context.module(ShelfModule.self) else { return "" }
            return m.model.items.isEmpty ? tr("Empty") : L10n.tr("%d items", m.model.items.count)
        case .clipboard:
            guard let m = context.module(ClipboardModule.self) else { return "" }
            if m.model.settings.paused { return tr("Paused") }
            let key = m.model.settings.hotkey
            return key.modifiers == 0 ? L10n.tr("%d items", m.model.items.count) : key.description
        case .windows:
            guard let m = context.module(WindowsModule.self) else { return "" }
            return m.hotkeys.enabled ? WindowsSection.summary(m.hotkeys) : tr("Shortcuts off")
        case .agents:
            return context.module(AgentsModule.self)?.settingsSummary ?? ""
        case .notes:
            return context.module(NotesModule.self)?.settingsSummary ?? ""
        case .command:
            guard let m = context.module(CommandModule.self) else { return "" }
            let key = m.model.settings.hotkey
            return key.modifiers == 0 ? tr("None") : key.description
        case .control:
            return context.module(ControlModule.self).map { ControlText.summary($0.settings) } ?? ""
        case .monitor:
            return context.module(MonitorModule.self).map { MonitorText.summary($0.settings) } ?? ""
        case .meetings:
            return context.module(MeetingsModule.self)?.settingsSummary ?? ""
        case .notifications:
            return ""
        }
    }

    /// One line under the module's name on its page.
    static func purpose(_ id: ModuleID) -> String {
        switch id {
        case .agents: AgentsText.t("Claude Code, Codex, OpenCode sessions")
        case .calendar: "Next meeting, Join"
        case .media: "Now playing, controls"
        case .hud: "Volume and brightness"
        case .power: "Battery and headphones"
        case .timer: "Timer and Pomodoro"
        case .shelf: "Files parked in the notch"
        case .clipboard: "Clipboard history"
        case .windows: "Window tiling"
        case .notifications: "Notifications in the notch"
        case .command: "Launcher, calculator, every action"
        case .control: "Quick toggles and system tools"
        case .notes: "Quick notes"
        case .monitor: "CPU, memory and the apps using them"
        case .meetings: "Record meetings, with your consent"
        }
    }
}

/// A module's page: its on/off switch with what it does, then its own settings.
struct ModuleSection: View {
    let context: SurfaceContext
    let id: ModuleID

    /// The page's switch: reads the setting, turns the module on or off through the app.
    static func enabled(_ id: ModuleID, _ context: SurfaceContext) -> Binding<Bool> {
        Binding(get: { context.settings.isEnabled(id) }, set: { context.setModuleEnabled(id, $0) })
    }

    var body: some View {
        let on = context.settings.isEnabled(id)
        VStack(alignment: .leading, spacing: 22) {
            SettingsBox {
                HStack(spacing: 12) {
                    SettingsIcon(symbol: SurfaceContext.symbol(id), tint: SettingsCatalog.tint(id), size: 32, dimmed: !on)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: tr(SurfaceContext.name(id)))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(SettingsStyle.primary)
                        Text(verbatim: tr(SettingsCatalog.purpose(id)))
                            .font(SettingsStyle.font(.s))
                            .foregroundStyle(SettingsStyle.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if context.modules.contains(where: { $0.id == id }) {
                        NotchSwitch(isOn: Self.enabled(id, context))
                            .help(on ? tr("Turn off") : tr("Turn on"))
                            .accessibilityLabel(tr(SurfaceContext.name(id)))
                    }
                }
                .padding(.vertical, 10)
            }
            if SettingsCatalog.hasSection(id) {
                SettingsBox {
                    VStack(alignment: .leading, spacing: SettingsStyle.rowSpacing) { content }
                }
                .opacity(on ? 1 : 0.5)
            } else if on, let (permission, text) = Self.permission(id) {
                // No settings of its own, but a permission it can't work without.
                let status = context.settings.permissions.status(permission)
                if status == .notDetermined || status == .denied {
                    SettingsBox { PermissionLine(context: context, permission: permission, text: text) }
                }
            }
        }
    }

    /// The permission a module without its own section needs, with the line that asks for it.
    private static func permission(_ id: ModuleID) -> (PermissionKind, String)? {
        switch id {
        case .notifications: (.fullDiskAccess, tr("Reading your notifications needs Full Disk Access"))
        default: nil
        }
    }

    @ViewBuilder private var content: some View {
        switch id {
        case .calendar: if let m = context.module(CalendarModule.self) { CalendarSection(module: m, context: context) }
        case .hud: if let m = context.module(HUDModule.self) { HUDSection(module: m, context: context) }
        case .power: if let m = context.module(PowerModule.self) { PowerSection(module: m, context: context) }
        case .media: if let m = context.module(MediaModule.self) { MediaSection(module: m, context: context) }
        case .timer: if let m = context.module(TimerModule.self) { TimerSection(module: m) }
        case .shelf: if let m = context.module(ShelfModule.self) { ShelfSettingsSection(module: m) }
        case .clipboard: if let m = context.module(ClipboardModule.self) { ClipboardSection(module: m, context: context) }
        case .windows: if let m = context.module(WindowsModule.self) { WindowsSection(module: m, context: context) }
        case .agents: if let m = context.module(AgentsModule.self) { m.settingsSection() }
        case .notes: if let m = context.module(NotesModule.self) { NotesSettingsSection(module: m, context: context) }
        case .command: if let m = context.module(CommandModule.self) { CommandSection(module: m, context: context) }
        case .control: if let m = context.module(ControlModule.self) { ControlSection(module: m) }
        case .monitor: if let m = context.module(MonitorModule.self) { MonitorSection(module: m) }
        case .meetings: if let m = context.module(MeetingsModule.self) { MeetingsSection(module: m, context: context) }
        case .notifications: EmptyView()
        }
    }
}

/// "Needs Accessibility · Allow…" — shown where a missing permission limits a section.
private struct PermissionLine: View {
    let context: SurfaceContext
    let permission: PermissionKind
    let text: String

    var body: some View {
        let center = context.settings.permissions
        let status = center.status(permission)
        if status == .notDetermined || status == .denied {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsStyle.waiting)
                Text(verbatim: text)
                    .font(SettingsStyle.font(.s))
                    .foregroundStyle(SettingsStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                NotchTextButton(status == .denied ? tr("Open Settings") : tr("Allow…")) { center.request(permission) }
                    .fixedSize()
            }
            .padding(.vertical, 6)
            .frame(minHeight: 22)
            .settingsRow()
        }
    }
}

// MARK: Calendar

private struct CalendarSection: View {
    let module: CalendarModule
    let context: SurfaceContext

    var body: some View {
        let settings = module.settings
        let calendars = settings.availableCalendars
        VStack(alignment: .leading, spacing: SettingsStyle.rowSpacing) {
            MeetingSettingsView(module: module, context: context)
            PermissionLine(context: context, permission: .calendar, text: tr("Glancy can't read your calendars yet"))
            if calendars.isEmpty {
                SettingsNote(module.model.access == .granted ? tr("No calendars on this Mac.") : tr("Calendars show up here once access is allowed."))
            } else {
                let accounts = Dictionary(grouping: calendars, by: \.source)
                ForEach(accounts.keys.sorted(), id: \.self) { account in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(verbatim: account.isEmpty ? tr("Other") : account)
                            .font(SettingsStyle.font(.m))
                            .foregroundStyle(SettingsStyle.primary)
                            .lineLimit(2)
                            .frame(width: 130, alignment: .leading)
                        FlowLayout(spacing: 6) {
                            ForEach(accounts[account] ?? []) { cal in
                                CalendarChip(info: cal, on: settings.isSelected(cal.id)) {
                                    settings.setSelected(cal.id, !settings.isSelected(cal.id))
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 6)
                    .settingsRow()
                }
                SettingsNote(tr("New calendars join automatically while every calendar is on."))
            }
        }
    }
}

private struct CalendarChip: View {
    let info: CalendarInfo
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(on ? info.color.color : .clear)
                    .overlay(Circle().strokeBorder(info.color.color, lineWidth: 1.5))
                    .frame(width: 9, height: 9)
                Text(verbatim: info.title)
                    .font(SettingsStyle.font(.s, on ? .medium : .regular))
                    .foregroundStyle(on ? SettingsStyle.primary : SettingsStyle.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(on ? info.color.color.opacity(0.16) : .clear))
            .overlay(Capsule().strokeBorder(on ? info.color.color.opacity(0.35) : SettingsStyle.hairline, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(info.title)
    }
}

// MARK: HUD

private struct HUDSection: View {
    let module: HUDModule
    let context: SurfaceContext
    @State private var system: Set<Hotkey> = []
    @State private var tick = 0

    static let kinds: [(HUDKind, String, String)] = [
        (.volume, "Volume", "speaker.wave.2.fill"),
        (.brightness, "Brightness", "sun.max.fill"),
        (.keyboard, "Keyboard backlight", "light.max"),
    ]

    var body: some View {
        @Bindable var settings = module.settings
        let _ = tick
        VStack(alignment: .leading, spacing: SettingsStyle.rowSpacing) {
            PermissionLine(context: context, permission: .accessibility, text: tr("Needs Accessibility to take over the keys"))
            SettingsRow(tr("Show in the notch"), note: tr("Replaces the system HUD for the keys below")) {
                NotchSwitch(isOn: $settings.enabled)
            }
            // The three keys under the label: side by side they would squeeze the note.
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: tr("Keys")).font(SettingsStyle.font(.m)).foregroundStyle(SettingsStyle.primary)
                    Text(verbatim: tr("Keys left out keep the system HUD. ⌥⇧ still steps by quarters."))
                        .font(SettingsStyle.font(.xs)).foregroundStyle(SettingsStyle.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                FlowLayout(spacing: 6) {
                    ForEach(Self.kinds, id: \.0) { kind, title, symbol in
                        NotchChip(symbol: symbol, title: tr(title), on: settings.handles(kind)) {
                            settings.set(kind, !settings.handles(kind))
                        }
                    }
                }
                .disabled(!settings.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .settingsRow()
            SettingsRow(tr("Mute microphone shortcut"), note: tr("Mutes or unmutes the default microphone")) {
                HotkeyField(id: "hud.mic", hotkey: settings.micHotkey, conflict: conflict(settings.micHotkey)) { h in
                    module.setMicHotkey(h)
                    tick += 1
                }
            }
            SettingsRow(tr("Microphone and camera in use"), note: tr("A red dot in the notch while an app records")) {
                NotchSwitch(isOn: $settings.showInUse)
            }
        }
        .onAppear { system = HotkeyConflict.systemHotkeys() }
    }

    private func conflict(_ h: Hotkey) -> HotkeyConflict? {
        let failed: Set<Hotkey> = module.micHotkeyFailed ? [h] : []
        return HotkeyConflict.find(HotkeyBinding(id: "hud.mic", title: tr("Mute microphone"), hotkey: h),
                                   among: GlancyHotkeys.bindings(context), system: system, failed: failed)
    }
}

// MARK: Power

private struct PowerSection: View {
    let module: PowerModule
    let context: SurfaceContext

    var body: some View {
        @Bindable var settings = module.settings
        VStack(alignment: .leading, spacing: SettingsStyle.rowSpacing) {
            SettingsRow(tr("Battery in the notch"), note: tr("Plugging in, unplugging, Low Power Mode")) {
                NotchSwitch(isOn: $settings.batteryActivities)
            }
            SettingsRow(tr("Low battery peek"), note: tr("On battery, once per discharge")) {
                HStack(spacing: 8) {
                    NotchSegments(selection: $settings.lowFirst, options: [30, 25, 20, 15].map { ($0, "\($0)%") }, windowMenu: true)
                    NotchSegments(selection: $settings.lowSecond, options: [15, 10, 5].map { ($0, "\($0)%") }, windowMenu: true)
                        .disabled(!settings.lowAlerts)
                    NotchSwitch(isOn: $settings.lowAlerts)
                }
            }
            SettingsRow(tr("Full charge peek"), note: tr("At 100 % or at the charge limit")) {
                NotchSwitch(isOn: $settings.fullAlert)
            }
            SettingsRow(tr("Headphones peek"), note: tr("AirPods and other headphones as they connect, with battery")) {
                NotchSwitch(isOn: $settings.bluetoothPeeks)
            }
            PermissionLine(context: context, permission: .bluetooth, text: tr("Headphones need Bluetooth access"))
        }
    }
}

// MARK: Media

private struct MediaSection: View {
    let module: MediaModule
    let context: SurfaceContext

    static func sourceShort(_ s: MediaModel.Source) -> String {
        switch s {
        case .starting: tr("Checking…")
        case .adapter: tr("Every app")
        case .scripts: tr("Music, Spotify")
        }
    }

    static func sourceTitle(_ s: MediaModel.Source) -> String {
        switch s {
        case .starting: tr("Checking…")
        case .adapter: tr("Every app")
        case .scripts: tr("Music and Spotify")
        }
    }

    var body: some View {
        let source = module.model.source
        VStack(alignment: .leading, spacing: SettingsStyle.rowSpacing) {
            SettingsRow(tr("Source in use"), note: note(source)) {
                Text(verbatim: Self.sourceTitle(source))
                    .font(SettingsStyle.font(.m))
                    .foregroundStyle(source == .scripts ? SettingsStyle.waiting : SettingsStyle.secondary)
            }
            if source == .scripts {
                PermissionLine(context: context, permission: .automation, text: tr("Controls need Automation for Music or Spotify"))
            }
            SettingsNote(tr("Chosen at launch: the reader is tried first, the scripts take over if it fails."))
            LyricsSettingsRows(module: module)
        }
    }

    private func note(_ s: MediaModel.Source) -> String {
        switch s {
        case .starting: tr("Testing the now-playing reader")
        case .adapter: tr("Now-playing reader: browsers, Music, Spotify, any player")
        case .scripts: tr("Scripts: the reader isn't working on this Mac")
        }
    }
}

// MARK: Timer

private struct TimerSection: View {
    let module: TimerModule
    @State private var lengths = Pomodoro.lengths

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsStyle.rowSpacing) {
            SettingsGroupTitle(tr("Pomodoro"))
            SettingsRow(tr("Focus")) { stepper(\.focus) }
            SettingsRow(tr("Short break")) { stepper(\.shortBreak) }
            SettingsRow(tr("Long break"), note: tr("After the fourth focus round")) { stepper(\.longBreak) }
            HStack(alignment: .firstTextBaseline) {
                SettingsNote(tr("A round already running keeps its length."))
                if lengths != PomodoroLengths() {
                    NotchTextButton(tr("Reset")) { set(PomodoroLengths()) }
                        .controlSize(.small)
                }
            }
            TimerMoreSettingsView(module: module)
        }
    }

    private func stepper(_ key: WritableKeyPath<PomodoroLengths, Int>) -> some View {
        MinutesStepper(value: lengths[keyPath: key], range: PomodoroLengths.range) { v in
            var l = lengths
            l[keyPath: key] = v
            set(l)
        }
    }

    private func set(_ l: PomodoroLengths) {
        lengths = l
        module.setPomodoroLengths(l)
    }
}

// MARK: Clipboard

private struct ClipboardSection: View {
    let module: ClipboardModule
    let context: SurfaceContext
    @State private var system: Set<Hotkey> = []
    @State private var tick = 0

    var body: some View {
        @Bindable var settings = module.model.settings
        let _ = tick
        VStack(alignment: .leading, spacing: SettingsStyle.rowSpacing) {
            SettingsRow(tr("Shortcut"), note: tr("Opens the list with the keyboard")) {
                HotkeyField(id: "clipboard", hotkey: settings.hotkey, conflict: conflict(settings.hotkey)) { h in
                    module.setHotkey(h)
                    tick += 1
                }
            }
            SettingsRow(tr("Paste after choosing"), note: tr("Presses ⌘V in the app underneath")) {
                NotchSwitch(isOn: Binding(get: { settings.pasteAfterChoosing },
                                          set: { settings.pasteAfterChoosing = $0; module.pasteSettingChanged($0) }))
            }
            if settings.pasteAfterChoosing {
                PermissionLine(context: context, permission: .accessibility, text: tr("Pasting needs Accessibility"))
            }
            SettingsRow(tr("Pause history"), note: settings.paused ? tr("Nothing is being recorded") : nil) {
                NotchSwitch(isOn: $settings.paused)
            }
            SettingsRow(tr("History"), note: L10n.tr("%d items, up to 60", module.model.items.count)) {
                ConfirmButton(title: tr("Clear"), question: tr("Pinned too?"), confirm: tr("Clear"),
                              enabled: !module.model.items.isEmpty) { module.model.clearAll() }
            }
            SettingsGroupTitle(tr("Excluded apps"))
            if settings.excluded.isEmpty {
                SettingsNote(tr("None. Right-click an item in the list to never record from its app. Password managers are always skipped."))
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(settings.excluded.sorted { $0.value < $1.value }, id: \.key) { bundleID, name in
                        ExcludedChip(name: name) { module.model.include(bundleID: bundleID) }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .onAppear { system = HotkeyConflict.systemHotkeys() }
    }

    private func conflict(_ h: Hotkey) -> HotkeyConflict? {
        let all = GlancyHotkeys.bindings(context)
        let failed: Set<Hotkey> = module.hotkeyFailed ? [h] : []
        return HotkeyConflict.find(HotkeyBinding(id: "clipboard", title: tr("Clipboard"), hotkey: h), among: all, system: system, failed: failed)
    }
}

private struct ExcludedChip: View {
    let name: String
    let remove: () -> Void
    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: name).font(SettingsStyle.font(.s)).foregroundStyle(SettingsStyle.primary).lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(SettingsStyle.faint)
                    .frame(width: 16, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr("Record from this app again"))
        }
        .padding(.leading, 10).padding(.trailing, 4)
        .frame(height: 24)
        .background(Capsule().fill(SettingsStyle.card))
    }
}

// MARK: Windows

/// Every hotkey Glancy binds, for conflict checks across modules.
@MainActor
enum GlancyHotkeys {
    static func bindings(_ context: SurfaceContext) -> [HotkeyBinding] {
        var out: [HotkeyBinding] = []
        if let c = context.module(ClipboardModule.self), context.settings.isEnabled(.clipboard) {
            out.append(HotkeyBinding(id: "clipboard", title: tr("Clipboard"), hotkey: c.model.settings.hotkey))
        }
        if let n = context.module(NotesModule.self), context.settings.isEnabled(.notes) {
            out.append(n.hotkeyBinding)
            out.append(n.voiceHotkeyBinding)
        }
        if let h = context.module(HUDModule.self), context.settings.isEnabled(.hud), h.settings.micHotkey.modifiers != 0 {
            out.append(HotkeyBinding(id: "hud.mic", title: tr("Mute microphone"), hotkey: h.settings.micHotkey))
        }
        if let c = context.module(CalendarModule.self), context.settings.isEnabled(.calendar) {
            out.append(HotkeyBinding(id: "calendar.join", title: CalL10n.joinShortcut, hotkey: c.settings.joinHotkey))
        }
        if let c = context.module(CommandModule.self), context.settings.isEnabled(.command) {
            out.append(HotkeyBinding(id: "command", title: CommandText.t("Command bar"), hotkey: c.model.settings.hotkey))
        }
        if let w = context.module(WindowsModule.self), context.settings.isEnabled(.windows), w.hotkeys.enabled {
            for a in WindowsSection.actions + WindowsSection.arrangeActions {
                out.append(HotkeyBinding(id: a.id, title: tr(a.title), hotkey: w.hotkeys[keyPath: a.key]))
            }
            out += w.workspaceHotkeyBindings
        }
        return out
    }
}

private struct WindowsSection: View {
    let module: WindowsModule
    let context: SurfaceContext
    @State private var system: Set<Hotkey> = []
    @State private var tick = 0

    struct Action { let id: String; let title: String; let key: WritableKeyPath<WindowsHotkeys, Hotkey> }

    /// Auto-arrange first: the one command most people need (⇧ = the front app only).
    static let actions: [Action] = [
        Action(id: "windows.autoArrange", title: "Auto-arrange", key: \.autoArrange),
        Action(id: "windows.undo", title: "Undo", key: \.undo),
        Action(id: "windows.open", title: "Open the map", key: \.open),
        Action(id: "windows.leftHalf", title: "Left half", key: \.leftHalf),
        Action(id: "windows.rightHalf", title: "Right half", key: \.rightHalf),
        Action(id: "windows.maximize", title: "Maximize", key: \.maximize),
        Action(id: "windows.restore", title: "Restore", key: \.restore),
        Action(id: "windows.fit", title: "Fill empty space", key: \.fit),
    ]

    /// "More shortcuts": arrange the display under the pointer with a fixed strategy, committed at
    /// once (⇧ = the front app only).
    static let arrangeActions: [Action] = [
        Action(id: "windows.arrangeBalanced", title: "Arrange: Balanced", key: \.arrangeBalanced),
        Action(id: "windows.arrangeColumns", title: "Arrange: Columns", key: \.arrangeColumns),
        Action(id: "windows.arrangeRows", title: "Arrange: Rows", key: \.arrangeRows),
        Action(id: "windows.arrangeMaster", title: "Arrange: Master + stack", key: \.arrangeMaster),
        Action(id: "windows.arrangeCells", title: "Arrange: One per cell", key: \.arrangeCells),
    ]

    static func summary(_ h: WindowsHotkeys) -> String {
        L10n.tr("%d shortcuts", (actions + arrangeActions).filter { h[keyPath: $0.key].modifiers != 0 }.count)
    }

    var body: some View {
        let _ = tick
        let hotkeys = module.hotkeys
        let all = GlancyHotkeys.bindings(context)
        let failed = Set((Self.actions + Self.arrangeActions).map { hotkeys[keyPath: $0.key] }
            .filter { module.failedHotkeys.contains($0.description) })
        VStack(alignment: .leading, spacing: SettingsStyle.rowSpacing) {
            PermissionLine(context: context, permission: .accessibility, text: tr("Moving windows needs Accessibility"))
            SettingsRow(tr("Shortcuts"), note: tr("Halves cycle ½ → ⅔ → ⅓ on repeat")) {
                NotchSwitch(isOn: Binding(get: { hotkeys.enabled }, set: { on in
                    var h = module.hotkeys; h.enabled = on; module.setHotkeys(h); tick += 1
                }))
            }
            Group {
                SettingsNote(WindowsText.f("Auto-arrange: the display under the pointer, at once · ⇧ = only the front app · undo %@",
                                           hotkeys.undo.description))
                grid(Self.actions, hotkeys: hotkeys, all: all, failed: failed)
                SettingsGroupTitle(WindowsText.t("More shortcuts"))
                SettingsNote(WindowsText.t("Arrange the display under the pointer with a fixed strategy · ⇧ = only the front app"))
                grid(Self.arrangeActions, hotkeys: hotkeys, all: all, failed: failed)
            }
            .disabled(!hotkeys.enabled)
            WorkspacesSettings(module: module) { id, key in
                HotkeyConflict.find(HotkeyBinding(id: id, title: "", hotkey: key), among: GlancyHotkeys.bindings(context),
                                    system: system, failed: Set([key].filter { module.failedHotkeys.contains($0.description) }))
            }
        }
        .onAppear { system = HotkeyConflict.systemHotkeys() }
    }

    /// One row per action (the window is narrower than the notch's two columns).
    @ViewBuilder
    private func grid(_ actions: [Action], hotkeys: WindowsHotkeys, all: [HotkeyBinding], failed: Set<Hotkey>) -> some View {
        ForEach(actions, id: \.id) { a in
            let key = hotkeys[keyPath: a.key]
            SettingsRow(tr(a.title)) {
                HotkeyField(id: a.id, hotkey: key,
                            conflict: HotkeyConflict.find(HotkeyBinding(id: a.id, title: tr(a.title), hotkey: key),
                                                          among: all, system: system, failed: failed)) { new in
                    var h = module.hotkeys
                    h[keyPath: a.key] = new
                    module.setHotkeys(h)
                    tick += 1
                }
            }
        }
    }
}

