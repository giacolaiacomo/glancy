import Foundation

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

    public init() {}

    public var isActive: Bool { status != .idle }
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

    public static func start(_ s: inout TimerState, minutes: Int, now: Date) {
        run(&s, duration: TimeInterval(max(1, minutes)) * 60, phase: nil, now: now)
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
    @discardableResult
    public static func advance(_ s: inout TimerState, now: Date) -> [TimerEvent] {
        var events: [TimerEvent] = []
        while s.status == .running, let deadline = s.deadline, deadline <= now {
            if let phase = s.phase, phase < Pomodoro.lastPhase {
                let next = phase + 1
                s.phase = next
                s.duration = Pomodoro.duration(of: next)
                s.deadline = deadline.addingTimeInterval(s.duration)
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

/// The persisted timer: survives relaunch (Application Support/Glancy/timer.json).
public struct TimerSnapshot: Codable, Equatable, Sendable {
    public var state = TimerState()
    public var customMinutes = 10
    public init(state: TimerState = TimerState(), customMinutes: Int = 10) {
        self.state = state; self.customMinutes = customMinutes
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
