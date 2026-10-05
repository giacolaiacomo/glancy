import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import GlancyKit

private func line(_ s: String) -> Data { Data(s.utf8) }

private func info(_ u: AdapterUpdate?) -> NowPlayingInfo? {
    if case .info(let i) = u { return i }
    return nil
}

// MARK: - Adapter lines

@Suite struct MediaAdapterParsingTests {
    @Test func spotifyPlayingWithMicros() throws {
        let l = line(#"{"type":"data","diff":false,"payload":{"bundleIdentifier":"com.spotify.client","processIdentifier":4211,"playing":true,"title":"Nightswimming","artist":"R.E.M.","album":"Automatic for the People","durationMicros":258000000,"elapsedTimeMicros":61234567,"timestampEpochMicros":1759658400000000,"playbackRate":1,"isMusicApp":false,"shuffleMode":1,"repeatMode":1,"trackNumber":10,"uniqueIdentifier":"spotify:track:x","mediaType":"MRMediaRemoteMediaTypeMusic"}}"#)
        let i = try #require(info(AdapterParser.parseStreamLine(l)))
        #expect(i.bundleID == "com.spotify.client")
        #expect(i.pid == 4211)
        #expect(i.playing)
        #expect(i.title == "Nightswimming")
        #expect(i.artist == "R.E.M.")
        #expect(i.album == "Automatic for the People")
        #expect(i.duration == 258)
        #expect(abs((i.elapsed ?? 0) - 61.234567) < 1e-9)
        #expect(i.timestamp == Date(timeIntervalSince1970: 1_759_658_400))
        #expect(i.rate == 1)
        #expect(i.appBundleID == "com.spotify.client")
    }

    @Test func safariThroughWebKitHelperWithISOTimestamp() throws {
        let l = line(#"{"type":"data","diff":false,"payload":{"bundleIdentifier":"com.apple.WebKit.GPU","parentApplicationBundleIdentifier":"com.apple.Safari","playing":false,"title":"Lo-fi beats to code to","artist":"Lofi Girl","duration":3600.5,"elapsedTime":12.25,"timestamp":"2026-10-05T10:00:00Z","playbackRate":0}}"#)
        let i = try #require(info(AdapterParser.parseStreamLine(l)))
        #expect(i.bundleID == "com.apple.WebKit.GPU")
        #expect(i.parentBundleID == "com.apple.Safari")
        #expect(i.appBundleID == "com.apple.Safari")
        #expect(!i.playing)
        #expect(i.album == nil)
        #expect(i.duration == 3600.5)
        #expect(i.elapsed == 12.25)
        let iso = ISO8601DateFormatter().date(from: "2026-10-05T10:00:00Z")
        #expect(i.timestamp == iso)
        #expect(i.effectiveRate == 0)
    }

    @Test func missingOptionalFieldsAndNulls() throws {
        // A live radio stream: no duration, null artist, empty album, no timing at all.
        let l = line(#"{"type":"data","diff":false,"payload":{"bundleIdentifier":"com.apple.Music","playing":true,"title":"Radio 1","artist":null,"album":"","duration":0}}"#)
        let i = try #require(info(AdapterParser.parseStreamLine(l)))
        #expect(i.artist == nil)
        #expect(i.album == nil)
        #expect(i.duration == nil)
        #expect(i.elapsed == nil)
        #expect(i.timestamp == nil)
        #expect(i.rate == nil)
        #expect(i.effectiveRate == 1)
        #expect(i.position(at: .now) == nil)
    }

    @Test func emptyPayloadMeansNothingPlaying() {
        // Real output on this Mac with nothing playing (macOS 26.6.2).
        #expect(AdapterParser.parseStreamLine(line(#"{"type":"data","diff":false,"payload":{}}"#)) == .nothing)
        #expect(AdapterParser.parseStreamLine(line(#"{"type":"data","diff":false,"payload":null}"#)) == .nothing)
    }

    @Test func missingMandatoryKeysMeanNothing() {
        #expect(AdapterParser.parseStreamLine(line(#"{"type":"data","diff":false,"payload":{"bundleIdentifier":"com.apple.Music","playing":true}}"#)) == .nothing)
        #expect(AdapterParser.parseStreamLine(line(#"{"type":"data","diff":false,"payload":{"title":"Orphan","playing":true}}"#)) == .nothing)
        #expect(AdapterParser.parseStreamLine(line(#"{"type":"data","diff":false,"payload":{"bundleIdentifier":"x","title":"   ","playing":true}}"#)) == .nothing)
    }

    @Test func garbageAndOtherTypesAreIgnored() {
        #expect(AdapterParser.parseStreamLine(line("")) == nil)
        #expect(AdapterParser.parseStreamLine(line("not json")) == nil)
        #expect(AdapterParser.parseStreamLine(line(#"{"type":"error","message":"x"}"#)) == nil)
        #expect(AdapterParser.parseStreamLine(line("[1,2,3]")) == nil)
        #expect(AdapterParser.parseStreamLine(line(#"{"type":"data","diff":false}"#)) == nil)
    }

    @Test func playingDefaultsToFalseWhenAbsent() throws {
        let i = try #require(info(AdapterParser.parseStreamLine(line(#"{"type":"data","payload":{"bundleIdentifier":"org.videolan.vlc","title":"movie.mkv"}}"#))))
        #expect(!i.playing)
    }

    @Test func getOutputNullAndArtwork() throws {
        #expect(AdapterParser.parseGet(line("null\n"))?.update == .nothing)
        #expect(AdapterParser.parseGet(line("")) == nil)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let json = #"{"bundleIdentifier":"com.apple.Music","playing":true,"title":"Song","artworkMimeType":"image/png","artworkData":"\#(png.base64EncodedString())"}"# + "\n"
        let r = try #require(AdapterParser.parseGet(line(json)))
        #expect(info(r.update)?.title == "Song")
        #expect(r.artwork == png)
    }

    @Test func trackKeyIgnoresTimingButNotIdentity() throws {
        let a = NowPlayingInfo(bundleID: "b", playing: true, title: "T", artist: "A", elapsed: 1, timestamp: .now)
        var b = a
        b.elapsed = 99; b.playing = false
        #expect(a.trackKey == b.trackKey)
        b.title = "T2"
        #expect(a.trackKey != b.trackKey)
    }
}

// MARK: - Player pushes

@Suite struct MediaPlayerNotificationTests {
    @Test func musicPlayerInfo() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let ui: [AnyHashable: Any] = ["Player State": "Playing", "Name": "Everybody Hurts", "Artist": "R.E.M.",
                                      "Album": "Automatic for the People", "Total Time": NSNumber(value: 320_000),
                                      "PersistentID": NSNumber(value: 123)]
        let i = try #require(PlayerNotification.parse(name: PlayerNotification.music, userInfo: ui, now: now))
        #expect(i.bundleID == "com.apple.Music")
        #expect(i.playing)
        #expect(i.duration == 320)
        #expect(i.elapsed == nil)  // Music's push has no position
    }

    @Test func spotifyPlaybackStateChanged() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let ui: [AnyHashable: Any] = ["Player State": "Paused", "Name": "Losing My Religion", "Artist": "R.E.M.",
                                      "Album": "Out of Time", "Duration": NSNumber(value: 268_000),
                                      "Playback Position": NSNumber(value: 42.5), "Track ID": "spotify:track:1"]
        let i = try #require(PlayerNotification.parse(name: PlayerNotification.spotify, userInfo: ui, now: now))
        #expect(i.bundleID == "com.spotify.client")
        #expect(!i.playing)
        #expect(i.duration == 268)
        #expect(i.position(at: now.addingTimeInterval(30)) == 42.5)
    }

    @Test func stoppedIsNil() {
        #expect(PlayerNotification.parse(name: PlayerNotification.music, userInfo: ["Player State": "Stopped"]) == nil)
        #expect(PlayerNotification.parse(name: PlayerNotification.spotify, userInfo: ["Player State": "Playing"]) == nil)
    }
}

// MARK: - Progress maths

@Suite struct MediaProgressTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func advancesWithRateWhilePlaying() {
        let i = NowPlayingInfo(bundleID: "b", playing: true, title: "T", duration: 200, elapsed: 50, timestamp: t0, rate: 1)
        #expect(i.position(at: t0) == 50)
        #expect(i.position(at: t0.addingTimeInterval(10)) == 60)
        #expect(i.fraction(at: t0.addingTimeInterval(50)) == 0.5)
    }

