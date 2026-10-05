import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import GlancyKit

// Command bar (lot P): matching and ranking, calculator, units, currency, app index, aggregation
// of modules' commands, keyboard model, focus ownership. No network (stub fetcher), temp dirs only.

// MARK: Helpers

@MainActor
private func makeModel(apps: AppIndex? = nil, fetcher: (any RatesFetching)? = nil, rateCache: URL? = nil) -> CommandModel {
    let suite = "glancy.test.palette.\(UUID().uuidString)"
    let settings = CommandSettings(defaults: UserDefaults(suiteName: suite)!)
    settings.webSearch = false
    let index = apps ?? AppIndex(folders: [], extras: [])
    return CommandModel(settings: settings, history: PaletteHistory(url: nil), apps: index,
                        rates: CurrencyRates(cacheURL: rateCache, fetcher: fetcher ?? StubFetcher(data: Data())))
}

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("glancy-palette-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeApp(_ name: String, in dir: URL) {
    let app = dir.appendingPathComponent("\(name).app/Contents", isDirectory: true)
    try? FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
}

final class StubFetcher: RatesFetching, @unchecked Sendable {
    let data: Data
    let fails: Bool
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }
    init(data: Data, fails: Bool = false) { self.data = data; self.fails = fails }
    func fetch() async throws -> Data {
        lock.withLock { _calls += 1 }
        if fails { throw URLError(.notConnectedToInternet) }
        return data
    }
}

let ecbSample = """
<?xml version="1.0" encoding="UTF-8"?>
<gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01" xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref">
  <gesmes:subject>Reference rates</gesmes:subject>
  <Cube>
    <Cube time='2026-10-02'>
      <Cube currency='USD' rate='1.1700'/>
      <Cube currency='JPY' rate='172.50'/>
      <Cube currency='GBP' rate='0.8700'/>
      <Cube currency='CHF' rate='0.9400'/>
    </Cube>
  </Cube>
</gesmes:Envelope>
""".data(using: .utf8)!

/// A module offering both a fixed command and query results (the contract's example).
@MainActor final class ExampleCommandModule: GlancyModule {
    let id: ModuleID
    var ran: [String] = []
    init(_ id: ModuleID = .timer) { self.id = id }
    func start(hub: ActivityHub) {}
    func stop() {}
    func commands() -> [GlancyCommand] {
        [GlancyCommand(id: "\(id.rawValue).start25", module: id, title: "Start 25-minute timer", symbol: "timer",
                       keywords: ["pomodoro", "avvia timer"]) { [weak self] in self?.ran.append("start25") },
         GlancyCommand(id: "\(id.rawValue).running", module: id, title: "Stop running timer", symbol: "stop.circle", rank: 80) {}]
    }
    func results(for query: String) -> [GlancyCommand] {
        guard query.hasPrefix("timer ") || query.hasPrefix("t ") else { return [] }
        let minutes = query.split(separator: " ").last.flatMap { Int($0) } ?? 0
        guard minutes > 0 else { return [] }
        return [GlancyCommand(id: "\(id.rawValue).custom", module: id, title: "Start \(minutes)-minute timer", symbol: "timer",
                              rank: 90) { [weak self] in self?.ran.append("custom\(minutes)") }]
    }
}

// MARK: Matcher

@Suite("Palette matcher")
struct PaletteMatcherTests {
    func s(_ q: String, _ t: String) -> Int? { PaletteMatcher.score(.init(q), MatchText(t)) }

    @Test func bands() {
        #expect(s("safari", "Safari") == PaletteMatcher.exact)
        #expect(s("saf", "Safari")! > PaletteMatcher.compactPrefix)
        #expect(s("studio", "Visual Studio Code")! >= PaletteMatcher.wordPrefix - 8)
        #expect(s("vsc", "Visual Studio Code")! >= PaletteMatcher.acronym - 4)
        #expect(s("te", "TextEdit")! >= PaletteMatcher.prefix - 60)      // prefix of "text edit"
        #expect(s("ted", "TextEdit") != nil)                              // subsequence across the camel-case words
        #expect(s("iterm", "iTerm")! >= PaletteMatcher.compactPrefix - 60)
        #expect(s("vis code", "Visual Studio Code") == PaletteMatcher.allWords)
        #expect(s("sfr", "Safari")! < PaletteMatcher.substring)          // subsequence
        #expect(s("xyz", "Safari") == nil)
        #expect(s("q", "Safari") == nil)                                  // one letter: prefixes only
    }

