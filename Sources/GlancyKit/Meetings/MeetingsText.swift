import Foundation

/// The Meetings module's words: helpers that build a line, and the Italian for every string (the
/// English literal is the key), merged into `L10n` when the module is built.
enum MeetingsText {
    /// The wing: "7 min", "<1 min".
    @MainActor static func minutes(_ m: Int) -> String { m < 1 ? L10n.tr("<1 min") : L10n.tr("%d min", m) }

    @MainActor static func tracks(_ t: [MeetingSpeaker]) -> String {
        switch (t.contains(.you), t.contains(.others)) {
        case (true, true): L10n.tr("You and the others, on two tracks")
        case (true, false): L10n.tr("Only you: system audio is off")
        case (false, true): L10n.tr("Only the others: the microphone is off")
        case (false, false): ""
        }
    }

    @MainActor static func modeHint(_ m: MeetingsMode) -> String {
        switch m {
        case .ask: L10n.tr("A card asks when a call takes the microphone.")
        case .always: L10n.tr("Calendar meetings record by themselves; other calls ask.")
        case .off: L10n.tr("Glancy records only when you press Record.")
        }
    }

    /// "42 min", "1 h 05 min" (the same in English and Italian).
    static func length(_ t: TimeInterval) -> String {
        let m = Int((t / 60).rounded())
        if m < 1 { return "<1 min" }
        if m < 60 { return "\(m) min" }
        return String(format: "%d h %02d min", m / 60, m % 60)
    }

    /// A row's second line: "Tue 7 Oct, 10:00 · 42 min".
    @MainActor static func when(_ r: MeetingRecord) -> String {
        let f = DateFormatter()
        f.locale = L10n.locale
        f.setLocalizedDateFormatFromTemplate("EEEdMMMHHmm")
        return "\(f.string(from: r.start)) · \(length(r.duration))"
    }

    @MainActor static func state(_ r: MeetingRecord) -> String {
        switch r.transcript {
        case .done: L10n.tr("%d lines", r.lines ?? 0)
        case .empty: L10n.tr("No speech")
        case .unavailable: L10n.tr("No transcript in this language")
        case .pending: L10n.tr("Transcribe")
        case .failed: L10n.tr("Transcript failed · Retry")
        case .needsPermission: L10n.tr("Allow Speech Recognition")
        }
    }

    // The transcript is written in its own language, whatever Glancy's.

    static func speakers(italian: Bool) -> (you: String, others: String) { italian ? ("Tu", "Altri") : ("You", "Others") }

    static func nobodySpoke(italian: Bool) -> String { italian ? "Nessuno ha parlato." : "Nobody spoke." }

