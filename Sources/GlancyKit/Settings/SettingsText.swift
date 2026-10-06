// Italian for the settings page, the permission checklist and the shortcut recorder (the English
// literal is the key). Merged into `L10n` with the surface's own table.
// Terms used across Glancy: Agenti, Calendario, Musica, Timer, Ripiano, Appunti, Finestre,
// Batteria, HUD, Notifiche; "notch" stays "notch".

let settingsItalian: [String: String] = [
    // Index
    "%d of %d on": "%d di %d attivi",
    "%d to allow": "%d da consentire",
    "All set": "Tutto a posto",
    "Off": "Spento",
    "Permissions": "Permessi",
    "Back": "Indietro",

    // General
    "Hover peeks, click opens": "Clic per aprire",
    "Resting on the notch opens it": "Si apre sostandoci sopra",
    "Screenshots and shared screens skip it": "Invisibile in screenshot e condivisioni",
    "A small notch on screens without one": "Una notch dove non c'è",

    // Modules
    "Claude Code sessions": "Sessioni di Claude Code",
    "Next meeting, Join": "Prossima riunione, Partecipa",
    "Now playing, controls": "In riproduzione, comandi",
    "Volume and brightness": "Volume e luminosità",
    "Battery and headphones": "Batteria e cuffie",
    "Timer and Pomodoro": "Timer e Pomodoro",
    "Files parked in the notch": "File parcheggiati nella notch",
    "Clipboard history": "Cronologia degli appunti",
    "Window tiling": "Finestre affiancate",
    "Notifications in the notch": "Notifiche nella notch",
    "Turn on": "Attiva",
    "Turn off": "Disattiva",

    // Permissions
    "Welcome to Glancy": "Benvenuto in Glancy",
    "Allow only what you need.": "Consenti solo ciò che ti serve.",
    "Done": "Fine",
    "Accessibility": "Accessibilità",
    "Bluetooth": "Bluetooth",
    "Automation": "Automazione",
    "Full Disk Access": "Accesso completo al disco",
    "Microphone": "Microfono",
    "Camera": "Fotocamera",
    "Speech Recognition": "Riconoscimento vocale",
    "Voice notes and the mic mute": "Note vocali e microfono silenziato",
    "The camera mirror": "Lo specchio della fotocamera",
    "Voice notes written out, on this Mac": "Trascrizione delle note vocali, su questo Mac",
    "Your next meeting, with a Join button": "La prossima riunione, con il tasto Partecipa",
    "HUD, window tiling, ⌘C history, paste after choosing": "HUD, finestre, ⌘C, incolla dopo la scelta",
    "Headphones and their battery": "Le cuffie e la loro batteria",
    "An alert when a timer ends": "Un avviso quando un timer finisce",
    "Music and Spotify controls": "Comandi per Musica e Spotify",
    "Your notifications in the notch": "Le tue notifiche nella notch",
    "Allowed": "Consentito",
    "Allow…": "Consenti…",
    "Open Settings": "Apri Impostazioni",
    "Unavailable": "Non disponibile",
    "Waiting…": "In attesa…",
    "Every module works without its permission; it just does less.":
        "Ogni modulo funziona anche senza il suo permesso, solo fa meno cose.",

    // Calendar
    "No access": "Senza accesso",
    "All calendars": "Tutti i calendari",
    "%d of %d calendars": "%d di %d calendari",
    "Glancy can't read your calendars yet": "Glancy non può ancora leggere i tuoi calendari",
    "No calendars on this Mac.": "Nessun calendario su questo Mac.",
    "Calendars show up here once access is allowed.": "I calendari compaiono qui quando consenti l'accesso.",
    "Other": "Altro",
    "New calendars join automatically while every calendar is on.":
        "Finché sono tutti attivi, i calendari nuovi si aggiungono da soli.",

    // HUD
    "All keys": "Tutti i tasti",
    "%d of %d keys": "%d di %d tasti",
    "Needs Accessibility to take over the keys": "Per gestire i tasti serve l'Accessibilità",
    "Show in the notch": "Mostra nella notch",
    "Replaces the system HUD for the keys below": "Sostituisce l'HUD di sistema per i tasti qui sotto",
    "Keys": "Tasti",
    "Volume": "Volume",
    "Brightness": "Luminosità",
    "Keyboard backlight": "Retroilluminazione",
    "Keys left out keep the system HUD. ⌥⇧ still steps by quarters.":
        "I tasti esclusi tengono l'HUD di sistema. Con ⌥⇧ si regola sempre a quarti.",

    // Power
    "All on": "Tutto attivo",
    "Battery only": "Solo batteria",
    "Headphones only": "Solo cuffie",
    "Quiet": "Silenzioso",
    "Battery in the notch": "Batteria nella notch",
    "Plugging in, unplugging, low battery, Low Power Mode":
        "Alimentatore collegato o staccato, batteria scarica, risparmio energetico",
    "Headphones peek": "Avviso cuffie",
    "AirPods and other headphones as they connect, with battery":
        "AirPods e altre cuffie appena si collegano, con la batteria",
    "Headphones need Bluetooth access": "Per le cuffie serve l'accesso al Bluetooth",
    "Plugging in, unplugging, Low Power Mode": "Alimentatore collegato o staccato, risparmio energetico",
    "Low battery peek": "Avviso batteria scarica",
    "On battery, once per discharge": "A batteria, una volta per scarica",
    "Full charge peek": "Avviso carica completa",
    "At 100 % or at the charge limit": "Al 100 % o al limite di carica",
    // HUD · microphone
    "Mute microphone": "Silenzia microfono",
    "Mute microphone shortcut": "Scorciatoia microfono",
    "Mutes or unmutes the default microphone": "Silenzia o riattiva il microfono predefinito",
    "Microphone and camera in use": "Microfono e fotocamera in uso",
    "A red dot in the notch while an app records": "Un punto rosso nella notch mentre un'app registra",

    // Media
    "Checking…": "Verifica…",
    "Every app": "Tutte le app",
    "Music, Spotify": "Musica, Spotify",
    "Music and Spotify": "Musica e Spotify",
    "Source in use": "Sorgente in uso",
    "Testing the now-playing reader": "Sto provando il lettore di ciò che suona",
    "Now-playing reader: browsers, Music, Spotify, any player":
        "Lettore di ciò che suona: browser, Musica, Spotify, qualsiasi player",
    "Scripts: the reader isn't working on this Mac": "Script: il lettore non funziona su questo Mac",
    "Controls need Automation for Music or Spotify": "Per i comandi serve l'Automazione di Musica o Spotify",
    "Chosen at launch: the reader is tried first, the scripts take over if it fails.":
        "Si sceglie all'avvio: prima il lettore, gli script subentrano se non funziona.",

    // Timer
    "%d / %d / %d min": "%d / %d / %d min",
    "Focus": "Concentrazione",
    "Short break": "Pausa breve",
    "Long break": "Pausa lunga",
    "After the fourth focus round": "Dopo il quarto round di concentrazione",
    "A round already running keeps its length.": "Un round già avviato mantiene la sua durata.",
    "Reset": "Ripristina",

    // Shelf
    "Empty": "Vuoto",
    "%d items": "%d elementi",
    "On the shelf": "Sul ripiano",
    "Nothing parked": "Niente in sosta",
    "Remove %d items?": "Togliere %d elementi?",
    "Your files stay where they are; copies Glancy made (text, links, mail attachments) are deleted.":
        "I tuoi file restano dove sono; le copie fatte da Glancy (testi, link, allegati) vengono eliminate.",
    "Holds up to %d items, kept across restarts.": "Tiene fino a %d elementi, anche dopo un riavvio.",

    // Clipboard
    "Clipboard": "Appunti",
    "Paused": "In pausa",
    "Pause history": "Sospendi cronologia",
    "Nothing is being recorded": "Non si registra nulla",
    "Paste after choosing": "Incolla dopo la scelta",
    "Presses ⌘V in the app underneath": "Preme ⌘V nell'app sottostante",
    "Shortcut": "Scorciatoia",
    "Opens the list with the keyboard": "Apre l'elenco",
    "History": "Cronologia",
    "%d items, up to 60": "%d elementi, fino a 60",
    "Clear": "Cancella",
    "Cancel": "Annulla",
    "Pinned too?": "Anche i fissati?",
    "Pasting needs Accessibility": "Per incollare serve l'Accessibilità",
    "Excluded apps": "App escluse",
    "None. Right-click an item in the list to never record from its app. Password managers are always skipped.":
        "Nessuna. Clic destro su un elemento dell'elenco per non registrare più dalla sua app. I gestori di password sono sempre esclusi.",
    "Record from this app again": "Registra di nuovo da questa app",

    // Windows
    "Shortcuts off": "Scorciatoie spente",
    "%d shortcuts": "%d scorciatoie",
    "Moving windows needs Accessibility": "Per spostare le finestre serve l'Accessibilità",
    "Shortcuts": "Scorciatoie",
    "Halves cycle ½ → ⅔ → ⅓ on repeat": "Ripetendo, le metà passano a ½ → ⅔ → ⅓",
    "Open the map": "Apri la mappa",
    "Left half": "Metà sinistra",
    "Right half": "Metà destra",
    "Maximize": "Massimizza",
    "Restore": "Ripristina",
    "Fill empty space": "Riempi il vuoto",
    "Undo": "Annulla",

    // Shortcut recorder
    "Click, then press the new shortcut. Esc cancels, ⌫ clears.":
        "Fai clic, poi premi la nuova scorciatoia. Esc annulla, ⌫ la toglie.",
    "Press keys…": "Premi i tasti…",
    "None": "Nessuna",
    "Add ⌃, ⌥ or ⌘": "Aggiungi ⌃, ⌥ o ⌘",
    "Esc cancels · ⌫ clears": "Esc annulla · ⌫ toglie",
    "Also %@": "Usata anche da %@",
    "Used by macOS": "Usata da macOS",
    "Taken by another app": "Già presa da un'altra app",

    // Agents
    "Hook log found": "Log trovato",
    "No hook log": "Nessun log",
    "Hook log": "Log dell'hook",
    "Read-only; Glancy never writes to it": "Sola lettura: Glancy non ci scrive mai",
    "Not found: install the cc-dashboard hook": "Non trovato: installa l'hook cc-dashboard",
    "Show in Finder": "Mostra nel Finder",
    "A session goes idle after 30 min without events; sessions silent for 12 h are dropped.":
        "Una sessione diventa inattiva dopo 30 min senza eventi; dopo 12 ore di silenzio sparisce.",
]