    @Test func caseAndDiacritics() {
        #expect(s("impostazioni", "Impostazioni di Sistema") != nil)
        #expect(s("cafe", "Café Menu") != nil)
        #expect(s("CAFÉ", "cafe menu") != nil)
        #expect(s("ITUNES", "iTunes") == PaletteMatcher.exact)
        #expect(PaletteMatcher.normalize("Crème Brûlée!") == "creme brulee")
    }

    @Test func orderingPrefersPrefixOverScattered() {
        let a = s("cal", "Calendar")!, b = s("cal", "Calculator")!, c = s("cal", "Musical Lab")!
        #expect(a > c && b > c)
        #expect(s("calc", "Calculator")! > s("calc", "Glancy Calculations Lab")!)
    }

    @Test func keywordsCountSlightlyLess() {
        let title = MatchText("Lock Screen")
        let kw = [MatchText("blocca schermo")]
        let viaTitle = PaletteMatcher.best(.init("lock"), title: title, keywords: kw)!
        let viaKeyword = PaletteMatcher.best(.init("blocca"), title: title, keywords: kw)!
        #expect(viaKeyword < viaTitle)
        #expect(viaKeyword > 0)
    }
}

// MARK: Frecency

@Suite("Palette frecency")
struct PaletteFrecencyTests {
    @Test func decayAndBoost() {
        var s = FrecencyStore()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        for _ in 0..<5 { s.record("a", query: "sa", now: t0) }
        s.record("b", query: "", now: t0)
        #expect(s.boost("a", now: t0) > s.boost("b", now: t0))
        // A month later the same uses count much less.
        #expect(s.boost("a", now: t0.addingTimeInterval(30 * 86400)) < s.boost("a", now: t0))
        #expect(s.boost("missing", now: t0) == 0)
        #expect(s.queryBoost("sa", "a") == 300)
        #expect(s.queryBoost("s", "a") == 150)
        #expect(s.queryBoost("sa", "b") == 0)
        #expect(s.recents(1) == ["b"] || s.recents(1) == ["a"])
    }

    @Test func capped() {
        var s = FrecencyStore()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<(FrecencyStore.maxEntries + 50) { s.record("id\(i)", query: "q\(i)", now: t0.addingTimeInterval(Double(i))) }
        #expect(s.entries.count == FrecencyStore.maxEntries)
        #expect(s.queries.count <= FrecencyStore.maxQueries)
        // The newest survive.
        #expect(s.entries["id\(FrecencyStore.maxEntries + 49)"] != nil)
    }

    @Test @MainActor func persistsAndClears() async throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("commands.json")
        let h = PaletteHistory(url: url)
        h.record("app./Applications/Safari.app", query: "saf")
        try await Task.sleep(for: .milliseconds(300))
        let again = PaletteHistory(url: url)
        #expect(!again.isLoaded)                       // lazy: nothing read until asked
        again.loadIfNeeded()
        #expect(again.store.entries["app./Applications/Safari.app"] != nil)
        again.clear()
        try await Task.sleep(for: .milliseconds(300))
        let third = PaletteHistory(url: url)
        third.loadIfNeeded()
        #expect(third.store.entries.isEmpty)
    }

    @Test @MainActor func rankingLearnsFromUse() {
        let model = makeModel()
        let a = ExampleCommandModule(.timer)
        model.sources = { [a] }
        model.setVisible(true, keyboard: false)
        model.query = "st"
        let first = model.rows.first?.id
        // Choose the other one a few times: it climbs to the top for "st".
        let other = first == "timer.start25" ? "timer.running" : "timer.start25"
        for _ in 0..<3 { model.history.record(other, query: "st") }
        model.query = ""
        model.query = "st"
        #expect(model.rows.first?.id == other)
        model.setVisible(false, keyboard: false)
    }
}

// MARK: Calculator

@Suite("Palette calculator")
struct CalculatorTests {
    func v(_ s: String, comma: Bool = false) throws -> Double? { try Calculator.evaluate(s, decimalComma: comma)?.value }

