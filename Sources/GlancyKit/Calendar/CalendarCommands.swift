import AppKit
import Foundation

// The Calendar's entries in the command bar: fixed actions (join, copy link, open Calendar, today's
// agenda, Focus off) and event search over today + the next 7 days (join when the call is on,
// otherwise open it in Calendar).

extension CalendarModule {
    public func commands() -> [GlancyCommand] {
        guard model.access == .granted else { return [] }
        let now = clock()
        var out: [GlancyCommand] = []
        let target = MeetingJoinLogic.target(model.events, now: now)
        out.append(GlancyCommand(
            id: "calendar.join", module: .calendar, title: CalL10n.cmdJoin,
            subtitle: target.map { $0.title + " · " + Self.when($0, now: now) } ?? settings.joinHotkey.shortcutText,
            symbol: "video.fill", keywords: ["join", "meeting", "call", "zoom", "meet", "teams", "partecipa", "riunione", "chiamata"],
            run: { [weak self] in self?.joinNow() }))
        if let e = MeetingJoinLogic.linkTarget(model.events, now: now) {
            out.append(GlancyCommand(
                id: "calendar.copyLink", module: .calendar, title: CalL10n.cmdCopy, subtitle: e.title,
                symbol: "link", keywords: ["copy", "link", "url", "meeting", "copia", "riunione"],
                run: { [weak self] in self?.copyLink() }))
        }
        out.append(GlancyCommand(
            id: "calendar.agenda", module: .calendar, title: CalL10n.cmdAgenda,
            subtitle: model.next.map { $0.title + " · " + Self.when($0, now: now) },
            symbol: "calendar", keywords: ["agenda", "today", "schedule", "calendar", "oggi", "calendario", "impegni"],
            closesPanel: false, run: { [weak self] in self?.hub?.requestOpen(.calendar) }))
        out.append(GlancyCommand(
            id: "calendar.openApp", module: .calendar, title: CalL10n.cmdOpenApp, symbol: "calendar.badge.clock",
            keywords: ["calendar", "ical", "app", "calendario"], run: { Self.openCalendarApp() }))
        if let focus, focus.isOn {
            out.append(GlancyCommand(
                id: "calendar.focusOff", module: .calendar, title: CalL10n.cmdFocusOff, symbol: "moon.zzz",
                keywords: ["focus", "dnd", "do not disturb", "non disturbare", "concentrazione"],
                rank: 10, run: { focus.turnOffNow() }))
        }
        return out
    }

    public func results(for query: String) -> [GlancyCommand] {
        guard model.access == .granted else { return [] }
        let now = clock()
        return CalendarSearch.match(model.events, query: query, now: now).map { hit in
            let e = hit.event
            let joinable = MeetingJoinLogic.isJoinable(e, now: now)
            let tail = joinable ? CalL10n.join : CalL10n.openInCalendar
            return GlancyCommand(
                id: "calendar.event.\(e.id)", module: .calendar, title: e.title,
                subtitle: Self.when(e, now: now) + " · " + tail,
                symbol: joinable ? "video.fill" : "calendar", rank: hit.score,
                run: { [weak self] in
                    if joinable { self?.join(e) } else { Self.openInCalendar(e) }
                })
        }
    }

    /// "15:30", "in 5 min", "Tomorrow 09:00", "Thu 10:00".
    static func when(_ e: CalendarEvent, now: Date) -> String {
        let cal = Calendar.current
        let time = e.isAllDay ? CalL10n.allDay : e.start.formatted(date: .omitted, time: .shortened)
        if e.start <= now { return CalL10n.now }
        if cal.isDate(e.start, inSameDayAs: now) {
            return e.start.timeIntervalSince(now) <= 60 * 60 ? untilText(e.start, now: now) : time
        }
        if let t = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(e.start, inSameDayAs: t) { return CalL10n.tomorrow + " " + time }
        return e.start.formatted(.dateTime.weekday(.abbreviated).locale(L10n.locale)).capitalized(with: L10n.locale) + " " + time
    }

    static func openCalendarApp() {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Calendar's own event link; Calendar opened on its own when the link does not resolve.
    static func openInCalendar(_ e: CalendarEvent) {
        let id = e.eventKitID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? e.eventKitID
        if let url = URL(string: "ical://ekevent/\(id)?method=show&options=more"), NSWorkspace.shared.open(url) { return }
        openCalendarApp()
    }
}

extension Hotkey {
    /// "⌃⌥J", or nil when unset.
    var shortcutText: String? { modifiers == 0 ? nil : description }
}
