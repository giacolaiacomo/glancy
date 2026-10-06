import SwiftUI

/// "Update to X.Y.Z": the one accent button, shown wherever a found update is offered. Opens
/// Sparkle's standard window for that update (install, later, skip).
struct UpdateButton: View {
    let updates: AppUpdates
    let version: String
    @State private var hover = false

    var body: some View {
        Button { updates.install() } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 10, weight: .semibold))
                Text(verbatim: L10n.tr("Update to %@", version)).font(Theme.font(.s, .semibold))
            }
            .foregroundStyle(Color.black)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(Theme.done.opacity(hover ? 1 : 0.9)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(L10n.tr("Install Update %@", version))
    }
}

/// Settings → General: the switch, the version, "Check now" or "Update to X.Y.Z".
struct UpdatesSettingsRows: View {
    let updates: AppUpdates?
    let version: String

    var body: some View {
        if let updates {
            @Bindable var updates = updates
            SettingsRow(L10n.tr("Check for updates automatically"), note: L10n.tr("At launch, then at most once a day")) {
                NotchSwitch(isOn: $updates.automatic, enabled: updates.isSupported)
            }
            SettingsRow(L10n.tr("Version %@", version), note: note(updates),
                        noteColor: updates.available != nil ? Theme.done : Theme.tertiary) {
                if let v = updates.available {
                    UpdateButton(updates: updates, version: v)
                } else {
                    NotchTextButton(L10n.tr("Check now")) { updates.checkNow() }
                        .opacity(updates.isSupported ? 1 : 0.4)
                        .disabled(!updates.isSupported)
                }
            }
        } else {
            SettingsRow(L10n.tr("Version %@", version), note: L10n.tr("Updates come with the installed app")) { EmptyView() }
        }
    }

    private func note(_ updates: AppUpdates) -> String {
        if let v = updates.available { return L10n.tr("Version %@ is available", v) }
        guard updates.isSupported else { return L10n.tr("Updates come with the installed app") }
        guard let last = updates.lastCheck else { return L10n.tr("Not checked yet") }
        let f = RelativeDateTimeFormatter()
        f.locale = L10n.locale
        f.unitsStyle = .full
        return L10n.tr("Last checked %@", f.localizedString(for: last, relativeTo: .now))
    }
}
