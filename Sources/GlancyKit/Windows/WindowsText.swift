// Windows — EN/IT strings. The English literal is the key (App/Localization.swift's approach);
// the table is merged into L10n when the module starts.

import Foundation

@MainActor
enum WindowsText {
    static func t(_ s: String) -> String { L10n.tr(s) }
    static func f(_ s: String, _ args: CVarArg...) -> String { String(format: L10n.tr(s), arguments: args) }

    static func register() { L10n.addItalian(italian) }

    static func strategy(_ s: ArrangeStrategy) -> String {
        switch s {
        case .balanced: t("Balanced")
        case .cells: t("One per cell")
        case .columns: t("Columns")
        case .rows: t("Rows")
        case .masterStack: t("Master + stack")
        }
    }

    /// A layout's name (thumbnail captions, the status line, the shortcut's peek).
    static func layoutTitle(_ s: WindowsAutoLayout.Shape) -> String {
        let n = s.capacity
        switch s.kind {
        case .full: return t("Full screen")
        case .leftHalf: return t("Left half")
        case .rightHalf: return t("Right half")
        case .sideBySide: return t("Side by side")
        case .stacked: return t("Stacked")
        case .twoThirds: return "⅔ + ⅓"
        case .mainStack: return f("Main + %d", n - 1)
        case .columns: return f("%d columns", n)
        case .rows: return f("%d rows", n)
        case .grid: return s.label.map { "\($0.cols)×\($0.rows)" } ?? f("%d windows", n)
        case .fill: return t("Fill empty space")
        }
    }

    /// A thumbnail's caption: "Suggested" for the first one.
    static func caption(_ o: WindowsAutoLayout.Option) -> String {
        o.suggested ? t("Suggested") : layoutTitle(o.shape)
    }

    /// The undo history's label for a layout.
    static func layout(_ o: WindowsAutoLayout.Option) -> String { layoutTitle(o.shape) }

