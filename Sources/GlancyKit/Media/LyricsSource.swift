import CryptoKit
import Foundation

// Where lyrics come from: LRCLIB (https://lrclib.net, free, no key) and a small on-disk cache.
// The only network Glancy does, and only when lyrics are on: the title, artist, album and length
// of the playing track go to lrclib.net (Settings → Media says so).

/// The track as LRCLIB looks it up.
public struct LyricsQuery: Equatable, Hashable, Sendable {
    public var title: String
    public var artist: String
    public var album: String?
    public var duration: TimeInterval?

    public init(title: String, artist: String, album: String? = nil, duration: TimeInterval? = nil) {
        self.title = title; self.artist = artist; self.album = album; self.duration = duration
    }

    /// Nil when there is nothing worth asking about (no artist: a browser tab, a podcast app…).
    public init?(_ info: NowPlayingInfo) {
        guard let artist = info.artist?.trimmingCharacters(in: .whitespaces), !artist.isEmpty else { return nil }
        let title = info.title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        self.init(title: title, artist: artist, album: info.album, duration: info.duration)
    }

    /// Stable cache key (duration rounded: players disagree by fractions of a second).
    public var cacheKey: String {
        let d = duration.map { String(Int($0.rounded())) } ?? "-"
        let raw = [title.lowercased(), artist.lowercased(), (album ?? "").lowercased(), d].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(raw.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

public enum LyricsError: Error, Equatable, Sendable {
    /// No connection, a timeout, a server error: try again later, never cached.
    case offline
}

/// Fetches lyrics for a track. Async, cancellable; tests use a stub transport.
public protocol LyricsProvider: Sendable {
    func lyrics(for query: LyricsQuery) async throws -> LyricsContent
}

/// LRCLIB's `/api/get` (exact match, ±2 s on duration), then `/api/search` as a fallback when the
/// album or duration doesn't match what LRCLIB has.
public struct LRCLIBClient: LyricsProvider {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    static let base = URL(string: "https://lrclib.net/api/")!
    let transport: Transport

    public init(transport: @escaping Transport = LRCLIBClient.urlSession) { self.transport = transport }

    /// Ephemeral session: no cookies, no URL cache on disk, 8 s per request.
    public static let urlSession: Transport = { request in
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LyricsError.offline }
        return (data, http)
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        c.timeoutIntervalForResource = 15
        c.httpAdditionalHeaders = ["User-Agent": "Glancy (https://github.com/giacolaiacomo/glancy)"]
        return URLSession(configuration: c)
    }()

    public func lyrics(for query: LyricsQuery) async throws -> LyricsContent {
        if let exact = try await get(query) { return exact }
        try Task.checkCancellation()
        return try await search(query)
    }

    static func getURL(_ q: LyricsQuery) -> URL {
        var c = URLComponents(url: base.appendingPathComponent("get"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "artist_name", value: q.artist), URLQueryItem(name: "track_name", value: q.title)]
        if let album = q.album, !album.isEmpty { items.append(URLQueryItem(name: "album_name", value: album)) }
        if let d = q.duration, d > 0 { items.append(URLQueryItem(name: "duration", value: String(Int(d.rounded())))) }
        c.queryItems = items
        return c.url!
    }

    static func searchURL(_ q: LyricsQuery) -> URL {
        var c = URLComponents(url: base.appendingPathComponent("search"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "track_name", value: q.title), URLQueryItem(name: "artist_name", value: q.artist)]
        return c.url!
    }

    /// nil = 404 (not an exact match).
    private func get(_ q: LyricsQuery) async throws -> LyricsContent? {
        let (data, status) = try await send(Self.getURL(q))
        if status == 404 { return nil }
        guard status == 200, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LyricsError.offline
        }
        return Self.content(obj)
    }

    private func search(_ q: LyricsQuery) async throws -> LyricsContent {
        let (data, status) = try await send(Self.searchURL(q))
        if status == 404 { return .notFound }
        guard status == 200, let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw LyricsError.offline
        }
        return Self.best(list, for: q).map(Self.content) ?? .notFound
    }

