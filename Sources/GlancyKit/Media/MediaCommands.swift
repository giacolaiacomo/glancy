import Foundation

/// Query folding shared by the Media and Notes command-bar entries: lower case, no accents,
/// single spaces ("Pàusa " → "pausa").
enum NLQuery {
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// 100 = the query is one of the terms; 60 = it starts one (3+ letters); nil = no match.
    static func score(_ query: String, terms: [String]) -> Int? {
        let q = fold(query)
        guard !q.isEmpty else { return nil }
        if terms.contains(where: { fold($0) == q }) { return 100 }
        if q.count >= 3, terms.contains(where: { fold($0).hasPrefix(q) }) { return 60 }
        return nil
    }
}

/// Media in the command bar: play/pause, next, previous, show lyrics. EN + IT.
extension MediaModule {
    enum Verb: CaseIterable {
        case toggle, next, previous, lyrics

        var terms: [String] {
            switch self {
            case .toggle: ["play", "pause", "play/pause", "resume", "stop", "riproduci", "pausa", "riprendi", "metti in pausa", "ferma"]
            case .next: ["next", "next track", "skip", "avanti", "successivo", "successiva", "prossima", "salta", "brano successivo"]
            case .previous: ["previous", "previous track", "prev", "back", "indietro", "precedente", "brano precedente"]
            case .lyrics: ["lyrics", "show lyrics", "words", "testo", "testi", "mostra testo", "parole"]
            }
        }
    }

    public func commands() -> [GlancyCommand] {
        guard model.info != nil else { return [] }
        return Verb.allCases.compactMap { command($0, rank: 0) }
    }

    public func results(for query: String) -> [GlancyCommand] {
        guard model.info != nil else { return [] }
        return Verb.allCases.compactMap { verb in
            NLQuery.score(query, terms: verb.terms).flatMap { command(verb, rank: $0 == 100 ? 90 : 60) }
        }
    }

    private func command(_ verb: Verb, rank: Int) -> GlancyCommand? {
        guard let info = model.info else { return nil }
        let track = [info.title, info.artist].compactMap { $0 }.joined(separator: " · ")
        switch verb {
        case .toggle:
            let playing = info.playing
            return GlancyCommand(id: "media.toggle", module: .media, title: L10n.tr(playing ? "Pause" : "Play"), subtitle: track,
                                 symbol: playing ? "pause.fill" : "play.fill", keywords: verb.terms, rank: rank,
                                 closesPanel: true) { [weak self] in self?.toggle() }
        case .next:
            return GlancyCommand(id: "media.next", module: .media, title: L10n.tr("Next track"), subtitle: track,
                                 symbol: "forward.fill", keywords: verb.terms, rank: rank,
                                 closesPanel: true) { [weak self] in self?.skip(.next) }
        case .previous:
            return GlancyCommand(id: "media.previous", module: .media, title: L10n.tr("Previous track"), subtitle: track,
                                 symbol: "backward.fill", keywords: verb.terms, rank: rank,
                                 closesPanel: true) { [weak self] in self?.skip(.previous) }
        case .lyrics:
            guard lyrics.settings.tabEnabled else { return nil }
            return GlancyCommand(id: "media.lyrics", module: .media, title: L10n.tr("Show lyrics"), subtitle: track,
                                 symbol: "quote.bubble", keywords: verb.terms, rank: rank, closesPanel: false) { [weak self] in
                self?.lyrics.settings.shown = true
                self?.openTab()
            }
        }
    }
}
