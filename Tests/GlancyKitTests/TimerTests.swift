import Foundation
import Testing
@testable import GlancyKit

private let tStart = Date(timeIntervalSinceReferenceDate: 800_000_000)

@Suite struct TimerMachineTests {
    @Test func startRunsToDeadline() {
        var s = TimerState()
        TimerMachine.start(&s, minutes: 25, now: tStart)
        #expect(s.status == .running)
        #expect(s.deadline == tStart.addingTimeInterval(1500))
        #expect(TimerMachine.remaining(s, now: tStart.addingTimeInterval(100)) == 1400)
        #expect(abs(TimerMachine.progress(s, now: tStart.addingTimeInterval(750)) - 0.5) < 1e-9)
    }

    @Test func pauseFreezesAndResumeShiftsDeadline() {
        var s = TimerState()
        TimerMachine.start(&s, minutes: 5, now: tStart)
        TimerMachine.pause(&s, now: tStart.addingTimeInterval(60))
        #expect(s.status == .paused)
        #expect(s.deadline == nil)
        #expect(TimerMachine.remaining(s, now: tStart.addingTimeInterval(10_000)) == 240)
        // Nothing expires while paused.
        #expect(TimerMachine.advance(&s, now: tStart.addingTimeInterval(10_000)).isEmpty)
        TimerMachine.resume(&s, now: tStart.addingTimeInterval(1000))
        #expect(s.status == .running)
        #expect(s.deadline == tStart.addingTimeInterval(1240))
    }

    @Test func stopResets() {
        var s = TimerState()
        TimerMachine.startPomodoro(&s, now: tStart)
        TimerMachine.stop(&s)
        #expect(s == TimerState())
        #expect(TimerMachine.remaining(s, now: tStart) == 0)
    }

    @Test func addMinuteWhileRunningAndPaused() {
        var s = TimerState()
        TimerMachine.start(&s, minutes: 1, now: tStart)
        TimerMachine.addMinute(&s, now: tStart)
        #expect(s.deadline == tStart.addingTimeInterval(120))
        #expect(s.duration == 120)
        TimerMachine.pause(&s, now: tStart.addingTimeInterval(30))
        TimerMachine.addMinute(&s, now: tStart.addingTimeInterval(30))
        #expect(s.pausedRemaining == 150)
        #expect(s.duration == 180)
        var idle = TimerState()
        TimerMachine.addMinute(&idle, now: tStart)
        #expect(idle == TimerState())
    }

    @Test func expiryFinishesPlainTimer() {
        var s = TimerState()
        TimerMachine.start(&s, minutes: 15, now: tStart)
        #expect(TimerMachine.advance(&s, now: tStart.addingTimeInterval(899)).isEmpty)
        #expect(TimerMachine.advance(&s, now: tStart.addingTimeInterval(900)) == [.finished(duration: 900)])
        #expect(s.status == .idle)
    }

    @Test func pomodoroPhasesChainFromTheDeadline() {
        var s = TimerState()
        TimerMachine.startPomodoro(&s, now: tStart)
        #expect(s.phase == 0 && s.duration == 1500)
        // Woken 3 s late: the break still starts at the old deadline, not at "now".
        let ev = TimerMachine.advance(&s, now: tStart.addingTimeInterval(1503))
        #expect(ev == [.phaseChanged(from: 0, to: 1)])
        #expect(s.phase == 1)
        #expect(s.deadline == tStart.addingTimeInterval(1500 + 300))
    }

    @Test func pomodoroFullCycle() {
        var s = TimerState()
        TimerMachine.startPomodoro(&s, now: tStart)
        var events: [TimerEvent] = []
        var now = tStart
        while s.isActive, let d = s.deadline { now = d; events += TimerMachine.advance(&s, now: now) }
        #expect(events.count == 8)
        #expect(events.last == .cycleComplete)
        #expect(events[5] == .phaseChanged(from: 5, to: 6))
        #expect(events[6] == .phaseChanged(from: 6, to: 7))
        // 4×25 + 3×5 + 15 = 130 min.
        #expect(now == tStart.addingTimeInterval(130 * 60))
        #expect(Pomodoro.duration(of: 7) == 900)
        #expect(Pomodoro.round(of: 6) == 4)
    }

    @Test func relaunchCatchesUpMidCycle() {
        var s = TimerState()
        TimerMachine.startPomodoro(&s, now: tStart)
        // Relaunched 40 min later: focus (25) + break (5) passed; focus 2 (ends at 55) has 15 min left.
        let ev = TimerMachine.advance(&s, now: tStart.addingTimeInterval(40 * 60))
        #expect(ev == [.phaseChanged(from: 0, to: 1), .phaseChanged(from: 1, to: 2)])
        #expect(s.phase == 2)
        #expect(TimerMachine.remaining(s, now: tStart.addingTimeInterval(40 * 60)) == 900)
    }
}

@Suite struct TimerScheduleTests {
    @Test func minutesLeftRoundsUp() {
        #expect(TimerSchedule.minutesLeft(0) == 0)
        #expect(TimerSchedule.minutesLeft(0.2) == 1)
        #expect(TimerSchedule.minutesLeft(60) == 1)
        #expect(TimerSchedule.minutesLeft(60.01) == 2)
        #expect(TimerSchedule.minutesLeft(1500) == 25)
    }

    @Test func expandedWakesOnlyAtFinishingAndExpiry() {
        let deadline = tStart.addingTimeInterval(1500)
        #expect(TimerSchedule.nextWake(now: tStart, deadline: deadline, minuteText: false) == deadline.addingTimeInterval(-10))
        #expect(TimerSchedule.nextWake(now: deadline.addingTimeInterval(-5), deadline: deadline, minuteText: false) == deadline)
    }

