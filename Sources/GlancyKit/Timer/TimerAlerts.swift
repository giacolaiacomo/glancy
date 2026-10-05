import Foundation
import UserNotifications

/// Delivers the expiry alert. The real one hands it to the system at start time, so it fires on
/// time even while Glancy sleeps; tests use a recorder.
@MainActor
public protocol TimerAlerting: AnyObject {
    func schedule(at date: Date, title: String, body: String)
    func cancel()
}

/// `UNUserNotificationCenter`, one pending request at a time. Authorization is asked lazily, the
/// first time a timer starts. Inert outside an app bundle (tests, the renderer): the center
/// traps there.
@MainActor
final class SystemTimerAlerts: NSObject, TimerAlerting, UNUserNotificationCenterDelegate {
    private static let requestID = "ai.glancy.timer"
    private var asked = false

    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil ? .current() : nil
    }

    func schedule(at date: Date, title: String, body: String) {
        guard let center else { return }
        center.delegate = self
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
        let request = UNNotificationRequest(identifier: Self.requestID, content: content, trigger: trigger)
        let ask = !asked
        asked = true
        Task {
            if ask { _ = try? await center.requestAuthorization(options: [.alert, .sound]) }
            try? await center.add(request)
        }
    }

    func cancel() {
        center?.removePendingNotificationRequests(withIdentifiers: [Self.requestID])
    }

    // Glancy is an accessory app and rarely frontmost, but when it is, still show the banner.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
