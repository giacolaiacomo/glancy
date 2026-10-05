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
            Button { CalendarJoin.open(link) } label: { label }.buttonStyle(.plain)
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
            if let link = event.link { JoinPill(link: link) }
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
                if let link = e.link { JoinPill(link: link) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: Tab

struct CalendarTabView: View {
    let model: CalendarModel
    var body: some View {
        switch model.access {
        case .denied: PermissionCard()
        case .notDetermined: Color.clear
        case .granted: Agenda(model: model)
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

struct Agenda: View {
    let model: CalendarModel

    private func items(for day: CalendarLogic.Day, isToday: Bool) -> [AgendaItem] {
        var out: [AgendaItem] = []
        var placed = !isToday
        for e in day.timed {
            if !placed, e.start > model.now { out.append(.nowLine); placed = true }
            out.append(.event(e))
        }
        if !placed, !day.timed.isEmpty { out.append(.nowLine) }
        return out
    }

    var body: some View {
        let days = CalendarLogic.agenda(model.events, now: model.now)
        let nextID = model.next?.id
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(verbatim: index == 0 ? CalL10n.today : CalL10n.tomorrow)
                                .font(Theme.font(.s, .semibold)).foregroundStyle(Theme.primary)
                            Text(day.start, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                                .font(Theme.font(.s)).foregroundStyle(Theme.tertiary)
                        }
                        if !day.allDay.isEmpty { AllDayStrip(events: day.allDay) }
                        if day.timed.isEmpty && day.allDay.isEmpty {
                            Text(verbatim: CalL10n.nothing).font(Theme.font(.s)).foregroundStyle(Theme.tertiary)
                        }
                        ForEach(items(for: day, isToday: index == 0)) { item in
                            switch item {
                            case .nowLine: NowLine()
                            case .event(let e): EventRow(event: e, now: model.now, isNext: e.id == nextID)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
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
            if !past, let link = event.link { JoinPill(link: link) }
        }
        .frame(minHeight: 26)
    }
}
