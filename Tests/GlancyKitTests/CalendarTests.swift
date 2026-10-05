import Foundation
import Testing
@testable import GlancyKit

private func link(_ notes: String? = nil, url: URL? = nil, location: String? = nil) -> MeetingLink? {
    MeetingLink.extract(url: url, location: location, notes: notes)
}

@Suite struct MeetingLinkTests {
    @Test func zoomInvitationWithPasscode() throws {
        let notes = """
        Alex Rossi is inviting you to a scheduled Zoom meeting.

        Topic: Design review
        Join Zoom Meeting
        https://us02web.zoom.us/j/84512345678?pwd=Qk1mT2xYd3A5ZXlnN1pYb0E3dz09

        Meeting ID: 845 1234 5678
        Passcode: 123456
        One tap mobile: +390012345678,,84512345678#
        """
        let l = try #require(link(notes))
        #expect(l.provider == .zoom)
        #expect(l.webURL.host == "us02web.zoom.us")
        #expect(l.joinURL.scheme == "zoommtg")
        let c = URLComponents(url: l.joinURL, resolvingAgainstBaseURL: false)
        #expect(c?.host == "us02web.zoom.us")
        #expect(c?.path == "/join")
        #expect(c?.queryItems?.first { $0.name == "confno" }?.value == "84512345678")
        #expect(c?.queryItems?.first { $0.name == "pwd" }?.value == "Qk1mT2xYd3A5ZXlnN1pYb0E3dz09")
    }

    @Test func zoomPersonalRoomFallsBackToHTTPS() throws {
        let l = try #require(link("Join: https://acme.zoom.us/my/alex.rossi"))
        #expect(l.provider == .zoom)
        #expect(l.joinURL == l.webURL)
    }

    @Test func teamsNotesRewriteToNativeScheme() throws {
        let notes = """
        ________________________________________________________________________________
        Microsoft Teams meeting
        Join on your computer, mobile app or room device
        Click here to join the meeting <https://teams.microsoft.com/l/meetup-join/19%3ameeting_ZDk0YzE%40thread.v2/0?context=%7b%22Tid%22%3a%22abc%22%7d>
        Meeting ID: 345 678 901 234
        Learn More | Meeting options
        """
        let l = try #require(link(notes))
        #expect(l.provider == .teams)
        #expect(l.joinURL.scheme == "msteams")
        #expect(l.webURL.scheme == "https")
    }

    @Test func teamsLiveStaysHTTPS() throws {
        let l = try #require(link("https://teams.live.com/meet/9876543210"))
        #expect(l.provider == .teams)
        #expect(l.joinURL.scheme == "https")
    }

    @Test func googleMeetFromURLField() throws {
        let l = try #require(link(nil, url: URL(string: "https://meet.google.com/abc-defg-hij?authuser=0")))
        #expect(l.provider == .meet)
    }

    @Test func googleMeetInNotesIgnoresNonMeetingLinks() throws {
        let notes = """
        Agenda: https://docs.google.com/document/d/1AbC/edit
        Join with Google Meet: https://meet.google.com/xyz-abcd-efg
        Or dial: (IT) +39 02 1234 5678 PIN: 123 456 789#
        More phone numbers: https://tel.meet/xyz-abcd-efg?pin=1234567
        """
        let l = try #require(link(notes))
        #expect(l.provider == .meet)
        #expect(l.webURL.path == "/xyz-abcd-efg")
    }

    @Test func multipleMeetingLinksPicksFirstRecognisedInFieldOrder() throws {
        // url field beats location beats notes.
        let l1 = try #require(link("https://acme.zoom.us/j/111", url: URL(string: "https://meet.google.com/aaa-bbbb-ccc"), location: "https://whereby.com/room"))
        #expect(l1.provider == .meet)
        let l2 = try #require(link("https://acme.zoom.us/j/111", location: "https://whereby.com/acme-room"))
        #expect(l2.provider == .whereby)
        // Within notes: first meeting link wins, skipping a leading non-meeting one.
        let l3 = try #require(link("Slides https://notion.so/x then https://acme.zoom.us/j/222 and backup https://meet.google.com/aaa-bbbb-ccc"))
        #expect(l3.provider == .zoom)
    }

    @Test func webexWherebyFaceTime() throws {
        #expect(try #require(link("https://acme.webex.com/meet/alex")).provider == .webex)
        #expect(try #require(link("https://whereby.com/acme-standup")).provider == .whereby)
        #expect(try #require(link("https://facetime.apple.com/join#v=1&p=abc")).provider == .facetime)
    }

