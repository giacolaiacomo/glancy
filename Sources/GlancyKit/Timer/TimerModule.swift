import AppKit
import SwiftUI

/// What the timer views render from.
@MainActor @Observable
public final class TimerModel {
    public internal(set) var state = TimerState()
    public var customMinutes = 10 {
        didSet {
            let clamped = min(max(customMinutes, TimerMachine.customRange.lowerBound), TimerMachine.customRange.upperBound)
            if clamped != customMinutes { customMinutes = clamped }
        }
    }
    /// Re-stamped once a second only while the Timer tab is on screen (the ring); otherwise at
    /// every state change.
    public internal(set) var now: Date = .now
    public init() {}

    public var remaining: TimeInterval { TimerMachine.remaining(state, now: now) }
    public var progress: Double { TimerMachine.progress(state, now: now) }
}

/// Timer / Pomodoro (SPEC §3). The deadline is a `Date`, persisted; the module wakes once at the
/// next thing that changes on screen (expiry, the 10-second "finishing" mark, and — only while the
/// collapsed wing shows whole minutes — the next minute boundary). Counting text is SwiftUI's own
/// `Text(timerInterval:)`, used only where it's on screen expanded, or for the last ten seconds.
@MainActor
public final class TimerModule: GlancyModule {
    public let id: ModuleID = .timer
    public let model = TimerModel()

    private let store: TimerStore
    private let alerts: TimerAlerting
    private var hub: ActivityHub?
    private var visibility: SurfaceVisibility = .collapsed
    private var wake: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var started = false

    public convenience init() {
        self.init(store: .default, alerts: SystemTimerAlerts())
        // Settings shows the saved lengths even while the module is off.
        Pomodoro.lengths = PomodoroLengths.load()
    }

    public init(store: TimerStore, alerts: TimerAlerting) {
        self.store = store
        self.alerts = alerts
    }

    // MARK: Lifecycle

    public func start(hub: ActivityHub) {
        guard !started else { return }
        started = true
        self.hub = hub
        L10n.addItalian(timerItalian)
        Pomodoro.lengths = PomodoroLengths.load()
        let snap = store.load()
        model.customMinutes = snap.customMinutes
        model.state = snap.state
        // A relaunch after the deadline: catch up quietly (the system already showed the alert).
        let events = TimerMachine.advance(&model.state, now: .now)
        if !events.isEmpty {
            persist()
            if model.state.status == .running { scheduleAlert() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(announce: true) }
        }
        refresh(announce: false)
    }

    public func stop() {
        started = false
        wake?.cancel(); wake = nil
        ticker?.cancel(); ticker = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        hub?.clearAll(from: .timer)
        hub = nil
    }

    public func visibilityChanged(_ v: SurfaceVisibility) {
        let wasCollapsed = visibility == .collapsed
        visibility = v
        guard started else { return }
        model.now = .now
        updateTicker()
        // Back to the wings: their minute text may be stale; otherwise only the wake-up changes.
        if v == .collapsed, !wasCollapsed { refresh(announce: true) } else { arm(now: .now) }
    }

    // MARK: Actions

    public func start(minutes: Int) {
        TimerMachine.start(&model.state, minutes: minutes, now: .now)
        committed(haptic: true)
    }

    public func startCustom() { start(minutes: model.customMinutes) }

    public func startPomodoro() {
        TimerMachine.startPomodoro(&model.state, now: .now)
        committed(haptic: true)
    }

    public func pause() {
        TimerMachine.pause(&model.state, now: .now)
        committed()
    }

    public func resume() {
        TimerMachine.resume(&model.state, now: .now)
        committed()
    }

    public func stopTimer() {
        TimerMachine.stop(&model.state)
        committed(haptic: true)
    }

    public func addMinute() {
        TimerMachine.addMinute(&model.state, now: .now)
        committed()
    }

    /// Changes the Pomodoro lengths (Settings → Timer). A phase already running keeps its length;
    /// the next phases use the new ones.
    public func setPomodoroLengths(_ l: PomodoroLengths) {
        guard l != Pomodoro.lengths else { return }
        Pomodoro.lengths = l
        l.save()
    }

    public func setCustomMinutes(_ m: Int) {
        model.customMinutes = m
        persist()
    }

    private func committed(haptic: Bool = false) {
        if haptic { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        persist()
        if model.state.status == .running { scheduleAlert() } else { alerts.cancel() }
        refresh(announce: false)
    }

    // MARK: Refresh / wake-up

    /// Passes any deadline that is due, republishes the wing, and arms the next single wake-up.
    func refresh(announce: Bool) {
        guard started else { return }
        let now = Date.now
        let events = TimerMachine.advance(&model.state, now: now)
        model.now = now
        if !events.isEmpty {
            persist()
            if model.state.status == .running { scheduleAlert() }
            if announce, let last = events.last { hub?.show(PeekEvent(module: .timer, duration: 3.5, content: AnyView(TimerPeek(event: last)))) }
        }
        publish(now: now)
        updateTicker()
        arm(now: now)
    }

    private func publish(now: Date) {
        guard let hub else { return }
        let s = model.state
        guard s.isActive else { hub.clear("timer"); return }
        let finishing = TimerSchedule.isFinishing(s, now: now)
        let snapshot = TimerWingSnapshot(progress: TimerMachine.progress(s, now: now),
                                         minutesLeft: TimerSchedule.minutesLeft(TimerMachine.remaining(s, now: now)),
                                         paused: s.status == .paused, isBreak: s.phase.map { !Pomodoro.isFocus($0) } ?? false,
                                         finishingUntil: finishing ? s.deadline : nil)
        hub.post(LiveActivity(id: "timer", module: .timer, priority: finishing ? 80 : 40, updated: now,
                              left: AnyView(TimerWingLeft(snap: snapshot)),
                              right: AnyView(TimerWingRight(snap: snapshot))))
    }

    private func arm(now: Date) {
        wake?.cancel(); wake = nil
        guard model.state.status == .running, let deadline = model.state.deadline else { return }
        let target = TimerSchedule.nextWake(now: now, deadline: deadline, minuteText: visibility == .collapsed)
        wake = Task { [weak self] in
            // +50 ms so the boundary has strictly passed when we look again.
            try? await Task.sleep(for: .seconds(max(0.05, target.timeIntervalSinceNow + 0.05)))
            guard !Task.isCancelled else { return }
            self?.refresh(announce: true)
        }
    }

    /// The ring in the Timer tab moves once a second, only while that tab is on screen and running.
    private func updateTicker() {
        let want = visibility == .expanded(.timer) && model.state.status == .running
        if !want { ticker?.cancel(); ticker = nil; return }
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.model.now = .now
            }
        }
    }

    // MARK: Persistence and alert

    private func persist() {
        store.save(TimerSnapshot(state: model.state, customMinutes: model.customMinutes))
    }

    private func scheduleAlert() {
        guard let deadline = model.state.deadline else { return }
        let (title, body) = TimerText.alert(for: model.state)
        alerts.schedule(at: deadline, title: title, body: body)
    }

    // MARK: Surface

    public var tab: PanelTab? {
        PanelTab(module: .timer, symbol: "timer", title: "Timer") { [unowned self] in
            AnyView(TimerTabView(timer: self, model: model))
        }
    }

    public func homeCard() -> AnyView? {
        guard model.state.isActive else { return nil }
        return AnyView(TimerHomeCard(timer: self, model: model))
    }
}
