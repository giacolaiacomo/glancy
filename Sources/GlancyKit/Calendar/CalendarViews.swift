import SwiftUI

extension CalendarRGB {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b) }
}

private func shortTime(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }

/// "in 5 min" / "in 1 h 32 min" ("tra …" in Italian), to the minute: no seconds, and no
/// self-updating text that would wake the app every second while the panel is open.
func untilText(_ start: Date, now: Date = .now) -> String {
    let minutes = max(1, Int((start.timeIntervalSince(now) / 60).rounded(.up)))
    let body = minutes < 60 ? "\(minutes) min" : (minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min")
    return (CalL10n.italian ? "tra " : "in ") + body
}

struct CalendarDot: View {
    let color: CalendarRGB
    var size: CGFloat = 7
    var body: some View { Circle().fill(color.color).frame(width: size, height: size) }
}

struct JoinPill: View {
    let link: MeetingLink
    var eventID: String? = nil
    var interactive = true
    var compact = false
    var body: some View {
        let label = Text(verbatim: CalL10n.join)
            .font(Theme.font(compact ? .xs : .s, .semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, compact ? 7 : 10).padding(.vertical, compact ? 2 : 4)
            .background(Capsule().fill(Theme.primary))
            .fixedSize()
        if interactive {
            Button { CalendarJoin.join(link, eventID: eventID) } label: { label }.buttonStyle(.plain)
                .help(link.provider.displayName)
        } else { label }
    }
}

// MARK: Wings / peek

struct CalendarWingLeft: View {
    let event: CalendarEvent
    let phase: CalendarPhase
    var body: some View {
        HStack(spacing: 5) {
            CalendarDot(color: event.color)
            switch phase {
            case .soon:
                Text(verbatim: untilText(event.start))
                    .font(Theme.font(.s, .medium)).monospacedDigit()
                    .foregroundStyle(Theme.primary).lineLimit(1)
            case .imminent:
                Text(event.start, style: .timer)
                    .font(Theme.font(.s, .semibold)).monospacedDigit().foregroundStyle(Theme.primary)
            case .started:
                Text(verbatim: CalL10n.now).font(Theme.font(.s, .semibold)).foregroundStyle(Theme.primary)
            }
        }
        .padding(.leading, 6).frame(maxWidth: Theme.wingMaxWidth, alignment: .leading)
    }
}

struct CalendarWingRight: View {
    let event: CalendarEvent
    let phase: CalendarPhase
    var body: some View {
        Group {
            if phase != .soon, let link = event.link {
                JoinPill(link: link, interactive: false, compact: true)
            } else {
                Text(verbatim: event.title).font(Theme.font(.s)).foregroundStyle(Theme.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
        }
        .padding(.trailing, 6).frame(maxWidth: Theme.wingMaxWidth, alignment: .trailing)
    }
}

struct CalendarPeek: View {
    let event: CalendarEvent
    var body: some View {
        HStack(spacing: 8) {
            CalendarDot(color: event.color)
            Text(verbatim: event.title).font(Theme.font(.m, .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
            Text(verbatim: "· " + CalL10n.inTwo).font(Theme.font(.m)).foregroundStyle(Theme.secondary).fixedSize()
            Spacer(minLength: 4)
            if let link = event.link { JoinPill(link: link, eventID: event.id) }
        }
        .padding(.horizontal, 14)
    }
}

// MARK: Home card

struct CalendarHomeCard: View {
    let model: CalendarModel
    var body: some View {
        if let e = model.next {
            let live = e.start <= model.now
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(e.color.color).frame(width: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: e.title).font(Theme.font(.l, .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
                    HStack(spacing: 4) {
                        Text(verbatim: shortTime(e.start) + " – " + shortTime(e.end)).monospacedDigit()
                        Text(verbatim: "·")
                        if live { Text(verbatim: CalL10n.now) }
                        else { Text(verbatim: untilText(e.start)).monospacedDigit() }
                    }
                    .font(Theme.font(.s)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if let link = e.link { JoinPill(link: link, eventID: e.id) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: Tab

struct CalendarTabView: View {
    let model: CalendarModel
    var focus: FocusController? = nil
    var body: some View {
        switch model.access {
        case .denied: PermissionCard()
        case .notDetermined: Color.clear
        case .granted: Agenda(model: model, focus: focus)
        }
    }
}

struct PermissionCard: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.exclamationmark").font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.secondary)
            Text(verbatim: CalL10n.allowTitle).font(Theme.font(.xl, .semibold)).foregroundStyle(Theme.primary)
            Text(verbatim: CalL10n.allowBody).font(Theme.font(.m)).foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 340)
            Button { NSWorkspace.shared.open(CalendarJoin.privacyURL) } label: {
                Text(verbatim: CalL10n.openSettings).font(Theme.font(.s, .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 12).padding(.vertical, 5).background(Capsule().fill(Theme.primary))
            }.buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private enum AgendaItem: Identifiable {
    case event(CalendarEvent)
    case nowLine
    var id: String { switch self { case .event(let e): e.id; case .nowLine: "now" } }
}

/// Today's list on the left; the next events of the coming days on the right.
struct Agenda: View {
    let model: CalendarModel
    var focus: FocusController? = nil

    private func items(for day: CalendarLogic.Day) -> [AgendaItem] {
        var out: [AgendaItem] = []
        var placed = false
        for e in day.timed {
            if !placed, e.start > model.now { out.append(.nowLine); placed = true }
            out.append(.event(e))
        }
        if !placed, !day.timed.isEmpty { out.append(.nowLine) }
        return out
    }

    var body: some View {
        let today = CalendarLogic.agenda(model.events, now: model.now, days: 1).first
        let next = CalendarLogic.upcoming(model.events, now: model.now)
        let nextID = model.next?.id
        HStack(alignment: .top, spacing: 14) {
            // Today
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ColumnHeader(title: CalL10n.today, date: model.now)
                    Spacer(minLength: 4)
                    if let focus, focus.isOn { FocusOnChip(focus: focus) }
                }
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let today, !today.allDay.isEmpty { AllDayStrip(events: today.allDay) }
                        if let today, today.timed.isEmpty, today.allDay.isEmpty {
                            Text(verbatim: CalL10n.nothing).font(Theme.font(.s)).foregroundStyle(Theme.tertiary)
                        }
                        if let today {
                            ForEach(items(for: today)) { item in
                                switch item {
                                case .nowLine: NowLine()
                                case .event(let e): EventRow(event: e, now: model.now, isNext: e.id == nextID)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            Rectangle().fill(Theme.card).frame(width: 1)

            // The coming days
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: CalL10n.comingDays).font(Theme.font(.s, .semibold)).foregroundStyle(Theme.primary)
                if next.isEmpty {
                    Text(verbatim: CalL10n.nothingAhead).font(Theme.font(.s)).foregroundStyle(Theme.tertiary)
                }
                ForEach(Array(next.enumerated()), id: \.element.id) { i, e in
                    let newDay = i == 0 || !Calendar.current.isDate(e.start, inSameDayAs: next[i - 1].start)
                    UpcomingRow(event: e, showDay: newDay, now: model.now)
                }
            }
            .frame(width: 212, alignment: .topLeading)
        }
    }
}

private struct ColumnHeader: View {
    let title: String
    let date: Date
    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: title).font(Theme.font(.s, .semibold)).foregroundStyle(Theme.primary)
            Text(date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                .font(Theme.font(.s)).foregroundStyle(Theme.tertiary)
        }
    }
}

/// One event of the coming days: the day once per group ("Tomorrow", "Thu 8"), then time and title.
struct UpcomingRow: View {
    let event: CalendarEvent
    let showDay: Bool
    let now: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if showDay {
                Text(verbatim: dayLabel).font(Theme.font(.xs, .semibold)).foregroundStyle(Theme.tertiary)
                    .padding(.top, 2)
            }
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5).fill(event.color.color).frame(width: 3, height: 14)
                Text(verbatim: event.isAllDay ? CalL10n.allDay : shortTime(event.start))
                    .font(Theme.font(.xs)).monospacedDigit().foregroundStyle(Theme.secondary)
                    .frame(width: 40, alignment: .leading)
                Text(verbatim: event.title).font(Theme.font(.s)).foregroundStyle(Theme.primary).lineLimit(1)
            }
        }
    }

    private var dayLabel: String {
        let cal = Calendar.current
        if cal.isDateInTomorrow(event.start) { return CalL10n.tomorrow }
        return event.start.formatted(.dateTime.weekday(.wide).day().locale(L10n.locale)).capitalized(with: L10n.locale)
    }
}

struct AllDayStrip: View {
    let events: [CalendarEvent]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(events) { e in
                    HStack(spacing: 5) {
                        CalendarDot(color: e.color, size: 6)
                        Text(verbatim: e.title).font(Theme.font(.s)).foregroundStyle(Theme.primary).lineLimit(1)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.card))
                }
            }
        }
    }
}

struct NowLine: View {
    var body: some View {
        HStack(spacing: 0) {
            Circle().fill(Theme.failed).frame(width: 5, height: 5)
            Rectangle().fill(Theme.failed.opacity(0.55)).frame(height: 1)
        }
        .frame(height: 5)
    }
}

struct EventRow: View {
    let event: CalendarEvent
    let now: Date
    let isNext: Bool
    var body: some View {
        let past = event.end <= now
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(event.color.color.opacity(past ? 0.4 : 1)).frame(width: 3, height: 24)
            Text(verbatim: shortTime(event.start)).font(Theme.font(.s)).monospacedDigit()
                .foregroundStyle(past ? Theme.tertiary : Theme.secondary).frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: event.title).font(Theme.font(.m, .medium))
                    .foregroundStyle(past ? Theme.tertiary : Theme.primary).lineLimit(1)
                if let loc = event.location, !loc.isEmpty, event.link == nil || !loc.contains("://") {
                    Text(verbatim: loc).font(Theme.font(.xs)).foregroundStyle(Theme.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if isNext, event.start > now {
                Text(verbatim: untilText(event.start))
                    .font(Theme.font(.xs)).monospacedDigit().foregroundStyle(Theme.secondary)
            }
            if !past, let link = event.link { JoinPill(link: link, eventID: event.id) }
        }
        .frame(minHeight: 26)
    }
}

// MARK: Wave 4: overrun, end peeks, join notices, Focus chip

/// A soft red for "you're running late" (Theme.failed, toned down).
private let overrunTint = Theme.failed.opacity(0.9)

/// Left wing while the previous call ran over and the next one has started.
struct CalendarOverrunWingLeft: View {
    let previous: CalendarEvent
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(overrunTint).frame(width: 7, height: 7)
            Text(verbatim: CalL10n.late).font(Theme.font(.s, .semibold)).foregroundStyle(overrunTint).lineLimit(1)
        }
        .padding(.leading, 6).frame(maxWidth: Theme.wingMaxWidth, alignment: .leading)
        .help(CalL10n.overrunHelp)
    }
}

/// Title truncated to keep a peek inside its 440 pt drop-down.
private struct PeekTitle: View {
    let text: String
    var weight: Font.Weight = .semibold
    var maxWidth: CGFloat = 150
    var body: some View {
        Text(verbatim: text).font(Theme.font(.m, weight)).foregroundStyle(Theme.primary)
            .lineLimit(1).truncationMode(.tail).frame(maxWidth: maxWidth, alignment: .leading).fixedSize(horizontal: false, vertical: true)
    }
}

/// "● Design review · ends in 5 min · next: Standup at 15:30" / "Next: Standup · in 10 min [Join]".
struct MeetingEndPeekView: View {
    let peek: MeetingEndPeek
    let now: Date
    var body: some View {
        HStack(spacing: 4) {
            switch peek {
            case .ending(let e, let minutes, let next):
                CalendarDot(color: e.color).padding(.trailing, 3)
                PeekTitle(text: e.title, maxWidth: next == nil ? 200 : 120)
                Text(verbatim: "· " + CalL10n.endsIn(minutes)).font(Theme.font(.m)).foregroundStyle(Theme.secondary).fixedSize()
                if let next {
                    Text(verbatim: "·").font(Theme.font(.m)).foregroundStyle(Theme.tertiary)
                    nextLine(next)
                }
            case .backToBack(_, let next):
                CalendarDot(color: next.color).padding(.trailing, 3)
                Text(verbatim: CalL10n.next).font(Theme.font(.m)).foregroundStyle(Theme.secondary).fixedSize()
                PeekTitle(text: next.title, maxWidth: 170)
                Text(verbatim: "· " + (next.start <= now ? CalL10n.now : untilText(next.start, now: now)))
                    .font(Theme.font(.m)).monospacedDigit().foregroundStyle(Theme.secondary).fixedSize()
                if let link = next.link { JoinPill(link: link, eventID: next.id).padding(.leading, 4) }
            }
        }
        .padding(.horizontal, 12)
    }

    /// "next: Standup at 15:30", the title truncated in the middle of the sentence.
    @ViewBuilder private func nextLine(_ next: CalendarEvent) -> some View {
        let parts = CalL10n.nextAt("\u{1}", shortTime(next.start)).components(separatedBy: "\u{1}")
        Text(verbatim: (parts.first ?? "").trimmingCharacters(in: .whitespaces)).font(Theme.font(.m)).foregroundStyle(Theme.tertiary).fixedSize()
        Text(verbatim: next.title).font(Theme.font(.m, .medium)).foregroundStyle(Theme.secondary)
            .lineLimit(1).truncationMode(.tail).frame(maxWidth: 100, alignment: .leading)
        Text(verbatim: (parts.count > 1 ? parts[1] : "").trimmingCharacters(in: .whitespaces))
            .font(Theme.font(.m)).monospacedDigit().foregroundStyle(Theme.tertiary).fixedSize()
    }
}

/// The Join hotkey found nothing to join now: says so, and offers the next call.
struct CalendarNothingToJoinPeek: View {
    let later: CalendarEvent?
    let now: Date
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "video.slash").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
            Text(verbatim: CalL10n.nothingToJoin).font(Theme.font(.m, .semibold)).foregroundStyle(Theme.primary).fixedSize()
            if let later {
                Text(verbatim: "·").font(Theme.font(.m)).foregroundStyle(Theme.tertiary)
                PeekTitle(text: later.title, weight: .regular, maxWidth: 120)
                Text(verbatim: when(later)).font(Theme.font(.m)).monospacedDigit().foregroundStyle(Theme.secondary).fixedSize()
                if let link = later.link { JoinPill(link: link, eventID: later.id) }
            }
        }
        .padding(.horizontal, 12)
    }

    private func when(_ e: CalendarEvent) -> String {
        Calendar.current.isDate(e.start, inSameDayAs: now) ? shortTime(e.start)
            : e.start.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(L10n.locale))
    }
}

