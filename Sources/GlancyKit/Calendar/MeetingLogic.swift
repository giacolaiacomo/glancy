import Foundation

// Pure meeting logic for wave 4: Focus during meetings, "ends in N min" / back-to-back peeks,
// the overrun indicator, the Join hotkey's target and the command-bar search. Every function takes
// `now`; the module calls them at its single scheduled wake-up (CalendarLogic.nextBoundary).

/// Which events turn Focus on (Settings → Calendar).
public enum MeetingFocusTrigger: String, Codable, CaseIterable, Sendable {
    /// Only events with a recognised call link (Zoom, Meet, Teams…).
    case calls
    /// Any timed event shown as busy.
    case busy
}

public enum MeetingFocusLogic {
    /// Events that may turn Focus on: timed, not declined, busy; for `.calls`, with a call link.
    public static func eligible(_ e: CalendarEvent, trigger: MeetingFocusTrigger) -> Bool {
        guard !e.isAllDay, !e.isDeclined, e.isBusy, e.end > e.start else { return false }
        return trigger == .busy || e.link != nil
    }

    /// The eligible events in progress at `now` (start ≤ now < end).
    public static func current(_ events: [CalendarEvent], now: Date, trigger: MeetingFocusTrigger) -> [CalendarEvent] {
        events.filter { eligible($0, trigger: trigger) && $0.start <= now && now < $0.end }
    }

    /// Whether Focus should be on: some eligible event is in progress and the user has not turned
    /// Focus off for it (`skipped`). Overlapping and back-to-back meetings keep it on throughout.
    public static func wants(_ events: [CalendarEvent], now: Date, trigger: MeetingFocusTrigger, skipped: Set<String>) -> Bool {
        current(events, now: now, trigger: trigger).contains { !skipped.contains($0.id) }
    }

    /// Skips that still matter: an event that has ended no longer needs to be remembered.
    public static func pruneSkipped(_ skipped: Set<String>, events: [CalendarEvent], now: Date) -> Set<String> {
        skipped.filter { id in events.contains { $0.id == id && $0.end > now } }
    }
}

/// A drop-down about the meeting in progress ending.
public enum MeetingEndPeek: Equatable, Sendable {
    /// "Ends in 5 min · next: Standup at 15:30".
    case ending(CalendarEvent, minutes: Int, next: CalendarEvent?)
    /// At the end, with another meeting right after: "Next: Standup in 10 min".
    case backToBack(ended: CalendarEvent, next: CalendarEvent)

    /// Stable per meeting, so each shows once.
    public var key: String {
        switch self {
        case .ending(let e, _, _): "end:\(e.id)"
        case .backToBack(let e, _): "after:\(e.id)"
        }
    }
}

public enum MeetingEndLogic {
    /// The choices in Settings (0 = off).
    public static let warningChoices = [0, 2, 5, 10]
    /// A meeting starting at most this long after another ends counts as back-to-back.
    public static let backToBackGap: TimeInterval = 15 * 60
    /// How late after an end the back-to-back peek may still show (wake-ups land +0.5 s).
    public static let freshness: TimeInterval = 60

    /// Meetings that get end peeks: timed, busy, not declined.
    static func counts(_ e: CalendarEvent) -> Bool { !e.isAllDay && !e.isDeclined && e.isBusy && e.end > e.start }

    /// The next meeting after `e` ends, the same day: earliest start ≥ e's end.
    public static func following(_ e: CalendarEvent, in events: [CalendarEvent], calendar: Calendar = .current) -> CalendarEvent? {
        events.filter { $0.id != e.id && counts($0) && $0.start >= e.end && calendar.isDate($0.start, inSameDayAs: e.end) }
            .min { ($0.start, $0.id) < ($1.start, $1.id) }
    }

    /// The peeks due at `now`, oldest meeting first. The module shows each key once.
    /// - Ending: from end − warning until the end, for meetings longer than the warning.
    /// - Back-to-back: within a minute of the end, when the next meeting starts ≤ 15 min later.
    public static func due(_ events: [CalendarEvent], now: Date, warningMinutes: Int, calendar: Calendar = .current) -> [MeetingEndPeek] {
        var out: [MeetingEndPeek] = []
        let warning = TimeInterval(max(0, warningMinutes) * 60)
        for e in events.filter(counts).sorted(by: { ($0.end, $0.id) < ($1.end, $1.id) }) {
            if warning > 0 {
                let at = e.end.addingTimeInterval(-warning)
                if e.start < at, at <= now, now < e.end {
                    let minutes = max(1, Int((e.end.timeIntervalSince(now) / 60).rounded(.up)))
                    out.append(.ending(e, minutes: minutes, next: following(e, in: events, calendar: calendar)))
                }
            }
            if e.end <= now, now.timeIntervalSince(e.end) < freshness,
               let next = following(e, in: events, calendar: calendar),
               next.start.timeIntervalSince(e.end) <= backToBackGap, now < next.end {
                out.append(.backToBack(ended: e, next: next))
            }
        }
        return out
    }

