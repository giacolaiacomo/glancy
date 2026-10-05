import AppKit
import Observation

public enum NotificationsState: Equatable, Sendable {
    case starting
    case live
    /// Glancy has no Full Disk Access: a calm card with a deep link.
    case needsFullDiskAccess
    /// The store is missing or its schema is unknown on this macOS. `detail` is technical, small print.
    case unavailable(detail: String)
}

/// What the peek shows; updated in place while a burst comes in.
@MainActor @Observable
final class NotificationPeekState {
    var latest: SystemNotification
    /// Arrived in the same burst besides `latest`.
    var more: Int
    init(latest: SystemNotification, more: Int) { self.latest = latest; self.more = more }
}

@MainActor @Observable
public final class NotificationsModel {
    public static let keep = 20

    public internal(set) var state: NotificationsState = .starting
    /// Newest first, at most `keep`, memory only (never written anywhere).
    public internal(set) var items: [SystemNotification] = []
    /// "Now" for relative times: refreshed on panel open and on arrival, never ticking.
    var now: Date = .now
    let settings: NotificationsSettings
    @ObservationIgnored let apps = AppDirectory()

    init(settings: NotificationsSettings) { self.settings = settings }

    /// Replaces the list (connection, reconnection).
    func replace(with all: [SystemNotification]) {
        items = Array(NotificationFilter.visible(all, muted: settings.mutedIDs).sorted { $0.recID > $1.recID }.prefix(Self.keep))
        now = .now
    }

    /// Adds new arrivals; returns those that are not muted (oldest first).
    @discardableResult
    func ingest(_ new: [SystemNotification]) -> [SystemNotification] {
        let shown = NotificationFilter.visible(new, muted: settings.mutedIDs)
        guard !shown.isEmpty else { return [] }
        // A reused rec_id (the newest row removed, then a new one): the new one wins.
        let incoming = Set(shown.map(\.recID))
        items = Array((shown.reversed() + items.filter { !incoming.contains($0.recID) }).prefix(Self.keep))
        now = .now
        return shown
    }

    var groups: [(bundleID: String, items: [SystemNotification])] {
        NotificationFilter.groups(NotificationFilter.visible(items, muted: settings.mutedIDs))
    }

    func mute(_ bundleID: String) {
        settings.muted[bundleID] = apps.name(bundleID)
        items.removeAll { NotificationFilter.isMuted($0.bundleID, [bundleID]) }
    }

    func unmute(_ bundleID: String) { settings.muted[bundleID] = nil }

    func clear() { items = [] }

    func lines(_ n: SystemNotification) -> (headline: String, detail: String?) {
        NotificationFilter.lines(n, appName: apps.name(n.bundleID), hidePreviews: settings.hidePreviews)
    }
}

/// Bundle ID → name, icon and location, resolved through Launch Services and cached in memory.
@MainActor
final class AppDirectory {
    private var urls: [String: URL?] = [:]
    private var icons: [String: NSImage] = [:]

    func url(_ bundleID: String) -> URL? {
        if let cached = urls[bundleID] { return cached }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        urls[bundleID] = url
        return url
    }

    func name(_ bundleID: String) -> String {
        if let url = url(bundleID) {
            let name = FileManager.default.displayName(atPath: url.path)
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
        // Unknown app: the last component, readable ("com.example.my-app" → "My App").
        let last = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        return last.replacingOccurrences(of: "-", with: " ").capitalized
    }

    func icon(_ bundleID: String) -> NSImage? {
        if let icon = icons[bundleID] { return icon }
        guard let url = url(bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = icon
        return icon
    }

    /// Drops the icons (kept only while the tab is on screen).
    func purgeIcons() { icons = [:] }

    /// Brings the source app forward.
    func open(_ bundleID: String) {
        guard let url = url(bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