    @Test func doubleSpeed() {
        let i = NowPlayingInfo(bundleID: "b", playing: true, title: "T", duration: 3600, elapsed: 100, timestamp: t0, rate: 2)
        #expect(i.position(at: t0.addingTimeInterval(10)) == 120)
    }

    @Test func pausedStandsStill() {
        let i = NowPlayingInfo(bundleID: "b", playing: false, title: "T", duration: 200, elapsed: 50, timestamp: t0, rate: 1)
        #expect(i.position(at: t0.addingTimeInterval(1000)) == 50)
    }

    @Test func playingWithRateZeroReportedStillAdvances() {
        // Some players report playing=true with rate 0 for a moment; trust `playing`.
        let i = NowPlayingInfo(bundleID: "b", playing: true, title: "T", duration: 200, elapsed: 0, timestamp: t0, rate: 0)
        #expect(i.position(at: t0.addingTimeInterval(3)) == 3)
    }

    @Test func clampsToDurationAndZero() {
        let i = NowPlayingInfo(bundleID: "b", playing: true, title: "T", duration: 200, elapsed: 190, timestamp: t0, rate: 1)
        #expect(i.position(at: t0.addingTimeInterval(60)) == 200)
        #expect(i.fraction(at: t0.addingTimeInterval(60)) == 1)
        // A timestamp in the future (clock skew) never moves it backwards.
        #expect(i.position(at: t0.addingTimeInterval(-30)) == 190)
        let neg = NowPlayingInfo(bundleID: "b", playing: false, title: "T", duration: 200, elapsed: -3)
        #expect(neg.position(at: t0) == 0)
    }

