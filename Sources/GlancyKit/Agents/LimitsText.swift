import Foundation

// EN/IT strings for plan limits (the Agents module's pattern: the English literal is the key,
// Italian is one table; the language is the app's).

enum LimitsText {
    static var isItalian: Bool { L10n.isItalian }

    static func t(_ en: String) -> String { isItalian ? italian[en] ?? en : en }

    private static let italian: [String: String] = [
        "Limits": "Limiti",
        "Plan limits": "Limiti del piano",
        "Sessions": "Sessioni",
        "Where it went": "Dove sono finiti",
        "Session": "Sessione",
        "Week": "Settimana",
        "all models": "tutti i modelli",
        "Window": "Finestra",
        "Reset": "Azzerato",
        "Refresh now": "Aggiorna ora",
        "Updating…": "Aggiorno…",
        "just now": "adesso",
        "Claude Code CLI not found.": "CLI di Claude Code non trovata.",
        "The claude binary isn't signed by Anthropic, so Glancy won't run it.":
            "Il binario claude non è firmato da Anthropic: Glancy non lo esegue.",
        "The claude CLI answered unexpectedly, so Glancy stopped calling it. Turn Claude Code limits off and on after updating.":
            "La CLI claude ha risposto in modo inatteso: Glancy ha smesso di chiamarla. Spegni e riaccendi i limiti di Claude Code dopo un aggiornamento.",
        "Couldn't read /usage this time.": "Questa volta /usage non ha risposto.",
        "No reading yet: open this tab again in a moment.": "Nessuna lettura per ora: riapri la scheda tra poco.",
        "No data yet: use it once and it will show up here.": "Nessun dato: usalo una volta e comparirà qui.",
        "Updates when you use Codex.": "Si aggiorna quando usi Codex.",
        "The tick on each bar shows where you'd be at an even pace.": "La tacca sulla barra indica dove saresti a ritmo costante.",
        "Reading local logs…": "Leggo i log locali…",
        "No usage in this window.": "Nessun utilizzo in questa finestra.",
        "Temporary folders": "Cartelle temporanee",
        "Unknown": "Sconosciuto",
        "Other": "Altro",
        "Estimated from Claude Code's and Codex's local logs, weighted by API price. The official % comes from the CLIs. Nothing leaves your Mac.":
            "Stima dai log locali di Claude Code e Codex, pesata sui prezzi API. La % ufficiale viene dai client. Nulla esce dal Mac.",
        "What the same usage would cost on the API, at list prices.": "Quanto costerebbe lo stesso utilizzo via API, a prezzi di listino.",
        "Not available here.": "Non disponibile qui.",
        // Settings
        "Claude Code limits": "Limiti di Claude Code",
        "Codex limits": "Limiti di Codex",
        "Limit alerts": "Avvisi sui limiti",
        "Refresh after": "Aggiorna dopo",
        "Runs the official /usage (0 tokens) when the tab opens, at most every 60 s": "Esegue /usage ufficiale (0 token) quando apri la scheda, al massimo ogni 60 s",
        "CLI not found": "CLI non trovata",
        "Not signed by Anthropic: never run": "Non firmata da Anthropic: mai eseguita",
        "Answered unexpectedly: stopped until turned off and on": "Risposta inattesa: ferma finché non la spegni e riaccendi",
        "From the rate_limits Codex writes in ~/.codex/sessions": "Dai rate_limits che Codex scrive in ~/.codex/sessions",
        "Needs Codex on in Sources above": "Serve Codex acceso tra le fonti qui sopra",
        "Not found: Codex has not run on this Mac yet": "Non trovato: Codex non è ancora stato usato su questo Mac",
        "A drop-down at 90% and 100%, when a session is on pace to run out, and when a used-up limit resets":
            "Un avviso al 90% e al 100%, quando una sessione sta per esaurirsi e quando un limite esaurito si azzera",
        "Safe by design: Glancy never reads tokens, cookies or passwords, never calls private endpoints and never sends a message. Claude's /usage runs only if the binary is signed by Anthropic, with no tools, MCP servers or hooks, sandboxed from your personal folders.":
            "Sicuro per costruzione: Glancy non legge mai token, cookie o password, non chiama endpoint privati e non invia messaggi. /usage di Claude parte solo se il binario è firmato da Anthropic, senza strumenti, server MCP né hook, isolato dalle tue cartelle personali.",
    ]

    // MARK: Labels

    /// The strip's short label: "5h", "Week", "Fable".
    static func short(_ k: UsageLimitKind) -> String {
        switch k {
        case .session(let h): return "\(h)h"
        case .week(let m): return m.flatMap { $0 == "all models" ? nil : $0 } ?? (isItalian ? "Sett." : "Week")
        case .other(let h): return h >= 24 ? "\(h / 24)\(isItalian ? "g" : "d")" : "\(h)h"
        }
    }

