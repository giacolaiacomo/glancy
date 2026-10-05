import AppKit
import Foundation
import Testing
@testable import GlancyKit

// Wave 4 FO: Focus during meetings and Pomodoro, end warnings, back-to-back, overrun, the Join
// target, the Pomodoro state machine and the command-bar parsing (EN + IT). No real `shortcuts`
// is ever run: the controller gets a recording runner.

private let base = Date(timeIntervalSinceReferenceDate: 800_000_000)   // a fixed instant
private func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }
private let meet = MeetingLink.extract(url: nil, location: nil, notes: "https://meet.google.com/abc-defg-hij")

private func ev(_ id: String, _ from: Double, _ to: Double, link: Bool = true, busy: Bool = true, title: String? = nil,
                declined: Bool = false, allDay: Bool = false) -> CalendarEvent {
    CalendarEvent(id: id, title: title ?? id, start: at(from), end: at(to), isAllDay: allDay, isDeclined: declined,
                  calendarID: "c", link: link ? meet : nil, isBusy: busy)
}

private func suite() -> UserDefaults {
    let name = "glancy.test.fo.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

actor RecordingRunner: ShortcutRunning {
    private(set) var runs: [String] = []
    var succeeds = true
    var names: [String]? = [FocusController.onShortcut, FocusController.offShortcut, "Other"]
    private(set) var lists = 0
    func list() async -> [String]? { lists += 1; return names }
    func run(_ name: String) async -> Bool { runs.append(name); return succeeds }
    func setSucceeds(_ v: Bool) { succeeds = v }
    func setNames(_ v: [String]?) { names = v }
}

private let on = FocusController.onShortcut
private let off = FocusController.offShortcut

// MARK: Pure meeting logic

@Suite struct MeetingFocusLogicTests {
    @Test func eligibilityFollowsTrigger() {
        let call = ev("call", 0, 30), plain = ev("plain", 0, 30, link: false), free = ev("free", 0, 30, busy: false)
        #expect(MeetingFocusLogic.eligible(call, trigger: .calls))
        #expect(!MeetingFocusLogic.eligible(plain, trigger: .calls))
        #expect(MeetingFocusLogic.eligible(plain, trigger: .busy))
        #expect(!MeetingFocusLogic.eligible(free, trigger: .busy))
        #expect(!MeetingFocusLogic.eligible(ev("d", 0, 30, declined: true), trigger: .busy))
        #expect(!MeetingFocusLogic.eligible(ev("a", 0, 1440, allDay: true), trigger: .busy))
    }

    @Test func onExactlyBetweenStartAndEnd() {
        let e = [ev("a", 0, 30)]
        #expect(!MeetingFocusLogic.wants(e, now: at(-0.01), trigger: .calls, skipped: []))
        #expect(MeetingFocusLogic.wants(e, now: at(0), trigger: .calls, skipped: []))
        #expect(MeetingFocusLogic.wants(e, now: at(29.9), trigger: .calls, skipped: []))
        #expect(!MeetingFocusLogic.wants(e, now: at(30), trigger: .calls, skipped: []))
    }

    @Test func overlapsAndBackToBackStayOn() {
        let overlap = [ev("a", 0, 60), ev("b", 30, 90)]
        for m in [0.0, 59.9, 60, 75] { #expect(MeetingFocusLogic.wants(overlap, now: at(m), trigger: .calls, skipped: [])) }
        #expect(!MeetingFocusLogic.wants(overlap, now: at(90), trigger: .calls, skipped: []))
        let chain = [ev("a", 0, 60), ev("b", 60, 90)]
        #expect(MeetingFocusLogic.wants(chain, now: at(60), trigger: .calls, skipped: []))
    }

    @Test func skippedMeetingStaysOffButTheNextTurnsOn() {
        let e = [ev("a", 0, 60), ev("b", 30, 90), ev("c", 120, 150)]
        // Turned off by hand at 0:45: both meetings in progress are skipped…
        let skipped = Set(MeetingFocusLogic.current(e, now: at(45), trigger: .calls).map(\.id))
        #expect(skipped == ["a", "b"])
        #expect(!MeetingFocusLogic.wants(e, now: at(70), trigger: .calls, skipped: skipped))
        // …the next one is not.
        #expect(MeetingFocusLogic.wants(e, now: at(125), trigger: .calls, skipped: skipped))
        #expect(MeetingFocusLogic.pruneSkipped(skipped, events: e, now: at(70)) == ["b"])
    }
}

@Suite struct MeetingEndLogicTests {
    let day = [ev("a", 0, 60, title: "Design review"), ev("b", 70, 100, title: "Standup"), ev("c", 300, 330, title: "Late")]

    @Test func endingWarningFromEndMinusN() {
        #expect(MeetingEndLogic.due(day, now: at(54.9), warningMinutes: 5).isEmpty)
        let p = MeetingEndLogic.due(day, now: at(55.5), warningMinutes: 5)
        #expect(p == [.ending(day[0], minutes: 5, next: day[1])])
        #expect(p.first?.key == "end:a")
        #expect(MeetingEndLogic.due(day, now: at(55.5), warningMinutes: 0).isEmpty)
        #expect(MeetingEndLogic.due(day, now: at(55.5), warningMinutes: 2).isEmpty)
        // The last meeting of the day ends with no "next".
        #expect(MeetingEndLogic.due(day, now: at(326), warningMinutes: 5) == [.ending(day[2], minutes: 4, next: nil)])
    }

    @Test func noWarningForMeetingsShorterThanIt() {
        let short = [ev("s", 0, 5)]
        #expect(MeetingEndLogic.due(short, now: at(0.5), warningMinutes: 10).isEmpty)
        #expect(MeetingEndLogic.due(short, now: at(0.5), warningMinutes: 5).isEmpty)
    }

    @Test func backToBackAtTheEnd() {
        // b starts 10 min after a ends: nudge right at the end, and only then.
        #expect(MeetingEndLogic.due(day, now: at(60.01), warningMinutes: 0) == [.backToBack(ended: day[0], next: day[1])])
        #expect(MeetingEndLogic.due(day, now: at(62), warningMinutes: 0).isEmpty)
        // b ends at 100, c starts 200 min later: not back-to-back.
        #expect(MeetingEndLogic.due(day, now: at(100.01), warningMinutes: 0).isEmpty)
        // Gap 0.
        let chain = [ev("x", 0, 30), ev("y", 30, 60)]
        #expect(MeetingEndLogic.due(chain, now: at(30.01), warningMinutes: 0) == [.backToBack(ended: chain[0], next: chain[1])])
    }

    @Test func endWarningIsAScheduledBoundary() {
        let one = [ev("a", 0, 60)]
        #expect(CalendarLogic.nextBoundary(one, after: at(20), endWarning: 300) == at(55))
        #expect(CalendarLogic.nextBoundary(one, after: at(20), endWarning: 0) == at(60))
    }

    @Test func overrunOnlyAfterJoiningThePreviousCall() {
        let chain = [ev("a", 0, 30), ev("b", 30, 60)]
        #expect(MeetingEndLogic.overrun(chain, now: at(31), joined: []) == nil)
        let o = MeetingEndLogic.overrun(chain, now: at(31), joined: ["a"])
        #expect(o?.previous.id == "a" && o?.next.id == "b")
        #expect(MeetingEndLogic.overrun(chain, now: at(31), joined: ["a", "b"]) == nil)   // joined the next one
        #expect(MeetingEndLogic.overrun(chain, now: at(35.1), joined: ["a"]) == nil)       // after the first five minutes
        #expect(MeetingEndLogic.overrun(chain, now: at(29), joined: ["a"]) == nil)         // a hasn't ended
        // A gap of more than a minute is not an overrun.
        let gap = [ev("a", 0, 30), ev("b", 40, 60)]
        #expect(MeetingEndLogic.overrun(gap, now: at(41), joined: ["a"]) == nil)
    }
}

@Suite struct MeetingJoinLogicTests {
    @Test func picksTheCallClosestToNow() {
        let running = ev("running", 0, 60), next = ev("next", 60, 90)
        #expect(MeetingJoinLogic.target([running, next], now: at(30))?.id == "running")   // next is 30' away
        #expect(MeetingJoinLogic.target([running, next], now: at(55))?.id == "next")      // starts in 5'
        #expect(MeetingJoinLogic.target([running, next], now: at(61))?.id == "next")
    }

    @Test func ignoresLinklessDeclinedAndFarCalls() {
        let e = [ev("nolink", 0, 60, link: false), ev("declined", 0, 60, declined: true), ev("far", 30, 60)]
        #expect(MeetingJoinLogic.target(e, now: at(5)) == nil)
        #expect(MeetingJoinLogic.later(e, now: at(5))?.id == "far")
        #expect(MeetingJoinLogic.linkTarget(e, now: at(5))?.id == "far")
        #expect(MeetingJoinLogic.target(e, now: at(21))?.id == "far")
    }

    @Test func tieGoesToTheLaterStart() {
        let e = [ev("a", 0, 30), ev("b", 10, 40)]
        #expect(MeetingJoinLogic.target(e, now: at(5))?.id == "b")
    }
}

@Suite struct CalendarSearchTests {
    let events = [ev("1", 30, 60, title: "Design review"), ev("2", 120, 150, title: "Weekly standup"),
                  ev("3", -60, -30, title: "Design sync"), ev("4", 200, 230, title: "Riunione Ufficio")]

    @Test func matchesTitlesPrefixFirst() {
        let r = CalendarSearch.match(events, query: "design", now: at(0))
        #expect(r.map(\.event.id) == ["1"])            // the ended "Design sync" is out
        #expect(CalendarSearch.match(events, query: "stand", now: at(0)).first?.score == 80)
        #expect(CalendarSearch.match(events, query: "ekly", now: at(0)).first?.score == 60)
        #expect(CalendarSearch.match(events, query: "x", now: at(0)).isEmpty)
    }

    @Test func joinWordsAndAccentsAreIgnored() {
        #expect(CalendarSearch.match(events, query: "join standup", now: at(0)).map(\.event.id) == ["2"])
        #expect(CalendarSearch.match(events, query: "partecipa ufficio", now: at(0)).map(\.event.id) == ["4"])
        #expect(CalendarSearch.match(events, query: "RIUNIONE", now: at(0)).map(\.event.id) == ["4"])
    }
}

// MARK: The controller

@MainActor @Suite struct FocusControllerTests {
    @Test func setupFromTheShortcutList() {
        #expect(FocusController.setup(from: nil) == .unavailable)
        #expect(FocusController.setup(from: ["glancy focus on", "Glancy Focus Off"]) == .ready)
        #expect(FocusController.setup(from: ["Glancy Focus On"]) == .missing([off]))
    }

    @Test func onceOnOnceOffWithTwoOwners() async {
        let runner = RecordingRunner()
        let f = FocusController(runner: runner, defaults: suite())
        f.register("calendar") {}
        f.register("timer") {}
        f.claim("calendar", true)
        f.claim("timer", true)
        f.claim("calendar", false)            // the timer still wants it
        f.claim("timer", false)
        await f.settle()
        #expect(await runner.runs == [on, off])
        #expect(!f.isOn)
    }

    @Test func neverTurnsOffWhatItDidNotTurnOn() async {
        let runner = RecordingRunner()
        let f = FocusController(runner: runner, defaults: suite())
        f.register("calendar") {}
        f.claim("calendar", false)
        f.claim("calendar", false)
        await f.settle()
        #expect(await runner.runs.isEmpty)
    }

    @Test func relaunchWaitsForEveryOwnerBeforeTurningOff() async {
        let d = suite()
        d.set(true, forKey: FocusController.isOnKey)          // quit mid-meeting
        let runner = RecordingRunner()
        let f = FocusController(runner: runner, defaults: d)
        f.register("calendar") {}
        f.register("timer") {}
        f.claim("timer", false)
        await f.settle()
        #expect(await runner.runs.isEmpty)                    // the calendar hasn't spoken yet
        f.claim("calendar", false)
        await f.settle()
        #expect(await runner.runs == [off])
        #expect(d.bool(forKey: FocusController.isOnKey) == false)
    }

    @Test func failedOnIsNotRetriedAndNeverTurnedOff() async {
        let runner = RecordingRunner()
        await runner.setSucceeds(false)
        await runner.setNames([])
        let f = FocusController(runner: runner, defaults: suite())
        f.register("calendar") {}
        f.claim("calendar", true)
        await f.settle()
        #expect(!f.isOn)
        #expect(f.lastRunFailed)
        f.claim("calendar", true)                           // the panel opened: no retry storm
        f.claim("calendar", false)                          // meeting over: nothing to turn off
        await f.settle()
        #expect(await runner.runs == [on])
        #expect(f.setup == .missing([on, off]))
    }

    @Test func frozenRunsNothing() async {
        let runner = RecordingRunner()
        let f = FocusController(runner: runner, defaults: suite())
        f.prepareForRender(.missing([on]))
        f.register("calendar") {}
        f.claim("calendar", true)
        f.checkSetup()
        await f.settle()
        #expect(await runner.runs.isEmpty)
        #expect(await runner.lists == 0)
    }
}

// MARK: The calendar module across meeting boundaries

@MainActor @Suite struct CalendarMeetingModuleTests {
    final class Source: CalendarEventSource {
        var authorization: CalendarAccess = .granted
        var all: [CalendarEvent] = []
        func requestAccess() async -> Bool { true }
        func calendars() -> [CalendarInfo] { [CalendarInfo(id: "c", title: "Work")] }
        func events(from: Date, to: Date, calendarIDs: Set<String>?) -> [CalendarEvent] { all }
    }

    private func make(_ events: [CalendarEvent], focus: FocusController?, trigger: MeetingFocusTrigger = .calls)
        -> (CalendarModule, ActivityHub) {
        let src = Source()
        src.all = events
        let settings = CalendarSettings(defaults: suite())
        settings.focusDuringMeetings = true
        settings.focusTrigger = trigger
        let m = CalendarModule(source: src, settings: settings, focus: focus)
        m.clock = { at(-30) }
        let hub = ActivityHub()
        m.start(hub: hub)
        return (m, hub)
    }

    private func step(_ m: CalendarModule, _ minutes: Double) {
        m.clock = { at(minutes) }
        m.refresh()
    }

    @Test func focusAcrossOverlapsAndBackToBack() async {
        let runner = RecordingRunner()
        let f = FocusController(runner: runner, defaults: suite())
        let (m, _) = make([ev("a", 0, 60), ev("b", 30, 90), ev("c", 90, 120), ev("d", 200, 230)], focus: f)
        for t in [-1.0, 0, 30, 59.9, 60, 90, 119] { step(m, t) }
        await f.settle()
        #expect(await runner.runs == [on])
        step(m, 120)
        step(m, 150)
        step(m, 200)
        step(m, 230)
        await f.settle()
        #expect(await runner.runs == [on, off, on, off])
        m.stop()
    }

    @Test func linklessMeetingsNeedTheBusyTrigger() async {
        let runner = RecordingRunner()
        let f = FocusController(runner: runner, defaults: suite())
        let (m, _) = make([ev("a", 0, 30, link: false), ev("free", 40, 50, link: true, busy: false)], focus: f)
        step(m, 1); step(m, 45)
        await f.settle()
        #expect(await runner.runs.isEmpty)
        m.settings.focusTrigger = .busy
        step(m, 2)
        await f.settle()
        #expect(await runner.runs == [on])
        m.stop()                                            // turning the module off lets go of Focus
        await f.settle()
        #expect(await runner.runs == [on, off])
    }

    @Test func manualOffHoldsForTheMeetingNotTheNextOne() async {
        let runner = RecordingRunner()
        let f = FocusController(runner: runner, defaults: suite())
        let (m, _) = make([ev("a", 0, 60), ev("b", 60, 90)], focus: f)
        step(m, 5)
        f.turnOffNow()
        step(m, 20); step(m, 59)
        await f.settle()
        #expect(await runner.runs == [on, off])
        #expect(!f.isOn)
        step(m, 60)                                         // b starts: on again
        await f.settle()
        #expect(await runner.runs == [on, off, on])
        m.stop()
    }

    @Test func settingOffMeansNoFocus() async {
        let runner = RecordingRunner()
        let f = FocusController(runner: runner, defaults: suite())
        let (m, _) = make([ev("a", 0, 60)], focus: f)
        m.settings.focusDuringMeetings = false
        step(m, 5)
        await f.settle()
        #expect(await runner.runs.isEmpty)
        m.stop()
    }

    @Test func endPeekShowsOnce() {
        let (m, hub) = make([ev("a", 0, 60), ev("b", 65, 90)], focus: nil)
        step(m, 56)
        #expect(hub.peek?.module == .calendar)
        let first = hub.peek?.id
        step(m, 57)
        #expect(hub.peek?.id == first)                       // nothing new queued behind it
        m.stop()
    }

    @Test func joinHotkeyTargetAndOverrun() {
        let (m, _) = make([ev("a", 0, 30), ev("b", 30, 60)], focus: nil)
        var opened: [String] = []
        m.opener = { opened.append($0.webURL.absoluteString) }
        step(m, 10)
        m.joinNow()
        #expect(opened.count == 1)
        #expect(m.joined == ["a"])
        step(m, 31)                                         // a ran over, b has started
        #expect(MeetingEndLogic.overrun(m.model.events, now: at(31), joined: m.joined) != nil)
        m.joinNow()                                         // b is now the closest
        #expect(m.joined == ["a", "b"])
        #expect(MeetingEndLogic.overrun(m.model.events, now: at(31), joined: m.joined) == nil)
        m.stop()
    }

    @Test func joinWithNothingToJoinPeeks() {
        let (m, hub) = make([ev("later", 120, 150)], focus: nil)
        var opened = 0
        m.opener = { _ in opened += 1 }
        step(m, 0)
        m.joinNow()
        #expect(opened == 0)
        #expect(hub.peek?.module == .calendar)
        m.stop()
    }

    @Test func copyLinkUsesTheJoinTarget() {
        let (m, _) = make([ev("a", 0, 30)], focus: nil)
        step(m, -5)
        let pb = NSPasteboard(name: .init("glancy.test.\(UUID().uuidString)"))
        m.copyLink(to: pb)
        #expect(pb.string(forType: .string) == "https://meet.google.com/abc-defg-hij")
        m.stop()
    }

    @Test func commandBarEntries() {
        let (m, _) = make([ev("a", 5, 30, title: "Design review"), ev("b", 300, 330, title: "Budget")], focus: nil)
        step(m, 0)
        let ids = m.commands().map(\.id)
        #expect(ids.contains("calendar.join") && ids.contains("calendar.copyLink") && ids.contains("calendar.openApp")
                && ids.contains("calendar.agenda"))
        #expect(!ids.contains("calendar.focusOff"))
        let r = m.results(for: "design")
        #expect(r.count == 1 && r[0].title == "Design review" && r[0].symbol == "video.fill")   // joinable now
        #expect(m.results(for: "budget").first?.symbol == "calendar")                          // opens in Calendar
        #expect(m.results(for: "zzz").isEmpty)
        m.stop()
    }
}

// MARK: Pomodoro

@Suite struct PomodoroMachineTests {
    @Test func fullCycleWithAutoStart() {
        var s = TimerState()
        TimerMachine.startPomodoro(&s, now: base)
        var tally: PomodoroTally?
        let events = TimerMachine.advance(&s, now: base.addingTimeInterval(4 * 3600))
        PomodoroTally.record(&tally, events: events, now: base)
        #expect(events.count == 8)                          // 7 phase changes + cycle complete
        #expect(events.last == .cycleComplete)
        #expect(tally?.count == 4)
        #expect(s.status == .idle)
    }

    @Test func withoutAutoStartEachPhaseWaits() {
        var s = TimerState()
        TimerMachine.startPomodoro(&s, now: base)
        let e = TimerMachine.advance(&s, now: base.addingTimeInterval(3 * 3600), autoStart: false)
        #expect(e == [.phaseChanged(from: 0, to: 1)])        // stops at the first boundary
        #expect(s.isHeld && s.phase == 1 && !s.isFocusBlock)
        #expect(TimerMachine.remaining(s, now: .distantFuture) == Pomodoro.duration(of: 1))
        TimerMachine.resume(&s, now: base.addingTimeInterval(3 * 3600))
        #expect(s.status == .running && !s.isHeld)
    }

    @Test func skipStartsTheNextPhaseAndDoesNotCount() {
        var s = TimerState()
        TimerMachine.startPomodoro(&s, now: base)
        #expect(TimerMachine.skip(&s, now: at(3)) == nil)
        #expect(s.phase == 1 && s.deadline == at(3).addingTimeInterval(Pomodoro.duration(of: 1)))
        s.phase = Pomodoro.lastPhase
        #expect(TimerMachine.skip(&s, now: at(4)) == .cycleComplete)
        #expect(s.status == .idle)
        var plain = TimerState()
        TimerMachine.start(&plain, minutes: 5, now: base)
        #expect(TimerMachine.skip(&plain, now: at(1)) == nil && plain.phase == nil)
    }

    @Test func tallyResetsOnANewDay() {
        var t: PomodoroTally? = PomodoroTally(day: Calendar.current.startOfDay(for: base), count: 3)
        PomodoroTally.record(&t, events: [.phaseChanged(from: 0, to: 1), .phaseChanged(from: 1, to: 2)], now: base)
        #expect(t?.count == 4)
        let tomorrow = base.addingTimeInterval(86_400)
        #expect(PomodoroTally.today(t, now: tomorrow) == 0)
        PomodoroTally.record(&t, events: [.phaseChanged(from: 2, to: 3)], now: tomorrow)
        #expect(t?.count == 1)
    }

    @Test func breakTimerIsGreenAndNotAFocusBlock() {
        var s = TimerState()
        TimerMachine.start(&s, minutes: 5, now: base, isBreak: true)
        #expect(s.isBreakRun && !s.isFocusBlock)
        TimerMachine.startPomodoro(&s, now: base)
        #expect(s.isBreak == nil && s.isFocusBlock)
    }

    @Test func oldSnapshotsStillDecode() throws {
        let json = #"{"state":{"status":"running","duration":60,"deadline":0,"pausedRemaining":0},"customMinutes":7}"#
        let snap = try JSONDecoder().decode(TimerSnapshot.self, from: Data(json.utf8))
        #expect(snap.customMinutes == 7 && snap.tally == nil && snap.state.isBreak == nil)
    }
}

@MainActor @Suite struct TimerFocusModuleTests {
    private func module(_ focus: FocusController, autoStart: Bool = true) -> TimerModule {
        let settings = TimerSettings(defaults: suite())
        settings.focusDuringWork = true
        settings.autoStartNext = autoStart
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("glancy-fo-\(UUID().uuidString)/timer.json")
        return TimerModule(store: TimerStore(url: url), alerts: SilentRecorder(), settings: settings, focus: focus)
    }

    @Test func focusDuringWorkRoundsOnly() async {
        let runner = RecordingRunner()
        let f = FocusController(runner: runner, defaults: suite())
        let m = module(f)
        m.start(hub: ActivityHub())
        m.startPomodoro()
        m.pause()                                            // a short pause keeps Focus
        m.resume()
        await f.settle()
        #expect(await runner.runs == [on])
        m.skip()                                             // a break: Focus off
        await f.settle()
        #expect(await runner.runs == [on, off])
        m.skip()                                             // the next focus round
        f.turnOffNow()                                       // turned off by hand…
        m.addMinute()
        await f.settle()
        #expect(await runner.runs == [on, off, on, off])     // …and not back this round
        m.stopTimer()
        m.stop()
    }

    @Test func plainTimersNeverClaim() async {
        let runner = RecordingRunner()
        let f = FocusController(runner: runner, defaults: suite())
        let m = module(f)
        m.start(hub: ActivityHub())
        m.start(minutes: 10)
        m.startBreak(minutes: 5)
        await f.settle()
        #expect(await runner.runs.isEmpty)
        m.stopTimer()
        m.stop()
    }

    @Test func commandsFollowTheState() {
        let m = module(FocusController(runner: RecordingRunner(), defaults: suite()))
        m.start(hub: ActivityHub())
        var ids = m.commands().map(\.id)
        #expect(ids.contains("timer.pomodoro") && ids.contains("timer.preset.25") && !ids.contains("timer.stop"))
        #expect(m.results(for: "stop timer").isEmpty)        // nothing to stop
        m.startPomodoro()
        ids = m.commands().map(\.id)
        #expect(ids.contains("timer.stop") && ids.contains("timer.pause") && ids.contains("timer.skip"))
        #expect(m.results(for: "ferma").map(\.id) == ["timer.stop"])
        #expect(m.results(for: "timer 10").map(\.id) == ["timer.start.10"])
        #expect(m.results(for: "pausa 5").map(\.id) == ["timer.break.5"])
        #expect(m.results(for: "pomodoro").map(\.id) == ["timer.pomodoro"])
        m.stopTimer()
        m.stop()
    }
}

private final class SilentRecorder: TimerAlerting {
    func schedule(at date: Date, title: String, body: String) {}
    func cancel() {}
}

@Suite struct TimerQueryTests {
    @Test func english() {
        #expect(TimerQuery.parse("timer 10") == .start(minutes: 10))
        #expect(TimerQuery.parse("10 min") == .start(minutes: 10))
        #expect(TimerQuery.parse("10m") == .start(minutes: 10))
        #expect(TimerQuery.parse("25 minutes") == .start(minutes: 25))
        #expect(TimerQuery.parse("1h30") == .start(minutes: 90))
        #expect(TimerQuery.parse("1 h 15 min") == .start(minutes: 75))
        #expect(TimerQuery.parse("set a timer for 20 min") == .start(minutes: 20))
        #expect(TimerQuery.parse("timer 1:30") == .start(minutes: 90))
        #expect(TimerQuery.parse("15 min timer") == .start(minutes: 15))
        #expect(TimerQuery.parse("break 5") == .breakTimer(minutes: 5))
        #expect(TimerQuery.parse("Pomodoro") == .pomodoro)
        #expect(TimerQuery.parse("pomo") == .pomodoro)
        #expect(TimerQuery.parse("stop timer") == .stop)
        #expect(TimerQuery.parse("pause") == .pause)
        #expect(TimerQuery.parse("resume") == .resume)
        #expect(TimerQuery.parse("skip") == .skip)
    }

    @Test func italian() {
        #expect(TimerQuery.parse("timer 25") == .start(minutes: 25))
        #expect(TimerQuery.parse("timer di 25 minuti") == .start(minutes: 25))
        #expect(TimerQuery.parse("10 minuti") == .start(minutes: 10))
        #expect(TimerQuery.parse("1 ora e 30") == .start(minutes: 90))
        #expect(TimerQuery.parse("2 ore") == .start(minutes: 120))
        #expect(TimerQuery.parse("pausa 5") == .breakTimer(minutes: 5))
        #expect(TimerQuery.parse("pausa di 10 minuti") == .breakTimer(minutes: 10))
        #expect(TimerQuery.parse("pausa") == .pause)
        #expect(TimerQuery.parse("ferma il timer") == .stop)
        #expect(TimerQuery.parse("riprendi") == .resume)
        #expect(TimerQuery.parse("salta") == .skip)
        #expect(TimerQuery.parse("avvia pomodoro") == .pomodoro)
    }

    @Test func notForTheTimer() {
        #expect(TimerQuery.parse("25") == nil)               // a bare number is the calculator's
        #expect(TimerQuery.parse("1:30") == nil)
        #expect(TimerQuery.parse("timer") == nil)
        #expect(TimerQuery.parse("timer 0") == nil)
        #expect(TimerQuery.parse("timer 999") == nil)
        #expect(TimerQuery.parse("pom") == nil)
        #expect(TimerQuery.parse("safari") == nil)
        #expect(TimerQuery.parse("") == nil)
    }
}
