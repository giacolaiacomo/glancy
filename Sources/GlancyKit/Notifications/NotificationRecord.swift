import Foundation

/*
 Notifications from other apps (SPEC §3 "Notifications (opt-in, experimental)").

 Source: the Notification Center store, `~/Library/Group Containers/group.com.apple.usernoted/db2/db`
 (SQLite in WAL mode, written by `usernoted`). It is TCC-protected: reading it needs Full Disk Access.
 No public API exists; the schema is undocumented and changes between releases.

 Schema ASSUMED from public reverse-engineering notes (macOS 15 Sequoia, still present on 26).
 It was NOT verified on this Mac: on macOS 26.6.2 both `ls` of the container and `sqlite3` fail with
 "Operation not permitted" / "authorization denied" for the build and test processes, which lack
 Full Disk Access. The decoder is built against fixtures that mirror the assumed structure:

   app(app_id INTEGER PRIMARY KEY, identifier TEXT, badge INTEGER, …)
     identifier = bundle ID, sometimes lower-cased, sometimes prefixed ("_system_center_:com.apple.x")
   record(rec_id INTEGER PRIMARY KEY, app_id INTEGER, uuid BLOB, data BLOB,
          request_date REAL, request_last_date REAL, delivered_date REAL, presented BOOL, style INTEGER, …)
     dates = Mac absolute time (seconds since 2001-01-01 UTC)
     data  = binary plist: { app: String, date: Double, uuid: Data, req: { titl, subt, body, iden, thre, cate, … } }

 What the reader relies on (checked with PRAGMA table_info; anything less → "unavailable on this macOS"):
 record.rec_id, record.app_id, record.data, app.app_id, app.identifier. record.delivered_date and
 record.uuid are used when present. Every plist field is optional; a record with no text is skipped.

 Privacy: decoded notifications live in memory only (the last 20); nothing here writes to disk, and
 the system database is opened read-only.
*/

/// One notification delivered by another app, decoded from the system store. Memory only.
public struct SystemNotification: Identifiable, Equatable, Sendable {
    public let recID: Int64
    /// The source app's bundle identifier, normalised (prefix stripped), as stored (case may differ).
    public let bundleID: String
    public let title: String?
    public let subtitle: String?
    public let body: String?
    public let date: Date

    public var id: Int64 { recID }

    public init(recID: Int64, bundleID: String, title: String?, subtitle: String?, body: String?, date: Date) {
        self.recID = recID; self.bundleID = bundleID; self.title = title; self.subtitle = subtitle
        self.body = body; self.date = date
    }
}

/// Decodes `record.data` (a binary plist) into a `SystemNotification`. Pure; any thread.
enum NotificationDecoder {
    /// - Parameters:
    ///   - identifier: `app.identifier` of the record's `app_id`, when the join found one.
    ///   - deliveredDate: `record.delivered_date` (Mac absolute time), when the column exists and is set.
    static func decode(recID: Int64, identifier: String?, data: Data, deliveredDate: Double?,
                       now: Date = .now) -> SystemNotification? {
        let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
        guard let plist else { return nil }
        let req = plist["req"] as? [String: Any] ?? [:]
        let title = text(req["titl"])
        let subtitle = text(req["subt"])
        let body = text(req["body"])
        guard title != nil || subtitle != nil || body != nil else { return nil }

        let rawID = identifier.flatMap(nonEmpty) ?? text(plist["app"]) ?? ""
        let date: Date
        if let d = deliveredDate, d > 0 {
            date = Date(timeIntervalSinceReferenceDate: d)
        } else if let d = plist["date"] as? Double, d > 0 {
            date = Date(timeIntervalSinceReferenceDate: d)
        } else if let d = plist["date"] as? Date {
            date = d
        } else {
            date = now
        }
        return SystemNotification(recID: recID, bundleID: normalizeBundleID(rawID), title: title, subtitle: subtitle,
                                  body: body, date: date)
    }

    /// "_system_center_:com.apple.battery" → "com.apple.battery".
    static func normalizeBundleID(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let colon = s.lastIndex(of: ":") { return String(s[s.index(after: colon)...]) }
        return s
    }

    /// A display string: whitespace runs (newlines included) collapsed to one space, trimmed; nil when empty.
    static func text(_ value: Any?) -> String? {
        let raw: String?
        switch value {
        case let s as String: raw = s
        case let a as NSAttributedString: raw = a.string
        default: raw = nil
        }
        guard let raw else { return nil }
        let collapsed = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return nonEmpty(collapsed)
    }

    private static func nonEmpty(_ s: String) -> String? { s.isEmpty ? nil : s }
}
