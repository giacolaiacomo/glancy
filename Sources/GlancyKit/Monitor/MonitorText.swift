import Foundation

/// The Monitor's strings and number formats. English literals are the keys; Italian below.
@MainActor
enum MonitorText {
    static func t(_ s: String) -> String { L10n.tr(s) }

    static func rowName(_ r: MonitorRow) -> String { r.isRemainder ? t("System processes") : r.name }

    /// "143%" — of one core, like Activity Monitor.
    static func percent(_ cores: Double) -> String { "\(Int((cores * 100).rounded()))%" }

    /// Memory: "1.2 GB", "640 MB" — binary units like Activity Monitor and the installed RAM, and
    /// always a point, like the rates beside them.
    static func bytes(_ b: UInt64) -> String {
        let v = Double(b), k = 1024.0
        if v >= k * k * k { return String(format: "%.1f GB", v / (k * k * k)) }
        if v >= k * k { return String(format: "%.0f MB", v / (k * k)) }
        return String(format: "%.0f KB", v / k)
    }

    /// Disk space: decimal units like the Finder ("299 GB", "42.5 GB", "1.2 TB"), always a point.
    static func disk(_ b: Int64) -> String {
        let v = Double(max(0, b))
        if v >= 1e12 { return String(format: "%.1f TB", v / 1e12) }
        if v >= 1e11 { return String(format: "%.0f GB", v / 1e9) }
        if v >= 1e9 { return String(format: "%.1f GB", v / 1e9) }
        return String(format: "%.0f MB", v / 1e6)
    }

    /// "11.4 GB" with one decimal (RAM: binary gigabytes, as macOS counts installed memory).
    static func gb(_ b: UInt64) -> String { String(format: "%.1f GB", Double(b) / 1_073_741_824) }

    static func rate(_ bps: Double) -> String { ControlFormat.rate(bps) }

    /// "13.7 W", "240 mW", "0 mW".
    static func watts(_ w: Double) -> String {
        if w >= 10 { return String(format: "%.0f W", w) }
        if w >= 1 { return String(format: "%.1f W", w) }
        return String(format: "%.0f mW", max(0, w) * 1000)
    }

    /// A row's value for the selected gauge.
    static func value(_ r: MonitorRow, _ i: MonitorIndicator) -> String {
        switch i {
        case .cpu: percent(r.cpu)
        case .memory: bytes(r.memory)
        case .gpu: percent(r.gpu)
        case .disk: rate(r.disk)
        case .energy: watts(r.energy)
        case .network: ""
        }
    }

    /// "CPU 12% · 640 MB" (command bar subtitle); memory only before there are rates.
    static func usage(_ r: MonitorRow, cpu: Bool) -> String {
        let mem = r.memory > 0 ? bytes(r.memory) : nil
        let parts = [cpu ? L10n.tr("CPU %@", percent(r.cpu)) : nil, mem].compactMap { $0 }
        return parts.joined(separator: " · ")
    }

    static func thermal(_ s: Int) -> String {
        switch s {
        case 0: t("Cool")
        case 1: t("Warm")
        case 2: t("Hot")
        default: t("Throttling")
        }
    }

    static func header(_ i: MonitorIndicator) -> String {
        switch i {
        case .cpu: t("Top by CPU")
        case .memory: t("Top by memory")
        case .gpu: t("Top by GPU time")
        case .disk: t("Top by disk read + write")
        case .network: t("Network")
        case .energy: t("Top by CPU energy")
        }
    }

    static func summary(_ s: MonitorSettings) -> String {
        let g = s.grouping == .apps ? t("Apps") : t("Processes")
        return t(s.indicator.title) + " · " + g
    }
}

