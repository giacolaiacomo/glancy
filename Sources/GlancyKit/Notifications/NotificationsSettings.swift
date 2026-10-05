import Foundation
import Observation

/// Notification preferences, edited from the tab's menu. Only preferences are stored; notifications
/// themselves never touch the disk.
@MainActor @Observable
public final class NotificationsSettings {
    static let mutedKey = "glancy.notifications.muted"
    static let hidePreviewsKey = "glancy.notifications.hidePreviews"

    /// Glancy's own bundle ID: muted by default (its timer alerts would echo back into the notch).
    nonisolated static let ownBundleID = "ai.glancy.app"

    /// Apps never shown: bundle ID → display name.
    public var muted: [String: String] { didSet { defaults.set(muted, forKey: Self.mutedKey) } }
    /// Show the app and the title only, never the subtitle or body.
    public var hidePreviews: Bool { didSet { defaults.set(hidePreviews, forKey: Self.hidePreviewsKey) } }

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        muted = defaults.dictionary(forKey: Self.mutedKey) as? [String: String] ?? [Self.ownBundleID: "Glancy"]
        hidePreviews = defaults.bool(forKey: Self.hidePreviewsKey)
    }

    var mutedIDs: Set<String> { Set(muted.keys) }
}

/// Mute and preview rules. Pure.
enum NotificationFilter {
    /// Bundle IDs compare case-insensitively: the store sometimes lower-cases them.
    static func isMuted(_ bundleID: String, _ muted: Set<String>) -> Bool {
        let id = bundleID.lowercased()
        return muted.contains { $0.lowercased() == id }
    }

    static func visible(_ items: [SystemNotification], muted: Set<String>) -> [SystemNotification] {
        items.filter { !isMuted($0.bundleID, muted) }
    }

    /// What a row or a peek shows: a headline and an optional one-line detail.
    /// With previews hidden: the title only (or the app name when there is no title).
    static func lines(_ n: SystemNotification, appName: String, hidePreviews: Bool) -> (headline: String, detail: String?) {
        if hidePreviews { return (n.title ?? appName, nil) }
        let rest = [n.subtitle, n.body].compactMap { $0 }
        guard let title = n.title else {
            return (rest.first ?? appName, rest.count > 1 ? rest[1] : nil)
        }
        return (title, rest.isEmpty ? nil : rest.joined(separator: " — "))
    }

    /// Newest first, grouped by app; groups ordered by their newest notification.
    static func groups(_ items: [SystemNotification]) -> [(bundleID: String, items: [SystemNotification])] {
        var order: [String] = []
        var byApp: [String: [SystemNotification]] = [:]
        for n in items.sorted(by: { $0.date != $1.date ? $0.date > $1.date : $0.recID > $1.recID }) {
            let key = n.bundleID.lowercased()
            if byApp[key] == nil { order.append(key) }
            byApp[key, default: []].append(n)
        }
        return order.map { (byApp[$0]![0].bundleID, byApp[$0]!) }
    }
}

/// Burst coalescing for the peek: the first notification shows a peek; more arriving while it is up
/// (within `window` of it) update that same peek ("+2") instead of queuing new ones. Pure.
struct PeekCoalescer {
    enum Decision: Equatable { case show, update }
    var window: TimeInterval = 3
    private(set) var shownAt: Date?

    mutating func offer(at now: Date) -> Decision {
        if let shownAt, now.timeIntervalSince(shownAt) < window { return .update }
        shownAt = now
        return .show
    }

    mutating func reset() { shownAt = nil }
}