    @Test func noTimestampIsStatic() {
        let i = NowPlayingInfo(bundleID: "b", playing: true, title: "T", duration: 200, elapsed: 30)
        #expect(i.position(at: t0) == 30)
    }

    @Test func noDurationNoFraction() {
        let i = NowPlayingInfo(bundleID: "b", playing: true, title: "T", elapsed: 30, timestamp: t0)
        #expect(i.fraction(at: t0) == nil)
        #expect(i.position(at: t0.addingTimeInterval(5)) == 35)
    }

    @Test func clockFormatting() {
        #expect(NowPlayingInfo.clock(0) == "0:00")
        #expect(NowPlayingInfo.clock(59.9) == "0:59")
        #expect(NowPlayingInfo.clock(187) == "3:07")
        #expect(NowPlayingInfo.clock(3723) == "1:02:03")
        #expect(NowPlayingInfo.clock(-4) == "0:00")
    }
}

// MARK: - State machine

@Suite struct MediaSessionTests {
    let t0 = Date(timeIntervalSince1970: 2_000_000)

    func track(_ title: String, playing: Bool = true, bundle: String = "com.spotify.client", pid: Int32? = 42) -> NowPlayingInfo {
        NowPlayingInfo(bundleID: bundle, pid: pid, playing: playing, title: title, artist: "Artist", duration: 200,
                       elapsed: 0, timestamp: t0, rate: playing ? 1 : 0)
    }

    @Test func firstTrackAfterLaunchDoesNotPeek() {
        var s = MediaSession()
        let c = s.apply(track("One"), now: t0)
        #expect(c.changed && c.trackChanged)
        #expect(!c.peek)
        #expect(s.phase == .playing)
        #expect(s.showsActivity(at: t0))
    }

    @Test func nextTrackPeeksSameTrackDoesNot() {
        var s = MediaSession()
        s.apply(track("One"), now: t0)
        var progressed = track("One"); progressed.elapsed = 10
        let same = s.apply(progressed, now: t0.addingTimeInterval(10))
        #expect(!same.trackChanged && !same.peek)
        let next = s.apply(track("Two"), now: t0.addingTimeInterval(11))
        #expect(next.trackChanged && next.peek)
    }

    @Test func trackChangeWhilePausedDoesNotPeek() {
        var s = MediaSession()
        s.apply(track("One"), now: t0)
        let c = s.apply(track("Two", playing: false), now: t0.addingTimeInterval(5))
        #expect(c.trackChanged && !c.peek)
    }

