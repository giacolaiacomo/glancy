import Foundation

/// The timer's strings. English literals are the keys; Italian below (`L10n.addItalian` at start).
@MainActor
enum TimerText {
    static func minutes(_ m: Int) -> String { L10n.tr("%d min", m) }
    static func left(_ m: Int) -> String { L10n.tr("%dm left", m) }

    /// The caption over the countdown: "Timer · 25 min", "Focus 2/4", "Short break", "Long break".
    static func caption(_ s: TimerState) -> String {
        guard let phase = s.phase else { return s.isBreak == true ? L10n.tr("Break") : L10n.tr("Timer") }
        if Pomodoro.isFocus(phase) { return L10n.tr("Focus %d/%d", Pomodoro.round(of: phase), Pomodoro.rounds) }
        return phase == Pomodoro.lastPhase ? L10n.tr("Long break") : L10n.tr("Short break")
    }

    /// What comes after the current run, for the "Up next" line.
    static func upNext(_ s: TimerState) -> String? {
        guard let phase = s.phase, phase < Pomodoro.lastPhase else { return nil }
        let next = phase + 1
        let len = Int(Pomodoro.duration(of: next) / 60)
        if Pomodoro.isFocus(next) { return L10n.tr("Focus %d/%d", Pomodoro.round(of: next), Pomodoro.rounds) + " · " + minutes(len) }
        return (next == Pomodoro.lastPhase ? L10n.tr("Long break") : L10n.tr("Short break")) + " · " + minutes(len)
    }

    /// What the collapsed wing names: a focus round, a break, or nothing (plain timer).
    enum WingKind: Sendable { case focus, rest }

    static func wingLabel(_ s: TimerState) -> WingKind? {
        if let phase = s.phase { return Pomodoro.isFocus(phase) ? .focus : .rest }
        return s.isBreak == true ? .rest : nil
    }

    /// The wing's right side: "12m left", "Focus 12m", "Break 4m", "Break ready".
    static func wing(_ kind: WingKind?, minutes: Int, held: Bool) -> String {
        switch (kind, held) {
        case (.focus, true): L10n.tr("Focus ready")
        case (.rest, true): L10n.tr("Break ready")
        case (.focus, false): L10n.tr("Focus %dm", minutes)
        case (.rest, false): L10n.tr("Break %dm", minutes)
        case (nil, _): left(minutes)
        }
    }

    /// The button that starts a held phase: "Start short break".
    static func startHeld(_ s: TimerState) -> String {
        guard let phase = s.phase else { return L10n.tr("Start") }
        if Pomodoro.isFocus(phase) { return L10n.tr("Start focus %d/%d", Pomodoro.round(of: phase), Pomodoro.rounds) }
        return phase == Pomodoro.lastPhase ? L10n.tr("Start long break") : L10n.tr("Start short break")
    }

    static func roundsToday(_ n: Int) -> String {
        n == 1 ? L10n.tr("1 focus round today") : L10n.tr("%d focus rounds today", n)
    }

    /// The system notification for the end of the current run.
    static func alert(for s: TimerState) -> (String, String) {
        guard let phase = s.phase else {
            if s.isBreak == true { return (L10n.tr("Break over"), L10n.tr("Your %d-minute break is over.", Int((s.duration / 60).rounded()))) }
            return (L10n.tr("Timer done"), L10n.tr("Your %d-minute timer has finished.", Int((s.duration / 60).rounded())))
        }
        if phase == Pomodoro.lastPhase { return (L10n.tr("Pomodoro complete"), L10n.tr("Four rounds done. Nice work.")) }
        if Pomodoro.isFocus(phase) {
            return (L10n.tr("Focus done"), L10n.tr("Take a %d-minute break.", Int(Pomodoro.duration(of: phase + 1) / 60)))
        }
        return (L10n.tr("Break over"), L10n.tr("Focus round %d of %d.", Pomodoro.round(of: phase + 1), Pomodoro.rounds))
    }

