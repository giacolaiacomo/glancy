import Foundation

@MainActor
enum ShelfText {
    static func count(_ n: Int) -> String { n == 1 ? L10n.tr("1 item") : L10n.tr("%d items", n) }
    static func selected(_ n: Int) -> String { L10n.tr("%d selected", n) }
    static func files(_ n: Int) -> String { n == 1 ? L10n.tr("1 file") : L10n.tr("%d files", n) }
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
    "They stay until you remove them": "Restano finché non li togli",
    "Drag files, text or links onto the notch. They stay here until you remove them.":
        "Trascina file, testo o link sulla notch: restano qui finché non li togli.",
    "1 file": "1 file",
    "%d files": "%d file",
    "Working…": "In corso…",
    "Copy": "Copia",
    "Zip": "Comprimi",
    "More": "Altro",
    "Open": "Apri",
    "Open With": "Apri con",
    "Copy %d items": "Copia %d elementi",
    "Zip %d items": "Comprimi %d elementi",
    "Convert to JPEG": "Converti in JPEG",
    "Resize to 50%": "Riduci al 50%",
    "Remove from Shelf": "Togli dal ripiano",
    "Remove %d from Shelf": "Togli %d dal ripiano",
    "Couldn't create the archive": "Impossibile creare l'archivio",
    "Couldn't convert the image": "Impossibile convertire l'immagine",
    // Drop targets
    "Share…": "Condividi…",
    "Nearby devices": "Dispositivi vicini",
    "Mail, Messages…": "Mail, Messaggi…",
    "Beside the file": "Accanto al file",
    "One archive": "Un archivio",
    // Screenshots and downloads
    "Screenshot": "Istantanea",
    "Drag it anywhere": "Trascinala dove vuoi",
    "Annotate": "Annota",
    "Keep on the shelf": "Tieni sul ripiano",
    "Delete": "Elimina",
    "Downloaded": "Scaricato",
    "Copied": "Copiato",
    "On the shelf": "Sul ripiano",
    "No new screenshot yet": "Ancora nessuna nuova istantanea",
    "No new download yet": "Ancora nessun nuovo download",
    // Command bar
    "Open Shelf": "Apri il ripiano",
    "Clear Shelf": "Svuota il ripiano",
    "AirDrop Last Shelf Item": "Invia con AirDrop l'ultimo elemento",
    "Zip Shelf": "Comprimi il ripiano",
    "Show Last Screenshot": "Mostra l'ultima istantanea",
    "Show Last Download": "Mostra l'ultimo download",
    // Settings
    "Drop targets": "Destinazioni di rilascio",
    "AirDrop, Share and Zip beside the shelf while you drag files": "AirDrop, Condividi e Comprimi accanto al ripiano mentre trascini file",
    "Screenshots": "Istantanee",
    "New screenshots drop down from the notch": "Le nuove istantanee scendono dalla notch",
    "Also keep them on the shelf": "Tienile anche sul ripiano",
    "Finished downloads": "Download completati",
    "A drop-down when a file in Downloads is complete": "Un avviso quando un file in Download è completo",
    "Watching %@": "Controlla %@",
    "No access to %@": "Nessun accesso a %@",
    "%@ is missing": "%@ non esiste",
    "Allow it in Privacy & Security › Files and Folders.": "Consentilo in Privacy e sicurezza › File e cartelle.",
    "Open Settings": "Apri Impostazioni",
]
