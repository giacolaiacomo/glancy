import Foundation

/// Italian for the Media module's strings (the English literal is the key), merged into `L10n`
/// at start.
enum MediaText {
    static let italian: [String: String] = [
        "Nothing playing": "Niente in riproduzione",
        "Play something in Music, Spotify or a browser and it shows up here.":
            "Avvia qualcosa in Musica, Spotify o nel browser e comparirà qui.",
        "Only Music and Spotify for now: the now-playing reader isn't working on this Mac.":
            "Per ora solo Musica e Spotify: il lettore di ciò che suona non funziona su questo Mac.",
        "Play": "Riproduci",
        "Pause": "Pausa",
        "Next": "Successivo",
        "Previous": "Precedente",
        "Open %@": "Apri %@",
        "Live": "In diretta",
        "Paused": "In pausa",
    ]
}

extension MediaText {
    /// Lyrics and command-bar strings.
    static let lyricsItalian: [String: String] = [
        "Lyrics": "Testi",
        "Next track": "Brano successivo",
        "Previous track": "Brano precedente",
        "Show lyrics": "Mostra il testo",
        "Hide lyrics": "Nascondi il testo",
        "Not synced": "Non sincronizzato",
        "Looking for lyrics…": "Cerco il testo…",
        "Lyrics need a connection. Trying again next time.": "Il testo richiede una connessione. Riprovo la prossima volta.",
        "Instrumental": "Strumentale",
        "No lyrics for this track": "Nessun testo per questo brano",
        "Lyrics are off": "Testi disattivati",
        "Lyrics in the Media tab": "Testi nella scheda Media",
        "Track names go to lrclib.net, once per song": "I brani vanno a lrclib.net, una volta per brano",
        "Lyrics in the wing": "Testo nell'ala",
        "The sung line beside the notch, while playing": "La riga cantata accanto al notch, mentre suona",
        "Wakes Glancy once per line while music plays (a few times a minute): a small CPU cost. Nothing runs when paused.":
            "Sveglia Glancy una volta per riga mentre la musica suona (qualche volta al minuto): un piccolo costo di CPU. In pausa non gira nulla.",
        "Title, artist, album and length of the playing track are sent to lrclib.net to find its lyrics, once per track. Nothing else leaves your Mac.":
            "Titolo, artista, album e durata del brano in riproduzione vengono inviati a lrclib.net per trovarne il testo, una volta per brano. Nient'altro lascia il tuo Mac.",
        "Lyrics cache": "Cache dei testi",
        "%d songs on this Mac": "%d brani su questo Mac",
        "Clear": "Svuota",
    ]
}