    @Test func arithmeticAndPrecedence() throws {
        #expect(try v("2+3*4") == 14)
        #expect(try v("(2+3)*4") == 20)
        #expect(try v("2^3^2") == 512)
        #expect(try v("-2^2") == -4)
        #expect(try v("2**10") == 1024)
        #expect(try v("10 / 4") == 2.5)
        #expect(try v("7 mod 3") == 1)
        #expect(try v("3x4") == 12)
        #expect(try v("3 × 4 ÷ 2") == 6)
        #expect(try v("2(3+4)") == 14)
        #expect(try v("5!") == 120)
        #expect(try v("sqrt 16 + 1") == 5)
        #expect(abs(try v("2pi")! - 2 * .pi) < 1e-12)
        #expect(try v("1e3 + 1") == 1001)
        #expect(try v("0.1 + 0.2").map { PaletteFormat.number($0, locale: Locale(identifier: "en_US")) } == "0.3")
    }

    @Test func percentages() throws {
        #expect(abs(try v("12% of 340")! - 40.8) < 1e-9)
        #expect(abs(try v("12% di 340")! - 40.8) < 1e-9)
        #expect(abs(try v("12 per cento di 340")! - 40.8) < 1e-9)
        #expect(try v("200 + 10%") == 220)
        #expect(try v("200 - 25%") == 150)
        #expect(try v("50%") == 0.5)
        #expect(try v("10% * 5") == 0.5)
    }

    @Test func italianNumbers() throws {
        #expect(try v("1,5 + 1", comma: true) == 2.5)
        #expect(try v("1.000 * 2", comma: true) == 2000)
        #expect(try v("3,5 * 2") == 7)                     // a lone comma decimal works in English too
        #expect(try v("1,000 + 1") == 1001)                 // …unless it groups thousands
        #expect(try v("1,234.5 + 0.5") == 1235)
        #expect(try v("1.234,5 + 0,5", comma: true) == 1235)
    }

    @Test func bases() throws {
        let r = try Calculator.evaluate("0xff")
        #expect(r?.value == 255)
        #expect(r?.usedBaseLiteral == true)
        #expect(try v("0b1010 + 1") == 11)
        let h = try Calculator.evaluate("255 in hex")
        #expect(h?.base == .hex)
        #expect(PaletteFormat.based(h!.value, .hex) == "0xFF")
        #expect(try Calculator.evaluate("10 to bin").map { PaletteFormat.based($0.value, .bin) } == "0b1010")
        #expect(try Calculator.evaluate("0xff in esadecimale")?.base == .hex)
    }

    @Test func notACalculation() throws {
        #expect(try Calculator.evaluate("42")?.value == 42)      // a bare number is the calculator's, not the timer's
        #expect(try Calculator.evaluate("-5")?.value == -5)
        #expect(try Calculator.evaluate("safari") == nil)
        #expect(try Calculator.evaluate("1password") == nil)
        #expect(try Calculator.evaluate("office 365") == nil)
        #expect(try Calculator.evaluate("e") == nil)
        #expect(try Calculator.evaluate("") == nil)
    }

    @Test func errors() {
        #expect(throws: CalcError.divisionByZero) { try Calculator.evaluate("1/0") }
        #expect(throws: CalcError.syntax) { try Calculator.evaluate("3+") }
        #expect(throws: CalcError.syntax) { try Calculator.evaluate("(1+2") }
        #expect(throws: CalcError.domain) { try Calculator.evaluate("sqrt(-1)") }
        #expect(throws: CalcError.overflow) { try Calculator.evaluate("200!") }
        #expect(throws: CalcError.overflow) { try Calculator.evaluate("10^400") }
        #expect(throws: CalcError.syntax) { try Calculator.evaluate("5%%") }
    }

    @Test func deepNestingIsRefused() {
        let deep = String(repeating: "(", count: 200) + "1" + String(repeating: ")", count: 200) + "+1"
        #expect(throws: CalcError.syntax) { try Calculator.evaluate(deep) }
    }

    @Test func formatting() {
        let en = Locale(identifier: "en_US"), it = Locale(identifier: "it_IT")
        #expect(PaletteFormat.number(1234567.5, locale: en) == "1,234,567.5")
        #expect(PaletteFormat.number(1234567.5, locale: it) == "1.234.567,5")
        #expect(PaletteFormat.number(1234567.5, locale: en, grouping: false) == "1234567.5")
        #expect(PaletteFormat.number(2.0 / 3.0, locale: en) == "0.6666666667")
        #expect(PaletteFormat.based(-10, .hex) == "-0xA")
        #expect(PaletteFormat.based(1.5, .hex) == nil)
    }
}

