import Foundation

/// Clipboard strings: English in the source, Italian here (registered at start).
@MainActor
enum ClipText {
    static func t(_ s: String) -> String { L10n.tr(s) }

    static let italian: [String: String] = [
        "Clipboard": "Appunti",
        "Search clipboard": "Cerca negli appunti",
        "Pinned": "Fissati",
        "Recent": "Recenti",
        "Pause history": "Sospendi cronologia",
        "History paused": "Cronologia sospesa",
        "Resume": "Riprendi",
        "Paste after choosing": "Incolla dopo la scelta",
        "Excluded apps": "App escluse",
        "No excluded apps": "Nessuna app esclusa",
        "Clear all…": "Cancella tutto…",
        "Clear": "Cancella",
        "Cancel": "Annulla",
        "Clear all %d items, pinned included?": "Cancellare tutti i %d elementi, fissati compresi?",
        "Pin": "Fissa",
        "Unpin": "Togli",
        "Delete": "Elimina",
        "Copy": "Copia",
        "Never record from %@": "Non registrare mai da %@",
        "Nothing copied yet": "Ancora nessuna copia",
        "What you copy shows up here. %@ opens this list.": "Ciò che copi compare qui. %@ apre questo elenco.",
        "What you copy shows up here.": "Ciò che copi compare qui.",
        "No matches": "Nessun risultato",
        "⌘C not seen": "⌘C non visto",
        "Copies show up when you switch app or open Glancy. Allow Input Monitoring to catch ⌘C at once.":
            "Le copie compaiono quando cambi app o apri Glancy. Consenti il Monitoraggio input per vedere subito ⌘C.",
        "Enable": "Attiva",
        "Text": "Testo",
        "Rich text": "Testo formattato",
        "Link": "Link",
        "Image": "Immagine",
        "Files": "File",
        "now": "ora",
        "⏎ copy": "⏎ copia",
        "⏎ paste": "⏎ incolla",
    ]

    /// The empty list's hint, with the hotkey when there is one.
    static func emptyBody(_ hotkey: Hotkey) -> String {
        hotkey.modifiers == 0 ? t("What you copy shows up here.")
            : String(format: t("What you copy shows up here. %@ opens this list."), hotkey.description)
    }

    static func kind(_ k: ClipKind) -> String {
        switch k {
        case .text: t("Text")
        case .richText: t("Rich text")
        case .url: t("Link")
        case .image: t("Image")
        case .files: t("Files")
        }
    }

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
