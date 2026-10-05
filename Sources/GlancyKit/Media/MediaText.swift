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
