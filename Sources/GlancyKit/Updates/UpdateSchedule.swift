import Foundation

/// When Glancy looks for an update. No timer, ever (the zero-idle rule): a check runs once at
/// launch and, when the panel opens, if the last one is more than a day old. The switch in
/// Settings → General ("Check for updates automatically") gates both; "Check now" never asks.
/// Pure logic over a defaults store and a clock, so the tests drive it without Sparkle.
struct UpdateSchedule {
    static let interval: TimeInterval = 24 * 3600

    enum Key {
        static let automatic = "updates.automatic"
        static let lastCheck = "updates.lastCheck"
    }

    let defaults: UserDefaults
    var now: () -> Date = { .now }

    /// The switch, on unless turned off.
    var automatic: Bool {
        get { defaults.object(forKey: Key.automatic) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.automatic) }
    }

    /// When Glancy last asked for the feed (any check, background or "Check now").
    var lastCheck: Date? { defaults.object(forKey: Key.lastCheck) as? Date }

    /// At launch: whenever the switch is on.
    func dueAtLaunch() -> Bool { automatic }

    /// When the panel opens: the switch is on and the last check is a day old (or never ran, or
    /// lies in the future after a clock change).
    func dueOnPanelOpen() -> Bool {
        guard automatic else { return false }
        guard let last = lastCheck else { return true }
        let age = now().timeIntervalSince(last)
        return age >= Self.interval || age < 0
    }

    func recordCheck() { defaults.set(now(), forKey: Key.lastCheck) }
}
