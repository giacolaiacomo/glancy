import AppKit
import SwiftUI

// The Notifications tab (last 20, grouped by app), the Full Disk Access card, the peek. Theme only.

struct NotificationsTabView: View {
    let model: NotificationsModel
    let onOpen: (String) -> Void
    let onGrantAccess: () -> Void

    var body: some View {
        switch model.state {
        case .needsFullDiskAccess:
            NotifAccessCard(onGrant: onGrantAccess)
        case .unavailable(let detail):
            NotifUnavailableCard(detail: detail)
        case .starting, .live:
            VStack(alignment: .leading, spacing: 6.ui) {
                NotifHeader(model: model)
                NotifList(model: model, onOpen: onOpen)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onDisappear { model.apps.purgeIcons() }
        }
    }
}

// MARK: Header

private struct NotifHeader: View {
    let model: NotificationsModel

    var body: some View {
        HStack(spacing: 8.ui) {
            Text(NotifText.t("Notifications").uppercased())
                .font(Theme.font(.xs, .semibold)).tracking(0.6.ui)
                .foregroundStyle(Theme.tertiary)
            Text("\(model.items.count)")
                .font(Theme.font(.xs, .medium).monospacedDigit())
                .foregroundStyle(Theme.tertiary)
            Spacer(minLength: 4.ui)
            if model.settings.hidePreviews {
                Button { model.settings.hidePreviews = false } label: {
                    HStack(spacing: 4.ui) {
                        Image(systemName: "eye.slash")
                        Text(NotifText.t("Previews hidden"))
                    }
                    .font(Theme.font(.xs, .medium))
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 7.ui)
                    .frame(height: 20.ui)
                    .background(Capsule().fill(Theme.card))
                }
                .buttonStyle(.plain)
            }
            NotifMenu(model: model)
        }
        .padding(.leading, 6.ui)
    }
}

private struct NotifMenu: View {
    let model: NotificationsModel

    var body: some View {
        let settings = model.settings
        Menu {
            Toggle(NotifText.t("Hide previews"), isOn: Bindable(settings).hidePreviews)
            Menu(NotifText.t("Muted apps")) {
                if settings.muted.isEmpty {
                    Text(NotifText.t("No muted apps"))
                } else {
                    ForEach(settings.muted.sorted { $0.value < $1.value }, id: \.key) { id, name in
                        Button { model.unmute(id) } label: { Label(name, systemImage: "checkmark") }
                    }
                }
            }
            Divider()
            Button(NotifText.t("Clear list")) { model.clear() }
                .disabled(model.items.isEmpty)
        } label: {
            Image(systemName: "ellipsis")
                .font(Theme.font(.m, .semibold))
                .foregroundStyle(Theme.secondary)
                .frame(width: 26.ui, height: 20.ui)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: List

private struct NotifList: View {
    let model: NotificationsModel
    let onOpen: (String) -> Void

    var body: some View {
        let groups = model.groups
        if groups.isEmpty {
            NotifEmpty()
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 1.ui) {
                    ForEach(groups, id: \.bundleID) { group in
                        NotifGroupHeader(model: model, bundleID: group.bundleID, count: group.items.count, onOpen: onOpen)
                            .padding(.top, group.bundleID == groups.first?.bundleID ? 0 : 5.ui)
                        ForEach(group.items) { n in
                            NotifRow(model: model, item: n, onOpen: onOpen)
                        }
                    }
                }
            }
        }
    }
}

private struct NotifGroupHeader: View {
    let model: NotificationsModel
    let bundleID: String
    let count: Int
    let onOpen: (String) -> Void

