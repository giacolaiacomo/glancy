import AppKit
import SwiftUI

// Settings → Calendar, "Meetings": Focus during meetings (with the one-time Shortcuts setup card),
// the end-of-meeting warning and the Join shortcut. Settings → Timer reuses the setup card.

enum FocusText {
    static func t(_ en: String, _ it: String) -> String { CalL10n.t(en, it) }
    static var setupTitle: String { t("Set up once", "Da fare una volta") }
    static var setupBody: String {
        t("macOS lets apps change Focus only through Shortcuts: make these two there (click a name to copy it). Any Focus works; use the same in both.",
          "macOS fa cambiare la full immersion solo tramite Comandi Rapidi: crea lì questi due (clic sul nome per copiarlo). Va bene qualsiasi full immersion, la stessa in entrambi.")
    }
    static var onAction: String { t("Set Focus → Do Not Disturb → Turn On", "Imposta full immersion → Non disturbare → Attiva") }
    static var offAction: String { t("Set Focus → Do Not Disturb → Turn Off", "Imposta full immersion → Non disturbare → Disattiva") }
    static var newShortcut: String { t("New shortcut", "Nuovo comando") }
    static var checkAgain: String { t("Check again", "Controlla di nuovo") }
    static var checking: String { t("Looking for the shortcuts…", "Cerco i comandi rapidi…") }
    static var ready: String { t("Shortcuts found: ready", "Comandi rapidi trovati: pronto") }
    static func missing(_ names: [String]) -> String { t("Not found: ", "Non trovati: ") + names.joined(separator: ", ") }
    static var unavailable: String { t("Couldn't read your shortcuts", "Impossibile leggere i comandi rapidi") }
    static var runFailed: String { t("The last run failed: check the shortcuts", "L'ultima esecuzione non è riuscita: controlla i comandi") }
    static var copied: String { t("Copied", "Copiato") }
}

/// Settings → Calendar, above the calendar list: Focus, the end warning, the Join shortcut.
struct MeetingSettingsView: View {
    let module: CalendarModule
    let context: SurfaceContext
    @State private var system: Set<Hotkey> = []
    @State private var tick = 0

    var body: some View {
        @Bindable var settings = module.settings
        let _ = tick
        VStack(alignment: .leading, spacing: SettingsStyle.rowSpacing) {
            SettingsRow(CalL10n.focusSwitch, note: CalL10n.focusNote) {
                NotchSegments(selection: Binding(get: { settings.focusDuringMeetings ? settings.focusTrigger : nil },
                                                 set: { v in
                                                     if let v { settings.focusTrigger = v }
                                                     settings.focusDuringMeetings = v != nil
                                                 }),
                              options: [(nil, CalL10n.off), (.calls, CalL10n.withLink), (.busy, CalL10n.anyBusy)])
            }
            if settings.focusDuringMeetings, let focus = module.focus {
                FocusSetupCard(focus: focus)
                    .padding(.bottom, 6)
            }
            SettingsRow(CalL10n.endWarning, note: CalL10n.endWarningNote) {
                NotchSegments(selection: $settings.endWarningMinutes,
                              options: MeetingEndLogic.warningChoices.map { ($0, $0 == 0 ? CalL10n.off : "\($0)′") })
            }
            SettingsRow(CalL10n.joinShortcut, note: CalL10n.joinShortcutNote) {
                HotkeyField(id: "calendar.join", hotkey: settings.joinHotkey, conflict: conflict(settings.joinHotkey)) { h in
                    settings.joinHotkey = h
                    tick += 1
                }
            }
            SettingsGroupTitle(CalL10n.calendarsTitle).padding(.top, 8)
        }
        .onAppear { system = HotkeyConflict.systemHotkeys() }
    }

    private func conflict(_ h: Hotkey) -> HotkeyConflict? {
        let failed: Set<Hotkey> = module.hotkeyFailed ? [h] : []
        return HotkeyConflict.find(HotkeyBinding(id: "calendar.join", title: CalL10n.joinShortcut, hotkey: h),
                                   among: GlancyHotkeys.bindings(context), system: system, failed: failed)
    }
}