    /// "Tuesday 7 October 2026, 10:00 · 42 min · Zoom".
    static func about(_ r: MeetingRecord, italian: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: italian ? "it_IT" : "en_GB")
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMMyyyyHHmm")
        var parts = [f.string(from: r.start), length(r.duration)]
        if let app = r.app { parts.append(app) }
        return parts.joined(separator: " · ")
    }

    static let italian: [String: String] = [
        "Meetings": "Riunioni",
        "Record meetings, with your consent": "Registra le riunioni, con il tuo consenso",
        // Drop-down, wing
        "Record this meeting?": "Registrare questa riunione?",
        "Record": "Registra",
        "Not now": "Non ora",
        "Starting…": "Avvio…",
        "Recording": "Registrazione",
        "Stop": "Ferma",
        "Glancy can't hear this meeting": "Glancy non sente questa riunione",
        "Open": "Apri",
        "Not recording": "Nessuna registrazione",
        "Recording saved": "Registrazione salvata",
        "<1 min": "<1 min",
        "%d min": "%d min",
        // Tab
        "Recordings": "Registrazioni",
        "Show in Finder": "Mostra nel Finder",
        "No recordings yet": "Ancora nessuna registrazione",
        "Audio and transcripts stay on this Mac.": "Audio e trascrizioni restano su questo Mac.",
        "Discard": "Scarta",
        "Discard?": "Scartare?",
        "Meeting on": "Riunione in corso",
        "Let the others know you're recording.": "Avvisa gli altri che stai registrando.",
        "Opening the microphone and system audio": "Apertura del microfono e dell'audio di sistema",
        "Can't record": "Impossibile registrare",
        "The microphone and system audio would not open.": "Il microfono e l'audio di sistema non si sono aperti.",
        "Allow the microphone or system audio in System Settings.":
            "Consenti il microfono o l'audio di sistema in Impostazioni di Sistema.",
        "Open Settings": "Apri Impostazioni",
        "OK": "OK",
        "Not listening": "Non in ascolto",
        "Listening for calls": "In ascolto delle chiamate",
        "No meeting on": "Nessuna riunione in corso",
        "Record now": "Registra ora",
        "Play": "Riproduci",
        "Pause": "Pausa",
        "Delete": "Elimina",
        "Delete?": "Eliminare?",
        "Copy transcript": "Copia la trascrizione",
        "Transcript %d%%": "Trascrizione %d%%",
        "%d lines": "%d righe",
        "No speech": "Nessun parlato",
        "No transcript in this language": "Nessuna trascrizione in questa lingua",
        "Transcribe": "Trascrivi",
        "Transcript failed · Retry": "Trascrizione non riuscita · Riprova",
        "Allow Speech Recognition": "Consenti il riconoscimento vocale",
        "You and the others, on two tracks": "Tu e gli altri, su due tracce",
        "Only you: system audio is off": "Solo tu: l'audio di sistema è spento",
        "Only the others: the microphone is off": "Solo gli altri: il microfono è spento",
        "A card asks when a call takes the microphone.": "Una scheda chiede quando una chiamata usa il microfono.",
        "Calendar meetings record by themselves; other calls ask.":
            "Le riunioni del calendario si registrano da sole; le altre chiamate chiedono.",
        "Glancy records only when you press Record.": "Glancy registra solo quando premi Registra.",
        // Home
        "Writing the transcript": "Trascrizione in corso",
        "Last recording": "Ultima registrazione",
        "Meeting recording": "Registrazione riunione",
        "While a meeting is offered, recorded or transcribed": "Mentre una riunione è proposta, registrata o trascritta",
        "At rest: the last recording, with Play": "A riposo: l'ultima registrazione, con Riproduci",
        // Module, commands
        "%@ meeting": "Riunione %@",
        "Meeting": "Riunione",
        "Stop recording the meeting": "Ferma la registrazione della riunione",
        "Record the meeting": "Registra la riunione",
        "Meeting recordings": "Registrazioni delle riunioni",
        "Asks when a call starts": "Chiede quando inizia una chiamata",
        "Records calendar meetings": "Registra le riunioni del calendario",
        "Only when you press Record": "Solo quando premi Registra",
        // Settings
        "When a call starts": "Quando inizia una chiamata",
        "Ask": "Chiedi",
        "Always": "Sempre",
        "Off": "Mai",
        "Always: calendar meetings start recording by themselves (a drop-down says so); other calls ask.":
            "Sempre: le riunioni del calendario si registrano da sole (un avviso lo dice); le altre chiamate chiedono.",
        "Off: no listening at all; Record in the tab still works.":
            "Mai: nessun ascolto; Registra nella scheda funziona comunque.",
        "A card asks \"Record this meeting?\" when Zoom, Teams, Webex, FaceTime or Slack takes the microphone, or a browser does during a calendar meeting with a link.":
            "Una scheda chiede \"Registrare questa riunione?\" quando Zoom, Teams, Webex, FaceTime o Slack usano il microfono, o un browser durante una riunione del calendario con un link.",
        "Transcript language": "Lingua della trascrizione",
        "App language": "Lingua dell'app",
        "Save transcripts to Notes": "Salva le trascrizioni in Note",
        "A note for each meeting": "Una nota per ogni riunione",
        "Turn the Notes module on to use this": "Attiva il modulo Note per usarlo",
        "Permissions": "Permessi",
        "Microphone": "Microfono",
        "Your voice": "La tua voce",
        "System audio": "Audio di sistema",
        "The others' voices, as the Mac plays them": "Le voci degli altri, come le riproduce il Mac",
        "Speech Recognition": "Riconoscimento vocale",
        "Turns the audio into text, on this Mac": "Trasforma l'audio in testo, su questo Mac",
        "Not needed on this Mac": "Non serve su questo Mac",
        "Allowed": "Consentito",
        "Allow…": "Consenti…",
        "Off in System Settings": "Disattivato in Impostazioni di Sistema",
        "Folder": "Cartella",
        "%d recordings": "%d registrazioni",
        "Stops by itself 30 s after the call lets go of the microphone, or 10 min after a calendar meeting's end once it's quiet.":
            "Si ferma da sola 30 s dopo che la chiamata lascia il microfono, o 10 min dopo la fine di una riunione del calendario quando è silenzio.",
        "Audio and transcripts stay on this Mac: speech is turned into text here, nothing is sent anywhere. Laws on recording differ: always tell the others.":
            "Audio e trascrizioni restano su questo Mac: il parlato diventa testo qui, nulla viene inviato. Le leggi sulla registrazione cambiano da paese a paese: avvisa sempre gli altri.",
        // Permissions page
        "Meetings: the other people's voices": "Riunioni: le voci delle altre persone",
        "Voice notes, meetings and the mic mute": "Note vocali, riunioni e silenziamento del microfono",
    ]
}