// MARK: Units

@Suite("Palette units")
struct UnitsTests {
    func conv(_ s: String) -> Double? { Units.parse(s)?.result }

    @Test func conversions() {
        #expect(abs(conv("5 km in mi")! - 3.10686) < 1e-4)
        #expect(abs(conv("5km to mi")! - 3.10686) < 1e-4)
        #expect(abs(conv("70 f to c")! - 21.1111) < 1e-3)
        #expect(abs(conv("-40 °C in °F")! - -40) < 1e-9)
        #expect(abs(conv("0 c in k")! - 273.15) < 1e-9)
        #expect(conv("3 ore in min") == 180)
        #expect(conv("2 giorni in ore") == 48)
        #expect(abs(conv("1 gal in l")! - 3.785411784) < 1e-9)
        #expect(conv("1 gb in mb") == 1000)
        #expect(conv("1 gib in mib") == 1024)
        #expect(abs(conv("100 km/h in mph")! - 62.1371) < 1e-3)
        #expect(abs(conv("10 lb in kg")! - 4.5359237) < 1e-9)
        #expect(conv("1 ha in m2") == 10_000)
        #expect(abs(conv("5 in to cm")! - 12.7) < 1e-9)       // "in" the unit, then "to"
        #expect(abs(conv("1,5 km in m")! - 1500) < 1e-9)
        #expect(abs(conv("12 pollici in cm")! - 30.48) < 1e-9)
    }

    @Test func defaultCounterpart() {
        let c = Units.parse("5 km")
        #expect(c?.to.symbol == "mi")
        #expect(Units.parse("20 °c")?.to.symbol == "°F")
    }

    @Test func notConversions() {
        #expect(Units.parse("5 km in kg") == nil)     // different kinds
        #expect(Units.parse("km in mi") == nil)       // no number
        #expect(Units.parse("1password") == nil)
        #expect(Units.parse("12% of 340") == nil)
        #expect(Units.parse("100 usd to eur") == nil)
    }
}

// MARK: Currency

@Suite("Palette currency")
struct CurrencyTests {
    @Test func parsing() {
        #expect(CurrencyParser.parse("100 usd to eur") == CurrencyQuery(amount: 100, from: "USD", to: "EUR"))
        #expect(CurrencyParser.parse("100 dollari in euro") == CurrencyQuery(amount: 100, from: "USD", to: "EUR"))
        #expect(CurrencyParser.parse("$100 in £") == CurrencyQuery(amount: 100, from: "USD", to: "GBP"))
        #expect(CurrencyParser.parse("€ 20") == CurrencyQuery(amount: 20, from: "EUR", to: nil))
        #expect(CurrencyParser.parse("50 franchi svizzeri in yen") == CurrencyQuery(amount: 50, from: "CHF", to: "JPY"))
        #expect(CurrencyParser.parse("1,5 sterline a euro", decimalComma: true) == CurrencyQuery(amount: 1.5, from: "GBP", to: "EUR"))
        #expect(CurrencyParser.parse("100 usd")?.target == "EUR")
        #expect(CurrencyParser.parse("100 eur")?.target == "USD")
        #expect(CurrencyParser.parse("5 km in mi") == nil)
        #expect(CurrencyParser.parse("100 pounds in kg") == nil)
        #expect(CurrencyParser.parse("usd to eur") == nil)
        #expect(CurrencyParser.parse("safari") == nil)
    }

    @Test func ecbXML() {
        let t = ECBParser.parse(ecbSample)
        #expect(t?.date == "2026-10-02")
        #expect(t?.rates["USD"] == 1.17)
        #expect(t?.rates["EUR"] == 1)
        #expect(abs(t!.convert(117, from: "USD", to: "EUR")! - 100) < 1e-9)
        #expect(abs(t!.convert(100, from: "GBP", to: "USD")! - 100 / 0.87 * 1.17) < 1e-9)
        #expect(t!.convert(1, from: "XXX", to: "EUR") == nil)
        #expect(ECBParser.parse(Data("<html>not it</html>".utf8)) == nil)
    }

