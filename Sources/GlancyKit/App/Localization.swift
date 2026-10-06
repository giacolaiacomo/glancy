import Foundation

// Localization, the Tessera way: the source is written in English and the literals are what the
// app shows. A translation is a table keyed by the English text. Each module may add its own table
// with `L10n.addItalian(_:)` at start-up; the surface ships the strings it owns below.

public enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case system, en, it
}

@MainActor
public enum L10n {
    /// The resolved language, "en" or "it". Updated by `AppSettings` when the preference changes.
    /// Readable from any thread (module string tables that are not main-actor bound); written only
    /// on main.
    public nonisolated(unsafe) private(set) static var current = "en"
    /// The Italian strings, built on the first Italian lookup: an English Glancy never builds the
    /// tables (about 20 dictionaries, ~0.4 MB of heap).
    private static var italian = LazyStrings { surfaceItalian.merging(settingsItalian) { _, new in new } }

    public static func apply(_ pref: AppLanguage) {
        current = resolve(pref, preferred: Locale.preferredLanguages)
    }

    /// True when the app speaks Italian. Safe from any thread.
    public nonisolated static var isItalian: Bool { current == "it" }

    /// The locale dates and relative times are written in: the Mac's own when it speaks the app's
    /// language (keeps the region's formats), otherwise the app's language.
    public nonisolated static var locale: Locale {
        let system = Locale.current
        if system.language.languageCode?.identifier == current { return system }
        return Locale(identifier: current == "it" ? "it_IT" : "en_US")
    }

    public nonisolated static func resolve(_ pref: AppLanguage, preferred: [String]) -> String {
        switch pref {
        case .en: return "en"
        case .it: return "it"
        case .system: return preferred.first?.hasPrefix("it") == true ? "it" : "en"
        }
    }

    /// Adds (or overrides) Italian strings. Call once from a module's `start`. The table is only
    /// read when the app speaks Italian.
    public static func addItalian(_ table: @autoclosure @escaping () -> [String: String]) {
        italian.add(table)
    }

    private static func italianStrings() -> [String: String] { italian.table() }

    /// Every Italian string registered so far (tests check placeholders against the English key).
    static var italianTable: [String: String] { italianStrings() }

    public static func tr(_ s: String) -> String {
        current == "it" ? italianStrings()[s] ?? s : s
    }

    /// `tr` plus `String(format:)`, for strings with placeholders.
    public static func tr(_ s: String, _ args: CVarArg...) -> String {
        String(format: tr(s), arguments: args)
    }
}

/// A string table assembled from parts only when first read; parts added later merge in at once.
struct LazyStrings {
    private var built: [String: String]?
    private var parts: [() -> [String: String]]

    init(_ base: @escaping () -> [String: String]) { parts = [base] }

    var isBuilt: Bool { built != nil }

    mutating func add(_ part: @escaping () -> [String: String]) {
        if built != nil { built!.merge(part()) { _, new in new } } else { parts.append(part) }
    }

    mutating func table() -> [String: String] {
        if let built { return built }
        var t: [String: String] = [:]
        for part in parts { t.merge(part()) { _, new in new } }
        parts.removeAll()
        built = t
        return t
    }
}

/// Shorthand used by the surface's own views.
@MainActor func tr(_ s: String) -> String { L10n.tr(s) }

private let surfaceItalian: [String: String] = [
    // Tabs and panel
    "Home": "Home",
    "Settings": "Impostazioni",
    "All quiet": "Tutto tranquillo",
    "Your next meeting, live sessions and what is playing will show up here.":
        "Qui compaiono la prossima riunione, le sessioni attive e ciò che sta suonando.",
    "Back": "Indietro",

    // Settings
    "General": "Generali",
    "Display": "Schermo",
    "Modules": "Moduli",
    "Open with": "Apri con",
    "Click": "Clic",
    "Hover": "Passaggio",
    "Language": "Lingua",
    "System": "Sistema",
    "Launch at login": "Apri al login",
    "Hidden from screen recordings": "Nascosta nelle registrazioni",
    "Pill on external displays": "Pillola sugli schermi esterni",
    "No modules yet.": "Ancora nessun modulo.",
    "Quit Glancy": "Esci da Glancy",
    "Needs approval in System Settings": "Da approvare in Impostazioni di Sistema",
    "Available from the installed app": "Disponibile dall'app installata",

    // Module names
    "Agents": "Agenti",
    "Calendar": "Calendario",
    "Media": "Musica",
    "Clipboard": "Appunti",
    "HUD": "HUD",
    "Power": "Batteria",
    "Timer": "Timer",
    "Shelf": "Ripiano",
    "Windows": "Finestre",
    "Notifications": "Notifiche",

    // Demo
    "Demo": "Demo",
    "Now playing": "In riproduzione",
    "AirPods Pro connected": "AirPods Pro connessi",
    "Focus": "Concentrazione",
    "Sample content, shown with --demo.": "Contenuti di esempio, mostrati con --demo.",
    "Up next": "A seguire",
]
