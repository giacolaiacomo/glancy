import AppKit
import Observation

/// The command bar's state: the query, the rows it produces, the selection, and running a row.
/// Everything is built when the bar opens and dropped when it closes.
@MainActor @Observable
public final class CommandModel {
    public var query = "" {
        didSet { if query != oldValue { recompute(queryChanged: true) } }
    }
    public private(set) var rows: [PaletteItem] = []
    /// Headers on the empty query: row index → "Suggested" / "Recent".
    public private(set) var sections: [Int: String] = [:]
    public var selection = 0
    public private(set) var visible = false

    // Wiring
    @ObservationIgnored public let settings: CommandSettings
    @ObservationIgnored public let history: PaletteHistory
    @ObservationIgnored public let apps: AppIndex
    @ObservationIgnored public let rates: CurrencyRates
    /// Every module (the bar's own included; it skips itself). Set in `Modules.make()`.
    @ObservationIgnored public var sources: () -> [any GlancyModule] = { [] }
    /// Whether a module is turned on (from the surface's settings).
    @ObservationIgnored public var isEnabled: (ModuleID) -> Bool = { _ in true }
    /// Closes the panel (after a row that closes it).
    @ObservationIgnored var close: () -> Void = {}
    /// Opens the panel on a tab.
    @ObservationIgnored var openTab: (ModuleID?) -> Void = { _ in }
    /// The formats in use decide "1,5" vs "1.5" (Italian, or a comma region).
    @ObservationIgnored var decimalComma: () -> Bool = { L10n.locale.decimalSeparator == "," }

    @ObservationIgnored private var pool: [PaletteCandidate] = []
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var escapeOwned = false
    /// Duration of the last recompute (seconds), for the < 5 ms budget.
    @ObservationIgnored public private(set) var lastCompute: TimeInterval = 0

    static let focusOwner = "palette.commandBar"
    static let maxRows = 40

    public init(settings: CommandSettings, history: PaletteHistory, apps: AppIndex, rates: CurrencyRates) {
        self.settings = settings
        self.history = history
        self.apps = apps
        self.rates = rates
        apps.onUpdate = { [weak self] in self?.sourcesChanged() }
        rates.onUpdate = { [weak self] in self?.sourcesChanged() }
    }

    // MARK: Open / close

    /// The bar appeared or went away. Index, history and the key monitor live only while shown.
    public func setVisible(_ on: Bool, keyboard: Bool = true) {
        guard on != visible else { return }
        visible = on
        if on {
            history.loadIfNeeded()
            if settings.apps { apps.refreshIfNeeded() }
            rebuildPool()
            recompute(queryChanged: true)
            if keyboard {
                SurfaceKeyFocus.request(true, owner: Self.focusOwner)
                installKeys()
            }
        } else {
            removeKeys()
            SurfaceKeyFocus.request(false, owner: Self.focusOwner)
            pool = []
            rows = []
            sections = [:]
            selection = 0
            if !query.isEmpty { query = "" }
            PaletteIcons.clear()
        }
    }

    /// Something arrived while open (the app list, exchange rates): refresh the rows in place.
    func sourcesChanged() {
        guard visible else { return }
        rebuildPool()
        recompute(queryChanged: false)
    }

    // MARK: Pool (fixed rows, matched by title)

    func rebuildPool() {
        var items = BuiltinCommands.items(model: self)
        for m in enabledSources() {
            items += m.commands().map(PaletteItem.init)
        }
        if settings.apps {
            items += apps.apps.map(Self.appItem)
        }
        pool = items.map(PaletteCandidate.init)
    }

    func enabledSources() -> [any GlancyModule] {
        sources().filter { $0.id != .command && isEnabled($0.id) }
    }

    static func appItem(_ a: AppEntry) -> PaletteItem {
        PaletteItem(id: "app." + a.path, title: a.displayName, subtitle: nil, icon: .app(a.path), tag: CommandText.t("Application"),
                    kind: .app, keywords: a.name == a.displayName ? [] : [a.name], rank: 10, primary: CommandText.t("Open"),
                    secondary: PaletteAction(title: CommandText.t("Show in Finder")) { PaletteActions.reveal(a.path) }) {
            PaletteActions.launch(a)
        }
    }

    // MARK: Rows

