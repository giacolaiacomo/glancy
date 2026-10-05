import Foundation

@MainActor
enum ShelfText {
    static func count(_ n: Int) -> String { n == 1 ? L10n.tr("1 item") : L10n.tr("%d items", n) }
    static func selected(_ n: Int) -> String { L10n.tr("%d selected", n) }
}

let shelfItalian: [String: String] = [
    "1 item": "1 elemento",
    "%d items": "%d elementi",
    "%d selected": "%d selezionati",
    "Receiving…": "Ricezione…",
    "Quick Look": "Vista rapida",
    "AirDrop": "AirDrop",
    "Share": "Condividi",
    "Show in Finder": "Mostra nel Finder",
    "Remove": "Rimuovi",
    "Clear shelf": "Svuota il ripiano",
    "Drop files here": "Trascina qui i file",
    "Drag files, text or links onto the notch. They stay here until you remove them.":
        "Trascina file, testo o link sulla notch: restano qui finché non li togli.",
]
