import Foundation

// EN/IT strings for the Agents module, Tessera-style: the English literal is the key, Italian is
// one table. The language is the app's (`L10n.current`, set from Settings → Language).

enum AgentsText {
    static var isItalian: Bool { L10n.isItalian }

    static func t(_ en: String) -> String { isItalian ? italian[en] ?? en : en }

    private static let italian: [String: String] = [
        "Agents": "Agenti",
        // A session ("sessione") is feminine.
        "waiting": "in attesa",
        "working": "al lavoro",
        "done": "finita",
        "failed": "in errore",
        "idle": "inattiva",
        "ended": "chiusa",
        "No Claude Code sessions": "Nessuna sessione di Claude Code",
        "Sessions appear here as soon as Claude Code runs.": "Le sessioni compaiono qui appena Claude Code è in esecuzione.",
        "Click to bring its terminal forward.": "Fai clic per portare in primo piano il suo terminale.",
        "Accessibility is off: Glancy can bring the terminal app forward, not the exact window.":
            "Senza Accessibilità Glancy porta in primo piano l'app del terminale, non la finestra esatta.",
        "No terminal window found for this session.": "Nessuna finestra di terminale trovata per questa sessione.",
        "background agents running": "subagenti al lavoro in background",
        "needs permission for": "chiede il permesso per",
        "last turn": "ultimo turno",
        "tools": "strumenti",
        "Show": "Mostra",
        "No terminal window found to tile.": "Nessuna finestra di terminale da affiancare.",
        "Cancel": "Annulla",
        "Apply": "Applica",
        "Undo": "Annulla",
        "Undone": "Annullato",
        "More": "Altro",
        "Esc": "Esc",
        "Lay out sessions": "Disponi sessioni",
        "Tiling needs Accessibility": "Serve l'Accessibilità",
        "Tiling needs Accessibility (System Settings → Privacy & Security).":
            "Per disporre le finestre serve l'Accessibilità (Impostazioni di Sistema → Privacy e sicurezza).",
        "No terminal windows found for the live sessions.": "Nessuna finestra di terminale trovata per le sessioni attive.",
        "Preview every live session's terminal tiled on this display; click again or press ⏎ to apply.":
            "Anteprima dei terminali di tutte le sessioni attive affiancati su questo schermo; clic di nuovo o ⏎ per applicare.",
        "⌥-click to also tile it into the focused cell.": "⌥-clic per metterlo anche nella cella attiva.",
        "⌥-click to tile needs Accessibility.": "Il ⌥-clic per affiancare richiede l'Accessibilità.",
    ]

    static func state(_ s: AgentState) -> String { t(s.rawValue) }

    /// Right wing: "2 waiting" / "3 working" (Italian agrees in number: "2 finite").
    static func count(_ n: Int, _ s: AgentState) -> String {
        guard isItalian, n > 1, let plural = italianPlural[s.rawValue] else { return "\(n) \(state(s))" }
        return "\(n) \(plural)"
    }

    private static let italianPlural: [String: String] = [
        "done": "finite", "idle": "inattive", "ended": "chiuse",
    ]

    static func finished(_ label: String) -> String {
        isItalian ? "\(label) ha finito" : "\(label) finished"
    }

    static func finishedMany(_ labels: [String]) -> String {
        isItalian ? "\(list(labels)) hanno finito" : "\(list(labels)) finished"
    }

    static func needsYou(_ labels: [String]) -> String {
        labels.count == 1
            ? (isItalian ? "\(labels[0]) ha bisogno di te" : "\(labels[0]) needs you")
            : (isItalian ? "\(list(labels)) hanno bisogno di te" : "\(list(labels)) need you")
    }

    /// "Preview: 4 terminals".
    static func previewing(_ n: Int) -> String {
        isItalian ? "Anteprima: \(n) \(n == 1 ? "terminale" : "terminali")" : "Preview: \(n) terminal\(n == 1 ? "" : "s")"
    }

    static func live(_ n: Int) -> String { isItalian ? "\(n) attive" : "\(n) live" }

    private static func list(_ labels: [String]) -> String {
        guard labels.count > 1 else { return labels.first ?? "" }
        let and = isItalian ? " e " : " & "
        return labels.dropLast().joined(separator: ", ") + and + labels.last!
    }

    /// "12s", "4m 12s", "1h 05m".
    static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
        return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m"
    }

    /// Compact age: "now", "40s", "4m", "2h", "3d".
    static func age(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s < 5 { return isItalian ? "ora" : "now" }
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)" + (isItalian ? "g" : "d")
    }
}
