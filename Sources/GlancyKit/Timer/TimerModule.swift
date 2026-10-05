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
    /// Focus rounds finished today (persisted with the timer).
    public internal(set) var tally: PomodoroTally?
    public init() {}

    public var remaining: TimeInterval { TimerMachine.remaining(state, now: now) }
    public var progress: Double { TimerMachine.progress(state, now: now) }
    public var roundsToday: Int { PomodoroTally.today(tally, now: now) }
}

/// Timer / Pomodoro (SPEC §3). The deadline is a `Date`, persisted; the module wakes once at the
/// next thing that changes on screen (expiry, the 10-second "finishing" mark, and — only while the
/// collapsed wing shows whole minutes — the next minute boundary). Counting text is SwiftUI's own
/// `Text(timerInterval:)`, used only where it's on screen expanded, or for the last ten seconds.
@MainActor
public final class TimerModule: GlancyModule {
    public let id: ModuleID = .timer
    public let model = TimerModel()
    public let settings: TimerSettings
    /// Focus during Pomodoro focus rounds; nil = none (tests, isolated runs).
    public let focus: FocusController?

    private let store: TimerStore
    private let alerts: TimerAlerting
    private(set) var hub: ActivityHub?
    private var visibility: SurfaceVisibility = .collapsed
    private var wake: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var started = false
    /// The user turned Focus off during this focus round: no claim until the round changes.
    private var focusSuppressed = false
    /// Renders: a state shown without being persisted or alerted.
    private var frozen = false
    static let focusOwner = "timer"

    public convenience init() {
        self.init(store: .default, alerts: SystemTimerAlerts(), settings: TimerSettings(), focus: .shared)
        // Settings shows the saved lengths (and its strings) even while the module is off.
        Pomodoro.lengths = PomodoroLengths.load()
        L10n.addItalian(timerItalian)
    }

    public init(store: TimerStore, alerts: TimerAlerting, settings: TimerSettings? = nil, focus: FocusController? = nil) {
        self.store = store
        self.alerts = alerts
        self.settings = settings ?? TimerSettings()
        self.focus = focus
    }

    // MARK: Lifecycle

    public func start(hub: ActivityHub) {
        guard !started else { return }
        started = true
        frozen = false
        self.hub = hub
        L10n.addItalian(timerItalian)
        Pomodoro.lengths = PomodoroLengths.load()
        let snap = store.load()
        model.customMinutes = snap.customMinutes
        model.state = snap.state
        model.tally = snap.tally
        settings.onChange = { [weak self] in self?.refresh(announce: false) }
        focus?.register(Self.focusOwner) { [weak self] in self?.suppressFocus() }
        // A relaunch after the deadline: catch up quietly (the system already showed the alert).
        let events = TimerMachine.advance(&model.state, now: .now, autoStart: settings.autoStartNext)
        if !events.isEmpty {
            PomodoroTally.record(&model.tally, events: events, now: .now)
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
        settings.onChange = nil
        focus?.unregister(Self.focusOwner)
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

    /// A plain timer shown as a break ("pausa 5"): green, "Break" in the wing.
    public func startBreak(minutes: Int) {
        TimerMachine.start(&model.state, minutes: minutes, now: .now, isBreak: true)
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

    /// Also "Start" for a Pomodoro phase held without auto-start.
    public func resume() {
        TimerMachine.resume(&model.state, now: .now)
        committed()
    }

    /// Pomodoro: the next phase now (skipping the long break ends the cycle).
    public func skip() {
        let event = TimerMachine.skip(&model.state, now: .now)
        committed(haptic: true)
        if let event { hub?.show(PeekEvent(module: .timer, duration: 3.5, content: AnyView(TimerPeek(event: event)))) }
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
        frozen = false
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
        let roundBefore = focusRound
        let events = frozen ? [] : TimerMachine.advance(&model.state, now: now, autoStart: settings.autoStartNext)
        model.now = now
        if !events.isEmpty {
            PomodoroTally.record(&model.tally, events: events, now: now)
            persist()
            if model.state.status == .running { scheduleAlert() }
            if announce, let last = events.last { hub?.show(PeekEvent(module: .timer, duration: 3.5, content: AnyView(TimerPeek(event: last)))) }
        }
        // A manual "Focus off" holds for the focus round it was made in, not the next one.
        if focusRound == nil || focusRound != roundBefore { focusSuppressed = false }
        publish(now: now)
        claimFocus()
        updateTicker()
        arm(now: now)
    }

    /// The focus round under way (phase), nil outside one.
    private var focusRound: Int? { model.state.isFocusBlock ? model.state.phase : nil }

    private func claimFocus() {
        guard let focus, !frozen else { return }
        focus.claim(Self.focusOwner, settings.focusDuringWork && focusRound != nil && !focusSuppressed)
    }

    /// The user turned Focus off (agenda chip, command bar): not again this round.
    private func suppressFocus() {
        focusSuppressed = focusRound != nil
        focus?.claim(Self.focusOwner, false)
    }

    private func publish(now: Date) {
        guard let hub else { return }
        let s = model.state
        guard s.isActive else { hub.clear("timer"); return }
        let finishing = TimerSchedule.isFinishing(s, now: now)
        let snapshot = TimerWingSnapshot(progress: TimerMachine.progress(s, now: now),
                                         minutesLeft: TimerSchedule.minutesLeft(TimerMachine.remaining(s, now: now)),
                                         paused: s.status == .paused, isBreak: s.isBreakRun,
                                         finishingUntil: finishing ? s.deadline : nil,
                                         label: TimerText.wingLabel(s), held: s.isHeld)
        hub.post(LiveActivity(id: "timer", module: .timer, priority: finishing ? 80 : 40, updated: now,
                              left: AnyView(TimerWingLeft(snap: snapshot)),
                              right: AnyView(TimerWingRight(snap: snapshot))))
    }

    private func arm(now: Date) {
        wake?.cancel(); wake = nil
        guard !frozen, model.state.status == .running, let deadline = model.state.deadline else { return }
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
        let want = visibility == .expanded(.timer) && model.state.status == .running && !frozen
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
        guard !frozen else { return }
        store.save(TimerSnapshot(state: model.state, customMinutes: model.customMinutes, tally: model.tally))
    }

    private func scheduleAlert() {
        guard !frozen, let deadline = model.state.deadline else { return }
        let (title, body) = TimerText.alert(for: model.state)
        alerts.schedule(at: deadline, title: title, body: body)
    }

    // MARK: Renders

    public enum RenderState: String, CaseIterable, Sendable { case pomodoro, held }

    /// Shows a Pomodoro state for `glancy-render` without touching the saved timer or alerts:
    /// focus round 2 of 4, 13 minutes left (`.pomodoro`), or its short break waiting for Start.
    public func prepareForRender(_ r: RenderState) {
        frozen = true
        wake?.cancel(); wake = nil
        let now = Date.now
        var s = TimerState()
        TimerMachine.startPomodoro(&s, now: now.addingTimeInterval(-42 * 60))
        TimerMachine.advance(&s, now: now)
        if r == .held, let deadline = s.deadline {
            TimerMachine.advance(&s, now: deadline, autoStart: false)
        }
        model.state = s
        model.now = now
        model.tally = PomodoroTally(day: Calendar.current.startOfDay(for: now), count: r == .held ? 2 : 1)
        publish(now: now)
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