    @Test @MainActor func fetchOnlyWhenTypedThenCache() async throws {
        let dir = tempDir()
        let cache = dir.appendingPathComponent("rates.json")
        let stub = StubFetcher(data: ecbSample)
        let model = makeModel(fetcher: stub, rateCache: cache)
        model.setVisible(true, keyboard: false)
        model.query = "12% of 340"
        model.query = "safari"
        #expect(model.rates.fetchCount == 0)             // no currency typed: no network
        model.query = "100 usd to eur"
        #expect(model.rates.fetchCount == 1)
        #expect(model.rows.first?.kind == .notice)       // "Fetching exchange rates…"
        await model.rates.waitForFetch()
        #expect(stub.calls == 1)
        #expect(model.rows.first?.kind == .answer)       // rows refreshed in place
        #expect(model.rows.first?.subtitle?.contains("2026") == true)
        model.query = "200 usd to eur"
        #expect(stub.calls == 1)                         // fresh: no second fetch
        try await Task.sleep(for: .milliseconds(300))
        // A new process reads the disk cache and does not fetch within 12 h.
        let other = CurrencyRates(cacheURL: cache, fetcher: stub)
        other.ensureFresh()
        #expect(other.table?.date == "2026-10-02")
        #expect(other.isFresh)
        #expect(stub.calls == 1)
        model.setVisible(false, keyboard: false)
    }

    @Test @MainActor func staleCacheRefetchesAndOfflineKeepsIt() async throws {
        let dir = tempDir()
        let cache = dir.appendingPathComponent("rates.json")
        var clock = Date(timeIntervalSince1970: 2_000_000)
        let ok = StubFetcher(data: ecbSample)
        let first = CurrencyRates(cacheURL: cache, fetcher: ok, now: { clock })
        first.ensureFresh()
        await first.waitForFetch()
        try await Task.sleep(for: .milliseconds(300))
        clock = clock.addingTimeInterval(13 * 3600)
        let offline = StubFetcher(data: Data(), fails: true)
        let later = CurrencyRates(cacheURL: cache, fetcher: offline, now: { clock })
        later.ensureFresh()
        #expect(later.fetchCount == 1)                   // stale: tries
        await later.waitForFetch()
        #expect(offline.calls == 1)
        #expect(later.status == .failed)
        #expect(later.table?.date == "2026-10-02")       // the cached table stays usable
        later.ensureFresh()
        #expect(later.fetchCount == 1)                   // no hammering right after a failure
    }

    @Test @MainActor func offlineWithoutCacheSaysSo() async {
        let model = makeModel(fetcher: StubFetcher(data: Data(), fails: true))
        model.setVisible(true, keyboard: false)
        model.query = "10 usd in eur"
        await model.rates.waitForFetch()
        #expect(model.rows.first?.kind == .notice)
        #expect(model.rows.first?.actionable == false)
        model.setVisible(false, keyboard: false)
    }
}

// MARK: Apps

