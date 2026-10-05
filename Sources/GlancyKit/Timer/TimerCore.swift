import Foundation
import Observation

// The timer's pure logic: state, transitions, Pomodoro phases and wake-up maths. No clocks of its
// own: every function takes `now`, so the module decides when to look and the tests drive time.

/// Pomodoro lengths in minutes (Settings → Timer). Default 25 / 5 / 15.
public struct PomodoroLengths: Codable, Equatable, Sendable {
    public var focus = 25
    public var shortBreak = 5
    public var longBreak = 15
    public static let range = 1...120
    public static let defaultsKey = "glancy.timer.pomodoro"

    public init(focus: Int = 25, shortBreak: Int = 5, longBreak: Int = 15) {
        self.focus = Self.clamp(focus); self.shortBreak = Self.clamp(shortBreak); self.longBreak = Self.clamp(longBreak)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(focus: (try? c.decode(Int.self, forKey: .focus)) ?? 25,
                  shortBreak: (try? c.decode(Int.self, forKey: .shortBreak)) ?? 5,
                  longBreak: (try? c.decode(Int.self, forKey: .longBreak)) ?? 15)
    }

    static func clamp(_ m: Int) -> Int { min(max(m, range.lowerBound), range.upperBound) }

    public static func load(_ defaults: UserDefaults = .standard) -> PomodoroLengths {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(PomodoroLengths.self, from: $0) } ?? PomodoroLengths()
    }

    public func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

/// Pomodoro 25 / 5 ×4 → 15 by default. Phases are numbered 0…7: even = focus (round = n / 2 + 1),
/// odd = break, 7 = the long break that ends the cycle.
public enum Pomodoro {
    /// The lengths in use; set on main by the Timer module (loaded at start, changed in Settings).
    public nonisolated(unsafe) static var lengths = PomodoroLengths()
    public static var focus: TimeInterval { TimeInterval(lengths.focus * 60) }
    public static var shortBreak: TimeInterval { TimeInterval(lengths.shortBreak * 60) }
    public static var longBreak: TimeInterval { TimeInterval(lengths.longBreak * 60) }
    public static let rounds = 4
    public static let lastPhase = rounds * 2 - 1

    public static func duration(of phase: Int) -> TimeInterval { duration(of: phase, lengths: lengths) }

    public static func duration(of phase: Int, lengths l: PomodoroLengths) -> TimeInterval {
        TimeInterval(60 * (phase == lastPhase ? l.longBreak : phase.isMultiple(of: 2) ? l.focus : l.shortBreak))
    }
    public static func isFocus(_ phase: Int) -> Bool { phase.isMultiple(of: 2) }
    public static func round(of phase: Int) -> Int { phase / 2 + 1 }
}

public struct TimerState: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case idle, running, paused }

    public var status: Status = .idle
    /// Length of the current run, including any "+1 min"; the ring's denominator.
    public var duration: TimeInterval = 0
    /// When the current run ends. Set while running only.
    public var deadline: Date?
    /// Time left, frozen while paused.
    public var pausedRemaining: TimeInterval = 0
    /// The Pomodoro phase (0…7) when the run is part of a cycle; nil for a plain timer.
    public var phase: Int?
    /// A plain timer started as a break ("pausa 5"): green, "Break" in the wing.
    public var isBreak: Bool?
    /// Pomodoro without auto-start: the next phase is set up but waits for Start (status paused).
    public var held: Bool?

    public init() {}

    public var isActive: Bool { status != .idle }
    /// Green: a Pomodoro break or a break timer.
    public var isBreakRun: Bool { phase.map { !Pomodoro.isFocus($0) } ?? (isBreak ?? false) }
    public var isHeld: Bool { held == true && status == .paused }
    /// A Pomodoro focus round under way (running or paused, not waiting to start).
    public var isFocusBlock: Bool { status != .idle && !isHeld && phase.map(Pomodoro.isFocus) == true }
}

/// Something that happened when a deadline passed.
public enum TimerEvent: Equatable, Sendable {
    /// A plain timer reached zero.
    case finished(duration: TimeInterval)
    /// A Pomodoro phase ended and the next one started.
    case phaseChanged(from: Int, to: Int)
    /// The long break ended: the cycle is over.
    case cycleComplete
}