    static let italian: [String: String] = [
        // Layouts (main surface)
        "Layout": "Disposizione",
        "Suggested": "Consigliata",
        "Full screen": "Schermo intero",
        "Left half": "Metà sinistra",
        "Right half": "Metà destra",
        "Fill empty space": "Riempi il vuoto",
        "No empty space on this display": "Nessuno spazio vuoto su questo schermo",
        "Where no other window is": "Dove non c'è nessun'altra finestra",
        "The front window, where no other window is": "La finestra davanti, dove non c'è nessun'altra finestra",
        "Fill the empty space": "Riempi lo spazio vuoto",
        "Side by side": "Affiancate",
        "Stacked": "Una sopra l'altra",
        "Main + %d": "Principale + %d",
        "%d columns": "%d colonne",
        "%d rows": "%d righe",
        "All %d windows": "Tutte le %d finestre",
        "The only window": "L'unica finestra",
        "More": "Altro",
        "Layouts": "Disposizioni",
        "Back to layouts": "Torna alle disposizioni",
        "Grid, scope, arrangements, placing on the map": "Griglia, ambito, disposizioni, posizionamento sulla mappa",
        "Clear": "Azzera",
        "Shortcuts": "Scorciatoie",
        "Already in place": "Già a posto",
        "Hover a layout to see it on the screen": "Passa su una disposizione per vederla sullo schermo",
        "Click windows to choose which · none = all": "Fai clic sulle finestre per sceglierle · nessuna = tutte",
        "Click: add or remove · ⇧-click: a range": "Clic: aggiungi o togli · ⇧-clic: un intervallo",
        "Auto-arrange": "Disponi automaticamente",
        "Auto-arrange: the display under the pointer, at once · ⇧ = only the front app · undo %@":
            "Disponi automaticamente: lo schermo sotto il puntatore, subito · ⇧ = solo l'app davanti · annulla %@",
        "front app": "app davanti",
        "click": "clic",
        "Hover a cell, click to place": "Passa su una cella, clic per sistemare",
        "More shortcuts": "Altre scorciatoie",
        "Arrange the display under the pointer with a fixed strategy · ⇧ = only the front app":
            "Dispone lo schermo sotto il puntatore con una strategia fissa · ⇧ = solo l'app davanti",
        "Apply the layout": "Applica la disposizione",
        "Undo the last change": "Annulla l'ultima modifica",
        "Open the map with the keyboard": "Apri la mappa con la tastiera",
        "Halves: ½ → ⅔ → ⅓ on repeat": "Metà: ½ → ⅔ → ⅓ ripetendo",
        "Choose windows: click · range: ⇧-click · clear: Esc": "Scegli le finestre: clic · intervallo: ⇧-clic · azzera: Esc",
        "Drag a window to the notch: drop it on a cell": "Trascina una finestra sul notch: rilasciala su una cella",
        "Windows": "Finestre",
        // Permission
        "Windows needs Accessibility": "Per le Finestre serve l'Accessibilità",
        "Glancy moves and resizes your windows through Accessibility. Nothing leaves this Mac.":
            "Glancy sposta e ridimensiona le finestre tramite l'Accessibilità. Nulla lascia questo Mac.",
        "Allow…": "Consenti…",
        "Open Settings": "Apri Impostazioni",
        "The map appears as soon as access is granted.": "La mappa compare appena l'accesso è concesso.",
        // Map
        "Grid": "Griglia",
        "Arrange": "Disponi",
        "Apply": "Applica",
        "Undo": "Annulla",
        "Balanced": "Bilanciata",
        "One per cell": "Una per cella",
        "Columns": "Colonne",
        "Rows": "Righe",
        "Master + stack": "Principale + colonna",
        "columns": "colonne",
        "rows": "righe",
        "←→↑↓ select · ⏎ place · ⇥ window · Space pick · A arrange": "←→↑↓ seleziona · ⏎ sistema · ⇥ finestra · Spazio scegli · A disponi",
        "←→↑↓ select · ⏎ place · ⇥ window · Space pick": "←→↑↓ seleziona · ⏎ sistema · ⇥ finestra · Spazio scegli",
        "1 window": "1 finestra",
        "%d left as they are": "%d lasciate come sono",
        "Pick a window in the list to place it": "Scegli una finestra nell'elenco per sistemarla",
        "Tab picks a window · or click one in the list": "Tab sceglie una finestra · o fai clic nell'elenco",
        "Click to pick %@": "Clic per scegliere %@",
        "%d×%d grid": "Griglia %d×%d",
        // List and selection
        "No windows on this display": "Nessuna finestra su questo schermo",
        "%d selected": "%d selezionate",
        "Swap the order (S)": "Scambia l'ordine (S)",
        "Rotate the order (S)": "Ruota l'ordine (S)",
        "Clear the selection (Esc)": "Annulla la selezione (Esc)",
        "Arrange the selected windows in this grid": "Disponi le finestre selezionate in questa griglia",
        "in pick order": "nell'ordine scelto",
        "%d selected · pick a grid or an arrangement": "%d selezionate · scegli una griglia o una disposizione",
        "Only the windows picked in the list, in pick order": "Solo le finestre scelte nell'elenco, nell'ordine scelto",
        // Scope
        "Screen": "Schermo",
        "App": "App",
        "Window": "Finestra",
        "Every window on this display": "Tutte le finestre di questo schermo",
        "Only one app's windows on this display": "Solo le finestre di un'app su questo schermo",
        "Click again for the next app": "Fai di nuovo clic per l'app successiva",
        "One window: place it, no arranging": "Una finestra: la sistemi, senza disporre",
        // Arrange shortcuts
        "Busy — try again": "Occupato — riprova",
        "Nothing to arrange here": "Niente da disporre qui",
        "No app in front": "Nessuna app in primo piano",
        "No %@ windows on this display": "Nessuna finestra di %@ su questo schermo",
        "%d left": "%d lasciate",
        "Arrange: Balanced": "Disponi: bilanciata",
        "Arrange: Columns": "Disponi: colonne",
        "Arrange: Rows": "Disponi: righe",
        "Arrange: Master + stack": "Disponi: principale + colonna",
        "Arrange: One per cell": "Disponi: una per cella",
        "Drop on a cell · on a window to swap · Esc cancels": "Rilascia su una cella · su una finestra per scambiare · Esc annulla",
        "%d windows": "%d finestre",
        "Swap with %@": "Scambia con %@",
        "Previous display": "Schermo precedente",
        "Built-in": "Integrato",
        "Next display": "Schermo successivo",
        // Outcomes
        "Placed exactly": "Sistemata esattamente",
        "%d exact": "%d esatte",
        "+%d more": "+%d altre",
        "Nothing moved": "Nulla è stato spostato",
        "%@ exact": "%@ esatta",
        "%@ kept %d×%d": "%@ ha tenuto %d×%d",
        "%@ can't be smaller than %d×%d": "%@ non scende sotto %d×%d",
        "%@ chose its size": "%@ ha scelto la sua misura",
        "%@ refused": "%@ ha rifiutato",
        "%@ unreachable": "%@ non raggiungibile",
        "%@ cancelled": "%@ annullata",
        "Undone": "Annullato",
        "Nothing to restore": "Niente da ripristinare",
        // Diagnostics
        "Diagnostics": "Diagnostica",
        "Run probe": "Esegui controllo",
        "Read-only: logs Accessibility state for Mail, Chrome and Terminal.":
            "Sola lettura: registra lo stato di Accessibilità di Mail, Chrome e Terminale.",
        "Test placement": "Prova posizionamento",
        "Moves the front window of Mail, Chrome and Terminal, then puts it back.":
            "Sposta la finestra davanti di Mail, Chrome e Terminale, poi la rimette a posto.",
        "Running…": "In corso…",
        "Hotkeys not registered: %@": "Scorciatoie non registrate: %@",
        "Done": "Fine",
        // Workspaces
        "Workspaces": "Workspace",
        "Workspace %d": "Workspace %d",
        "Saved workspaces: every display's windows, back in one click":
            "Workspace salvati: le finestre di ogni schermo, di nuovo a posto con un clic",
        "No workspaces yet": "Ancora nessun workspace",
        "Save how your windows sit now, on every display, and bring it back in one click":
            "Salva come sono ora le finestre, su ogni schermo, e rimettile così con un clic",
        "Applied when this display setup connects": "Applicato quando si collega questa configurazione di schermi",
        "Apply when this display setup connects": "Applica quando si collega questa configurazione di schermi",
        "Restoring…": "Ripristino…",
        "Restore": "Ripristina",
        "Restore %@": "Ripristina %@",
        "Rename…": "Rinomina…",
        "Rename": "Rinomina",
        "Delete": "Elimina",
        "Name": "Nome",
        "Cancel": "Annulla",
        "Save": "Salva",
        "Save current": "Salva attuale",
        "Save every window on every display as a workspace": "Salva ogni finestra di ogni schermo come workspace",
        "Saved %@": "Salvato %@",
        "Deleted %@": "Eliminato %@",
        "Missing apps open when you restore": "Le app mancanti si aprono al ripristino",
        "Saved arrangements": "Disposizioni salvate",
        "Saved": "Salvati",
        "a saved workspace": "un workspace salvato",
        "Click to restore · hover to preview · right-click for more":
            "Clic per ripristinare · passa sopra per l'anteprima · clic destro per altro",
        "None saved yet: use Workspaces on the Windows tab, or “Save workspace” in the command bar.":
            "Nessuno salvato: usa Workspace nella scheda Finestre o “Salva workspace” nella barra comandi.",
        "Restoring opens apps that are not running; minimised and hidden windows are left alone. Undo puts everything back.":
            "Il ripristino apre le app non avviate; le finestre ridotte e nascoste restano come sono. Annulla rimette tutto com'era.",
        "1 app": "1 app",
        "%d apps": "%d app",
        "%d displays": "%d schermi",
        "places running apps only": "sistema solo le app avviate",
        "Placed %d": "Sistemate %d",
        "launched %d": "aperte %d app",
        "%d not found": "%d non trovate",
        "%d left alone": "%d lasciate stare",
        "%d refused": "%d rifiutate",
        "Opening %@…": "Apertura di %@…",
        "No windows to save": "Nessuna finestra da salvare",
        "Saved %@ · %d windows": "Salvato %@ · %d finestre",
        "%@ undoes": "%@ annulla",
        "Display setup: %@": "Schermi: %@",
        // Command bar
        "Auto-arrange windows": "Disponi le finestre automaticamente",
        "The display under the pointer": "Lo schermo sotto il puntatore",
        "Undo the last window change": "Annulla l'ultima modifica alle finestre",
        "Save workspace": "Salva workspace",
        "Save workspace “%@”": "Salva workspace “%@”",
        "Every window on every display": "Ogni finestra di ogni schermo",
        "Halves": "Metà",
        "The two front windows side by side": "Le due finestre davanti, affiancate",
        "Thirds": "Terzi",
        "The three front windows in columns": "Le tre finestre davanti, in colonne",
        "2×2 grid": "Griglia 2×2",
        "The four front windows in a grid": "Le quattro finestre davanti, in griglia",
        "The front window": "La finestra davanti",
        "Maximize": "Massimizza",
        "Center": "Centra",
        "The front window, at its size": "La finestra davanti, alla sua misura",
        "Nothing to undo": "Niente da annullare",
    ]
}
