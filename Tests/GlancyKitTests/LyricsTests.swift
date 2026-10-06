import Foundation
import Testing
@testable import GlancyKit

private func tempDir(_ name: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("glancy-lyrics-tests-\(name)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@MainActor private func freshSettings() -> LyricsSettings {
    let suite = "ai.glancy.tests.lyrics.\(UUID().uuidString)"
    return LyricsSettings(defaults: UserDefaults(suiteName: suite)!)
}

private func track(_ title: String = "Golden Hour Drive", playing: Bool = true, elapsed: TimeInterval = 0, at t: Date,
                   rate: Double? = 1, duration: TimeInterval? = 236) -> NowPlayingInfo {
    NowPlayingInfo(bundleID: "com.apple.Music", playing: playing, title: title, artist: "Paper Lanterns", album: "Night Roads",
                   duration: duration, elapsed: elapsed, timestamp: t, rate: playing ? rate : 0)
}

// MARK: - LRC

@Suite struct LRCParsingTests {
    @Test func basicLinesAndPrecision() {
        let lines = LRC.parse("""
        [00:12.40]Streetlights hum
        [00:16.8]One digit
        [01:02.345]Millis
        [02:03]No fraction
        [03:04:50]Colon fraction
        """)
        #expect(lines.map(\.text) == ["Streetlights hum", "One digit", "Millis", "No fraction", "Colon fraction"])
        #expect(abs(lines[0].time - 12.40) < 1e-9)
        #expect(abs(lines[1].time - 16.8) < 1e-9)
        #expect(abs(lines[2].time - 62.345) < 1e-9)
        #expect(lines[3].time == 123)
        #expect(abs(lines[4].time - 184.5) < 1e-9)
    }

    @Test func multipleTimestampsPerLineAreSorted() {
        let lines = LRC.parse("""
        [00:10.00][00:40.00]Chorus
        [00:20.00]Verse
        """)
        #expect(lines.map(\.time) == [10, 20, 40])
        #expect(lines.map(\.text) == ["Chorus", "Verse", "Chorus"])
    }

    @Test func emptyLinesAreBreaksAndBlankOnesAreSkipped() {
        let lines = LRC.parse("[00:01.00]Hello\n\n[00:05.00]\n   \n[00:09.00] World  ")
        #expect(lines.count == 3)
        #expect(lines[1] == LyricLine(time: 5, text: ""))
        #expect(lines[2].text == "World")
    }

    @Test func offsetShiftsEarlierAndMetadataIsIgnored() {
        let lines = LRC.parse("""
        [ar:Paper Lanterns]
        [ti:Golden Hour Drive]
        [length:03:56]
        [offset:+500]
        [00:10.00]Line
        [00:00.20]Clamped
        """)
        #expect(lines.count == 2)
        #expect(lines[0] == LyricLine(time: 0, text: "Clamped"))
        #expect(abs(lines[1].time - 9.5) < 1e-9)
        let later = LRC.parse("[offset:-250]\n[00:10.00]Line")
        #expect(abs(later[0].time - 10.25) < 1e-9)
    }

    @Test func wordStampsAndGarbage() {
        let lines = LRC.parse("""
        [00:01.00]<00:01.00>Every <00:01.50>mile
        not a lyric line
        [xx:yy]bad stamp
        [00:61.00]bad seconds
        [00:02.00]Text with [brackets] inside
        """)
        #expect(lines.map(\.text) == ["Every mile", "Text with [brackets] inside"])
    }

    @Test func serializeRoundTrips() {
        let lines = [LyricLine(time: 0, text: ""), LyricLine(time: 12.4, text: "a"), LyricLine(time: 75.05, text: "b")]
        let back = LRC.parse(LyricsCache.serialize(lines))
        #expect(back.count == 3)
        for (a, b) in zip(lines, back) { #expect(abs(a.time - b.time) < 0.006 && a.text == b.text) }
    }
}

// MARK: - Timeline

@Suite struct LyricsTimelineTests {
    let lines = [LyricLine(time: 5, text: "a"), LyricLine(time: 10, text: "b"), LyricLine(time: 10, text: "b2"),
                 LyricLine(time: 20, text: "c")]

    @Test func lineAtTime() {
        #expect(LyricsTimeline.index(in: lines, at: 0) == nil)
        #expect(LyricsTimeline.index(in: lines, at: 4.99) == nil)
        #expect(LyricsTimeline.index(in: lines, at: 5) == 0)
        #expect(LyricsTimeline.index(in: lines, at: 9.9) == 0)
        #expect(LyricsTimeline.index(in: lines, at: 10) == 2)
        #expect(LyricsTimeline.index(in: lines, at: 19) == 2)
        #expect(LyricsTimeline.index(in: lines, at: 500) == 3)
        #expect(LyricsTimeline.index(in: [], at: 3) == nil)
    }

    @Test func nextLineTime() {
        #expect(LyricsTimeline.nextTime(in: lines, after: 0) == 5)
        #expect(LyricsTimeline.nextTime(in: lines, after: 5) == 10)
        #expect(LyricsTimeline.nextTime(in: lines, after: 10) == 20)
        #expect(LyricsTimeline.nextTime(in: lines, after: 20) == nil)
    }

    @Test func wakeDelayFollowsRateAndPauses() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        // 3 s into the track, read 1 s later: position 4, next line at 5 → 1 s.
        let d = LyricsTimeline.delayToNextLine(lines, info: track(elapsed: 3, at: t0), now: t0.addingTimeInterval(1))
        #expect(abs((d ?? -1) - 1) < 1e-9)
        // Double speed: half the wall time.
        let fast = LyricsTimeline.delayToNextLine(lines, info: track(elapsed: 3, at: t0, rate: 2), now: t0)
        #expect(abs((fast ?? -1) - 1) < 1e-9)
        // Paused, past the last line, or no timing at all: nothing to wake for.
        #expect(LyricsTimeline.delayToNextLine(lines, info: track(playing: false, elapsed: 3, at: t0), now: t0) == nil)
        #expect(LyricsTimeline.delayToNextLine(lines, info: track(elapsed: 25, at: t0), now: t0) == nil)
        var untimed = track(at: t0); untimed.elapsed = nil
        #expect(LyricsTimeline.delayToNextLine(lines, info: untimed, now: t0) == nil)
        // A line stamped past the track's end never wakes.
        #expect(LyricsTimeline.delayToNextLine(lines, info: track(elapsed: 12, at: t0, duration: 15), now: t0) == nil)
    }
}

// MARK: - LRCLIB client (stubbed transport, never the network)

private final class StubTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URL] = []
    var responses: [String: (Int, String)] = [:]   // path suffix → status, body
    var failure: Error?
    var requests: [URL] { lock.withLock { _requests } }

    var transport: LRCLIBClient.Transport {
        { [self] req in
            lock.withLock { _requests.append(req.url!) }
            if let failure { throw failure }
            let path = req.url!.path
            let (status, body) = responses.first { path.hasSuffix($0.key) }?.value ?? (404, "{}")
            return (Data(body.utf8), HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
}

@Suite struct LRCLIBClientTests {
    let query = LyricsQuery(title: "Golden Hour Drive", artist: "Paper Lanterns", album: "Night Roads", duration: 236.4)

    @Test func getURLCarriesEveryField() throws {
        let url = LRCLIBClient.getURL(query)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(url.host == "lrclib.net" && url.path == "/api/get")
        #expect(items.first { $0.name == "artist_name" }?.value == "Paper Lanterns")
        #expect(items.first { $0.name == "track_name" }?.value == "Golden Hour Drive")
        #expect(items.first { $0.name == "album_name" }?.value == "Night Roads")
        #expect(items.first { $0.name == "duration" }?.value == "236")
    }

    @Test func exactMatchWithSyncedLyrics() async throws {
        let stub = StubTransport()
        stub.responses["/api/get"] = (200, #"{"id":1,"instrumental":false,"plainLyrics":"a\nb","syncedLyrics":"[00:01.00]a\n[00:02.00]b"}"#)
        let r = try await LRCLIBClient(transport: stub.transport).lyrics(for: query)
        #expect(r == .synced([LyricLine(time: 1, text: "a"), LyricLine(time: 2, text: "b")]))
        #expect(stub.requests.count == 1)
    }

    @Test func notFoundFallsBackToSearchClosestDuration() async throws {
        let stub = StubTransport()
        stub.responses["/api/get"] = (404, #"{"code":404,"name":"TrackNotFound"}"#)
        stub.responses["/api/search"] = (200, #"""
        [{"duration":300,"syncedLyrics":"[00:01.00]wrong length"},
         {"duration":235,"plainLyrics":"plain only","syncedLyrics":null},
         {"duration":237,"syncedLyrics":"[00:01.00]right"}]
        """#)
        let r = try await LRCLIBClient(transport: stub.transport).lyrics(for: query)
        #expect(r == .synced([LyricLine(time: 1, text: "right")]))
        #expect(stub.requests.map(\.path) == ["/api/get", "/api/search"])
    }

    @Test func instrumentalPlainAndNothing() async throws {
        #expect(LRCLIBClient.content(["instrumental": true, "plainLyrics": NSNull(), "syncedLyrics": NSNull()]) == .instrumental)
        #expect(LRCLIBClient.content(["plainLyrics": " words \n"]) == .plain("words"))
        #expect(LRCLIBClient.content(["syncedLyrics": "[00:01.00]\n[00:02.00]"]) == .notFound)
        let stub = StubTransport()
        stub.responses["/api/search"] = (200, "[]")
        #expect(try await LRCLIBClient(transport: stub.transport).lyrics(for: query) == .notFound)
    }

    @Test func serverErrorsAndNoConnectionAreOffline() async {
        let stub = StubTransport()
        stub.responses["/api/get"] = (503, "busy")
        await #expect(throws: LyricsError.offline) { try await LRCLIBClient(transport: stub.transport).lyrics(for: query) }
        let down = StubTransport()
        down.failure = URLError(.notConnectedToInternet)
        await #expect(throws: LyricsError.offline) { try await LRCLIBClient(transport: down.transport).lyrics(for: query) }
    }

    @Test func noArtistNoQuery() {
        let t0 = Date()
        var i = track(at: t0); i.artist = nil
        #expect(LyricsQuery(i) == nil)
        #expect(LyricsQuery(track(at: t0))?.cacheKey == LyricsQuery(track(at: t0, duration: 236.3))?.cacheKey)
        #expect(LyricsQuery(track(at: t0))?.cacheKey != LyricsQuery(track("Other", at: t0))?.cacheKey)
    }
}

// MARK: - Cache

@Suite struct LyricsCacheTests {
    func q(_ n: Int) -> LyricsQuery { LyricsQuery(title: "Song \(n)", artist: "A", album: nil, duration: 200) }

    @Test func roundTripsEveryKind() async {
        let cache = LyricsCache(directory: tempDir("rt"))
        let synced = LyricsContent.synced([LyricLine(time: 1, text: "a"), LyricLine(time: 2.5, text: "")])
        await cache.put(synced, for: q(1))
        await cache.put(.plain("words"), for: q(2))
        await cache.put(.instrumental, for: q(3))
        #expect(await cache.get(q(1)) == synced)
        #expect(await cache.get(q(2)) == .plain("words"))
        #expect(await cache.get(q(3)) == .instrumental)
        #expect(await cache.get(q(4)) == nil)
    }

    @Test func leastRecentlyUsedIsDropped() async {
        let cache = LyricsCache(directory: tempDir("lru"), limit: 3)
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        for n in 1...3 { await cache.put(.plain("\(n)"), for: q(n), now: t.addingTimeInterval(Double(n))) }
        // Reading 1 makes it the freshest; adding 4 drops 2.
        _ = await cache.get(q(1), now: t.addingTimeInterval(10))
        await cache.put(.plain("4"), for: q(4), now: t.addingTimeInterval(11))
        #expect(await cache.count() == 3)
        #expect(await cache.get(q(2), now: t.addingTimeInterval(12)) == nil)
        #expect(await cache.get(q(1), now: t.addingTimeInterval(12)) == .plain("1"))
    }

    @Test func notFoundExpires() async {
        let cache = LyricsCache(directory: tempDir("ttl"), notFoundTTL: 100)
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        await cache.put(.notFound, for: q(1), now: t)
        #expect(await cache.get(q(1), now: t.addingTimeInterval(50)) == .notFound)
        #expect(await cache.get(q(1), now: t.addingTimeInterval(200)) == nil)
    }
}

// MARK: - Controller: one lookup per track, one wake per line, only while seen

private actor CountingProvider: LyricsProvider {
    var calls = 0
    var result: Result<LyricsContent, LyricsError>
    init(_ r: Result<LyricsContent, LyricsError>) { result = r }
    func lyrics(for query: LyricsQuery) async throws -> LyricsContent {
        calls += 1
        return try result.get()
    }
}

@MainActor
@Suite struct LyricsControllerTests {
    let lines = [LyricLine(time: 10, text: "one"), LyricLine(time: 14, text: "two"), LyricLine(time: 20, text: "three")]

    func settle() async { for _ in 0..<20 { await Task.yield() }; try? await Task.sleep(for: .milliseconds(30)) }

    @Test func looksUpOnlyWhenSeenAndOncePerTrack() async {
        let provider = CountingProvider(.success(.synced(lines)))
        let cache = LyricsCache(directory: tempDir("ctl"))
        let t0 = Date()
        let c = LyricsController(settings: freshSettings(), provider: provider, cache: cache, debounce: .zero, now: { t0 })
        c.update(track(elapsed: 11, at: t0))
        c.visibility(.collapsed)
        await settle()
        #expect(await provider.calls == 0)          // tab closed, wing off: nothing leaves the Mac
        c.visibility(.expanded(.media))
        await settle()
        #expect(await provider.calls == 1)
        #expect(c.model.lines == lines)
        #expect(c.model.index == 0)
        c.visibility(.collapsed); c.visibility(.expanded(.media))
        c.update(track(elapsed: 12, at: t0))        // a fresh timestamp, same track
        await settle()
        #expect(await provider.calls == 1)
        // The next track: a new lookup.
        c.update(track("Second", elapsed: 0, at: t0))
        await settle()
        #expect(await provider.calls == 2)
        // The first track again: served from the cache.
        c.update(track(elapsed: 11, at: t0))
        await settle()
        #expect(await provider.calls == 2)
        #expect(c.model.lines == lines)
        c.stop()
    }

    @Test func schedulesOneWakeAtTheNextLineOnlyWhileSeenAndPlaying() async {
        let provider = CountingProvider(.success(.synced(lines)))
        let t0 = Date()
        let settings = freshSettings()
        let c = LyricsController(settings: settings, provider: provider, cache: nil, debounce: .zero, now: { t0 })
        c.visibility(.expanded(.media))
        c.update(track(elapsed: 11, at: t0))
        await settle()
        // Position 11 → line 0, next at 14: 3 s (+30 ms).
        #expect(c.model.index == 0)
        #expect(abs((c.nextWake?.timeIntervalSince(t0) ?? -1) - 3.03) < 1e-6)
        // Paused: no wake.
        c.update(track(playing: false, elapsed: 11, at: t0))
        #expect(c.nextWake == nil)
        c.update(track(elapsed: 15, at: t0))
        #expect(c.model.index == 1)
        #expect(abs((c.nextWake?.timeIntervalSince(t0) ?? -1) - 5.03) < 1e-6)
        // Another tab: no wake. Collapsed with the wing off: none either.
        c.visibility(.expanded(.calendar))
        #expect(c.nextWake == nil)
        c.visibility(.collapsed)
        #expect(c.nextWake == nil)
        #expect(!c.wingActive)
        // The wing on: collapsed and playing ticks.
        settings.wingEnabled = true
        c.settingsChanged()
        #expect(c.wingActive)
        #expect(c.nextWake != nil)
        c.visibility(.hidden)
        #expect(c.nextWake == nil)
        c.stop()
    }

    @Test func wakeFiresAndAdvancesTheLine() async throws {
        let start = Date()
        let close = [LyricLine(time: 1.00, text: "a"), LyricLine(time: 1.6, text: "b"), LyricLine(time: 60, text: "c")]
        let provider = CountingProvider(.success(.synced(close)))
        let c = LyricsController(settings: freshSettings(), provider: provider, cache: nil, debounce: .zero)
        c.visibility(.expanded(.media))
        c.update(track(elapsed: 1.0, at: start))
        await settle()
        #expect(c.model.lines == close)
        // A fresh timestamp 0.15 s before line "b": one wake lands on it (polled: busy machines are slow).
        c.update(track(elapsed: 1.45, at: Date()))
        #expect(c.model.index == 0)
        for _ in 0..<200 where c.wakes == 0 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(c.wakes == 1)
        #expect(c.model.index == 1)
        c.stop()
        #expect(c.nextWake == nil)
    }

    @Test func offlineIsShownAndNotCached() async {
        let provider = CountingProvider(.failure(.offline))
        let cache = LyricsCache(directory: tempDir("offline"))
        let t0 = Date()
        let c = LyricsController(settings: freshSettings(), provider: provider, cache: cache, debounce: .zero, now: { t0 })
        c.visibility(.expanded(.media))
        c.update(track(elapsed: 3, at: t0))
        await settle()
        #expect(c.model.state == .offline)
        #expect(await cache.count() == 0)
        #expect(!c.model.hasWords)
        c.stop()
    }

    @Test func offWhenBothSettingsOff() async {
        let provider = CountingProvider(.success(.synced(lines)))
        let settings = freshSettings()
        settings.tabEnabled = false
        let c = LyricsController(settings: settings, provider: provider, cache: nil, debounce: .zero)
        c.visibility(.expanded(.media))
        c.update(track(elapsed: 3, at: .now))
        await settle()
        #expect(await provider.calls == 0)
        #expect(c.model.state == .idle)
    }

    @Test func wingTextShowsNoteGlyphInBreaks() {
        let m = LyricsModel()
        m.state = .ready(.synced([LyricLine(time: 1, text: "hi"), LyricLine(time: 2, text: "")]))
        #expect(m.currentText == "♪")
        m.index = 0
        #expect(m.currentText == "hi")
        m.index = 1
        #expect(m.currentText == "♪")
    }
}