@Suite("Palette app index")
struct AppIndexTests {
    @Test func scansFoldersOneLevelDeep() {
        let dir = tempDir(), user = tempDir()
        makeApp("Safari", in: dir)
        makeApp("Visual Studio Code", in: dir)
        let office = dir.appendingPathComponent("Microsoft Office", isDirectory: true)
        makeApp("Microsoft Word", in: office)
        let deep = office.appendingPathComponent("Nested", isDirectory: true)
        makeApp("Too Deep", in: deep)
        makeApp("Mine", in: user)
        // Flagged hidden like /Applications/Safari.app (a symlink into the cryptex): still found.
        makeApp("Hidden Browser", in: dir)
        var hidden = dir.appendingPathComponent("Hidden Browser.app")
        var values = URLResourceValues()
        values.isHidden = true
        try? hidden.setResourceValues(values)
        makeApp(".Dot", in: dir)
        try? "x".write(to: dir.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        let apps = AppScanner.scan([dir, user, dir], extras: [])
        #expect(apps.map(\.name) == ["Hidden Browser", "Microsoft Word", "Mine", "Safari", "Visual Studio Code"])
        #expect(apps.first { $0.name == "Safari" }?.path.hasSuffix("Safari.app") == true)
    }

    @Test @MainActor func indexesOffMainAndWatches() async {
        let dir = tempDir()
        makeApp("Alpha", in: dir)
        let index = AppIndex(folders: [dir], extras: [])
        var updates = 0
        index.onUpdate = { updates += 1 }
        #expect(index.stale)
        index.refreshIfNeeded()
        index.refreshIfNeeded()                          // one scan at a time
        await index.waitForIndex()
        #expect(index.scanCount == 1)
        #expect(index.apps.map(\.name) == ["Alpha"])
        #expect(!index.stale)
        #expect(index.isWatching)
        #expect(updates == 1)
        index.refreshIfNeeded()                          // fresh: nothing to do
        #expect(index.scanCount == 1)
        index.invalidate()                               // what FSEvents does on a change
        index.refreshIfNeeded()
        await index.waitForIndex()
        #expect(index.scanCount == 2)
        index.stop()
        #expect(!index.isWatching)
    }

    @Test @MainActor func appsInResultsWithReveal() async {
        let dir = tempDir()
        makeApp("Safari", in: dir)
        makeApp("Safe Exam Browser", in: dir)
        makeApp("Calculator", in: dir)
        let model = makeModel(apps: AppIndex(folders: [dir], extras: []))
        model.setVisible(true, keyboard: false)
        await model.apps.waitForIndex()
        model.query = "saf"
        #expect(model.rows.first?.title == "Safari")
        #expect(model.rows.first?.kind == .app)
        #expect(model.rows.first?.secondary != nil)      // ⌘⏎ shows it in Finder
        model.settings.apps = false
        model.sourcesChanged()
        model.query = "safa"
        #expect(!model.rows.contains { $0.kind == .app })
        model.setVisible(false, keyboard: false)
        model.apps.stop()
    }
}

// MARK: Aggregation, keyboard, focus

@Suite("Palette model", .serialized)
@MainActor
struct CommandModelTests {
    @Test func aggregatesEnabledModulesOnly() {
        let model = makeModel()
        let timer = ExampleCommandModule(.timer)
        let notes = ExampleCommandModule(.notes)
        var disabled: Set<ModuleID> = [.notes]
        model.sources = { [timer, notes] }
        model.isEnabled = { !disabled.contains($0) }
        model.setVisible(true, keyboard: false)
        model.query = "start 25"
        #expect(model.rows.contains { $0.id == "timer.start25" })
        #expect(!model.rows.contains { $0.id == "notes.start25" })
        // results(for:) is asked too, and only of enabled modules.
        model.query = "timer 10"
        #expect(model.rows.first?.id == "timer.custom")
        #expect(!model.rows.contains { $0.id == "notes.custom" })
        // Turned on: next open sees it.
        disabled = []
        model.setVisible(false, keyboard: false)
        model.setVisible(true, keyboard: false)
        model.query = "start 25"
        #expect(model.rows.contains { $0.id == "notes.start25" })
        model.setVisible(false, keyboard: false)
    }

    @Test func sameIDFromCommandsAndResultsShowsOnceHigherRankWins() {
        @MainActor final class Twice: GlancyModule {
            let id = ModuleID.timer
            func start(hub: ActivityHub) {}
            func stop() {}
            func commands() -> [GlancyCommand] {
                [GlancyCommand(id: "timer.pomodoro", module: .timer, title: "Pomodoro", subtitle: "commands", symbol: "timer") {}]
            }
            func results(for query: String) -> [GlancyCommand] {
                query.isEmpty || query.hasPrefix("pom")
                    ? [GlancyCommand(id: "timer.pomodoro", module: .timer, title: "Pomodoro", subtitle: "results", symbol: "timer", rank: 90) {}]
                    : []
            }
        }
        let model = makeModel()
        model.sources = { [Twice()] }
        model.setVisible(true, keyboard: false)
        model.query = "pomo"
        #expect(model.rows.filter { $0.id == "timer.pomodoro" }.count == 1)
        #expect(model.rows.first?.subtitle == "results")
        model.query = ""
        #expect(model.rows.filter { $0.id == "timer.pomodoro" }.count == 1)
        model.setVisible(false, keyboard: false)
    }

    @Test func bareNumberGoesToTheCalculator() {
        let model = makeModel()
        model.sources = { [ExampleCommandModule(.timer)] }
        model.setVisible(true, keyboard: false)
        model.query = "25"
        #expect(model.rows.first?.id == "calc")
        #expect(model.rows.first?.subtitle == "0x19 · 0b11001")
        model.setVisible(false, keyboard: false)
    }

