import SwiftUI

/// "Update to X.Y.Z": the one accent button, shown wherever a found update is offered. Opens
/// Sparkle's standard window for that update (install, later, skip).
struct UpdateButton: View {
    let updates: AppUpdates
    let version: String

    var body: some View {
        Button { updates.install() } label: {
            Label(L10n.tr("Update to %@", version), systemImage: "arrow.down.circle.fill")
        }
        .buttonStyle(.borderedProminent)
        .help(L10n.tr("Install Update %@", version))
    }
}

/// Settings → About → Updates: the switch, then "Check now" with the last check, or the update
/// that was found.
struct UpdatesSettingsRows: View {
    let updates: AppUpdates?

    var body: some View {
        if let updates {
            @Bindable var updates = updates
            SettingsRow(L10n.tr("Check for updates automatically"), note: L10n.tr("At launch, then at most once a day")) {
                NotchSwitch(isOn: $updates.automatic, enabled: updates.isSupported)
            }
            if let v = updates.available {
                SettingsRow(L10n.tr("Version %@ is available", v), note: lastCheck(updates)) {
                    UpdateButton(updates: updates, version: v)
                }
            } else {
                SettingsRow(updates.isSupported ? lastCheck(updates) : L10n.tr("Updates come with the installed app")) {
                    NotchTextButton(L10n.tr("Check now")) { updates.checkNow() }
                        .disabled(!updates.isSupported)
                }
            }
        } else {
            SettingsRow(L10n.tr("Updates come with the installed app")) { EmptyView() }
        }
    }

    private func lastCheck(_ updates: AppUpdates) -> String {
        guard let last = updates.lastCheck else { return L10n.tr("Not checked yet") }
        let f = RelativeDateTimeFormatter()
        f.locale = L10n.locale
        f.unitsStyle = .full
        return L10n.tr("Last checked %@", f.localizedString(for: last, relativeTo: .now))
    }
}
