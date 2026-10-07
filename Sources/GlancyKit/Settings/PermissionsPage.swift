import SwiftUI

/// Which permissions the checklist shows, and how each is described.
@MainActor
enum PermissionRows {
    /// Only what a registered module can use: Automation only while media runs on the scripts
    /// fallback, Full Disk Access only while the Notifications module is on.
    static func visible(_ context: SurfaceContext) -> [PermissionKind] {
        let ids = Set(context.modules.map(\.id))
        var out: [PermissionKind] = []
        if ids.contains(.calendar) { out.append(.calendar) }
        if !ids.isDisjoint(with: [.hud, .windows, .clipboard, .agents]) { out.append(.accessibility) }
        if ids.contains(.power) { out.append(.bluetooth) }
        if ids.contains(.timer) { out.append(.notifications) }
        if context.module(MediaModule.self)?.model.source == .scripts { out.append(.automation) }
        if ids.contains(.notifications), context.settings.isEnabled(.notifications) { out.append(.fullDiskAccess) }
        if !ids.isDisjoint(with: [.notes, .hud]) { out.append(.microphone) }
        if ids.contains(.notes) { out.append(.speech) }
        if ids.contains(.control) { out.append(.camera) }
        return out
    }

    /// Rows that still need the user (granted and unavailable ones don't count).
    static func missing(_ context: SurfaceContext) -> Int {
        let center = context.settings.permissions
        guard !center.status.isEmpty else { return 0 }
        return visible(context).filter { [.notDetermined, .denied].contains(center.status($0)) }.count
    }

    static func title(_ p: PermissionKind) -> String {
        switch p {
        case .calendar: tr("Calendar")
        case .accessibility: tr("Accessibility")
        case .bluetooth: tr("Bluetooth")
        case .notifications: tr("Notifications")
        case .automation: tr("Automation")
        case .fullDiskAccess: tr("Full Disk Access")
        case .microphone: tr("Microphone")
        case .camera: tr("Camera")
        case .speech: tr("Speech Recognition")
        }
    }

    static func purpose(_ p: PermissionKind) -> String {
        switch p {
        case .calendar: tr("Your next meeting, with a Join button")
        case .accessibility: tr("HUD, window tiling, ⌘C history, paste after choosing")
        case .bluetooth: tr("Headphones and their battery")
        case .notifications: tr("An alert when a timer ends")
        case .automation: tr("Music and Spotify controls")
        case .fullDiskAccess: tr("Your notifications in the notch")
        case .microphone: tr("Voice notes and the mic mute")
        case .camera: tr("The camera mirror")
        case .speech: tr("Voice notes written out, on this Mac")
        }
    }

    static func symbol(_ p: PermissionKind) -> String {
        switch p {
        case .calendar: "calendar"
        case .accessibility: "accessibility"
        case .bluetooth: "headphones"
        case .notifications: "bell.badge"
        case .automation: "music.note"
        case .fullDiskAccess: "externaldrive"
        case .microphone: "mic"
        case .camera: "camera"
        case .speech: "waveform"
        }
    }
}

/// The permission checklist: Settings → Permissions, and the first-run welcome.
struct PermissionsSection: View {
    let context: SurfaceContext
    let welcome: Bool
    /// The welcome's Done: closes the window.
    var done: () -> Void = {}

    var body: some View {
        let center = context.settings.permissions
        let rows = PermissionRows.visible(context)
        VStack(alignment: .leading, spacing: 18) {
            if welcome {
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.black)
                        .overlay(GlancyGlyph().fill(Color.white).frame(width: 24, height: 12).offset(y: -3))
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: tr("Welcome to Glancy"))
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(SettingsStyle.primary)
                        Text(verbatim: tr("Allow only what you need. Every module works without its permission; it just does less."))
                            .font(SettingsStyle.font(.m))
                            .foregroundStyle(SettingsStyle.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 4)
            }
            SettingsSection(nil, footer: welcome ? nil : tr("Every module works without its permission; it just does less.")) {
                VStack(alignment: .leading, spacing: SettingsStyle.rowSpacing) {
                    if rows.isEmpty {
                        SettingsNote(tr("Nothing to allow: no module needs a permission."))
                    }
                    ForEach(rows, id: \.self) { p in
                        PermissionRow(permission: p, status: center.status(p), asking: center.asking == p) {
                            center.request(p)
                        }
                    }
                }
            }
            if welcome {
                HStack {
                    Spacer()
                    Button(tr("Done"), action: done)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

private struct PermissionRow: View {
    let permission: PermissionKind
    let status: PermissionStatus
    let asking: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: PermissionRows.symbol(permission), tint: Self.tint(permission), size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: PermissionRows.title(permission))
                    .font(SettingsStyle.font(.m))
                    .foregroundStyle(SettingsStyle.primary)
                Text(verbatim: PermissionRows.purpose(permission))
                    .font(SettingsStyle.font(.xs))
                    .foregroundStyle(SettingsStyle.tertiary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            control
                .fixedSize()
        }
        .padding(.vertical, 6)
        .settingsRow()
    }

    static func tint(_ p: PermissionKind) -> Color {
        switch p {
        case .calendar, .notifications: Color(nsColor: .systemRed)
        case .accessibility, .bluetooth, .fullDiskAccess: Color(nsColor: .systemBlue)
        case .microphone: Color(nsColor: .systemOrange)
        case .camera: Color(nsColor: .systemGreen)
        case .automation, .speech: Color(nsColor: .systemGray)
        }
    }

    @ViewBuilder private var control: some View {
        if asking {
            Text(verbatim: tr("Waiting…")).font(SettingsStyle.font(.s)).foregroundStyle(SettingsStyle.secondary)
        } else {
            switch status {
            case .granted:
                Label(tr("Allowed"), systemImage: "checkmark.circle.fill")
                    .font(SettingsStyle.font(.s, .medium))
                    .foregroundStyle(SettingsStyle.done)
            case .notDetermined:
                Button(tr("Allow…"), action: action)
            case .denied:
                HStack(spacing: 8) {
                    Text(verbatim: tr("Not allowed")).font(SettingsStyle.font(.s)).foregroundStyle(SettingsStyle.failed)
                    Button(tr("Open Settings"), action: action)
                }
            case .unavailable:
                if permission == .bluetooth || permission == .notifications {
                    Text(verbatim: tr("Unavailable")).font(SettingsStyle.font(.s)).foregroundStyle(SettingsStyle.secondary)
                } else {
                    Button(tr("Open Settings"), action: action)
                }
            }
        }
    }
}
