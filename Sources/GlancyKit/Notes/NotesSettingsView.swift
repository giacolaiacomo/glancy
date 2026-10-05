import AppKit
import SwiftUI

/// Settings → Notes: the quick-note shortcut and where the files live.
struct NotesSettingsSection: View {
    let module: NotesModule
    let context: SurfaceContext
    @State private var system: Set<Hotkey> = []
    @State private var tick = 0

    var body: some View {
        let _ = tick
        let settings = module.model.settings
        let folder = module.model.store.directory
        VStack(alignment: .leading, spacing: 4) {
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
        }
        .onAppear { system = HotkeyConflict.systemHotkeys() }
    }

    private func conflict(_ h: Hotkey) -> HotkeyConflict? {
        let failed: Set<Hotkey> = module.hotkeyFailed ? [h] : []
        return HotkeyConflict.find(HotkeyBinding(id: "notes.quick", title: module.hotkeyBinding.title, hotkey: h),
                                   among: GlancyHotkeys.bindings(context), system: system, failed: failed)
    }
}
