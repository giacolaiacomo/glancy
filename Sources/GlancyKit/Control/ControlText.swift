import Foundation

/// The Control module's strings. English literals are the keys; Italian below (`L10n.addItalian`
/// at start).
@MainActor
enum ControlText {
    static func t(_ s: String) -> String { L10n.tr(s) }

    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = L10n.locale
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: d)
    }

    /// "until 14:30".
    static func until(_ d: Date) -> String { L10n.tr("until %@", time(d)) }

    /// "On · until 14:30" / "On · until you turn it off".
    static func awakeState(_ s: AwakeState) -> String {
        guard s.isOn else { return t("Off") }
        return s.until.map(until) ?? t("Until turned off")
    }

    /// "Keep awake for 1h" / "Keep awake until turned off".
    static func awakeFor(_ d: AwakeDuration) -> String {
        guard let s = d.seconds else { return t("Keep awake until turned off") }
        return awakeFor(seconds: s)
    }

    static func awakeFor(seconds: TimeInterval) -> String { L10n.tr("Keep awake for %@", ControlFormat.length(seconds)) }

    static func trash(_ s: TrashSummary) -> String {
        let items = s.items == 1 ? t("1 item") : L10n.tr("%d items", s.items)
        guard let b = s.bytes else { return items }
        return items + " · " + ControlFormat.bytes(b)
    }

    /// Settings index: "11 of 13 tiles".
    static func summary(_ s: ControlSettings) -> String {
        let l = s.layout
        return L10n.tr("%d of %d tiles", l.toggles.count + l.tools.count, ControlTile.allCases.count)
    }
}

