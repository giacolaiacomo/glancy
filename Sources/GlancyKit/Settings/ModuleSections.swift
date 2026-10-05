import AppKit
import SwiftUI

/// What the index says about each section, and which modules have one.
@MainActor
enum SettingsCatalog {
    static func hasSection(_ id: ModuleID) -> Bool {
        [.agents, .calendar, .media, .timer, .shelf, .clipboard, .windows, .hud, .power].contains(id)
    }

    static func generalSummary(_ s: AppSettings) -> String {
        let open = s.openModel == .click ? tr("Click") : tr("Hover")
        let lang = switch s.language { case .system: tr("System"); case .en: "English"; case .it: "Italiano" }
        return "\(open) · \(lang)"
    }

    /// One line for a module's tile.
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
            return FileManager.default.fileExists(atPath: AgentsModule.defaultLogURL.path) ? tr("Hook log found") : tr("No hook log")
        case .notifications, .command, .control, .notes:
            return ""
        }
    }

    /// One line under each module in Settings → Modules.
    static func purpose(_ id: ModuleID) -> String {
        switch id {
        case .agents: "Claude Code sessions"
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
        }
    }
}

/// A module's own settings, under a header with its on/off switch.
struct ModuleSection: View {
    let context: SurfaceContext
    let id: ModuleID

    var body: some View {
        let on = context.settings.isEnabled(id)
        VStack(alignment: .leading, spacing: 4) {
            SettingsHeader(context: context, title: tr(SurfaceContext.name(id))) {
                if context.modules.contains(where: { $0.id == id }) {
                    NotchSwitch(isOn: Binding(get: { on }, set: { context.setModuleEnabled(id, $0) }))
                        .help(on ? tr("Turn off") : tr("Turn on"))
                }
            }
            content
                .opacity(on ? 1 : 0.5)
        }
    }

