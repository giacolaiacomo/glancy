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
        // Sources
        "Terminal": "Terminale",
        "Unknown app": "App sconosciuta",
        "No agent sessions": "Nessuna sessione di agenti",
        "Claude Code, Codex and OpenCode sessions appear here as soon as they run.":
            "Le sessioni di Claude Code, Codex e OpenCode compaiono qui appena sono in esecuzione.",
        "Claude Code, Codex, OpenCode sessions": "Sessioni di Claude Code, Codex, OpenCode",
        "The app this session runs in is not installed.": "L'app di questa sessione non è installata.",
        "Off": "Spento",
        "No agents found": "Nessun agente trovato",
        "Hook found": "Hook trovato",
        "Hook found · update it to tell terminals from VS Code": "Hook trovato · aggiornalo per distinguere terminale e VS Code",
        "No hook log: install the cc-dashboard hook": "Nessun log: installa l'hook cc-dashboard",
        "Not found: Codex has not run on this Mac yet": "Non trovato: Codex non è ancora stato usato su questo Mac",
        "Plugin installed: also shows when it needs you": "Plugin installato: mostra anche quando ha bisogno di te",
        "Reading its database · install the plugin to see when it needs you":
            "Legge il suo database · installa il plugin per sapere quando ha bisogno di te",
        "Not set up: OpenCode has not run on this Mac yet": "Non configurato: OpenCode non è ancora stato usato su questo Mac",
        "Show log": "Mostra log",
        "Install…": "Installa…",
        "Uninstall": "Disinstalla",
        "Update": "Aggiorna",
        "Could not write the plugin file.": "Impossibile scrivere il file del plugin.",
        "Adds Glancy's plugin to ~/.config/opencode/plugins (opencode.json is not touched). Restart OpenCode to load it.":
            "Aggiunge il plugin di Glancy a ~/.config/opencode/plugins (opencode.json non viene toccato). Riavvia OpenCode per caricarlo.",
        "Read-only: Glancy never writes to Claude Code or Codex files. A session goes idle after 30 min without events; sessions silent for 12 h are dropped.":
            "Sola lettura: Glancy non scrive mai nei file di Claude Code o Codex. Una sessione diventa inattiva dopo 30 min senza eventi; quelle silenziose da 12 h spariscono.",
        "Show agent sessions": "Mostra sessioni degli agenti",
        "Click to open it in the Codex app.": "Fai clic per aprirla nell'app Codex.",
        "Click to bring its window forward.": "Fai clic per portare in primo piano la sua finestra.",
    ]

    /// "Reading ~/.codex/sessions".
    static func reading(_ path: String) -> String { isItalian ? "Legge \(path)" : "Reading \(path)" }

    /// The tooltip's last line: what a click does for this session.
    static func clickHint(_ plan: AgentJumpPlan, host: AgentHost?) -> String {
        switch plan {
        case .terminal: return t("Click to bring its terminal forward.")
        case .codexThread: return t("Click to open it in the Codex app.")
        case .editor, .app:
            let name = host?.name ?? ""
            return name.isEmpty ? t("Click to bring its window forward.")
                : (isItalian ? "Fai clic per portare in primo piano \(name)." : "Click to bring \(name) forward.")
        }
    }

    /// After Install: where the plugin went, and the backup of a file that was there.
    static func installed(_ path: String, backup: String?) -> String {
        let p = (path as NSString).abbreviatingWithTildeInPath
        var s = isItalian ? "Installato in \(p). Riavvia OpenCode per caricarlo." : "Installed at \(p). Restart OpenCode to load it."
        if let backup { s += isItalian ? " Il file precedente è in \(backup)." : " The previous file was kept as \(backup)." }
        return s
    }

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
