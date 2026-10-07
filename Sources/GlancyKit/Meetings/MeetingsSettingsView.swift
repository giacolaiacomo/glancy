import AppKit
import SwiftUI

/// Settings → Meetings: when to ask, the transcript's language, Notes, the three permissions,
/// the folder. A plain module section (ModuleSections), wherever Settings is shown.
struct MeetingsSection: View {
    let module: MeetingsModule
    let context: SurfaceContext
    @State private var tick = 0
    @State private var count: Int?

    var body: some View {
        let _ = tick
        let settings = module.settings
        VStack(alignment: .leading, spacing: SettingsStyle.rowSpacing) {
            SettingsRow(L10n.tr("When a call starts")) {
                NotchSegments(selection: Binding(get: { settings.mode }, set: { settings.mode = $0; tick += 1 }),
                              options: [(.ask, L10n.tr("Ask")), (.always, L10n.tr("Always")), (.off, L10n.tr("Off"))])
            }
            SettingsNote(modeNote(settings.mode))
            SettingsRow(L10n.tr("Transcript language")) {
                NotchSegments(selection: Binding(get: { settings.language }, set: { settings.language = $0; tick += 1 }),
                              options: [(.app, L10n.tr("App language")), (.en, "English"), (.it, "Italiano")])
            }
            let notesOn = context.settings.isEnabled(.notes)
            SettingsRow(L10n.tr("Save transcripts to Notes"),
                        note: notesOn ? L10n.tr("A note for each meeting") : L10n.tr("Turn the Notes module on to use this"),
                        noteColor: notesOn ? SettingsStyle.tertiary : SettingsStyle.waiting) {
                NotchSwitch(isOn: Binding(get: { settings.saveToNotes }, set: { settings.saveToNotes = $0; tick += 1 }), enabled: notesOn)
            }
            SettingsGroupTitle(L10n.tr("Permissions")).padding(.top, 8)
            AccessRow(title: L10n.tr("Microphone"), purpose: L10n.tr("Your voice"), status: module.permissions.mic(),
                      pane: .microphone) { await module.permissions.requestMic() } done: { tick += 1 }
            AccessRow(title: L10n.tr("System audio"), purpose: L10n.tr("The others' voices, as the Mac plays them"),
                      status: module.permissions.systemAudio(), pane: .systemAudio) {
                await module.permissions.requestSystemAudio()
            } done: { tick += 1 }
            if module.system.transcriber.needsSpeechPermission {
                AccessRow(title: L10n.tr("Speech Recognition"), purpose: L10n.tr("Turns the audio into text, on this Mac"),
                          status: speechAccess, pane: .speech) { await module.permissions.requestSpeech() } done: { tick += 1 }
            } else {
                SettingsRow(L10n.tr("Speech Recognition"), note: L10n.tr("Turns the audio into text, on this Mac")) {
                    Text(verbatim: L10n.tr("Not needed on this Mac")).font(SettingsStyle.font(.s)).foregroundStyle(SettingsStyle.tertiary)
                }
            }
            SettingsRow(L10n.tr("Folder"), note: count.map { L10n.tr("%d recordings", $0) }) {
                NotchTextButton(L10n.tr("Show in Finder")) { module.reveal() }
            }
            SettingsNote(L10n.tr("Stops by itself 30 s after the call lets go of the microphone, or 10 min after a calendar meeting's end once it's quiet."))
            SettingsNote(L10n.tr("Audio and transcripts stay on this Mac: speech is turned into text here, nothing is sent anywhere. Laws on recording differ: always tell the others."))
        }
        .task { await countRecordings() }
    }

    private var speechAccess: MicAccess {
        switch module.permissions.speech() {
        case .granted: .granted
        case .denied: .denied
        case .notDetermined: .notDetermined
        }
    }

    private func modeNote(_ m: MeetingsMode) -> String {
        switch m {
        case .ask: L10n.tr("A card asks \"Record this meeting?\" when Zoom, Teams, Webex, FaceTime or Slack takes the microphone, or a browser does during a calendar meeting with a link.")
        case .always: L10n.tr("Always: calendar meetings start recording by themselves (a drop-down says so); other calls ask.")
        case .off: L10n.tr("Off: no listening at all; Record in the tab still works.")
        }
    }

    /// The folders on disk (off the main thread), or the list already read.
    private func countRecordings() async {
        if module.model.loaded { count = module.model.records.count; return }
        let store = module.store
        count = await store.loadAll().count
    }
}

extension MeetingsModule {
    /// Settings → Meetings on its own (glancy-render draws it at its full height: the panel shows
    /// only its top).
    public func settingsSection(_ context: SurfaceContext) -> some View { MeetingsSection(module: self, context: context) }
}

/// "Microphone · Your voice — Allowed / Allow… / Open Settings".
private struct AccessRow: View {
    let title: String
    let purpose: String
    let status: MicAccess
    let pane: PermissionKind
    let request: () async -> Bool
    let done: () -> Void

    var body: some View {
        SettingsRow(title, note: status == .denied ? L10n.tr("Off in System Settings") : purpose,
                    noteColor: status == .granted ? SettingsStyle.tertiary : SettingsStyle.waiting) {
            switch status {
            case .granted:
                HStack(spacing: 4) {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(SettingsStyle.done)
                    Text(verbatim: L10n.tr("Allowed")).font(SettingsStyle.font(.s)).foregroundStyle(SettingsStyle.secondary)
                }
            case .notDetermined:
                NotchTextButton(L10n.tr("Allow…")) {
                    Task { @MainActor in
                        _ = await request()
                        done()
                    }
                }
            case .denied:
                NotchTextButton(L10n.tr("Open Settings")) { NSWorkspace.shared.open(PermissionCenter.settingsURL(pane)) }
            }
        }
    }
}
