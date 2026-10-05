import Foundation

/// Synthetic notifications for the off-screen renderer: renders never show real ones.
enum NotificationsSample {
    static func items(now: Date = .now) -> [SystemNotification] {
        var id: Int64 = 100
        func n(_ app: String, _ title: String?, _ subtitle: String? = nil, _ body: String?, _ age: TimeInterval) -> SystemNotification {
            id += 1
            return SystemNotification(recID: id, bundleID: app, title: title, subtitle: subtitle, body: body,
                                      date: now.addingTimeInterval(-age))
        }
        let messages = "com.apple.MobileSMS", mail = "com.apple.mail", calendar = "com.apple.iCal"
        let slack = "com.tinyspeck.slackmacgap", reminders = "com.apple.reminders"
        // Oldest first, as the store hands them out.
        return [
            n(reminders, "Pay the electricity bill", nil, "Today", 5 * 3600),
            n(calendar, "Design review", nil, "Tomorrow at 10:30 · Room 2", 3 * 3600 + 400),
            n(slack, "#glancy", "Alex Kim", "Pushed the wings fix, can you check on the ultrawide?", 2 * 3600),
            n(mail, "Jordan Lee", "Contract — final version", "Hi, attached is the version with yesterday’s edits.", 47 * 60),
            n(messages, "Sam", nil, "Be there in 10 minutes 🚲", 12 * 60),
            n(messages, "Sam", nil, "I’ll grab the bread", 9 * 60),
            n(mail, "GitHub", "[glancy] CI passed on main", nil, 3 * 60),
        ]
    }
}
