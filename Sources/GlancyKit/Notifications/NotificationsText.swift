import Foundation

/// Notifications strings: English in the source, Italian here (registered at start).
@MainActor
enum NotifText {
    static func t(_ s: String) -> String { L10n.tr(s) }

    static let italian: [String: String] = [
        "Notifications": "Notifiche",
        "Allow Full Disk Access": "Consenti l'accesso completo al disco",
        "macOS keeps notifications in a protected store. Glancy only reads it, keeps the last 20 in memory and never saves them.":
            "macOS conserva le notifiche in un archivio protetto. Glancy lo legge soltanto, tiene in memoria le ultime 20 e non le salva mai.",
        "Open Privacy Settings": "Apri Privacy e sicurezza",
        "Add Glancy to Full Disk Access, then come back.": "Aggiungi Glancy all'elenco, poi torna qui.",
        "Not available on this macOS": "Non disponibile su questa versione di macOS",
        "The notification store has changed. Glancy leaves it alone rather than guess.":
            "L'archivio delle notifiche è cambiato. Glancy non lo tocca piuttosto che tirare a indovinare.",
        "No notifications yet": "Ancora nessuna notifica",
        "New notifications from other apps show up here.": "Qui compaiono le nuove notifiche delle altre app.",
        "Hide previews": "Nascondi anteprime",
        "Muted apps": "App silenziate",
        "No muted apps": "Nessuna app silenziata",
        "Mute %@": "Silenzia %@",
        "Open %@": "Apri %@",
        "Clear list": "Svuota elenco",
        "Previews hidden": "Anteprime nascoste",
        "+%d more": "+%d altre",
        "now": "ora",
    ]

    /// "now", "5m", "3h", "2d" (IT "2g"), else a short date. Computed, never ticking.
    static func relative(_ date: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return t("now") }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86_400 { return "\(Int(s / 3600))h" }
        if s < 7 * 86_400 { return "\(Int(s / 86_400))" + (L10n.current == "it" ? "g" : "d") }
        let f = DateFormatter()
        f.locale = Locale(identifier: L10n.current == "it" ? "it_IT" : "en_US")
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return f.string(from: date)
    }
}