let monitorItalian: [String: String] = [
    "Monitor": "Monitor",
    "System monitor": "Monitor di sistema",
    "CPU, memory and the apps using them": "CPU, memoria e le app che le usano",

    // Gauges
    "CPU": "CPU",
    "Memory": "Memoria",
    "GPU": "GPU",
    "Disk": "Disco",
    "Network": "Rete",
    "Energy": "Energia",
    "user %@ · sys %@": "utente %@ · sist %@",
    "of %@ · swap %@": "di %@ · swap %@",
    "of %@": "di %@",
    "%@ free": "%@ liberi",
    "R %@ · W %@": "L %@ · S %@",
    "On battery": "A batteria",
    "From the adapter": "Dall'alimentatore",
    "Cool": "Fresco",
    "Warm": "Tiepido",
    "Hot": "Caldo",
    "Throttling": "Rallentato",
    "Pressure high": "Pressione alta",
    "Pressure critical": "Pressione critica",
    "Utilisation": "Utilizzo",

    // Right column
    "Top by CPU": "Più CPU",
    "Top by memory": "Più memoria",
    "Top by GPU time": "Più tempo GPU",
    "Top by disk read + write": "Più letture + scritture",
    "Top by CPU energy": "Più energia CPU",
    "Apps": "App",
    "Processes": "Processi",
    "System processes": "Processi di sistema",
    "Other users' processes (root daemons, WindowServer): their CPU, measured as what's left.":
        "Processi di altri utenti (demoni root, WindowServer): la loro CPU, misurata come resto.",
    "Measuring…": "Misuro…",
    "Nothing busy": "Niente di attivo",
    "Per-app network use needs a private macOS API: the Mac's total is shown.":
        "L'uso di rete per app richiede un'API privata di macOS: qui il totale del Mac.",
    "Download": "Download",
    "Upload": "Upload",
    "The kernel's estimate of the energy each process spent on the CPU.": "La stima del kernel dell'energia spesa da ogni processo sulla CPU.",
    "Each app's share of the GPU's time.": "La quota di tempo GPU di ogni app.",

    // Actions
    "Quit": "Esci",
    "Force Quit…": "Uscita forzata…",
    "Force quit": "Uscita forzata",
    "Reveal in Finder": "Mostra nel Finder",
    "Open Activity Monitor": "Apri Monitoraggio Attività",
    "Activity Monitor": "Monitoraggio Attività",
    "Cancel": "Annulla",
    "Force quit %@? Unsaved changes are lost.": "Uscita forzata da %@? Le modifiche non salvate vanno perse.",
    "Quit %@? It's not an app: it gets a terminate signal.": "Chiudere %@? Non è un'app: riceve un segnale di chiusura.",
    "%@ didn't quit": "%@ non si è chiuso",
    "Couldn't force quit %@": "Impossibile forzare l'uscita da %@",

    // Command bar
    "Top CPU": "Più CPU",
    "Top memory": "Più memoria",
    "What's using the processor": "Cosa usa il processore",
    "What's using the RAM": "Cosa usa la RAM",
    "Quit %@": "Esci da %@",
    "Force quit %@…": "Uscita forzata da %@…",
    "Asks first, in the Monitor tab": "Chiede prima, nella scheda Monitor",
    "CPU %@": "CPU %@",

    // Settings
    "Opens on": "Si apre su",
    "The gauge selected when the tab opens": "L'indicatore selezionato quando apri la scheda",
    "List": "Elenco",
    "Apps sum their helpers; processes show each one": "Le app sommano i loro processi ausiliari; i processi uno per uno",
    "Sparklines": "Grafici",
    "The last minute under each gauge": "L'ultimo minuto sotto ogni indicatore",
    "Refresh": "Aggiorna",
    "Only while this tab is open": "Solo mentre questa scheda è aperta",
    "1 s": "1 s",
    "2 s": "2 s",
    "Processes of other users can't be read without administrator rights: their CPU shows as \"System processes\". Quit and Force quit act only on your click; Force quit asks first.":
        "I processi di altri utenti non si leggono senza diritti di amministratore: la loro CPU appare come \"Processi di sistema\". Esci e Uscita forzata agiscono solo al tuo clic; l'uscita forzata chiede prima.",
]