let controlItalian: [String: String] = [
    // Module
    "Control": "Controllo",
    "Quick toggles and system tools": "Interruttori rapidi e strumenti di sistema",

    // Tiles
    "Keep awake": "Tieni sveglio",
    "Dark mode": "Tema scuro",
    "Wi-Fi": "Wi-Fi",
    "Desktop icons": "Icone scrivania",
    "Hidden files": "File nascosti",
    "Lock": "Blocca",
    "Display off": "Schermo off",
    "Screen saver": "Salvaschermo",
    "Screenshot": "Istantanea",
    "Color picker": "Contagocce",
    "Mirror": "Specchio",
    "Empty Trash": "Svuota cestino",
    "Eject all": "Espelli tutto",

    // States
    "On": "Attivo",
    "Off": "Spento",
    "Hidden": "Nascoste",
    "Shown": "Visibili",
    "Light": "Chiara",
    "Dark": "Scura",
    "No Wi-Fi": "Niente Wi-Fi",
    "until %@": "fino alle %@",
    "Until turned off": "Finché non lo spegni",
    "Keep awake for %@": "Tieni sveglio per %@",
    "Keep awake until turned off": "Tieni sveglio finché non lo spegni",
    "Stop keeping awake": "Smetti di tenere sveglio",
    "Keep awake ended": "Fine di Tieni sveglio",
    "Awake": "Sveglio",
    "Awake until %@": "Sveglio fino alle %@",
    "Awake, no end": "Sveglio, senza fine",
    "Stop": "Ferma",
    "Length": "Durata",

    // Commands
    "Turn Dark mode on": "Attiva la modalità scura",
    "Turn Dark mode off": "Disattiva la modalità scura",
    "Turn Wi-Fi on": "Attiva il Wi-Fi",
    "Turn Wi-Fi off": "Disattiva il Wi-Fi",
    "Hide desktop icons": "Nascondi le icone della scrivania",
    "Show desktop icons": "Mostra le icone della scrivania",
    "Show hidden files": "Mostra i file nascosti",
    "Hide hidden files": "Nascondi i file nascosti",
    "Finder restarts": "Il Finder si riavvia",
    "Lock screen": "Blocca lo schermo",
    "Turn display off": "Spegni lo schermo",
    "Start screen saver": "Avvia il salvaschermo",
    "Screenshot an area": "Istantanea di un'area",
    "Screenshot to Desktop": "Istantanea sulla scrivania",
    "To the Desktop": "Sulla scrivania",
    "To the clipboard": "Negli appunti",
    "Pick a color": "Preleva un colore",
    "Copies the HEX": "Copia l'HEX",
    "Copy HEX": "Copia HEX",
    "Copy RGB": "Copia RGB",
    "Camera mirror": "Specchio con la fotocamera",
    "Eject all disks": "Espelli tutti i dischi",

    // Bar and notes
    "Finder restarts to apply this. Open windows come back.": "Il Finder si riavvia per applicarlo. Le finestre aperte tornano.",
    "Restart Finder": "Riavvia il Finder",
    "Empty the Trash?": "Svuotare il cestino?",
    "Icons hidden": "Icone nascoste",
    "Icons shown": "Icone visibili",
    "It can't be undone.": "Non si può annullare.",
    "Empty now": "Svuota ora",
    "1 item": "1 elemento",
    "%d items": "%d elementi",
    "Automation needed": "Serve l'Automazione",
    "Allow Glancy to control %@ in Privacy → Automation.": "Consenti a Glancy di controllare %@ in Privacy → Automazione.",
    "The mirror needs the camera.": "Lo specchio ha bisogno della fotocamera.",
    "Allow it in Privacy → Camera.": "Consentila in Privacy → Fotocamera.",
    "Open Settings": "Apri Impostazioni",
    "Cancel": "Annulla",
    "Couldn't keep the Mac awake": "Impossibile tenere sveglio il Mac",
    "Couldn't change the appearance": "Impossibile cambiare l'aspetto",
    "No Wi-Fi on this Mac": "Nessun Wi-Fi su questo Mac",
    "Couldn't change Wi-Fi": "Impossibile cambiare il Wi-Fi",
    "Couldn't restart Finder": "Impossibile riavviare il Finder",
    "Trash emptied": "Cestino svuotato",
    "Couldn't empty the Trash": "Impossibile svuotare il cestino",
    "The Trash is already empty": "Il cestino è già vuoto",
    "Couldn't read the Trash": "Impossibile leggere il cestino",
    "Nothing to eject": "Niente da espellere",
    "1 disk ejected": "1 disco espulso",
    "%d disks ejected": "%d dischi espulsi",
    "%d ejected, %d in use": "%d espulsi, %d in uso",
    "Mirror works in the installed app": "Lo specchio funziona nell'app installata",
    "Copied": "Copiato",
    "Close": "Chiudi",
    "Camera preview": "Anteprima fotocamera",
    "Recent": "Recenti",
    "Clear colors": "Cancella i colori",

    // Settings
    "Tiles": "Riquadri",
    "%d of %d tiles": "%d di %d riquadri",
    "Click a tile to show or hide it; arrows move it within its row.":
        "Clic su un riquadro per mostrarlo o nasconderlo; le frecce lo spostano nella sua riga.",
    "Toggles": "Interruttori",
    "Tools": "Strumenti",
    "Keep awake by default": "Durata di Tieni sveglio",
    "The length the tile starts with": "La durata con cui parte il riquadro",
    "Keep awake in the notch": "Tieni sveglio nella notch",
    "A cup in the wings while it's on": "Una tazzina ai lati della notch finché è attivo",
    "Screenshots go to": "Le istantanee vanno",
    "Clipboard": "Appunti",
    "Desktop": "Scrivania",
    "Move left": "Sposta a sinistra",
    "Move right": "Sposta a destra",
    "Dark mode asks for Automation (System Events); Empty Trash for Automation (Finder); the mirror for the camera, on first use.":
        "La modalità scura chiede l'Automazione (System Events); Svuota cestino l'Automazione (Finder); lo specchio la fotocamera, al primo uso.",
]