    @Test func noLinkCases() {
        #expect(link("Lunch at Da Mario, no link") == nil)
        #expect(link("https://zoom.us/support") == nil)
        #expect(link("https://example.com/j/123") == nil)
        #expect(link(nil) == nil)
    }
}

@Suite struct CalendarLogicTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func ev(_ id: String, start: TimeInterval, mins: Double = 30, allDay: Bool = false, declined: Bool = false, cal: String = "c") -> CalendarEvent {
        CalendarEvent(id: id, title: id, start: t0.addingTimeInterval(start), end: t0.addingTimeInterval(start + mins * 60),
                      isAllDay: allDay, isDeclined: declined, calendarID: cal)
    }

    @Test func sameMeetingOnTwoCalendarsShowsOnce() {
        let a = CalendarEvent(id: "a", title: "Standup", start: t0, end: t0 + 900, calendarID: "work")
        let b = CalendarEvent(id: "b", title: "standup ", start: t0, end: t0 + 900, calendarID: "personal")
        let c = CalendarEvent(id: "c", title: "Standup", start: t0 + 3600, end: t0 + 4500, calendarID: "work")
        #expect(CalendarLogic.visible([a, b, c]).map(\.id) == ["a", "c"])
    }

    @Test func boundariesAreTheFiveInstants() {
        let e = ev("a", start: 3600, mins: 45)
        let b = CalendarLogic.boundaries(of: e)
        #expect(b == [e.start - 900, e.start - 120, e.start, e.start + 2700, e.start + 300])
    }

    @Test func nextBoundaryAdvancesAndEndsNil() {
        let e = ev("a", start: 3600, mins: 30)
        let list = [e]
        #expect(CalendarLogic.nextBoundary(list, after: t0) == e.start - 900)
        #expect(CalendarLogic.nextBoundary(list, after: e.start - 900) == e.start - 120)
        #expect(CalendarLogic.nextBoundary(list, after: e.start - 119) == e.start)
        #expect(CalendarLogic.nextBoundary(list, after: e.start) == e.start + 300)
        #expect(CalendarLogic.nextBoundary(list, after: e.start + 300) == e.end)
        #expect(CalendarLogic.nextBoundary(list, after: e.end) == nil)
    }

    @Test func nextBoundaryTakesEarliestAcrossEvents() {
        let list = [ev("late", start: 7200), ev("soon", start: 1800)]
        #expect(CalendarLogic.nextBoundary(list, after: t0) == t0.addingTimeInterval(900))
    }

    @Test func declinedAndAllDayNeverCount() {
        let all = ev("allday", start: 600, allDay: true)
        let dec = ev("declined", start: 300, declined: true)
        let ok = ev("ok", start: 1200)
        #expect(CalendarLogic.countdownEvents([all, dec, ok]).map(\.id) == ["ok"])
        #expect(CalendarLogic.nextEvent([all, dec, ok], now: t0)?.id == "ok")
        #expect(CalendarLogic.nextBoundary([all, dec], after: t0) == nil)
        #expect(CalendarLogic.activeEvent([all, dec], now: t0.addingTimeInterval(400)) == nil)
        #expect(CalendarLogic.visible([all, dec, ok]).map(\.id) == ["allday", "ok"])
    }

    @Test func calendarSelectionFilters() {
        let a = ev("a", start: 100, cal: "work"), b = ev("b", start: 200, cal: "home")
        #expect(CalendarLogic.visible([a, b], calendarIDs: ["home"]).map(\.id) == ["b"])
        #expect(CalendarLogic.visible([a, b], calendarIDs: nil).count == 2)
        #expect(CalendarLogic.visible([a, b], calendarIDs: []).isEmpty)
    }

    @Test func phasesFollowTheSpec() {
        let e = ev("m", start: 3600)
        func p(_ off: TimeInterval) -> CalendarPhase? { CalendarLogic.phase(of: e, now: e.start.addingTimeInterval(off)) }
        #expect(p(-1000) == nil)
        #expect(p(-900) == .soon)
        #expect(p(-121) == .soon)
        #expect(p(-120) == .imminent)
        #expect(p(-1) == .imminent)
        #expect(p(0) == .started)
        #expect(p(299) == .started)
        #expect(p(300) == nil)
        #expect(CalendarPhase.soon.priority == 20)
        #expect(CalendarPhase.imminent.priority == 85)
        #expect(CalendarPhase.started.priority == 85)
    }

    @Test func activeEventPrefersHigherPhase() {
        let running = ev("just-started", start: 0)             // started
        let upcoming = ev("upcoming", start: 600)              // soon at +100 s
        let r = CalendarLogic.activeEvent([upcoming, running], now: t0.addingTimeInterval(100))
        #expect(r?.event.id == "just-started")
        #expect(r?.phase == .started)
    }

    @Test func agendaSplitsDaysAndAllDay() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: Double(1_800_000_000 - 1_800_000_000 % 86400 + 10 * 3600))
        let day0 = cal.startOfDay(for: now)
        let today = CalendarEvent(id: "t", title: "t", start: day0 + 11 * 3600, end: day0 + 12 * 3600)
        let tomorrow = CalendarEvent(id: "m", title: "m", start: day0 + 86400 + 9 * 3600, end: day0 + 86400 + 10 * 3600)
        let allDay = CalendarEvent(id: "a", title: "a", start: day0, end: day0 + 86400, isAllDay: true)
        let hidden = CalendarEvent(id: "d", title: "d", start: day0 + 3600, end: day0 + 7200, isDeclined: true)
        let days = CalendarLogic.agenda([tomorrow, hidden, today, allDay], now: now, calendar: cal)
        #expect(days.count == 2)
        #expect(days[0].timed.map(\.id) == ["t"])
        #expect(days[0].allDay.map(\.id) == ["a"])
        #expect(days[1].timed.map(\.id) == ["m"])
        #expect(days[1].allDay.isEmpty)
    }
}

