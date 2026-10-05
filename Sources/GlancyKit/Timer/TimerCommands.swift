import Foundation

// The Timer's entries in the command bar. Fixed actions (Pomodoro, presets, and stop / pause /
// resume / +1 min / skip while one runs) and typed ones parsed from the query, English and Italian:
// "timer 10", "10 min", "1h30", "timer di 25 minuti", "pomodoro", "break 5", "pausa 5",
// "stop timer", "ferma", "pausa", "riprendi", "salta".

public enum TimerIntent: Equatable, Sendable {
    case start(minutes: Int)
    case breakTimer(minutes: Int)
    case pomodoro, stop, pause, resume, skip
}

public enum TimerQuery {
    static let stopWords: Set<String> = ["stop", "stop timer", "stop the timer", "cancel timer", "stop pomodoro",
                                         "ferma", "ferma timer", "ferma il timer", "annulla timer", "ferma pomodoro"]
    static let pauseWords: Set<String> = ["pause", "pause timer", "pause the timer", "pausa", "pausa timer", "metti in pausa",
                                          "metti in pausa il timer"]
    static let resumeWords: Set<String> = ["resume", "resume timer", "continue timer", "riprendi", "riprendi timer",
                                           "riprendi il timer", "continua timer"]
    static let skipWords: Set<String> = ["skip", "skip phase", "salta", "salta fase", "salta la fase"]
    static let pomodoroWords: Set<String> = ["start pomodoro", "avvia pomodoro", "inizia pomodoro"]
    static let timerPrefixes = ["set a timer for", "set timer for", "set timer", "start timer", "start a timer",
                                "imposta un timer di", "imposta timer", "avvia un timer di", "avvia timer", "timer per",
                                "timer di", "timer for", "timer", "countdown", "conto alla rovescia"]
    static let breakPrefixes = ["take a break", "break for", "break of", "break", "fai una pausa di", "pausa di", "pausa"]

    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// What the query asks of the timer, or nil when it isn't for the timer.
    public static func parse(_ query: String) -> TimerIntent? {
        let q = normalize(query)
        guard !q.isEmpty else { return nil }
        if q.count >= 4, "pomodoro".hasPrefix(q) || pomodoroWords.contains(q) { return .pomodoro }
        if stopWords.contains(q) { return .stop }
        if pauseWords.contains(q) { return .pause }
        if resumeWords.contains(q) { return .resume }
        if skipWords.contains(q) { return .skip }
        for p in breakPrefixes where q.hasPrefix(p + " ") {
            return minutes(String(q.dropFirst(p.count + 1)), bare: true).map { .breakTimer(minutes: $0) }
        }
        for p in timerPrefixes where q.hasPrefix(p + " ") {
            return minutes(String(q.dropFirst(p.count + 1)), bare: true).map { .start(minutes: $0) }
        }
        for s in [" timer", " countdown"] where q.hasSuffix(s) {
            return minutes(String(q.dropLast(s.count)), bare: true).map { .start(minutes: $0) }
        }
        return minutes(q, bare: false).map { .start(minutes: $0) }
    }

    private static let minuteUnit = #"(?:m|min|mins|minute|minutes|minuto|minuti|')"#
    private static let hourUnit = #"(?:h|hr|hrs|hour|hours|ora|ore)"#

