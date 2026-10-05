import Foundation

// Currency conversion: "100 usd to eur", "100 dollari in euro", "$100 in £". Rates come from the
// ECB's daily reference XML, fetched only when a currency query is typed, cached on disk for 12 h.
// Offline: the cached table (any age, its date shown) or a clear message. The only network use
// of the command bar.

public struct CurrencyQuery: Equatable, Sendable {
    public var amount: Double
    public var from: String
    /// nil = not typed (EUR, or USD when converting from EUR).
    public var to: String?

    public var target: String { to ?? (from == "EUR" ? "USD" : "EUR") }
}

/// Rates per euro, as the ECB publishes them, plus EUR = 1.
public struct RateTable: Codable, Equatable, Sendable {
    /// The ECB's reference date, "2026-10-02".
    public var date: String
    public var rates: [String: Double]

    public init(date: String, rates: [String: Double]) {
        self.date = date
        var r = rates
        r["EUR"] = 1
        self.rates = r
    }

    public func convert(_ amount: Double, from: String, to: String) -> Double? {
        guard let f = rates[from], let t = rates[to], f > 0 else { return nil }
        return amount / f * t
    }
}

public enum CurrencyParser {
    /// The ECB's currencies (and the euro).
    public static let codes: Set<String> = ["EUR", "USD", "JPY", "BGN", "CZK", "DKK", "GBP", "HUF", "PLN", "RON", "SEK", "CHF",
                                            "ISK", "NOK", "TRY", "AUD", "BRL", "CAD", "CNY", "HKD", "IDR", "ILS", "INR", "KRW",
                                            "MXN", "MYR", "NZD", "PHP", "SGD", "THB", "ZAR"]

    static let symbols: [String: String] = ["$": "USD", "€": "EUR", "£": "GBP", "¥": "JPY", "₹": "INR", "₩": "KRW", "₺": "TRY",
                                            "us$": "USD", "c$": "CAD", "a$": "AUD", "chf": "CHF", "fr": "CHF", "r$": "BRL"]

    /// Names in English and Italian, normalised (folded, lowercased).
    static let names: [String: String] = {
        let table: [String: [String]] = [
            "EUR": ["euro", "euros"],
            "USD": ["dollar", "dollars", "dollaro", "dollari", "us dollar", "us dollars", "dollaro americano", "dollari americani", "bucks"],
            "GBP": ["pound", "pounds", "sterling", "pound sterling", "pounds sterling", "sterlina", "sterline", "sterline inglesi", "quid"],
            "JPY": ["yen", "japanese yen", "yen giapponese", "yen giapponesi"],
            "CHF": ["franc", "francs", "swiss franc", "swiss francs", "franco", "franchi", "franco svizzero", "franchi svizzeri"],
            "CNY": ["yuan", "renminbi", "rmb"],
            "CAD": ["canadian dollar", "canadian dollars", "dollaro canadese", "dollari canadesi"],
            "AUD": ["australian dollar", "australian dollars", "dollaro australiano", "dollari australiani"],
            "NZD": ["new zealand dollar", "new zealand dollars"],
            "HKD": ["hong kong dollar", "hong kong dollars"],
            "SGD": ["singapore dollar", "singapore dollars"],
            "SEK": ["swedish krona", "swedish kronor", "corona svedese", "corone svedesi"],
            "NOK": ["norwegian krone", "norwegian kroner", "corona norvegese", "corone norvegesi"],
            "DKK": ["danish krone", "danish kroner", "corona danese", "corone danesi"],
            "CZK": ["czech koruna", "corona ceca", "corone ceche"],
            "PLN": ["zloty", "zlotys", "zloty polacco", "zloty polacchi"],
            "HUF": ["forint", "fiorino ungherese", "fiorini ungheresi"],
            "RON": ["leu", "lei"],
            "TRY": ["turkish lira", "lira turca", "lire turche"],
            "INR": ["rupee", "rupees", "indian rupee", "rupia", "rupie", "rupia indiana", "rupie indiane"],
            "BRL": ["real", "reais", "brazilian real"],
            "MXN": ["peso", "pesos", "mexican peso", "peso messicano", "pesos messicani"],
            "KRW": ["won", "korean won"],
            "ZAR": ["rand", "rands"],
            "ILS": ["shekel", "shekels", "sheqel"],
            "THB": ["baht"],
            "IDR": ["rupiah"],
            "MYR": ["ringgit"],
            "ISK": ["icelandic krona", "corona islandese"],
        ]
        var map: [String: String] = [:]
        for (code, list) in table { for n in list { map[n] = code } }
        return map
    }()

    public static func code(for phrase: String) -> String? {
        let p = phrase.trimmingCharacters(in: .whitespaces).lowercased()
        guard !p.isEmpty else { return nil }
        if let c = symbols[p] { return c }
        if p.count == 3, codes.contains(p.uppercased()) { return p.uppercased() }
        return names[PaletteMatcher.normalize(p)]
    }

    static let separators = [" in ", " to ", " into ", " as ", " a ", " = ", " => ", " in "]