    @Test func pauseKeepsItsStartAndExpiresAfterFiveMinutes() {
        var s = MediaSession()
        s.apply(track("One"), now: t0)
        let p = s.apply(track("One", playing: false), now: t0.addingTimeInterval(10))
        #expect(p.changed && !p.trackChanged)
        let since = t0.addingTimeInterval(10)
        #expect(s.phase == .paused(since: since))
        // Another paused line later (debounced metadata) must not restart the clock.
        s.apply(track("One", playing: false), now: t0.addingTimeInterval(100))
        #expect(s.phase == .paused(since: since))
        #expect(s.pausedDeadline == since.addingTimeInterval(300))
        #expect(s.showsActivity(at: since.addingTimeInterval(299)))
        #expect(!s.showsActivity(at: since.addingTimeInterval(300)))
        #expect(s.wantsStream(at: since.addingTimeInterval(299)))
        #expect(!s.wantsStream(at: since.addingTimeInterval(301)))
        #expect(!s.expireIfPausedTooLong(now: since.addingTimeInterval(200)).cleared)
        let e = s.expireIfPausedTooLong(now: since.addingTimeInterval(301))
        #expect(e.cleared)
        #expect(s.info == nil && s.phase == .none)
    }

    @Test func resumeGoesBackToPlaying() {
        var s = MediaSession()
        s.apply(track("One"), now: t0)
        s.apply(track("One", playing: false), now: t0.addingTimeInterval(10))
        let r = s.apply(track("One"), now: t0.addingTimeInterval(20))
        #expect(r.changed && !r.peek)
        #expect(s.phase == .playing)
        #expect(s.pausedDeadline == nil)
    }

    @Test func stopClearsAndStartsTheNoPlayerClock() {
        var s = MediaSession()
        s.apply(track("One"), now: t0)
        let c = s.apply(.nothing, now: t0.addingTimeInterval(30))
        #expect(c.cleared && c.changed)
        #expect(s.info == nil && s.phase == .none)
        #expect(s.noPlayerSince == t0.addingTimeInterval(30))
        // Repeated empty payloads don't move the clock.
        let again = s.apply(.nothing, now: t0.addingTimeInterval(60))
        #expect(!again.changed)
        #expect(s.noPlayerSince == t0.addingTimeInterval(30))
        #expect(s.wantsStream(at: t0.addingTimeInterval(329)))
        #expect(!s.wantsStream(at: t0.addingTimeInterval(331)))
        // A restarted stream gets the full grace period again.
        s.restartNoPlayerClock(now: t0.addingTimeInterval(1000))
        #expect(s.wantsStream(at: t0.addingTimeInterval(1200)))
    }

    @Test func launchWithNothingPlaying() {
        var s = MediaSession()
        #expect(s.wantsStream(at: t0))  // nothing known yet: learn the state
        let c = s.apply(.nothing, now: t0)
        #expect(!c.changed)
        #expect(s.noPlayerSince == t0)
        #expect(!s.showsActivity(at: t0))
    }

    @Test func sourceAppQuitClearsAndIgnoresLateLines() {
        var s = MediaSession()
        s.apply(track("One"), now: t0)
        #expect(!s.appTerminated(bundleID: "com.apple.Music", now: t0).changed)  // someone else
        let q = s.appTerminated(bundleID: "com.spotify.client", pid: 42, now: t0.addingTimeInterval(1))
        #expect(q.cleared)
        #expect(s.info == nil)
        // The adapter's debounced last line from the dead app arrives late: ignored.
        let late = s.apply(track("One"), now: t0.addingTimeInterval(1.3))
        #expect(!late.changed)
        #expect(s.info == nil)
        // After the grace period (Spotify relaunched) it shows again, and that is a new track.
        let back = s.apply(track("One", pid: 99), now: t0.addingTimeInterval(10))
        #expect(back.changed && back.trackChanged)
    }

    @Test func helperProcessQuitMatchesByParentOrPid() {
        var s = MediaSession()
        s.apply(NowPlayingInfo(bundleID: "com.apple.WebKit.GPU", parentBundleID: "com.apple.Safari", pid: 7,
                               playing: true, title: "Video"), now: t0)
        #expect(s.appTerminated(bundleID: "com.apple.Safari", now: t0).cleared)
        s.apply(NowPlayingInfo(bundleID: "com.google.Chrome.helper", pid: 8, playing: true, title: "Video 2"), now: t0.addingTimeInterval(10))
        #expect(s.appTerminated(bundleID: "com.google.Chrome", pid: 8, now: t0.addingTimeInterval(11)).cleared)
    }

