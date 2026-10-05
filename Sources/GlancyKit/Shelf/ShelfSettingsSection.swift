import AppKit
import SwiftUI

/// Settings → Shelf.
struct ShelfSettingsSection: View {
    let module: ShelfModule

    var body: some View {
        @Bindable var settings = module.settings
        let model = module.model
        let count = model.items.count
        VStack(alignment: .leading, spacing: 4) {
            SettingsRow(L10n.tr("Drop targets"), note: L10n.tr("AirDrop, Share and Zip beside the shelf while you drag files")) {
                NotchSwitch(isOn: $settings.dropTargets)
            }
            SettingsRow(L10n.tr("Screenshots"), note: L10n.tr("New screenshots drop down from the notch")) {
                NotchSwitch(isOn: $settings.screenshots)
            }
            if settings.screenshots {
                FolderLine(status: model.screenshotsStatus, folder: model.screenshotsFolder)
                SettingsRow(L10n.tr("Also keep them on the shelf")) {
                    NotchSwitch(isOn: $settings.screenshotsToShelf)
                }
            }
            SettingsRow(L10n.tr("Finished downloads"), note: L10n.tr("A drop-down when a file in Downloads is complete")) {
                NotchSwitch(isOn: $settings.downloads)
            }
            if settings.downloads {
                FolderLine(status: model.downloadsStatus, folder: module.folders.downloads)
            }
            SettingsRow(L10n.tr("On the shelf"), note: count == 0 ? L10n.tr("Nothing parked") : L10n.tr("%d items", count)) {
                ConfirmButton(title: L10n.tr("Clear"), question: L10n.tr("Remove %d items?", count), confirm: L10n.tr("Clear"),
                              enabled: count > 0) { module.clear() }
            }
            SettingsNote(L10n.tr("Your files stay where they are; copies Glancy made (text, links, mail attachments) are deleted."))
            SettingsNote(L10n.tr("Holds up to %d items, kept across restarts.", ShelfStore.limit))
        }
    }
}

/// Which folder is watched, or why it isn't (macOS refused it: Files and Folders privacy).
private struct FolderLine: View {
    let status: ShelfFolderStatus
    let folder: URL?

    var body: some View {
        if let folder, status != .off {
            let name = FileManager.default.displayName(atPath: folder.path)
            HStack(spacing: 6) {
                Circle().fill(status == .watching ? Theme.done : Theme.waiting).frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: text(name)).font(Theme.font(.xs)).foregroundStyle(Theme.secondary).lineLimit(1)
                    if status == .denied {
                        Text(verbatim: L10n.tr("Allow it in Privacy & Security › Files and Folders."))
                            .font(Theme.font(.xs)).foregroundStyle(Theme.tertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if status == .denied {
                    NotchTextButton(L10n.tr("Open Settings")) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            .frame(minHeight: 20)
            .padding(.leading, 2)
        }
    }

    private func text(_ name: String) -> String {
        switch status {
        case .watching: L10n.tr("Watching %@", name)
        case .denied: L10n.tr("No access to %@", name)
        case .missing: L10n.tr("%@ is missing", name)
        case .off: ""
        }
    }
}