    /// nil when the input isn't a currency conversion.
    public static func parse(_ input: String, decimalComma: Bool = false) -> CurrencyQuery? {
        var s = input.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "->", with: " to ").replacingOccurrences(of: "→", with: " to ")
        // A leading symbol: "$100", "€ 20".
        var symbolFrom: String?
        if let first = s.first, let c = symbols[String(first)] {
            symbolFrom = c
            s = String(s.dropFirst())
        }
        guard let (amount, rest) = Units.leadingNumber(s, decimalComma: decimalComma) else { return nil }
        if let from = symbolFrom {
            if rest.isEmpty { return CurrencyQuery(amount: amount, from: from, to: nil) }
            // "$100 in eur": the rest is a separator and a target.
            let r = " " + rest + " "
            for sep in separators where r.hasPrefix(sep) {
                if let to = code(for: String(r.dropFirst(sep.count))) { return CurrencyQuery(amount: amount, from: from, to: to) }
            }
            return nil
        }
        guard !rest.isEmpty else { return nil }
        let text = " " + rest + " "
        for sep in separators {
            var search = text.startIndex..<text.endIndex
            while let r = text.range(of: sep, range: search) {
                if let from = code(for: String(text[..<r.lowerBound])), let to = code(for: String(text[r.upperBound...])) {
                    return CurrencyQuery(amount: amount, from: from, to: to)
                }
                search = text.index(after: r.lowerBound)..<text.endIndex
            }
        }
        if let from = code(for: rest) { return CurrencyQuery(amount: amount, from: from, to: nil) }
        return nil
    }
}

// MARK: ECB XML

/// Reads `<Cube time='…'>` and every `<Cube currency='USD' rate='1.1'/>` of the ECB daily file.
final class ECBParser: NSObject, XMLParserDelegate {
    private var date: String?
    private var rates: [String: Double] = [:]

    static func parse(_ data: Data) -> RateTable? {
        let delegate = ECBParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), let date = delegate.date, !delegate.rates.isEmpty else { return nil }
        return RateTable(date: date, rates: delegate.rates)
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        guard name == "Cube" else { return }
        if let t = attributes["time"] { date = t }
        if let c = attributes["currency"], let r = attributes["rate"].flatMap(Double.init), r > 0 { rates[c.uppercased()] = r }
    }
}

// MARK: Fetch + cache

public protocol RatesFetching: Sendable {
    func fetch() async throws -> Data
}

/// The real source. An ephemeral session: no cookies, no cache on disk beyond ours.
public struct ECBFetcher: RatesFetching {
    public static let url = URL(string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml")!
    public init() {}
    public func fetch() async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: Self.url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}

/// The rates the bar converts with: the disk cache, refreshed on demand (≥ 12 h old).
@MainActor
public final class CurrencyRates {
    public enum Status: Equatable { case idle, loading, failed }

    struct Cache: Codable { var table: RateTable; var fetchedAt: Date }

    public private(set) var table: RateTable?
    public private(set) var fetchedAt: Date?
    public private(set) var status: Status = .idle
    /// Called on main when a fetch finishes (the bar recomputes its rows).
    public var onUpdate: (() -> Void)?

    public static let maxAge: TimeInterval = 12 * 3600
    /// After a failure, wait this long before trying again (typing must not hammer the network).
    static let retryAfter: TimeInterval = 60

    private let cacheURL: URL?
    private let fetcher: any RatesFetching
    private let now: () -> Date
    private var cacheRead = false
    private var failedAt: Date?
    private var task: Task<Void, Never>?
    public private(set) var fetchCount = 0

    public init(cacheURL: URL?, fetcher: any RatesFetching = ECBFetcher(), now: @escaping () -> Date = { .now }) {
        self.cacheURL = cacheURL
        self.fetcher = fetcher
        self.now = now
    }

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Glancy", isDirectory: true).appendingPathComponent("currency-rates.json")
    }

    /// Fixed rates, no disk and no network (the renderer).
    public func useFixed(_ t: RateTable) {
        table = t
        fetchedAt = now()
        cacheRead = true
        status = .idle
    }

    public var isFresh: Bool {
        guard let fetchedAt, table != nil else { return false }
        return now().timeIntervalSince(fetchedAt) < Self.maxAge
    }

    func readCacheIfNeeded() {
        guard !cacheRead else { return }
        cacheRead = true
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL),
              let c = try? JSONDecoder.history.decode(Cache.self, from: data) else { return }
        table = c.table
        fetchedAt = c.fetchedAt
    }

    /// A currency query was typed: make sure fresh rates are on their way.
    public func ensureFresh() {
        readCacheIfNeeded()
        guard !isFresh, status != .loading else { return }
        if let failedAt, now().timeIntervalSince(failedAt) < Self.retryAfter { return }
        status = .loading
        fetchCount += 1
        let fetcher = self.fetcher
        task = Task { [weak self] in
            let parsed: RateTable?
            do {
                let data = try await fetcher.fetch()
                parsed = await Task.detached { ECBParser.parse(data) }.value
            } catch {
                parsed = nil
            }
            guard !Task.isCancelled else { return }
            self?.finished(parsed)
        }
    }

    private func finished(_ t: RateTable?) {
        task = nil
        if let t {
            table = t
            fetchedAt = now()
            status = .idle
            failedAt = nil
            if let cacheURL, let data = try? JSONEncoder.history.encode(Cache(table: t, fetchedAt: fetchedAt!)) {
                Task.detached(priority: .utility) {
                    try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? data.write(to: cacheURL, options: .atomic)
                }
            }
        } else {
            status = .failed
            failedAt = now()
        }
        onUpdate?()
    }

    public func cancel() {
        task?.cancel()
        task = nil
        if status == .loading { status = .idle }
    }

    /// Tests: wait for the fetch in flight.
    func waitForFetch() async { await task?.value }
}
