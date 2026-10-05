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

    static let italian: [String: String] = [
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
        "Hover a cell, click to place · ⌘-click windows to pick several":
            "Passa su una cella, clic per sistemare · ⌘-clic per sceglierne più d'una",
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
        "Click: only this window · ⌘-click: add to the selection · ⇧-click: a range":
            "Clic: solo questa finestra · ⌘-clic: aggiungi alla selezione · ⇧-clic: un intervallo",
        "Arrange the selected windows in this grid": "Disponi le finestre selezionate in questa griglia",
        "in pick order": "nell'ordine scelto",
        "%d selected · pick a grid or an arrangement": "%d selezionate · scegli una griglia o una disposizione",
        "⌘-click another window to pick it too": "⌘-clic su un'altra finestra per aggiungerla",
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
        "Arrange the display under the pointer at once (undo: %@) · add ⇧ for the front app only":
            "Dispone subito lo schermo sotto il puntatore (annulla: %@) · con ⇧ solo l'app in primo piano",
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
    ]
}