    /// The peek line after a deadline: title + detail.
    static func peek(_ e: TimerEvent) -> (String, String) {
        switch e {
        case .finished(let d): (L10n.tr("Timer done"), minutes(Int((d / 60).rounded())))
        case .cycleComplete: (L10n.tr("Pomodoro complete"), L10n.tr("Four rounds done"))
        case .phaseChanged(let from, let to):
            Pomodoro.isFocus(from)
                ? (L10n.tr("Focus done"), (to == Pomodoro.lastPhase ? L10n.tr("Long break") : L10n.tr("Short break")) + " · " + minutes(Int(Pomodoro.duration(of: to) / 60)))
                : (L10n.tr("Break over"), L10n.tr("Focus %d/%d", Pomodoro.round(of: to), Pomodoro.rounds))
        }
    }
}

let timerItalian: [String: String] = [
    "%d min": "%d min",
    "%dm left": "ancora %d min",
    "Focus %d/%d": "Concentrazione %d/%d",
    "Short break": "Pausa breve",
    "Long break": "Pausa lunga",
    "Timer done": "Timer finito",
    "Your %d-minute timer has finished.": "Il timer da %d minuti è finito.",
    "Pomodoro complete": "Pomodoro completato",
    "Four rounds done. Nice work.": "Quattro round fatti. Ottimo lavoro.",
    "Four rounds done": "Quattro round fatti",
    "Focus done": "Concentrazione finita",
    "Take a %d-minute break.": "Fai una pausa di %d minuti.",
    "Break over": "Pausa finita",
    "Focus round %d of %d.": "Round di concentrazione %d di %d.",
    "Paused": "In pausa",
    "Up next": "A seguire",
    "Custom": "Personalizzato",
    "Start": "Avvia",
    "Pomodoro": "Pomodoro",
    "%d / %d ×4, then %d": "%d / %d ×4, poi %d",
    "Pause": "Pausa",
    "Resume": "Riprendi",
    "Stop": "Ferma",
    "+1 min": "+1 min",
    "Ready when you are": "Pronto quando vuoi",
    "Scroll or use − + to set minutes": "Scorri o usa − + per i minuti",
    // Wave 4
    "Break": "Pausa",
    "Focus %dm": "Focus %d min",
    "Break %dm": "Pausa %d min",
    "Focus ready": "Focus pronto",
    "Break ready": "Pausa pronta",
    "Start focus %d/%d": "Avvia concentrazione %d/%d",
    "Start short break": "Avvia pausa breve",
    "Start long break": "Avvia pausa lunga",
    "1 focus round today": "1 round di concentrazione oggi",
    "%d focus rounds today": "%d round di concentrazione oggi",
    "Your %d-minute break is over.": "La pausa da %d minuti è finita.",
    "Skip": "Salta",
    "Skip to the next phase": "Passa alla fase successiva",
    "Start the next phase automatically": "Avvia da sola la fase successiva",
    "Otherwise each phase waits for Start": "Altrimenti ogni fase aspetta Avvia",
    "Focus during focus rounds": "Full immersion durante la concentrazione",
    "Uses the Glancy Focus shortcuts": "Usa i comandi rapidi Glancy Focus",
    // Command bar
    "Start Pomodoro": "Avvia Pomodoro",
    "Start a %d-minute timer": "Avvia un timer di %d minuti",
    "Start a %d-minute break": "Avvia una pausa di %d minuti",
    "Timer %d min": "Timer %d min",
    "Stop timer": "Ferma timer",
    "Pause timer": "Metti in pausa il timer",
    "Resume timer": "Riprendi il timer",
    "Add a minute": "Aggiungi un minuto",
    "Skip Pomodoro phase": "Salta la fase del Pomodoro",
    "%d / %d min ×4, then %d": "%d / %d min ×4, poi %d",
    "Running · %@ left": "In corso · mancano %@",
]