    /// "10", "10 min", "10m", "10 minuti", "1h", "1 h 30", "1h30m", "1:30" → minutes in 1…240.
    /// A bare number counts only after a keyword ("timer 10"): alone it belongs to the calculator.
    static func minutes(_ text: String, bare: Bool) -> Int? {
        let s = text.trimmingCharacters(in: .whitespaces)
        func match(_ pattern: String) -> [String]? {
            guard let re = try? NSRegularExpression(pattern: "^" + pattern + "$"),
                  let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
            return (0..<m.numberOfRanges).map { i in
                Range(m.range(at: i), in: s).map { String(s[$0]) } ?? ""
            }
        }
        var total: Int?
        if let g = match(#"(\d{1,3})\s*"# + minuteUnit) { total = Int(g[1]) }
        else if bare, let g = match(#"(\d{1,3})"#) { total = Int(g[1]) }
        else if let g = match(#"(\d{1,2})\s*"# + hourUnit + #"(?:\s*(?:e\s+|and\s+)?(\d{1,2})\s*"# + minuteUnit + "?)?") {
            total = (Int(g[1]) ?? 0) * 60 + (Int(g[2]) ?? 0)
        } else if bare, let g = match(#"(\d{1,2}):(\d{2})"#) {
            total = (Int(g[1]) ?? 0) * 60 + (Int(g[2]) ?? 0)
        }
        guard let total, TimerMachine.customRange.contains(total) else { return nil }
        return total
    }
}

extension TimerModule {
    public func commands() -> [GlancyCommand] {
        let s = model.state
        var out: [GlancyCommand] = [pomodoroCommand()]
        for m in TimerMachine.presets {
            out.append(GlancyCommand(id: "timer.preset.\(m)", module: .timer, title: L10n.tr("Timer %d min", m),
                                     symbol: "timer", keywords: ["timer", "countdown", "minutes", "minuti", "conto alla rovescia"],
                                     run: { [weak self] in self?.start(minutes: m) }))
        }
        if s.isActive {
            out.append(command(.stop, rank: 20))
            out.append(command(s.status == .running ? .pause : .resume, rank: 20))
            if !s.isHeld {
                out.append(GlancyCommand(id: "timer.addMinute", module: .timer, title: L10n.tr("Add a minute"), symbol: "plus",
                                         keywords: ["+1", "minute", "minuto", "timer"], rank: 10, closesPanel: false,
                                         run: { [weak self] in self?.addMinute() }))
            }
            if s.phase != nil { out.append(command(.skip, rank: 10)) }
        }
        return out
    }

    public func results(for query: String) -> [GlancyCommand] {
        guard let intent = TimerQuery.parse(query) else { return [] }
        let active = model.state.isActive
        switch intent {
        case .start(let m):
            return [GlancyCommand(id: "timer.start.\(m)", module: .timer, title: L10n.tr("Start a %d-minute timer", m),
                                  subtitle: active ? runningNote : nil, symbol: "timer", rank: 90,
                                  run: { [weak self] in self?.start(minutes: m) })]
        case .breakTimer(let m):
            return [GlancyCommand(id: "timer.break.\(m)", module: .timer, title: L10n.tr("Start a %d-minute break", m),
                                  subtitle: active ? runningNote : nil, symbol: "cup.and.saucer", rank: 90,
                                  run: { [weak self] in self?.startBreak(minutes: m) })]
        case .pomodoro:
            var c = pomodoroCommand()
            c.rank = 90
            return [c]
        case .stop, .pause, .resume, .skip:
            guard active, isApplicable(intent) else { return [] }
            return [command(intent, rank: 90)]
        }
    }

    private var runningNote: String {
        L10n.tr("Running · %@ left", TimerFormat.clock(TimerMachine.remaining(model.state, now: .now)))
    }

    private func isApplicable(_ i: TimerIntent) -> Bool {
        let s = model.state
        switch i {
        case .pause: return s.status == .running
        case .resume: return s.status == .paused
        case .skip: return s.phase != nil
        default: return s.isActive
        }
    }

    private func pomodoroCommand() -> GlancyCommand {
        let l = Pomodoro.lengths
        return GlancyCommand(id: "timer.pomodoro", module: .timer, title: L10n.tr("Start Pomodoro"),
                             subtitle: L10n.tr("%d / %d min ×4, then %d", l.focus, l.shortBreak, l.longBreak),
                             symbol: "repeat", keywords: ["pomodoro", "focus", "work", "concentrazione", "lavoro"],
                             run: { [weak self] in self?.startPomodoro() })
    }

    private func command(_ i: TimerIntent, rank: Int) -> GlancyCommand {
        switch i {
        case .stop:
            return GlancyCommand(id: "timer.stop", module: .timer, title: L10n.tr("Stop timer"), symbol: "stop.fill",
                                 keywords: ["stop", "cancel", "ferma", "annulla", "timer", "pomodoro"], rank: rank,
                                 run: { [weak self] in self?.stopTimer() })
        case .pause:
            return GlancyCommand(id: "timer.pause", module: .timer, title: L10n.tr("Pause timer"), symbol: "pause.fill",
                                 keywords: ["pause", "pausa", "timer"], rank: rank, closesPanel: false,
                                 run: { [weak self] in self?.pause() })
        case .resume:
            return GlancyCommand(id: "timer.resume", module: .timer,
                                 title: model.state.isHeld ? TimerText.startHeld(model.state) : L10n.tr("Resume timer"),
                                 symbol: "play.fill", keywords: ["resume", "start", "riprendi", "avvia", "timer"], rank: rank,
                                 closesPanel: false, run: { [weak self] in self?.resume() })
        default:
            return GlancyCommand(id: "timer.skip", module: .timer, title: L10n.tr("Skip Pomodoro phase"), symbol: "forward.end.fill",
                                 keywords: ["skip", "next", "salta", "pomodoro"], rank: rank, closesPanel: false,
                                 run: { [weak self] in self?.skip() })
        }
    }
}