    private func send(_ url: URL) async throws -> (Data, Int) {
        var r = URLRequest(url: url)
        r.httpMethod = "GET"
        do {
            let (data, http) = try await transport(r)
            if http.statusCode >= 500 { throw LyricsError.offline }
            return (data, http.statusCode)
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch {
            throw LyricsError.offline
        }
    }

    /// The search hit closest in length (within 3 s when both know it), synced first.
    static func best(_ list: [[String: Any]], for q: LyricsQuery) -> [String: Any]? {
        let candidates = list.filter { item in
            guard let d = q.duration, let theirs = (item["duration"] as? NSNumber)?.doubleValue else { return true }
            return abs(theirs - d) <= 3
        }
        func score(_ item: [String: Any]) -> Int {
            if (item["syncedLyrics"] as? String)?.isEmpty == false { return 2 }
            if (item["plainLyrics"] as? String)?.isEmpty == false { return 1 }
            return (item["instrumental"] as? Bool) == true ? 1 : 0
        }
        return candidates.max { score($0) < score($1) }
    }

    /// One LRCLIB record → what we show.
    static func content(_ obj: [String: Any]) -> LyricsContent {
        if let synced = obj["syncedLyrics"] as? String {
            let lines = LRC.parse(synced)
            if lines.contains(where: { !$0.text.isEmpty }) { return .synced(lines) }
        }
        if let plain = (obj["plainLyrics"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !plain.isEmpty {
            return .plain(plain)
        }
        if (obj["instrumental"] as? Bool) == true { return .instrumental }
        return .notFound
    }
}

/// Lyrics already fetched, one small JSON file per track under `Application Support/Glancy/lyrics`,
/// least recently used dropped beyond `limit`. "Not found" is remembered for a few days only
/// (LRCLIB grows); "offline" is never written.
public actor LyricsCache {
    public let directory: URL
    let limit: Int
    let notFoundTTL: TimeInterval

    struct Entry: Codable {
        var kind: String          // synced, plain, instrumental, notFound
        var text: String?
        var fetched: Date
    }

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Glancy/lyrics", isDirectory: true)
    }

    public init(directory: URL = LyricsCache.defaultDirectory, limit: Int = 200, notFoundTTL: TimeInterval = 3 * 86_400) {
        self.directory = directory
        self.limit = limit
        self.notFoundTTL = notFoundTTL
    }

    private func url(_ key: String) -> URL { directory.appendingPathComponent("\(key).json") }

    public func get(_ query: LyricsQuery, now: Date = .now) -> LyricsContent? {
        let file = url(query.cacheKey)
        guard let data = try? Data(contentsOf: file),
              let e = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        if e.kind == "notFound", now.timeIntervalSince(e.fetched) > notFoundTTL {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        // Touch: the modification date is the LRU clock.
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        switch e.kind {
        case "synced": return .synced(LRC.parse(e.text ?? ""))
        case "plain": return .plain(e.text ?? "")
        case "instrumental": return .instrumental
        default: return .notFound
        }
    }

    public func put(_ content: LyricsContent, for query: LyricsQuery, now: Date = .now) {
        let e: Entry
        switch content {
        case .synced(let lines): e = Entry(kind: "synced", text: Self.serialize(lines), fetched: now)
        case .plain(let s): e = Entry(kind: "plain", text: s, fetched: now)
        case .instrumental: e = Entry(kind: "instrumental", text: nil, fetched: now)
        case .notFound: e = Entry(kind: "notFound", text: nil, fetched: now)
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(e) else { return }
        try? data.write(to: url(query.cacheKey), options: .atomic)
        try? fm.setAttributes([.modificationDate: now], ofItemAtPath: url(query.cacheKey).path)
        trim()
    }

    public func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    public func count() -> Int { files().count }

    private func files() -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        return ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? [])
            .filter { $0.pathExtension == "json" }
    }

    private func trim() {
        let all = files()
        guard all.count > limit else { return }
        let dated = all.map { u in
            (u, (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.sorted { $0.1 < $1.1 }
        for (u, _) in dated.prefix(all.count - limit) { try? FileManager.default.removeItem(at: u) }
    }

    static func serialize(_ lines: [LyricLine]) -> String {
        lines.map { l in
            let cs = Int((l.time * 100).rounded())
            return String(format: "[%02d:%02d.%02d]", cs / 6000, (cs / 100) % 60, cs % 100) + l.text
        }.joined(separator: "\n")
    }
}