/// A one-line notice ("Link copied · Standup").
struct CalendarNoticePeek: View {
    let text: String
    var detail: String? = nil
    var symbol = "calendar"
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
            Text(verbatim: text).font(Theme.font(.m, .semibold)).foregroundStyle(Theme.primary).fixedSize()
            if let detail {
                Text(verbatim: "·").font(Theme.font(.m)).foregroundStyle(Theme.tertiary)
                PeekTitle(text: detail, weight: .regular, maxWidth: 200)
            }
        }
        .padding(.horizontal, 12)
    }
}

/// "☾ Focus on ✕" in the agenda header while Glancy holds Focus; the ✕ turns it off.
struct FocusOnChip: View {
    let focus: FocusController
    @State private var hover = false
    var body: some View {
        Button { focus.turnOffNow() } label: {
            HStack(spacing: 4) {
                Image(systemName: "moon.fill").font(.system(size: 9, weight: .semibold))
                Text(verbatim: CalL10n.focusOn).font(Theme.font(.xs, .semibold))
                Image(systemName: "xmark").font(.system(size: 7, weight: .bold)).opacity(hover ? 1 : 0.6)
            }
            .foregroundStyle(Color(red: 0.62, green: 0.58, blue: 1.0))
            .padding(.horizontal, 7).frame(height: 18)
            .background(Capsule().fill(Color(red: 0.62, green: 0.58, blue: 1.0).opacity(hover ? 0.24 : 0.14)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(CalL10n.cmdFocusOff)
    }
}