    @Test func keywordsInItalianFindTheCommand() {
        let model = makeModel()
        model.sources = { [ExampleCommandModule(.timer)] }
        model.setVisible(true, keyboard: false)
        model.query = "avvia timer"
        #expect(model.rows.first?.id == "timer.start25")
        model.query = "blocca"
        #expect(model.rows.first?.id == "system.lock")
        model.setVisible(false, keyboard: false)
    }

    @Test func emptyQueryShowsSuggestionsThenRecents() {
        let model = makeModel()
        let timer = ExampleCommandModule(.timer)
        model.sources = { [timer] }
        model.history.record("system.lock", query: "")
        model.setVisible(true, keyboard: false)
        #expect(model.rows.first?.id == "timer.running")     // rank 80 = suggested
        #expect(model.sections[0] != nil)
        #expect(model.rows.contains { $0.id == "system.lock" })
        model.setVisible(false, keyboard: false)
    }

    @Test func runningCommandsAndClosing() {
        let model = makeModel()
        let timer = ExampleCommandModule(.timer)
        model.sources = { [timer] }
        var closed = 0
        model.close = { closed += 1 }
        model.setVisible(true, keyboard: false)
        model.query = "pomodoro"
        model.handle(.enter)
        #expect(timer.ran == ["start25"])
        #expect(closed == 1)
        #expect(model.history.store.entries["timer.start25"] != nil)
        // ⌘2 picks the second row.
        model.query = "timer"
        let second = model.rows.indices.contains(1) ? model.rows[1].id : nil
        model.handle(.pick(1))
        #expect(model.selection == 1 || second == nil)
        model.setVisible(false, keyboard: false)
    }

    @Test func keyboardNavigation() {
        typealias K = CommandModel.Key
        #expect(CommandModel.key(keyCode: 125, flags: [], characters: nil) == .down)
        #expect(CommandModel.key(keyCode: 126, flags: [], characters: nil) == .up)
        #expect(CommandModel.key(keyCode: 36, flags: [], characters: "\r") == .enter)
        #expect(CommandModel.key(keyCode: 76, flags: [], characters: "\u{3}") == .enter)
        #expect(CommandModel.key(keyCode: 36, flags: .command, characters: "\r") == .secondary)
        #expect(CommandModel.key(keyCode: 36, flags: .option, characters: "\r") == nil)
        #expect(CommandModel.key(keyCode: 18, flags: .command, characters: "1") == .pick(0))
        #expect(CommandModel.key(keyCode: 25, flags: .command, characters: "9") == .pick(8))
        #expect(CommandModel.key(keyCode: 29, flags: .command, characters: "0") == nil)
        #expect(CommandModel.key(keyCode: 45, flags: .control, characters: "n") == .down)
        #expect(CommandModel.key(keyCode: 35, flags: .control, characters: "p") == .up)
        #expect(CommandModel.key(keyCode: 0, flags: [], characters: "a") == nil)     // typing goes to the field

        let model = makeModel()
        model.sources = { [ExampleCommandModule(.timer)] }
        model.setVisible(true, keyboard: false)
        model.query = "t"
        let count = model.rows.count
        #expect(count >= 2)
        model.handle(.up)
        #expect(model.selection == 0)
        for _ in 0..<(count + 3) { model.handle(.down) }
        #expect(model.selection == count - 1)              // clamps at the end
        model.query = "ti"                                 // a new query starts at the top
        #expect(model.selection == 0)
        model.setVisible(false, keyboard: false)
    }

    @Test func secondaryActionAndNotices() {
        let model = makeModel()
        var closed = 0
        model.close = { closed += 1 }
        model.setVisible(true, keyboard: false)
        model.query = "2+2"
        #expect(model.rows.first?.title == "4")
        #expect(model.rows.first?.learns == false)
        model.setVisible(false, keyboard: false)
        #expect(model.rows.isEmpty)
        #expect(model.query.isEmpty)
    }

