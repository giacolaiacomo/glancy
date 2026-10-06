import Foundation

public struct CalendarRGB: Equatable, Sendable, Hashable {
    public var r: Double, g: Double, b: Double
    public init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
    public static let fallback = CalendarRGB(r: 0.45, g: 0.62, b: 1.0)
}

public struct CalendarInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var source: String
    public var color: CalendarRGB
    public init(id: String, title: String, source: String = "", color: CalendarRGB = .fallback) {
        self.id = id; self.title = title; self.source = source; self.color = color
    }
}

/// A calendar event reduced to what Glancy needs. EventKit is mapped into this once, at the edge.
public struct CalendarEvent: Identifiable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var isDeclined: Bool
    public var calendarID: String
    public var color: CalendarRGB
    public var location: String?
    public var link: MeetingLink?
    /// Shown as busy (EventKit availability not "free"). Free events never turn Focus on.
    public var isBusy: Bool

    public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool = false,
                isDeclined: Bool = false, calendarID: String = "", color: CalendarRGB = .fallback,
                location: String? = nil, link: MeetingLink? = nil, isBusy: Bool = true) {
        self.id = id; self.title = title; self.start = start; self.end = end; self.isAllDay = isAllDay
        self.isDeclined = isDeclined; self.calendarID = calendarID; self.color = color
        self.location = location; self.link = link; self.isBusy = isBusy
    }

    /// EventKit's own identifier (ours appends "@<start>" to tell recurrences apart).
    public var eventKitID: String {
        guard let at = id.lastIndex(of: "@") else { return id }
        return String(id[..<at])
    }
}

/// The seam between the module and EventKit. Tests supply a fake.
public enum CalendarAccess: Sendable, Equatable { case notDetermined, granted, denied }

@MainActor
public protocol CalendarEventSource: AnyObject {
    var authorization: CalendarAccess { get }
    func requestAccess() async -> Bool
    func calendars() -> [CalendarInfo]
    /// Raw events in [start, end), already mapped; filtering (declined, all-day) is `CalendarLogic`'s job.
    func events(from start: Date, to end: Date, calendarIDs: Set<String>?) -> [CalendarEvent]
}

public enum CalendarPhase: Int, Sendable, Comparable {
    case soon = 20        // ≤ 15' before start
    case imminent = 85    // ≤ 2' before start
    case started = 86     // start … start + 5'  (still priority 85; ordering only)
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    public var priority: Int { self == .soon ? 20 : 85 }
}

public enum CalendarLogic {
    public static let soonLead: TimeInterval = 15 * 60
    public static let imminentLead: TimeInterval = 2 * 60
    public static let startedTail: TimeInterval = 5 * 60

    /// Declined events never show anywhere; unselected calendars are dropped.
    public static func visible(_ events: [CalendarEvent], calendarIDs: Set<String>? = nil) -> [CalendarEvent] {
        let kept = events.filter { e in
            !e.isDeclined && (calendarIDs.map { $0.contains(e.calendarID) } ?? true)
        }.sorted { ($0.start, $0.end, $0.id) < ($1.start, $1.end, $1.id) }
        // The same meeting invited on two accounts shows up once: same title, same times.
        // Keep the copy that carries a meeting link.
        var seen: [String: Int] = [:]
        var out: [CalendarEvent] = []
        for e in kept {
            let key = "\(e.title.trimmingCharacters(in: .whitespaces).lowercased())|\(e.start.timeIntervalSince1970)|\(e.end.timeIntervalSince1970)"
            if let i = seen[key] {
                if out[i].link == nil, e.link != nil { out[i] = e }
            } else {
                seen[key] = out.count
                out.append(e)
            }
        }
        return out
    }

    /// Events that take part in countdowns, wings and wake-ups: timed, not declined.
    public static func countdownEvents(_ events: [CalendarEvent]) -> [CalendarEvent] {
        events.filter { !$0.isAllDay && !$0.isDeclined && $0.end > $0.start }
    }