    /// The full label: "Session · 5h", "Week · all models", "Week · Fable", "Week".
    static func label(_ k: UsageLimitKind) -> String {
        switch k {
        case .session(let h): return "\(t("Session")) · \(h)h"
        case .week(nil): return t("Week")
        case .week(let m?): return "\(t("Week")) · \(m == "all models" ? t(m) : m)"
        case .other(let h): return "\(t("Window")) \(h)h"
        }
    }

    // MARK: Times

    static var locale: Locale { L10n.locale }

    /// "45m", "3h12", "2d4h" (IT "2g4h").
    static func compactUntil(_ d: Date?, now: Date) -> String? {
        guard let d, d > now else { return nil }
        let m = Int(d.timeIntervalSince(now) / 60)
        return m < 60 ? "\(m)m" : m < 1440 ? String(format: "%dh%02d", m / 60, m % 60) : "\(m / 1440)\(isItalian ? "g" : "d")\(m % 1440 / 60)h"
    }

    /// "18:40" within 12 hours (a 5-hour window needs no date), else "Sat 3 · 14:00".
    static func shortWhen(_ d: Date, now: Date) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = abs(d.timeIntervalSince(now)) < 12 * 3600 ? "HH:mm" : "EEE d · HH:mm"
        return f.string(from: d)
    }

    /// "Resets in 2h 18m · 00:40", "Reset".
    static func resetLine(_ d: Date?, now: Date) -> String {
        guard let d else { return "" }
        if d <= now { return t("Reset") }
        let m = Int(d.timeIntervalSince(now) / 60)
        let dd = isItalian ? "g" : "d"
        let rel = m < 60 ? "\(m)m" : m < 1440 ? "\(m / 60)h \(m % 60)m" : "\(m / 1440)\(dd) \(m % 1440 / 60)h"
        return isItalian ? "Si azzera tra \(rel) · \(shortWhen(d, now: now))" : "Resets in \(rel) · \(shortWhen(d, now: now))"
    }

    /// The Limits page's row: "2h 17m · 01:29", "3d 3h · Sat 10 · 03:11", "Reset".
    static func resetShort(_ d: Date?, now: Date) -> String {
        guard let d else { return "" }
        if d <= now { return t("Reset") }
        let m = Int(d.timeIntervalSince(now) / 60)
        let dd = isItalian ? "g" : "d"
        let rel = m < 60 ? "\(m)m" : m < 1440 ? "\(m / 60)h \(m % 60)m" : "\(m / 1440)\(dd) \(m % 1440 / 60)h"
        return "\(rel) · \(shortWhen(d, now: now))"
    }

    /// "4 min ago".
    static func ago(_ d: Date, now: Date) -> String {
        let m = Int(now.timeIntervalSince(d) / 60)
        if m < 1 { return t("just now") }
        if m < 60 { return isItalian ? "\(m) min fa" : "\(m) min ago" }
        if m < 1440 { return isItalian ? "\(m / 60) h fa" : "\(m / 60) h ago" }
        return isItalian ? "\(m / 1440) g fa" : "\(m / 1440) d ago"
    }

    // MARK: Forecasts

    /// Only as precise as it deserves: minutes for a session, the day for a week (the hour once close).
    static func runsOut(_ l: UsageLimit, eta: Date, now: Date, short: Bool = false) -> String {
        if l.kind.isSession {
            let rounded = Date(timeIntervalSinceReferenceDate: (eta.timeIntervalSinceReferenceDate / 300).rounded() * 300)
            let w = shortWhen(rounded, now: now)
            if short { return isItalian ? "finisce ~\(w)" : "out ~\(w)" }
            return isItalian ? "Finisce verso \(w) a questo ritmo" : "Runs out ~\(w) at this pace"
        }
        let cal = Calendar.current
        let when: String
        if eta.timeIntervalSince(now) < 86400 {
            when = shortWhen(cal.dateInterval(of: .hour, for: eta.addingTimeInterval(1800))?.start ?? eta, now: now)
        } else if cal.isDate(eta, inSameDayAs: now.addingTimeInterval(86400)) {
            when = isItalian ? "domani" : "tomorrow"
        } else {
            let f = DateFormatter()
            f.locale = locale
            f.dateFormat = "EEEE"
            when = f.string(from: eta)
        }
        if short { return isItalian ? "finisce ~\(when)" : "out ~\(when)" }
        return isItalian ? "Al ritmo di questa settimana finisce verso \(when)" : "At this week's pace it runs out ~\(when)"
    }

    static func dailyBudget(_ b: Double, short: Bool = false) -> String {
        let n = Int(b.rounded(.down))
        if short { return isItalian ? "~\(n)%/giorno" : "~\(n)%/day" }
        return isItalian ? "~\(n)% al giorno per arrivare al reset" : "~\(n)% a day lasts until the reset"
    }

    static func switchHint(_ model: String, left: Int) -> String {
        isItalian ? "\(model) è quasi esaurito. Agli altri modelli resta il \(left)% questa settimana."
            : "\(model) is nearly used up. Other models still have \(left)% left this week."
    }

    // MARK: Alerts

    /// "Claude Code session", "Codex week", "Fable week" (IT "Sessione di Claude Code"…).
    static func alertName(_ s: UsageService, _ k: UsageLimitKind) -> String {
        switch k {
        case .session: return isItalian ? "Sessione di \(s.name)" : "\(s.name) session"
        case .week(let m):
            // A model's bucket names itself (the drop-down's glyph shows the service).
            if let m, m != "all models" { return isItalian ? "Settimana \(m)" : "\(m) week" }
            return isItalian ? "Settimana di \(s.name)" : "\(s.name) week"
        case .other(let h): return isItalian ? "Finestra \(h)h di \(s.name)" : "\(s.name) \(h)h window"
        }
    }

    /// "alle 01:29", but "sab 10 · 03:27" (Italian puts "alle" only before a bare time).
    private static func alle(_ when: String) -> String { when.contains("·") ? when : "alle \(when)" }

    static func alert(_ s: UsageService, _ l: UsageLimit, level: Int, now: Date) -> String {
        let n = alertName(s, l.kind)
        let reset = l.resetsAt.map { shortWhen($0, now: now) }
        if level >= 100 {
            return isItalian ? "\(n) esaurita" + (reset.map { " · torna \(alle($0))" } ?? "")
                : "\(n) used up" + (reset.map { " · back at \($0)" } ?? "")
        }
        let p = Int(l.effective(at: now))
        return isItalian ? "\(n) al \(p)%" + (reset.map { " · si azzera \(alle($0))" } ?? "")
            : "\(n) at \(p)%" + (reset.map { " · resets \($0)" } ?? "")
    }

    static func paceAlert(_ s: UsageService, _ l: UsageLimit, eta: Date, now: Date) -> String {
        let n = alertName(s, l.kind)
        let w = shortWhen(Date(timeIntervalSinceReferenceDate: (eta.timeIntervalSinceReferenceDate / 300).rounded() * 300), now: now)
        return isItalian ? "\(n): a questo ritmo finisce verso le \(w)" : "\(n) runs out ~\(w) at this pace"
    }

    static func resetAlert(_ s: UsageService, _ l: UsageLimit) -> String {
        isItalian ? "\(alertName(s, l.kind)) azzerata, puoi ripartire" : "\(alertName(s, l.kind)) reset, you're good to go"
    }

    /// The used-up wing: "until 00:40".
    static func until(_ d: Date, now: Date) -> String {
        isItalian ? "fino alle \(shortWhen(d, now: now))" : "until \(shortWhen(d, now: now))"
    }

    // MARK: Where it went

    static func project(_ name: String) -> String {
        name == usageTempProject ? t("Temporary folders") : name == "?" ? t("Unknown") : name == UsageShare.other ? t("Other") : name
    }

    static func tokens(_ t: Double) -> String {
        t >= 1e9 ? String(format: "%.1fB", t / 1e9) : t >= 1e6 ? String(format: "%.1fM", t / 1e6) : t >= 1e3 ? String(format: "%.0fK", t / 1e3) : String(Int(t))
    }

    static func usedTokens(_ percent: Double?, _ tokens: Double) -> String {
        if let p = percent {
            return isItalian ? "\(Int(p.rounded()))% usato · \(LimitsText.tokens(tokens)) token" : "\(Int(p.rounded()))% used · \(LimitsText.tokens(tokens)) tokens"
        }
        return isItalian ? "\(LimitsText.tokens(tokens)) token" : "\(LimitsText.tokens(tokens)) tokens"
    }

    static func dollars(_ v: Double) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        f.minimumFractionDigits = v < 100 ? 2 : 0
        f.maximumFractionDigits = v < 100 ? 2 : 0
        let s = f.string(from: NSNumber(value: v)) ?? String(format: "%.0f", v)
        return isItalian ? "≈ $\(s) a prezzi API" : "≈ $\(s) at API prices"
    }

    static func versusLastWeek(_ delta: Int) -> String {
        let d = (delta >= 0 ? "+" : "") + "\(delta)%"
        return isItalian ? "\(d) rispetto a 7 giorni fa" : "\(d) vs last week"
    }
}

extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