    /// The overrun indicator: you joined a meeting through Glancy, it has ended, the next one
    /// (starting at or before that end + 1 min) has started, and you have not joined it yet.
    /// Lasts the next meeting's first five minutes, or until you join it.
    public static func overrun(_ events: [CalendarEvent], now: Date, joined: Set<String>) -> (previous: CalendarEvent, next: CalendarEvent)? {
        let timed = events.filter(counts)
        for next in timed.sorted(by: { ($0.start, $0.id) > ($1.start, $1.id) })
        where next.start <= now && now < next.start.addingTimeInterval(CalendarLogic.startedTail) && now < next.end
            && !joined.contains(next.id) {
            if let previous = timed.filter({ p in
                p.id != next.id && joined.contains(p.id) && p.end <= now && p.start < next.start
                    && next.start <= p.end.addingTimeInterval(60)
            }).max(by: { $0.end < $1.end }) {
                return (previous, next)
            }
        }
        return nil
    }
}

public enum MeetingJoinLogic {
    /// How early before its start a meeting becomes the Join hotkey's target.
    public static let window: TimeInterval = 10 * 60

    /// What ⌃⌥J joins: a meeting with a call link running now or starting within 10 minutes; when
    /// several qualify, the one whose start is closest to now (later start wins a tie), so the
    /// call about to begin beats the one that has been running for an hour.
    public static func target(_ events: [CalendarEvent], now: Date) -> CalendarEvent? {
        events.filter { $0.link != nil && !$0.isDeclined && !$0.isAllDay && $0.end > now
            && $0.start.addingTimeInterval(-window) <= now }
            .min { a, b in
                let da = abs(a.start.timeIntervalSince(now)), db = abs(b.start.timeIntervalSince(now))
                return da != db ? da < db : (a.start, a.id) > (b.start, b.id)
            }
    }

    /// The next meeting with a call link after the window (for "nothing to join yet").
    public static func later(_ events: [CalendarEvent], now: Date) -> CalendarEvent? {
        events.filter { $0.link != nil && !$0.isDeclined && !$0.isAllDay && $0.start.addingTimeInterval(-window) > now }
            .min { ($0.start, $0.id) < ($1.start, $1.id) }
    }

    /// The link "Copy meeting link" copies: the Join target, else the next meeting with a link.
    public static func linkTarget(_ events: [CalendarEvent], now: Date) -> CalendarEvent? {
        target(events, now: now) ?? later(events, now: now)
    }

    /// A search result joins when its call is joinable now; otherwise it opens in Calendar.
    public static func isJoinable(_ e: CalendarEvent, now: Date) -> Bool {
        e.link != nil && e.end > now && e.start.addingTimeInterval(-window) <= now
    }
}

public enum CalendarSearch {
    /// Leading words that mean "join …" ("join standup", "partecipa standup").
    static let joinWords = ["join", "partecipa", "entra"]

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The query minus a leading "join"/"partecipa"; nil when nothing searchable is left.
    public static func term(_ query: String) -> String? {
        var q = fold(query)
        for w in joinWords where q.hasPrefix(w + " ") { q = String(q.dropFirst(w.count + 1)).trimmingCharacters(in: .whitespaces) }
        return q.count >= 2 ? q : nil
    }

    /// Events of today and the next 7 days whose title matches, not yet ended: title-prefix and
    /// word-prefix matches first, then substring matches; earlier first within each. At most `limit`.
    public static func match(_ events: [CalendarEvent], query: String, now: Date, limit: Int = 5) -> [(event: CalendarEvent, score: Int)] {
        guard let q = term(query) else { return [] }
        var out: [(CalendarEvent, Int)] = []
        for e in events where !e.isDeclined && e.end > now {
            let t = fold(e.title)
            guard !t.isEmpty else { continue }
            let score: Int
            if t.hasPrefix(q) { score = 90 }
            else if t.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(q) }) { score = 80 }
            else if t.contains(q) { score = 60 }
            else { continue }
            out.append((e, score))
        }
        return out.sorted { a, b in a.1 != b.1 ? a.1 > b.1 : (a.0.start, a.0.id) < (b.0.start, b.0.id) }
            .prefix(limit).map { (event: $0.0, score: $0.1) }
    }
}