public enum TimerMachine {
    public static let presets = [5, 15, 25, 50]
    public static let customRange = 1...240

    public static func start(_ s: inout TimerState, minutes: Int, now: Date, isBreak: Bool = false) {
        run(&s, duration: TimeInterval(max(1, minutes)) * 60, phase: nil, now: now)
        s.isBreak = isBreak ? true : nil
    }

    public static func startPomodoro(_ s: inout TimerState, now: Date) {
        run(&s, duration: Pomodoro.duration(of: 0), phase: 0, now: now)
    }

    private static func run(_ s: inout TimerState, duration: TimeInterval, phase: Int?, now: Date) {
        s.status = .running
        s.duration = duration
        s.deadline = now.addingTimeInterval(duration)
        s.pausedRemaining = 0
        s.phase = phase
        s.isBreak = nil
        s.held = nil
    }

    public static func pause(_ s: inout TimerState, now: Date) {
        guard s.status == .running, let deadline = s.deadline else { return }
        s.pausedRemaining = max(0, deadline.timeIntervalSince(now))
        s.deadline = nil
        s.status = .paused
    }

    public static func resume(_ s: inout TimerState, now: Date) {
        guard s.status == .paused else { return }
        s.deadline = now.addingTimeInterval(s.pausedRemaining)
        s.pausedRemaining = 0
        s.status = .running
        s.held = nil
    }

    /// Pomodoro "Skip": the next phase starts now (the skipped round does not count as done).
    /// Skipping the long break ends the cycle.
    @discardableResult
    public static func skip(_ s: inout TimerState, now: Date) -> TimerEvent? {
        guard s.isActive, let phase = s.phase else { return nil }
        guard phase < Pomodoro.lastPhase else { s = TimerState(); return .cycleComplete }
        run(&s, duration: Pomodoro.duration(of: phase + 1), phase: phase + 1, now: now)
        return nil
    }

    public static func stop(_ s: inout TimerState) {
        s = TimerState()
    }

    /// "+1 min": extends the current run (and the ring's length with it).
    public static func addMinute(_ s: inout TimerState, now: Date) {
        switch s.status {
        case .running: s.deadline = s.deadline?.addingTimeInterval(60)
        case .paused: s.pausedRemaining += 60
        case .idle: return
        }
        s.duration += 60
    }

    public static func remaining(_ s: TimerState, now: Date) -> TimeInterval {
        switch s.status {
        case .running: max(0, (s.deadline ?? now).timeIntervalSince(now))
        case .paused: s.pausedRemaining
        case .idle: 0
        }
    }

    /// Elapsed fraction of the current run, 0…1.
    public static func progress(_ s: TimerState, now: Date) -> Double {
        guard s.isActive, s.duration > 0 else { return 0 }
        return min(1, max(0, 1 - remaining(s, now: now) / s.duration))
    }

    /// Moves past every deadline that is ≤ now (also after a relaunch hours later: a Pomodoro
    /// catches up phase by phase, each starting where the previous one ended). Returns what
    /// happened, oldest first.
    /// `autoStart` false: a Pomodoro stops at the next phase, set up and held for Start.
    @discardableResult
    public static func advance(_ s: inout TimerState, now: Date, autoStart: Bool = true) -> [TimerEvent] {
        var events: [TimerEvent] = []
        while s.status == .running, let deadline = s.deadline, deadline <= now {
            if let phase = s.phase, phase < Pomodoro.lastPhase {
                let next = phase + 1
                s.phase = next
                s.duration = Pomodoro.duration(of: next)
                if autoStart {
                    s.deadline = deadline.addingTimeInterval(s.duration)
                } else {
                    s.status = .paused
                    s.deadline = nil
                    s.pausedRemaining = s.duration
                    s.held = true
                }
                events.append(.phaseChanged(from: phase, to: next))
            } else {
                events.append(s.phase == nil ? .finished(duration: s.duration) : .cycleComplete)
                s = TimerState()
            }
        }
        return events
    }
}

/// When the module must next wake up while a timer runs. One wake-up, never a tick.
public enum TimerSchedule {
    /// The last seconds are the "finishing" activity (priority 80) with a live seconds count.
    public static let finishingWindow: TimeInterval = 10

