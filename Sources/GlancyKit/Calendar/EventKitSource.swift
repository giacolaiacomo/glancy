import EventKit
import Foundation

/// The only file that touches EventKit. Read-only: never creates or modifies events.
@MainActor
public final class EventKitSource: CalendarEventSource {
    public let store = EKEventStore()
    public init() {}

    public static var status: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }
    public var hasAccess: Bool { Self.status == .fullAccess }

    public var authorization: CalendarAccess {
        switch Self.status {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied   // denied, restricted, writeOnly (cannot read), legacy .authorized
        }
    }

    public func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    static func rgb(_ cg: CGColor?) -> CalendarRGB {
        guard let cg, let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let c = cg.converted(to: srgb, intent: .defaultIntent, options: nil),
              let k = c.components, k.count >= 3 else { return .fallback }
        return CalendarRGB(r: Double(k[0]), g: Double(k[1]), b: Double(k[2]))
    }

    public func calendars() -> [CalendarInfo] {
        guard hasAccess else { return [] }
        return store.calendars(for: .event).map {
            CalendarInfo(id: $0.calendarIdentifier, title: $0.title, source: $0.source?.title ?? "", color: Self.rgb($0.cgColor))
        }.sorted { ($0.source, $0.title) < ($1.source, $1.title) }
    }

    public func events(from start: Date, to end: Date, calendarIDs: Set<String>?) -> [CalendarEvent] {
        guard hasAccess else { return [] }
        var cals: [EKCalendar]?
        if let ids = calendarIDs {
            cals = store.calendars(for: .event).filter { ids.contains($0.calendarIdentifier) }
            if cals?.isEmpty == true { return [] }
        }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: cals)
        return store.events(matching: predicate).map(Self.map)
    }

    static func map(_ e: EKEvent) -> CalendarEvent {
        let declined = e.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined
        let start = e.startDate ?? .now
        let key = (e.eventIdentifier ?? UUID().uuidString) + "@" + String(Int(start.timeIntervalSince1970))
        return CalendarEvent(
            id: key, title: e.title ?? "", start: start, end: e.endDate ?? start,
            isAllDay: e.isAllDay, isDeclined: declined,
            calendarID: e.calendar?.calendarIdentifier ?? "", color: rgb(e.calendar?.cgColor),
            location: e.location,
            link: MeetingLink.extract(url: e.url, location: e.location, notes: e.notes),
            isBusy: e.availability != .free)
    }
}