    /// Next event worth a glance: the earliest timed event that has not ended yet.
    public static func nextEvent(_ events: [CalendarEvent], now: Date) -> CalendarEvent? {
        countdownEvents(events).filter { $0.end > now }.min { ($0.start, $0.id) < ($1.start, $1.id) }
    }

    /// `endWarning` > 0 adds the "ends in N min" instant (Settings → Calendar).
    public static func boundaries(of event: CalendarEvent, endWarning: TimeInterval = 0) -> [Date] {
        var out = [event.start.addingTimeInterval(-soonLead), event.start.addingTimeInterval(-imminentLead),
                   event.start, event.end, event.start.addingTimeInterval(startedTail)]
        if endWarning > 0 { out.append(event.end.addingTimeInterval(-endWarning)) }
        return out
    }

    /// The single next instant at which anything about the display could change.
    public static func nextBoundary(_ events: [CalendarEvent], after now: Date, endWarning: TimeInterval = 0) -> Date? {
        countdownEvents(events).flatMap { boundaries(of: $0, endWarning: endWarning) }.filter { $0 > now }.min()
    }

    public static func phase(of event: CalendarEvent, now: Date) -> CalendarPhase? {
        guard !event.isAllDay, !event.isDeclined else { return nil }
        let t = event.start.timeIntervalSince(now)
        if t > soonLead { return nil }
        if t > imminentLead { return .soon }
        if t > 0 { return .imminent }
        if -t < startedTail { return .started }
        return nil
    }

    /// When the current phase of `event` stops being valid.
    public static func phaseEnd(of event: CalendarEvent, phase: CalendarPhase) -> Date {
        switch phase {
        case .soon: event.start.addingTimeInterval(-imminentLead)
        case .imminent: event.start
        case .started: event.start.addingTimeInterval(startedTail)
        }
    }

    /// The event that owns the wings right now (highest phase, then earliest start).
    public static func activeEvent(_ events: [CalendarEvent], now: Date) -> (event: CalendarEvent, phase: CalendarPhase)? {
        let candidates: [(event: CalendarEvent, phase: CalendarPhase)] = countdownEvents(events).compactMap {
            (e: CalendarEvent) -> (event: CalendarEvent, phase: CalendarPhase)? in
            guard let p = phase(of: e, now: now) else { return nil }
            return (event: e, phase: p)
        }
        return candidates.max { (a, b) -> Bool in
            if a.phase != b.phase { return a.phase < b.phase }
            return a.event.start > b.event.start
        }
    }

    public struct Day: Equatable, Sendable {
        public var start: Date
        public var allDay: [CalendarEvent]
        public var timed: [CalendarEvent]
    }

    /// The next events after today (from tomorrow's midnight), declined ones out, earliest first.
    public static func upcoming(_ events: [CalendarEvent], now: Date, calendar: Calendar = .current, limit: Int = 5) -> [CalendarEvent] {
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { return [] }
        return events.filter { !$0.isDeclined && $0.start >= tomorrow }
            .sorted { ($0.start, $0.isAllDay ? 0 : 1, $0.id) < ($1.start, $1.isAllDay ? 0 : 1, $1.id) }
            .prefix(limit).map { $0 }
    }

    /// Today + tomorrow, split into all-day strip and timed rows. Events overlapping midnight appear on both.
    public static func agenda(_ events: [CalendarEvent], now: Date, calendar: Calendar = .current, days: Int = 2) -> [Day] {
        let visible = events.filter { !$0.isDeclined }.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        let today = calendar.startOfDay(for: now)
        return (0..<days).compactMap { offset -> Day? in
            guard let ds = calendar.date(byAdding: .day, value: offset, to: today),
                  let de = calendar.date(byAdding: .day, value: 1, to: ds) else { return nil }
            let overlapping = visible.filter { $0.start < de && max($0.end, $0.start.addingTimeInterval(1)) > ds }
            return Day(start: ds, allDay: overlapping.filter(\.isAllDay), timed: overlapping.filter { !$0.isAllDay })
        }
    }
}