    /// Whole minutes shown in the collapsed wing: ceil(remaining / 60), at least 1 while running.
    public static func minutesLeft(_ remaining: TimeInterval) -> Int {
        remaining <= 0 ? 0 : max(1, Int((remaining / 60).rounded(.up)))
    }

    /// The next instant something visible changes: the expiry, the start of the finishing window,
    /// and — only when the collapsed wing shows whole minutes — the next minute boundary.
    public static func nextWake(now: Date, deadline: Date, minuteText: Bool) -> Date {
        var candidates = [deadline]
        let finishing = deadline.addingTimeInterval(-finishingWindow)
        if finishing > now { candidates.append(finishing) }
        if minuteText {
            let remaining = deadline.timeIntervalSince(now)
            let shown = minutesLeft(remaining)
            let boundary = deadline.addingTimeInterval(-TimeInterval(shown - 1) * 60)
            if shown > 1, boundary > now { candidates.append(boundary) }
        }
        return candidates.min()!
    }

    /// "Finishing" = running and within the last ten seconds.
    public static func isFinishing(_ s: TimerState, now: Date) -> Bool {
        s.status == .running && TimerMachine.remaining(s, now: now) <= finishingWindow
    }
}

/// mm:ss (h:mm:ss past the hour) for static, non-ticking text.
public enum TimerFormat {
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Focus rounds completed today (a focus phase that ran to its end; skipped ones don't count).
public struct PomodoroTally: Codable, Equatable, Sendable {
    public var day: Date
    public var count: Int
    public init(day: Date, count: Int) { self.day = day; self.count = count }

    /// Counts the focus phases `events` finished, starting a new day when `now` is on another one.
    public static func record(_ t: inout PomodoroTally?, events: [TimerEvent], now: Date, calendar: Calendar = .current) {
        let done = events.filter { if case .phaseChanged(let from, _) = $0 { Pomodoro.isFocus(from) } else { false } }.count
        guard done > 0 else { return }
        let today = calendar.startOfDay(for: now)
        if let cur = t, calendar.isDate(cur.day, inSameDayAs: today) { t?.count += done }
        else { t = PomodoroTally(day: today, count: done) }
    }

    public static func today(_ t: PomodoroTally?, now: Date, calendar: Calendar = .current) -> Int {
        guard let t, calendar.isDate(t.day, inSameDayAs: now) else { return 0 }
        return t.count
    }
}

/// The persisted timer: survives relaunch (Application Support/Glancy/timer.json).
public struct TimerSnapshot: Codable, Equatable, Sendable {
    public var state = TimerState()
    public var customMinutes = 10
    public var tally: PomodoroTally?
    public init(state: TimerState = TimerState(), customMinutes: Int = 10, tally: PomodoroTally? = nil) {
        self.state = state; self.customMinutes = customMinutes; self.tally = tally
    }
}

/// Timer preferences (Settings → Timer).
@MainActor @Observable
public final class TimerSettings {
    static let autoStartKey = "glancy.timer.autoStartNext"
    static let focusKey = "glancy.timer.focusDuringWork"
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onChange: (() -> Void)?

    /// Start the next Pomodoro phase by itself (default) or wait for Start.
    public var autoStartNext = true {
        didSet { guard autoStartNext != oldValue else { return }; defaults.set(autoStartNext, forKey: Self.autoStartKey); onChange?() }
    }
    /// Turn on Focus during Pomodoro focus rounds (the meeting Focus shortcuts).
    public var focusDuringWork = false {
        didSet { guard focusDuringWork != oldValue else { return }; defaults.set(focusDuringWork, forKey: Self.focusKey); onChange?() }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Self.autoStartKey) != nil { autoStartNext = defaults.bool(forKey: Self.autoStartKey) }
        focusDuringWork = defaults.bool(forKey: Self.focusKey)
    }
}

public struct TimerStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public static var `default`: TimerStore {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Glancy", isDirectory: true)
        return TimerStore(url: dir.appendingPathComponent("timer.json"))
    }

    public func load() -> TimerSnapshot {
        guard let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(TimerSnapshot.self, from: data) else { return TimerSnapshot() }
        return snap
    }

    public func save(_ snap: TimerSnapshot) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snap) { try? data.write(to: url, options: .atomic) }
    }
}