    func recompute(queryChanged: Bool) {
        let start = DispatchTime.now().uptimeNanoseconds
        let selected = rows.indices.contains(selection) ? rows[selection].id : nil
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            (rows, sections) = emptyRows()
        } else {
            rows = search(q)
            sections = [:]
        }
        if queryChanged {
            selection = 0
        } else {
            selection = selected.flatMap { id in rows.firstIndex { $0.id == id } } ?? min(selection, max(0, rows.count - 1))
        }
        lastCompute = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    }

    /// Suggestions (modules' timely commands: a meeting to join, a running timer) then recents.
    func emptyRows() -> ([PaletteItem], [Int: String]) {
        var suggested: [PaletteItem] = []
        for m in enabledSources() {
            suggested += m.results(for: "").map(PaletteItem.init)
        }
        suggested += pool.map(\.item).filter { $0.rank >= 50 && $0.kind == .command }
        suggested.sort { $0.rank > $1.rank }
        var seen = Set<String>()
        suggested = Array(suggested.filter { seen.insert($0.id).inserted }.prefix(3))
        let byID = Dictionary(pool.map { ($0.item.id, $0.item) }, uniquingKeysWith: { a, _ in a })
        let recent = history.store.recents(12).compactMap { byID[$0] }.filter { !seen.contains($0.id) }.prefix(8)
        var sections: [Int: String] = [:]
        if !suggested.isEmpty { sections[0] = CommandText.t("Suggested") }
        if !recent.isEmpty { sections[suggested.count] = CommandText.t("Recent") }
        return (suggested + recent, sections)
    }

    func search(_ q: String) -> [PaletteItem] {
        let now = Date.now
        let store = history.store
        let mq = PaletteMatcher.Query(q)
        let learned = store.queryBoosts(String(decoding: mq.text, as: UTF16.self))
        // Rows computed for this query (answers, modules' results), then the fixed pool by index:
        // nothing is copied until the top rows are known.
        var extra: [PaletteItem] = []
        var scored: [(ref: Int, score: Int)] = []     // ref ≥ 0: pool index; < 0: extra[-ref - 1]
        func addExtra(_ item: PaletteItem, _ score: Int) {
            extra.append(item)
            scored.append((-extra.count, score))
        }

        // Answers first: the query is a calculation, a conversion, a URL.
        for (n, a) in answers(q).enumerated() { addExtra(a, 3000 - n) }

        // Modules' own results for this query.
        for m in enabledSources() {
            for c in m.results(for: q) {
                addExtra(PaletteItem(c), 550 + c.rank + store.boost(c.id, now: now) + (learned[c.id] ?? 0))
            }
        }

        // Fixed rows by fuzzy match, learning from use.
        if !mq.isEmpty {
            for (i, c) in pool.enumerated() {
                guard let s = PaletteMatcher.best(mq, title: c.title, keywords: c.keywords) else { continue }
                let id = c.item.id
                scored.append((i, s + c.item.rank + store.boost(id, now: now) + (learned[id] ?? 0)))
            }
        }

        func item(_ ref: Int) -> PaletteItem { ref >= 0 ? pool[ref].item : extra[-ref - 1] }
        // One row per id (a module may offer the same command from commands() and results(for:)):
        // the best score, shown as the entry with the higher rank.
        var byID: [String: (ref: Int, score: Int, rank: Int)] = [:]
        for s in scored {
            let it = item(s.ref)
            if let b = byID[it.id] {
                let ref = it.rank > b.rank ? s.ref : b.ref
                byID[it.id] = (ref, max(b.score, s.score), max(b.rank, it.rank))
            } else {
                byID[it.id] = (s.ref, s.score, it.rank)
            }
        }
        var unique = Array(byID.values)
        unique.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            let ta = item(a.ref).title, tb = item(b.ref).title
            return ta.count != tb.count ? ta.count < tb.count : ta < tb
        }
        var out = unique.prefix(Self.maxRows).map { item($0.ref) }
        if settings.webSearch, let url = PaletteURL.webSearch(q) {
            out.append(PaletteItem(id: "web.search", title: L10n.tr(CommandText.t("Search Google for “%@”"), q), icon: .symbol("magnifyingglass"),
                                   tag: CommandText.t("Web"), kind: .fallback, learns: false, primary: CommandText.t("Search")) {
                PaletteActions.open(url)
            })
        }
        return out
    }

    /// Calculator, units, currency and typed URLs.
    func answers(_ q: String) -> [PaletteItem] {
        var out: [PaletteItem] = []
        let comma = decimalComma()
        let locale = L10n.locale
        if settings.calculator, let item = PaletteAnswers.calculation(q, decimalComma: comma, locale: locale) { out.append(item) }
        if settings.units, let c = Units.parse(q, decimalComma: comma) { out.append(PaletteAnswers.conversion(c, locale: locale)) }
        if settings.currency, let c = CurrencyParser.parse(q, decimalComma: comma) {
            rates.ensureFresh()
            out.append(PaletteAnswers.currency(c, rates: rates, locale: locale))
        }
        if let url = PaletteURL.detect(q) {
            out.append(PaletteItem(id: "url.open", title: L10n.tr(CommandText.t("Open %@"), url.host ?? q), subtitle: url.absoluteString,
                                   icon: .symbol("safari"), tag: CommandText.t("Web"), kind: .fallback, learns: false,
                                   primary: CommandText.t("Open"),
                                   secondary: PaletteAction(title: CommandText.t("Copy link")) { PaletteActions.copy(url.absoluteString) }) {
                PaletteActions.open(url)
            })
        }
        return out
    }

    // MARK: Running

    public var selectedItem: PaletteItem? { rows.indices.contains(selection) ? rows[selection] : nil }

    /// Runs a row (⏎, a click, ⌘1…9) or its secondary action (⌘⏎).
    public func run(_ index: Int, secondary: Bool = false) {
        guard rows.indices.contains(index) else { return }
        let item = rows[index]
        let action: (@MainActor () -> Void)?
        if secondary { action = item.secondary?.run } else { action = item.run }
        guard let action else { return }
        if item.learns { history.record(item.id, query: query) }
        // Close first: the panel gives the keyboard back before an app activates or a tab opens.
        if secondary || item.closesPanel { close() }
        action()
    }

    // MARK: Keyboard

    public enum Key: Equatable, Sendable {
        case up, down, enter, secondary, pick(Int)
    }

    /// ↑↓ (and ⌃P/⌃N), ⏎, ⌘⏎, ⌘1…9. Everything else goes to the search field.
    public nonisolated static func key(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) -> Key? {
        let mods = flags.intersection([.command, .control, .option, .shift])
        switch keyCode {
        case 125 where mods.isEmpty: return .down
        case 126 where mods.isEmpty: return .up
        case 36, 76:
            if mods == .command { return .secondary }
            return mods.isEmpty ? .enter : nil
        default: break
        }
        let c = characters?.lowercased()
        if mods == .control, c == "n" { return .down }
        if mods == .control, c == "p" { return .up }
        if mods == .command, let c, c.count == 1, let n = Int(c), (1...9).contains(n) { return .pick(n - 1) }
        return nil
    }

    /// True when used.
    @discardableResult
    public func handle(_ key: Key) -> Bool {
        switch key {
        case .down:
            guard !rows.isEmpty else { return true }
            selection = min(selection + 1, rows.count - 1)
        case .up:
            selection = max(selection - 1, 0)
        case .enter:
            run(selection)
        case .secondary:
            run(selection, secondary: true)
        case .pick(let n):
            guard rows.indices.contains(n) else { return true }
            selection = n
            run(n)
        }
        return true
    }

    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let key = Self.key(keyCode: event.keyCode, flags: event.modifierFlags, characters: event.charactersIgnoringModifiers)
            let used = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.visible else { return false }
                if let key { return self.handle(key) }
                // Typing with the field unfocused (a row was clicked): it goes to the query.
                if !(event.window?.firstResponder is NSText), event.modifierFlags.intersection([.command, .control]).isEmpty,
                   let chars = event.characters, !chars.isEmpty, chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                    self.query += chars
                    return true
                }
                return false
            }
            return used ? nil : event
        }
        // Esc clears a typed query first; on an empty one it closes the panel as usual.
        if SurfaceKeyFocus.escapeInterceptor == nil {
            escapeOwned = true
            SurfaceKeyFocus.escapeInterceptor = { [weak self] in
                guard let self, self.visible, !self.query.isEmpty else { return false }
                self.query = ""
                return true
            }
        }
    }

    private func removeKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if escapeOwned {
            escapeOwned = false
            SurfaceKeyFocus.escapeInterceptor = nil
        }
    }
}