    @ViewBuilder private var content: some View {
        switch id {
        case .calendar: if let m = context.module(CalendarModule.self) { CalendarSection(module: m, context: context) }
        case .hud: if let m = context.module(HUDModule.self) { HUDSection(module: m, context: context) }
        case .power: if let m = context.module(PowerModule.self) { PowerSection(module: m, context: context) }
        case .media: if let m = context.module(MediaModule.self) { MediaSection(module: m, context: context) }
        case .timer: if let m = context.module(TimerModule.self) { TimerSection(module: m) }
        case .shelf: if let m = context.module(ShelfModule.self) { ShelfSection(module: m) }
        case .clipboard: if let m = context.module(ClipboardModule.self) { ClipboardSection(module: m, context: context) }
        case .windows: if let m = context.module(WindowsModule.self) { WindowsSection(module: m, context: context) }
        case .agents: AgentsSection()
        case .notifications, .command, .control, .notes: EmptyView()
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
            HStack(spacing: 6) {
                Circle().fill(Theme.waiting).frame(width: 6, height: 6)
                Text(verbatim: text).font(Theme.font(.xs)).foregroundStyle(Theme.secondary).lineLimit(1)
                Spacer(minLength: 6)
                NotchTextButton(status == .denied ? tr("Open Settings") : tr("Allow…")) { center.request(permission) }
            }
            .frame(minHeight: 24)
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
        VStack(alignment: .leading, spacing: 5) {
            PermissionLine(context: context, permission: .calendar, text: tr("Glancy can't read your calendars yet"))
            if calendars.isEmpty {
                SettingsNote(module.model.access == .granted ? tr("No calendars on this Mac.") : tr("Calendars show up here once access is allowed."))
            } else {
                let accounts = Dictionary(grouping: calendars, by: \.source)
                ForEach(accounts.keys.sorted(), id: \.self) { account in
                    HStack(alignment: .top, spacing: 8) {
                        Text(verbatim: account.isEmpty ? tr("Other") : account)
                            .font(Theme.font(.s))
                            .foregroundStyle(Theme.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(width: 120, height: 22, alignment: .leading)
                        FlowLayout(spacing: 4) {
                            ForEach(accounts[account] ?? []) { cal in
                                CalendarChip(info: cal, on: settings.isSelected(cal.id)) {
                                    settings.setSelected(cal.id, !settings.isSelected(cal.id))
                                }
                            }
                        }
                    }
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
            HStack(spacing: 5) {
                Circle()
                    .fill(on ? info.color.color : .clear)
                    .overlay(Circle().strokeBorder(info.color.color, lineWidth: 1.5))
                    .frame(width: 8, height: 8)
                Text(verbatim: info.title)
                    .font(Theme.font(.s, on ? .medium : .regular))
                    .foregroundStyle(on ? Theme.primary : Theme.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(on ? Color.white.opacity(0.12) : .clear))
            .overlay(Capsule().strokeBorder(on ? .clear : Theme.hairline, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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
        VStack(alignment: .leading, spacing: 4) {
            PermissionLine(context: context, permission: .accessibility, text: tr("Needs Accessibility to take over the keys"))
            SettingsRow(tr("Show in the notch"), note: tr("Replaces the system HUD for the keys below")) {
                NotchSwitch(isOn: $settings.enabled)
            }
            SettingsRow(tr("Keys")) {
                HStack(spacing: 4) {
                    ForEach(Self.kinds, id: \.0) { kind, title, symbol in
                        NotchChip(symbol: symbol, title: tr(title), on: settings.handles(kind)) {
                            settings.set(kind, !settings.handles(kind))
                        }
                    }
                }
                .opacity(settings.enabled ? 1 : 0.4)
                .disabled(!settings.enabled)
            }
            SettingsNote(tr("Keys left out keep the system HUD. ⌥⇧ still steps by quarters."))
            HStack(alignment: .top, spacing: 22) {
                SettingsRow(tr("Mute microphone shortcut"), note: tr("Mutes or unmutes the default microphone")) {
                    HotkeyField(id: "hud.mic", hotkey: settings.micHotkey, conflict: conflict(settings.micHotkey)) { h in
                        module.setMicHotkey(h)
                        tick += 1
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                SettingsRow(tr("Microphone and camera in use"), note: tr("A red dot in the notch while an app records")) {
                    NotchSwitch(isOn: $settings.showInUse)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
        VStack(alignment: .leading, spacing: 4) {
            SettingsRow(tr("Battery in the notch"), note: tr("Plugging in, unplugging, Low Power Mode")) {
                NotchSwitch(isOn: $settings.batteryActivities)
            }
            SettingsRow(tr("Low battery peek"), note: tr("On battery, once per discharge")) {
                HStack(spacing: 6) {
                    NotchSegments(selection: $settings.lowFirst, options: [30, 25, 20, 15].map { ($0, "\($0)%") })
                    NotchSegments(selection: $settings.lowSecond, options: [15, 10, 5].map { ($0, "\($0)%") })
                        .opacity(settings.lowAlerts ? 1 : 0.4)
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
        VStack(alignment: .leading, spacing: 4) {
            SettingsRow(tr("Source in use"), note: note(source)) {
                Text(verbatim: Self.sourceTitle(source))
                    .font(Theme.font(.s, .medium))
                    .foregroundStyle(source == .scripts ? Theme.waiting : Theme.secondary)
            }
            if source == .scripts {
                PermissionLine(context: context, permission: .automation, text: tr("Controls need Automation for Music or Spotify"))
            }
            SettingsNote(tr("Chosen at launch: the reader is tried first, the scripts take over if it fails."))
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
        VStack(alignment: .leading, spacing: 4) {
            SettingsRow(tr("Focus")) { stepper(\.focus) }
            SettingsRow(tr("Short break")) { stepper(\.shortBreak) }
            SettingsRow(tr("Long break"), note: tr("After the fourth focus round")) { stepper(\.longBreak) }
            HStack {
                SettingsNote(tr("A round already running keeps its length."))
                Spacer()
                if lengths != PomodoroLengths() {
                    NotchTextButton(tr("Reset")) { set(PomodoroLengths()) }
                }
            }
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

// MARK: Shelf

private struct ShelfSection: View {
    let module: ShelfModule

    var body: some View {
        let count = module.model.items.count
        VStack(alignment: .leading, spacing: 4) {
            SettingsRow(tr("On the shelf"), note: count == 0 ? tr("Nothing parked") : L10n.tr("%d items", count)) {
                ConfirmButton(title: tr("Clear"), question: L10n.tr("Remove %d items?", count), confirm: tr("Clear"),
                              enabled: count > 0) { module.clear() }
            }
            SettingsNote(tr("Your files stay where they are; copies Glancy made (text, links, mail attachments) are deleted."))
            SettingsNote(L10n.tr("Holds up to %d items, kept across restarts.", ShelfStore.limit))
        }
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    SettingsRow(tr("Pause history"), note: settings.paused ? tr("Nothing is being recorded") : nil) {
                        NotchSwitch(isOn: $settings.paused)
                    }
                    SettingsRow(tr("Paste after choosing"), note: tr("Presses ⌘V in the app underneath")) {
                        NotchSwitch(isOn: Binding(get: { settings.pasteAfterChoosing },
                                                  set: { settings.pasteAfterChoosing = $0; module.pasteSettingChanged($0) }))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    SettingsRow(tr("Shortcut"), note: tr("Opens the list with the keyboard")) {
                        HotkeyField(id: "clipboard", hotkey: settings.hotkey, conflict: conflict(settings.hotkey)) { h in
                            module.setHotkey(h)
                            tick += 1
                        }
                    }
                    SettingsRow(tr("History"), note: L10n.tr("%d items, up to 60", module.model.items.count)) {
                        ConfirmButton(title: tr("Clear"), question: tr("Pinned too?"), confirm: tr("Clear"),
                                      enabled: !module.model.items.isEmpty) { module.model.clearAll() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if settings.pasteAfterChoosing {
                PermissionLine(context: context, permission: .accessibility, text: tr("Pasting needs Accessibility"))
            }
            VStack(alignment: .leading, spacing: 3) {
                SettingsGroupTitle(tr("Excluded apps"))
                if settings.excluded.isEmpty {
                    SettingsNote(tr("None. Right-click an item in the list to never record from its app. Password managers are always skipped."))
                } else {
                    FlowLayout(spacing: 4) {
                        ForEach(settings.excluded.sorted { $0.value < $1.value }, id: \.key) { bundleID, name in
                            ExcludedChip(name: name) { module.model.include(bundleID: bundleID) }
                        }
                    }
                }
            }
            .padding(.top, 2)
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
            Text(verbatim: name).font(Theme.font(.s)).foregroundStyle(Theme.primary).lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.tertiary)
                    .frame(width: 14, height: 14).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr("Record from this app again"))
        }
        .padding(.leading, 8).padding(.trailing, 4)
        .frame(height: 22)
        .background(Capsule().fill(Theme.card))
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
        if let h = context.module(HUDModule.self), context.settings.isEnabled(.hud), h.settings.micHotkey.modifiers != 0 {
            out.append(HotkeyBinding(id: "hud.mic", title: tr("Mute microphone"), hotkey: h.settings.micHotkey))
        }
        if let w = context.module(WindowsModule.self), context.settings.isEnabled(.windows), w.hotkeys.enabled {
            for a in WindowsSection.actions + WindowsSection.arrangeActions {
                out.append(HotkeyBinding(id: a.id, title: tr(a.title), hotkey: w.hotkeys[keyPath: a.key]))
            }
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
        Action(id: "windows.fit", title: "Largest free space", key: \.fit),
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
        VStack(alignment: .leading, spacing: 4) {
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
                    .padding(.top, 8)
                SettingsNote(WindowsText.t("Arrange the display under the pointer with a fixed strategy · ⇧ = only the front app"))
                grid(Self.arrangeActions, hotkeys: hotkeys, all: all, failed: failed)
            }
            .opacity(hotkeys.enabled ? 1 : 0.4)
            .disabled(!hotkeys.enabled)
        }
        .onAppear { system = HotkeyConflict.systemHotkeys() }
    }

    private func grid(_ actions: [Action], hotkeys: WindowsHotkeys, all: [HotkeyBinding], failed: Set<Hotkey>) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 22), GridItem(.flexible())], alignment: .leading, spacing: 2) {
            ForEach(actions, id: \.id) { a in
                let key = hotkeys[keyPath: a.key]
                SettingsRow(tr(a.title), minHeight: 24) {
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
}

// MARK: Agents

private struct AgentsSection: View {
    var body: some View {
        let url = AgentsModule.defaultLogURL
        let exists = FileManager.default.fileExists(atPath: url.path)
        VStack(alignment: .leading, spacing: 4) {
            SettingsRow(tr("Hook log"), note: exists ? tr("Read-only; Glancy never writes to it") : tr("Not found: install the cc-dashboard hook"),
                        noteColor: exists ? Theme.tertiary : Theme.waiting) {
                if exists {
                    NotchTextButton(tr("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            }
            Text(verbatim: (url.path as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.card))
            SettingsNote(tr("A session goes idle after 30 min without events; sessions silent for 12 h are dropped."))
        }
    }
}
