import AppKit
import SwiftUI

/// Settings → Notes: the quick-note shortcut and where the files live.
struct NotesSettingsSection: View {
    let module: NotesModule
    let context: SurfaceContext
    @State private var system: Set<Hotkey> = []
    @State private var tick = 0
    @State private var speech: SpeechAccess = .notDetermined
    @State private var onDevice = true

    var body: some View {
        let _ = tick
        let settings = module.model.settings
        let folder = module.model.store.directory
        VStack(alignment: .leading, spacing: SettingsStyle.rowSpacing) {
            SettingsRow(L10n.tr("Quick note"), note: L10n.tr("Opens the tab with the cursor in a note")) {
                HotkeyField(id: "notes.quick", hotkey: settings.hotkey, conflict: conflict(settings.hotkey)) { h in
                    module.setHotkey(h)
                    tick += 1
                }
            }
            SettingsNote(L10n.tr("The last note if edited in the past 15 minutes, otherwise a new one."))
            SettingsRow(L10n.tr("Folder"), note: L10n.tr("%d notes, plain text (.md)", module.model.notes.count)) {
                NotchTextButton(L10n.tr("Show in Finder")) {
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
            }
            SettingsNote(L10n.tr("Saved as you type. \"- [ ] \" makes a box you can tick; pin a note to see it on Home."))
            SettingsGroupTitle(L10n.tr("Voice notes")).padding(.top, 8)
            SettingsRow(L10n.tr("Voice note"), note: L10n.tr("Starts and stops a recording from anywhere")) {
                HotkeyField(id: "notes.voice", hotkey: settings.voiceHotkey, conflict: voiceConflict(settings.voiceHotkey)) { h in
                    module.setVoiceHotkey(h)
                    tick += 1
                }
            }
            SettingsRow(L10n.tr("Transcribe"), note: transcribeNote, noteColor: speech == .denied || !onDevice ? SettingsStyle.waiting : SettingsStyle.tertiary) {
                NotchSwitch(isOn: Binding(get: { settings.transcribe }, set: { settings.transcribe = $0; tick += 1 }),
                            enabled: speech != .denied && onDevice)
            }
            if speech == .denied {
                HStack {
                    Spacer()
                    NotchTextButton(L10n.tr("Open Settings")) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")!)
                    }
                }
            }
            SettingsRow(L10n.tr("Longest recording")) {
                NotchSegments(selection: Binding(get: { settings.maxMinutes }, set: { settings.maxMinutes = $0; tick += 1 }),
                              options: NotesSettings.maxMinutesChoices.map { ($0, L10n.tr("%d min", $0)) })
            }
            SettingsNote(L10n.tr("Recordings are saved as .m4a next to the notes. Speech is turned into text on this Mac; nothing is sent anywhere."))
        }
        .onAppear {
            system = HotkeyConflict.systemHotkeys()
            speech = module.voice.transcriber.status()
            onDevice = module.voice.transcriber.availableOnDevice(VoiceLocale.current(italian: L10n.isItalian))
        }
    }

    private var transcribeNote: String {
        if speech == .denied { return L10n.tr("Speech Recognition is off in System Settings") }
        if !onDevice { return L10n.tr("Not available on this Mac for this language") }
        return L10n.tr("On this Mac, after each recording")
    }

    private func voiceConflict(_ h: Hotkey) -> HotkeyConflict? {
        let failed: Set<Hotkey> = module.voiceHotkeyFailed ? [h] : []
        return HotkeyConflict.find(HotkeyBinding(id: "notes.voice", title: module.voiceHotkeyBinding.title, hotkey: h),
                                   among: GlancyHotkeys.bindings(context), system: system, failed: failed)
    }

    private func conflict(_ h: Hotkey) -> HotkeyConflict? {
        let failed: Set<Hotkey> = module.hotkeyFailed ? [h] : []
        return HotkeyConflict.find(HotkeyBinding(id: "notes.quick", title: module.hotkeyBinding.title, hotkey: h),
                                   among: GlancyHotkeys.bindings(context), system: system, failed: failed)
    }
}