/// Whether Glancy can drive Focus; when not, how to set it up. Checks once when shown.
struct FocusSetupCard: View {
    let focus: FocusController
    @State private var copied: String?

    var body: some View {
        Group {
            if focus.setup == .ready && !focus.lastRunFailed {
                HStack(spacing: 6) {
                    Circle().fill(SettingsStyle.done).frame(width: 6, height: 6)
                    Text(verbatim: FocusText.ready).font(SettingsStyle.font(.xs)).foregroundStyle(SettingsStyle.secondary)
                    Spacer(minLength: 6)
                    NotchTextButton(FocusText.checkAgain) { focus.checkSetup() }
                }
                .frame(minHeight: 24)
                .padding(.vertical, 2)
            } else {
                card
            }
        }
        .onAppear { if focus.setup == .unknown { focus.checkSetup() } }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "moon.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(SettingsStyle.waiting)
                Text(verbatim: FocusText.setupTitle).font(SettingsStyle.font(.s, .semibold)).foregroundStyle(SettingsStyle.primary).lineLimit(1)
                Text(verbatim: status).font(SettingsStyle.font(.xs)).foregroundStyle(statusColor).lineLimit(1)
                Spacer(minLength: 6)
                NotchTextButton(FocusText.newShortcut) { FocusController.openShortcutsEditor() }
                NotchTextButton(FocusText.checkAgain) { focus.checkSetup() }
            }
            step(1, FocusController.onShortcut, FocusText.onAction)
            step(2, FocusController.offShortcut, FocusText.offAction)
            Text(verbatim: FocusText.setupBody).font(SettingsStyle.font(.xs)).foregroundStyle(SettingsStyle.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SettingsStyle.waiting.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SettingsStyle.waiting.opacity(0.3), lineWidth: 1))
    }

    private func step(_ n: Int, _ name: String, _ action: String) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: "\(n)").font(SettingsStyle.font(.xs, .bold)).foregroundStyle(.white)
                .frame(width: 16, height: 16).background(Circle().fill(Color.accentColor))
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(name, forType: .string)
                copied = name
            } label: {
                HStack(spacing: 4) {
                    Text(verbatim: name).font(SettingsStyle.font(.s, .semibold)).foregroundStyle(SettingsStyle.primary)
                    Image(systemName: copied == name ? "checkmark" : "doc.on.doc").font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(SettingsStyle.tertiary)
                }
                .padding(.horizontal, 7).frame(height: 18)
                .background(Capsule().fill(SettingsStyle.card))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(copied == name ? FocusText.copied : name)
            Text(verbatim: action).font(SettingsStyle.font(.xs)).foregroundStyle(SettingsStyle.secondary).lineLimit(1)
        }
    }

    private var status: String {
        if focus.lastRunFailed { return FocusText.runFailed }
        switch focus.setup {
        case .unknown, .checking: return FocusText.checking
        case .ready: return FocusText.ready
        case .missing(let names): return FocusText.missing(names)
        case .unavailable: return FocusText.unavailable
        }
    }

    private var statusColor: Color {
        switch focus.setup {
        case .ready: SettingsStyle.done
        case .unknown, .checking: SettingsStyle.tertiary
        default: SettingsStyle.waiting
        }
    }
}

/// Settings → Timer, under the Pomodoro lengths.
struct TimerMoreSettingsView: View {
    let module: TimerModule

    var body: some View {
        @Bindable var settings = module.settings
        VStack(alignment: .leading, spacing: SettingsStyle.rowSpacing) {
            SettingsRow(L10n.tr("Start the next phase automatically"), note: L10n.tr("Otherwise each phase waits for Start")) {
                NotchSwitch(isOn: $settings.autoStartNext)
            }
            if module.focus != nil {
                SettingsRow(L10n.tr("Focus during focus rounds"), note: L10n.tr("Uses the Glancy Focus shortcuts")) {
                    NotchSwitch(isOn: $settings.focusDuringWork)
                }
                if settings.focusDuringWork, let focus = module.focus { FocusSetupCard(focus: focus).padding(.vertical, 6) }
            }
        }
    }
}
