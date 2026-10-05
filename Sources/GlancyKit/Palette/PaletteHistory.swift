import Foundation

// What the command bar learns from use: a decaying score per command (frecency) and which command
// was chosen for a typed query. Small and capped; stored in Application Support/Glancy/commands.json.

public struct FrecencyStore: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var score: Double
        public var last: Date
    }

    public var entries: [String: Entry] = [:]
    /// Normalised query → the id chosen for it last.
    public var queries: [String: String] = [:]

    public static let maxEntries = 300
    public static let maxQueries = 200
    /// A use counts half after a week.
    public static let halfLife: TimeInterval = 7 * 24 * 3600

    public init() {}

    static func decayed(_ e: Entry, now: Date) -> Double {
        let age = max(0, now.timeIntervalSince(e.last))
        return e.score * pow(0.5, age / halfLife)
    }

    public mutating func record(_ id: String, query: String, now: Date = .now) {
        let old = entries[id].map { Self.decayed($0, now: now) } ?? 0
        entries[id] = Entry(score: old + 1, last: now)
        let q = PaletteMatcher.normalize(query)
        if !q.isEmpty { queries[q] = id }
        trim(now: now)
    }

    public mutating func forget(_ id: String) {
        entries[id] = nil
        queries = queries.filter { $0.value != id }
    }

    /// Up to +200 for something used often and lately.
    public func boost(_ id: String, now: Date = .now) -> Int {
        guard let e = entries[id] else { return 0 }
        let s = Self.decayed(e, now: now)
        return Int(min(200, 70 * log2(1 + s)))
    }

    /// +300 when this exact query picked this id before; +150 when a longer query starting with
    /// it did (typing "sa" after choosing Safari for "saf").
    public func queryBoost(_ query: String, _ id: String) -> Int {
        guard !query.isEmpty else { return 0 }
        if queries[query] == id { return 300 }
        for (q, chosen) in queries where chosen == id && q.count > query.count && q.hasPrefix(query) { return 150 }
        return 0
    }

    /// `queryBoost` for every id at once (one pass over the stored queries per keystroke).
    public func queryBoosts(_ query: String) -> [String: Int] {
        guard !query.isEmpty else { return [:] }
        var out: [String: Int] = [:]
        for (q, id) in queries {
            if q == query { out[id] = 300 }
            else if q.count > query.count, q.hasPrefix(query), out[id] == nil { out[id] = 150 }
        }
        return out
    }

    /// Most recently used first.
    public func recents(_ limit: Int) -> [String] {
        entries.sorted { $0.value.last > $1.value.last }.prefix(limit).map(\.key)
    }

    private mutating func trim(now: Date) {
        if entries.count > Self.maxEntries {
            let keep = entries.sorted { Self.decayed($0.value, now: now) > Self.decayed($1.value, now: now) }
                .prefix(Self.maxEntries)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
            queries = queries.filter { entries[$0.value] != nil }
        }
        if queries.count > Self.maxQueries {
            // Drop the queries whose command is least used.
            let keep = queries.sorted { (entries[$0.value]?.last ?? .distantPast) > (entries[$1.value]?.last ?? .distantPast) }
                .prefix(Self.maxQueries)
            queries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }
}

/// The store on disk. Loaded on the bar's first open; written off the main thread after each use.
@MainActor
public final class PaletteHistory {
    public private(set) var store = FrecencyStore()
    private let url: URL?
    private var loaded = false
    private var version = 0
    private let writer = HistoryWriter()

    /// nil = memory only (tests, renderer).
    public init(url: URL?) { self.url = url }

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Glancy", isDirectory: true).appendingPathComponent("commands.json")
    }

    public var isLoaded: Bool { loaded }

    public func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let url, let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder.history.decode(FrecencyStore.self, from: data) else { return }
        store = s
    }

    public func record(_ id: String, query: String, now: Date = .now) {
        loadIfNeeded()
        store.record(id, query: query, now: now)
        save()
    }

    public func clear() {
        store = FrecencyStore()
        loaded = true
        save()
    }

    private func save() {
        guard let url else { return }
        guard let data = try? JSONEncoder.history.encode(store) else { return }
        version += 1
        let v = version
        Task { [writer] in await writer.write(data, to: url, version: v) }
    }
}

/// Writes off the main thread; an older snapshot arriving late never overwrites a newer one.
actor HistoryWriter {
    private var written = 0
    func write(_ data: Data, to url: URL, version: Int) {
        guard version > written else { return }
        written = version
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

extension JSONEncoder {
    static var history: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }
}

extension JSONDecoder {
    static var history: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}