    @Test func collapsedWakesAtEachMinuteBoundary() {
        let deadline = tStart.addingTimeInterval(1500)
        // 25:00 left shows "25m"; it becomes "24m" one minute later.
        #expect(TimerSchedule.nextWake(now: tStart, deadline: deadline, minuteText: true) == tStart.addingTimeInterval(60))
        // 24:59.5 left (just after a boundary) → next boundary at 24:00 left.
        let now = deadline.addingTimeInterval(-1499.5)
        #expect(TimerSchedule.nextWake(now: now, deadline: deadline, minuteText: true) == deadline.addingTimeInterval(-1440))
        // Under two minutes: boundary at 1:00 left, then the finishing mark, then expiry.
        #expect(TimerSchedule.nextWake(now: deadline.addingTimeInterval(-90), deadline: deadline, minuteText: true) == deadline.addingTimeInterval(-60))
        #expect(TimerSchedule.nextWake(now: deadline.addingTimeInterval(-60), deadline: deadline, minuteText: true) == deadline.addingTimeInterval(-10))
        #expect(TimerSchedule.nextWake(now: deadline.addingTimeInterval(-10), deadline: deadline, minuteText: true) == deadline)
    }

    @Test func wakesNeverRepeatAndCountIsBounded() {
        // A 25-minute run collapsed the whole time: 24 minute boundaries + finishing + expiry.
        let deadline = tStart.addingTimeInterval(1500)
        var now = tStart, wakes = 0
        while now < deadline {
            let next = TimerSchedule.nextWake(now: now, deadline: deadline, minuteText: true)
            #expect(next > now)
            now = next; wakes += 1
        }
        #expect(wakes == 26)
    }

    @Test func finishingWindow() {
        var s = TimerState()
        TimerMachine.start(&s, minutes: 1, now: tStart)
        #expect(!TimerSchedule.isFinishing(s, now: tStart.addingTimeInterval(49)))
        #expect(TimerSchedule.isFinishing(s, now: tStart.addingTimeInterval(50)))
        TimerMachine.pause(&s, now: tStart.addingTimeInterval(55))
        #expect(!TimerSchedule.isFinishing(s, now: tStart.addingTimeInterval(55)))
    }

    @Test func clockFormat() {
        #expect(TimerFormat.clock(0) == "0:00")
        #expect(TimerFormat.clock(59.2) == "1:00")
        #expect(TimerFormat.clock(1500) == "25:00")
        #expect(TimerFormat.clock(3725) == "1:02:05")
    }
}

@MainActor
private final class RecordingAlerts: TimerAlerting {
    var scheduled: [Date] = []
    var cancels = 0
    func schedule(at date: Date, title: String, body: String) { scheduled.append(date) }
    func cancel() { cancels += 1 }
}

@MainActor
@Suite struct TimerModuleTests {
    private func tempStore() -> TimerStore {
        TimerStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("glancy-timer-\(UUID().uuidString)/timer.json"))
    }

    @Test func persistsAndRestoresAcrossRelaunch() {
        let store = tempStore()
        let alerts = RecordingAlerts()
        let hub = ActivityHub()
        let a = TimerModule(store: store, alerts: alerts)
        a.start(hub: hub)
        a.start(minutes: 15)
        a.setCustomMinutes(42)
        let deadline = a.model.state.deadline
        #expect(alerts.scheduled == [deadline!])
        #expect(hub.top?.id == "timer")
        #expect(hub.top?.priority == 40)
        a.stop()
        #expect(hub.top == nil)

        let b = TimerModule(store: store, alerts: RecordingAlerts())
        b.start(hub: ActivityHub())
        #expect(b.model.state.status == .running)
        #expect(b.model.state.deadline == deadline)
        #expect(b.model.customMinutes == 42)
        b.stopTimer()
        b.stop()
        try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent())
    }

    @Test func expiredWhileQuitRestoresIdle() {
        let store = tempStore()
        var s = TimerState()
        TimerMachine.start(&s, minutes: 5, now: Date.now.addingTimeInterval(-3600))
        store.save(TimerSnapshot(state: s))
        let hub = ActivityHub()
        let m = TimerModule(store: store, alerts: RecordingAlerts())
        m.start(hub: hub)
        #expect(m.model.state.status == .idle)
        #expect(hub.top == nil)
        #expect(hub.peek == nil)   // stale: no peek for a timer that ended an hour ago
        #expect(store.load().state.status == .idle)
        m.stop()
        try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent())
    }

    @Test func pauseCancelsAlertAndStopClearsActivity() {
        let store = tempStore()
        let alerts = RecordingAlerts()
        let hub = ActivityHub()
        let m = TimerModule(store: store, alerts: alerts)
        m.start(hub: hub)
        m.startPomodoro()
        m.pause()
        #expect(alerts.cancels == 1)
        #expect(hub.top?.id == "timer")
        m.resume()
        #expect(alerts.scheduled.count == 2)
        m.stopTimer()
        #expect(hub.top == nil)
        #expect(alerts.cancels == 2)
        m.stop()
        try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent())
    }

    @Test func finishingRaisesPriority() {
        let store = tempStore()
        var s = TimerState()
        TimerMachine.start(&s, minutes: 1, now: Date.now.addingTimeInterval(-55))
        store.save(TimerSnapshot(state: s))
        let hub = ActivityHub()
        let m = TimerModule(store: store, alerts: RecordingAlerts())
        m.start(hub: hub)
        #expect(hub.top?.priority == 80)
        m.stopTimer()
        m.stop()
        try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent())
    }
}
