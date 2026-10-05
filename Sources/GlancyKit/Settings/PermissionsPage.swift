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
        }
    }
}

/// The permission checklist: Settings → Permissions, and the first-run welcome.
struct PermissionsSection: View {
    let context: SurfaceContext
    let welcome: Bool

    var body: some View {
        let center = context.settings.permissions
        let rows = PermissionRows.visible(context)
        VStack(alignment: .leading, spacing: 4) {
            if welcome {
                HStack(spacing: 8) {
                    GlancyGlyph()
                        .fill(Theme.secondary)
                        .frame(width: 18, height: 9)
                    Text(verbatim: tr("Welcome to Glancy"))
                        .font(Theme.font(.xl, .semibold))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text(verbatim: tr("Allow only what you need."))
                        .font(Theme.font(.s))
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    NotchTextButton(tr("Done")) { context.settings.navigation.go(.index) }
                }
                .frame(height: 24)
            } else {
                SettingsHeader(context: context, title: tr("Permissions"))
            }
            VStack(spacing: 0) {
                ForEach(rows, id: \.self) { p in
                    PermissionRow(permission: p, status: center.status(p), asking: center.asking == p) {
                        center.request(p)
                    }
                }
            }
            if !welcome {
                SettingsNote(tr("Every module works without its permission; it just does less."))
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
        HStack(spacing: 8) {
            Circle()
                .fill(dot)
                .frame(width: 6, height: 6)
            Image(systemName: PermissionRows.symbol(permission))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: 16)
            Text(verbatim: PermissionRows.title(permission))
                .font(Theme.font(.m, .medium))
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
                .frame(width: 112, alignment: .leading)
            Text(verbatim: PermissionRows.purpose(permission))
                .font(Theme.font(.s))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            control
        }
        .frame(height: 26)
    }

    private var dot: Color {
        switch status {
        case .granted: Theme.done
        case .denied: Theme.failed
        case .notDetermined: Theme.waiting
        case .unavailable: Theme.idle
        }
    }

    @ViewBuilder private var control: some View {
        if asking {
            Text(verbatim: tr("Waiting…")).font(Theme.font(.xs)).foregroundStyle(Theme.tertiary)
        } else {
            switch status {
            case .granted:
                Text(verbatim: tr("Allowed")).font(Theme.font(.xs, .medium)).foregroundStyle(Theme.done.opacity(0.9))
            case .notDetermined:
                NotchTextButton(tr("Allow…"), action: action)
            case .denied:
                NotchTextButton(tr("Open Settings"), action: action)
            case .unavailable:
                if permission == .bluetooth || permission == .notifications {
                    Text(verbatim: tr("Unavailable")).font(Theme.font(.xs)).foregroundStyle(Theme.tertiary)
                } else {
                    NotchTextButton(tr("Open Settings"), action: action)
                }
            }
        }
    }
}