    @Test func optimisticCommands() {
        var s = MediaSession()
        s.apply(track("One"), now: t0)
        s.assume(playing: false, now: t0.addingTimeInterval(30))
        #expect(s.phase == .paused(since: t0.addingTimeInterval(30)))
        #expect(s.info?.position(at: t0.addingTimeInterval(100)) == 30)
        s.assume(playing: true, now: t0.addingTimeInterval(40))
        #expect(s.info?.position(at: t0.addingTimeInterval(45)) == 35)
        s.assume(position: 120, now: t0.addingTimeInterval(50))
        #expect(s.info?.position(at: t0.addingTimeInterval(51)) == 121)
    }
}

// MARK: - Artwork

@Suite struct MediaArtworkTests {
    /// A PNG, left half red, right half blue.
    func makePNG(width: Int, height: Int, left: (CGFloat, CGFloat, CGFloat), right: (CGFloat, CGFloat, CGFloat)) throws -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: left.0, green: left.1, blue: left.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        ctx.setFillColor(CGColor(srgbRed: right.0, green: right.1, blue: right.2, alpha: 1))
        ctx.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        let image = try #require(ctx.makeImage())
        let data = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return data as Data
    }

    @Test func downsamplesToTheLongSide() throws {
        let png = try makePNG(width: 1200, height: 800, left: (1, 0, 0), right: (0, 0, 1))
        let d = try #require(Artwork.decode(png))
        #expect(d.image.width == 300)
        #expect(d.image.height == 200)
        let small = try #require(Artwork.thumbnail(png, maxPixelSize: 16))
        #expect(max(small.width, small.height) == 16)
    }

    @Test func averageColourOfTwoHalves() throws {
        let png = try makePNG(width: 600, height: 600, left: (1, 0, 0), right: (0, 0, 1))
        let thumb = try #require(Artwork.thumbnail(png, maxPixelSize: 16))
        let avg = try #require(Artwork.averageColor(thumb))
        #expect(abs(avg.r - 0.5) < 0.06)
        #expect(avg.g < 0.05)
        #expect(abs(avg.b - 0.5) < 0.06)
    }

    @Test func tintIsLegibleOnBlack() throws {
        let png = try makePNG(width: 300, height: 300, left: (0.10, 0.04, 0.02), right: (0.12, 0.05, 0.03))
        let d = try #require(Artwork.decode(png))
        let (_, s, v) = Artwork.hsv(d.tint)
        #expect(v >= 0.71)
        #expect(s <= 0.76)
        #expect(d.tint.r > d.tint.b)  // keeps its warm hue
        // Grey stays grey.
        let g = Artwork.legibleTint(.init(r: 0.2, g: 0.2, b: 0.21))
        #expect(abs(g.r - g.b) < 0.01)
    }

    @Test func garbageIsNil() {
        #expect(Artwork.decode(Data([1, 2, 3, 4])) == nil)
    }
}

// MARK: - The real adapter (only when built: build/mediaremote-adapter via cmake)

@Suite struct MediaAdapterLiveTests {
    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var updates: [AdapterUpdate] = []
        var exits: [Bool] = []
    }

    @Test(.disabled(if: CI.isCI, "real MediaRemote through perl: needs a logged-in Mac"))
    func healthCheckAndStreamRoundTrip() async throws {
        guard let adapter = MediaAdapter.locate() else { return }  // not built here: nothing to check
        #expect(await adapter.healthCheck())
        let box = Box()
        let stream = AdapterStream()
        let started = stream.start(adapter, onUpdate: { u in box.lock.withLock { box.updates.append(u) } },
                                   onExit: { e in box.lock.withLock { box.exits.append(e) } })
        #expect(started)
        #expect(stream.isRunning)
        // The stream prints the current state right away (debounce 200 ms).
        for _ in 0..<50 where box.lock.withLock({ box.updates.isEmpty }) { try await Task.sleep(for: .milliseconds(100)) }
        #expect(!box.lock.withLock { box.updates.isEmpty })
        stream.stop()
        for _ in 0..<30 where box.lock.withLock({ box.exits.isEmpty }) { try await Task.sleep(for: .milliseconds(100)) }
        #expect(box.lock.withLock { box.exits } == [true])
        #expect(!stream.isRunning)
        #expect(!FileManager.default.fileExists(atPath: AdapterStream.pidFile.path))
    }
}