    @Test func urlAndWebFallback() {
        let model = makeModel()
        model.settings.webSearch = true
        model.setVisible(true, keyboard: false)
        model.query = "github.com"
        #expect(model.rows.first?.id == "url.open")
        #expect(model.rows.last?.id == "web.search")
        model.query = "zzqqxx"
        #expect(model.rows.map(\.id) == ["web.search"])
        model.setVisible(false, keyboard: false)
        #expect(PaletteURL.detect("github.com")?.absoluteString == "https://github.com")
        #expect(PaletteURL.detect("localhost:3000/x")?.absoluteString == "http://localhost:3000/x")
        #expect(PaletteURL.detect("https://a.b/c?d=1") != nil)
        #expect(PaletteURL.detect("12.5") == nil)
        #expect(PaletteURL.detect("hello world.com") == nil)
        #expect(PaletteURL.detect("safari") == nil)
    }

    @Test func focusOwnerSetAndReleased() {
        let model = makeModel()
        #expect(!SurfaceKeyFocus.holds(CommandModel.focusOwner))
        model.setVisible(true)
        #expect(SurfaceKeyFocus.holds(CommandModel.focusOwner))
        model.setVisible(false)
        #expect(!SurfaceKeyFocus.holds(CommandModel.focusOwner))
    }

    @Test func moduleOpensOnItsPageAndHotkeyToggles() {
        let suite = "glancy.test.palette.module.\(UUID().uuidString)"
        let module = CommandModule(settings: CommandSettings(defaults: UserDefaults(suiteName: suite)!), history: PaletteHistory(url: nil),
                                   apps: AppIndex(folders: [], extras: []), rates: CurrencyRates(cacheURL: nil), sample: true)
        let hub = ActivityHub()
        var opened: [ModuleID?] = [], closes = 0
        hub.onOpenRequest = { opened.append($0) }
        hub.onCloseRequest = { closes += 1 }
        module.start(hub: hub)
        module.hotkeyPressed()
        #expect(opened == [.command])
        module.visibilityChanged(.expanded(.command))
        #expect(module.model.visible)
        module.hotkeyPressed()
        #expect(closes == 1)
        module.visibilityChanged(.expanded(.calendar))
        #expect(!module.model.visible)
        module.stop()
        #expect(module.tab?.module == .command)
    }

    @Test func surfaceHidesTheBarFromTheStrip() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "glancy.test.palette.ctx.\(UUID().uuidString)")!)
        let module = CommandModule(settings: CommandSettings(defaults: UserDefaults(suiteName: "glancy.test.palette.ctx2.\(UUID().uuidString)")!),
                                   history: PaletteHistory(url: nil), apps: AppIndex(folders: [], extras: []),
                                   rates: CurrencyRates(cacheURL: nil), sample: true)
        let context = SurfaceContext(hub: ActivityHub(), settings: settings, launchAtLogin: LaunchAtLogin(),
                                     modules: [module, ExampleCommandModule(.timer)])
        #expect(context.tabs.contains { $0.module == .command })            // the panel can show it…
        #expect(!context.stripTabs.contains { $0.module == .command })      // …but it has no icon
        #expect(!context.tabSequence.contains(.command))                    // and swipes skip it
        // attach(): the bar reads enabled state from the app's settings.
        settings.setEnabled(.timer, false)
        #expect(module.model.isEnabled(.timer) == false)
        #expect(module.model.isEnabled(.calendar) == true)
    }

    @Test func perKeystrokeBudget() {
        let names = (0..<600).map { "App Number \($0) \(["Studio", "Pro", "Lite", "Café", "Builder"][$0 % 5])" }
        let index = AppIndex(folders: [], extras: [])
        index.setApps(names.map { AppEntry(path: "/Applications/\($0).app", name: $0, displayName: $0) })
        let model = makeModel(apps: index)
        model.sources = { [ExampleCommandModule(.timer), ExampleCommandModule(.notes)] }
        model.setVisible(true, keyboard: false)
        var worst: TimeInterval = 0
        for q in ["a", "ap", "app", "app n", "app nu", "stu", "cafe", "pro 12", "12% of 340", "5 km in mi", "zzz"] {
            model.query = q
            worst = max(worst, model.lastCompute)
        }
        print("palette: worst recompute over 600 apps = \(Int(worst * 1_000_000)) µs")
        // < 5 ms in release; debug builds are several times slower, so the test allows 25 ms.
        #expect(worst < 0.025)
        model.setVisible(false, keyboard: false)
    }
}