    var body: some View {
        let name = model.apps.name(bundleID)
        HStack(spacing: 6.ui) {
            NotifAppIcon(model: model, bundleID: bundleID, side: 14)
            Text(verbatim: name)
                .font(Theme.font(.s, .semibold))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
            if count > 1 {
                Text("\(count)")
                    .font(Theme.font(.xs, .medium).monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6.ui)
        .frame(height: 18.ui)
        .contentShape(Rectangle())
        .onTapGesture { onOpen(bundleID) }
        .contextMenu { NotifActions(model: model, bundleID: bundleID, name: name, onOpen: onOpen) }
    }
}

private struct NotifRow: View {
    let model: NotificationsModel
    let item: SystemNotification
    let onOpen: (String) -> Void
    @State private var hover = false

    var body: some View {
        let (headline, detail) = model.lines(item)
        HStack(spacing: 6.ui) {
            (Text(verbatim: headline).font(Theme.font(.m, .semibold)).foregroundColor(Theme.primary)
             + Text(verbatim: detail.map { "  " + $0 } ?? "").font(Theme.font(.m)).foregroundColor(Theme.secondary))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(NotifText.relative(item.date, now: model.now))
                .font(Theme.font(.xs).monospacedDigit())
                .foregroundStyle(Theme.tertiary)
                .frame(minWidth: 24.ui, alignment: .trailing)
        }
        .padding(.leading, 26.ui)
        .padding(.trailing, 6.ui)
        .frame(height: 24.ui)
        .background(
            RoundedRectangle(cornerRadius: 7.ui, style: .continuous)
                .fill(hover ? Theme.hairline.opacity(0.6) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { onOpen(item.bundleID) }
        .contextMenu {
            NotifActions(model: model, bundleID: item.bundleID, name: model.apps.name(item.bundleID), onOpen: onOpen)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

private struct NotifActions: View {
    let model: NotificationsModel
    let bundleID: String
    let name: String
    let onOpen: (String) -> Void

    var body: some View {
        Button(L10n.tr("Open %@", name)) { onOpen(bundleID) }
        Divider()
        Button(L10n.tr("Mute %@", name)) { model.mute(bundleID) }
    }
}

struct NotifAppIcon: View {
    let model: NotificationsModel
    let bundleID: String
    let side: CGFloat

    var body: some View {
        if let icon = model.apps.icon(bundleID) {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: side, height: side)
        } else {
            Image(systemName: "app.badge")
                .font(.system(size: side * 0.8, weight: .regular))
                .foregroundStyle(Theme.tertiary)
                .frame(width: side, height: side)
        }
    }
}

private struct NotifEmpty: View {
    var body: some View {
        VStack(spacing: 6.ui) {
            Image(systemName: "bell")
                .font(.system(size: 18.ui, weight: .light))
                .foregroundStyle(Theme.tertiary)
            Text(NotifText.t("No notifications yet"))
                .font(Theme.font(.l, .semibold))
                .foregroundStyle(Theme.secondary)
            Text(NotifText.t("New notifications from other apps show up here."))
                .font(Theme.font(.s))
                .foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Permission and degraded states

private struct NotifAccessCard: View {
    let onGrant: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14.ui) {
            ZStack {
                RoundedRectangle(cornerRadius: 9.ui, style: .continuous).fill(Theme.card)
                Image(systemName: "bell.badge")
                    .font(.system(size: 17.ui, weight: .regular))
                    .foregroundStyle(Theme.secondary)
            }
            .frame(width: 38.ui, height: 38.ui)
            VStack(alignment: .leading, spacing: 5.ui) {
                Text(NotifText.t("Allow Full Disk Access"))
                    .font(Theme.font(.l, .semibold))
                    .foregroundStyle(Theme.primary)
                Text(NotifText.t("macOS keeps notifications in a protected store. Glancy only reads it, keeps the last 20 in memory and never saves them."))
                    .font(Theme.font(.s))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10.ui) {
                    Button(action: onGrant) {
                        Text(NotifText.t("Open Privacy Settings"))
                            .font(Theme.font(.s, .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 10.ui)
                            .frame(height: 22.ui)
                            .background(Capsule().fill(Theme.primary))
                    }
                    .buttonStyle(.plain)
                    Text(NotifText.t("Add Glancy to Full Disk Access, then come back."))
                        .font(Theme.font(.xs))
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                }
                .padding(.top, 3.ui)
            }
            .frame(maxWidth: 400.ui, alignment: .leading)
        }
        .padding(14.ui)
        .background(RoundedRectangle(cornerRadius: 12.ui, style: .continuous).fill(Theme.card))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct NotifUnavailableCard: View {
    let detail: String

    var body: some View {
        VStack(spacing: 6.ui) {
            Image(systemName: "bell.slash")
                .font(.system(size: 18.ui, weight: .light))
                .foregroundStyle(Theme.tertiary)
            Text(NotifText.t("Not available on this macOS"))
                .font(Theme.font(.l, .semibold))
                .foregroundStyle(Theme.secondary)
            Text(NotifText.t("The notification store has changed. Glancy leaves it alone rather than guess."))
                .font(Theme.font(.s))
                .foregroundStyle(Theme.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320.ui)
            Text(verbatim: detail)
                .font(Theme.font(.xs).monospaced())
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 360.ui)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Peek

struct NotificationPeek: View {
    let model: NotificationsModel
    let state: NotificationPeekState

    var body: some View {
        let n = state.latest
        let (headline, detail) = model.lines(n)
        HStack(spacing: 8.ui) {
            NotifAppIcon(model: model, bundleID: n.bundleID, side: 16)
            Text(verbatim: headline)
                .font(Theme.font(.m, .semibold))
                .foregroundStyle(Theme.primary)
                .layoutPriority(1)
            if let detail {
                Text(verbatim: detail)
                    .font(Theme.font(.m))
                    .foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 4.ui)
            if state.more > 0 {
                Text(L10n.tr("+%d more", state.more))
                    .font(Theme.font(.xs, .medium).monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize()
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.horizontal, 14.ui)
    }
}