@MainActor @Suite struct CalendarModuleTests {
    final class FakeSource: CalendarEventSource {
        var authorization: CalendarAccess = .granted
        var all: [CalendarEvent] = []
        func requestAccess() async -> Bool { true }
        func calendars() -> [CalendarInfo] { [CalendarInfo(id: "c", title: "Work"), CalendarInfo(id: "h", title: "Home")] }
        func events(from: Date, to: Date, calendarIDs: Set<String>?) -> [CalendarEvent] {
            all.filter { $0.start < to && $0.end > from }
        }
    }

    @Test func settingsPersistAndDefaultToAll() {
        let d = UserDefaults(suiteName: "glancy.test.\(UUID().uuidString)")!
        let s = CalendarSettings(defaults: d)
        s.availableCalendars = [CalendarInfo(id: "c", title: "Work"), CalendarInfo(id: "h", title: "Home")]
        #expect(s.selectedCalendarIDs == nil)
        #expect(s.isSelected("c"))
        s.setSelected("h", false)
        #expect(s.selectedCalendarIDs == ["c"])
        #expect(CalendarSettings(defaults: d).selectedCalendarIDs == ["c"])
        s.setSelected("h", true)
        #expect(s.selectedCalendarIDs == nil)
        #expect(d.array(forKey: CalendarSettings.defaultsKey) == nil)
    }

    @Test func imminentMeetingPostsActivityAndPeek() {
        let src = FakeSource()
        let start = Date.now.addingTimeInterval(90)
        src.all = [CalendarEvent(id: "x", title: "Design review", start: start, end: start.addingTimeInterval(1800),
                                 calendarID: "c", link: MeetingLink.extract(url: nil, location: nil, notes: "https://meet.google.com/abc-defg-hij"))]
        let m = CalendarModule(source: src, settings: CalendarSettings(defaults: UserDefaults(suiteName: "glancy.test.\(UUID().uuidString)")!))
        let hub = ActivityHub()
        m.start(hub: hub)
        m.refresh()
        #expect(hub.top?.id == "calendar")
        #expect(hub.top?.priority == 85)
        #expect(hub.peek?.module == .calendar)
        m.stop()
        #expect(hub.top == nil)
    }

    @Test func deniedShowsNoHomeCardAndNoActivity() {
        let src = FakeSource(); src.authorization = .denied
        let m = CalendarModule(source: src, settings: CalendarSettings(defaults: UserDefaults(suiteName: "glancy.test.\(UUID().uuidString)")!))
        let hub = ActivityHub()
        m.start(hub: hub); m.refresh()
        #expect(m.model.access == .denied)
        #expect(m.homeCard() == nil)
        #expect(hub.top == nil)
        m.stop()
    }
}

@Suite("Calendar countdown text")
struct CalendarUntilTextTests {
    @Test func roundsUpToTheMinuteWithoutSeconds() {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        #expect(untilText(now.addingTimeInterval(302), now: now).hasSuffix("6 min"))
        #expect(untilText(now.addingTimeInterval(20), now: now).hasSuffix("1 min"))
        #expect(untilText(now.addingTimeInterval(92 * 60), now: now).hasSuffix("1 h 32 min"))
        #expect(untilText(now.addingTimeInterval(120 * 60), now: now).hasSuffix("2 h"))
    }
}