/// Made-up recordings for renders and the lab (no audio behind them).
enum MeetingsSample {
    static func records(_ now: Date) -> [MeetingRecord] {
        let cal = Calendar.current
        func at(_ daysAgo: Int, _ h: Int, _ m: Int) -> Date {
            let day = cal.date(byAdding: .day, value: -daysAgo, to: now) ?? now
            return cal.date(bySettingHour: h, minute: m, second: 0, of: day) ?? day
        }
        let it = L10n.isItalian
        return [
            MeetingRecord(id: "sample-1", title: it ? "Revisione del design" : "Design review", start: at(0, 9, 30), duration: 42 * 60,
                          app: "Zoom", language: "en-US", tracks: [.you, .others], transcript: .done, lines: 118),
            MeetingRecord(id: "sample-2", title: it ? "Riunione settimanale" : "Weekly sync", start: at(1, 15, 0), duration: 28 * 60,
                          app: "Google Meet", language: "en-US", tracks: [.you, .others], transcript: .done, lines: 64),
            MeetingRecord(id: "sample-3", title: it ? "Chiamata con Marta" : "Call with Marta", start: at(2, 11, 15), duration: 12 * 60,
                          app: "FaceTime", language: "it-IT", tracks: [.you, .others], transcript: .pending),
            MeetingRecord(id: "sample-4", title: it ? "Intervista candidato" : "Candidate interview", start: at(5, 16, 30),
                          duration: 65 * 60, app: "Microsoft Teams", language: "en-US", tracks: [.you, .others], transcript: .done, lines: 203),
        ]
    }

    static func detection(_ now: Date) -> MeetingDetection {
        let e = CalendarEvent(id: "sample-meeting", title: L10n.isItalian ? "Revisione del progetto" : "Project check-in",
                              start: now.addingTimeInterval(-3 * 60), end: now.addingTimeInterval(27 * 60),
                              link: MeetingLink.extract(url: URL(string: "https://zoom.us/j/5550100123"), location: nil, notes: nil))
        return MeetingDetection(key: "event:sample-meeting", event: e, app: "Zoom", holderBundles: ["us.zoom."])
    }

    @MainActor static func fill(_ model: MeetingsModel, now: Date) {
        model.records = records(now)
        model.loaded = true
    }
}
