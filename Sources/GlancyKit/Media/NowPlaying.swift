import Foundation

/// What a player reports as playing. Values only; built from an adapter line, a Music/Spotify
/// distributed notification or an AppleScript reply.
public struct NowPlayingInfo: Equatable, Sendable {
    public var bundleID: String
    /// The app that owns the player when `bundleID` is a helper (Safari's WebKit GPU process).
    public var parentBundleID: String?
    public var pid: Int32?
    public var playing: Bool
    public var title: String
    public var artist: String?
    public var album: String?
    /// Seconds; nil for live streams and players that don't say.
    public var duration: TimeInterval?
    /// Elapsed seconds at `timestamp`.
    public var elapsed: TimeInterval?
    public var timestamp: Date?
    /// 1 while playing at normal speed, 0 when paused; nil = unknown (derived from `playing`).
    public var rate: Double?

    public init(bundleID: String, parentBundleID: String? = nil, pid: Int32? = nil, playing: Bool, title: String,
                artist: String? = nil, album: String? = nil, duration: TimeInterval? = nil,
                elapsed: TimeInterval? = nil, timestamp: Date? = nil, rate: Double? = nil) {
        self.bundleID = bundleID; self.parentBundleID = parentBundleID; self.pid = pid; self.playing = playing
        self.title = title; self.artist = artist; self.album = album; self.duration = duration
        self.elapsed = elapsed; self.timestamp = timestamp; self.rate = rate
    }

    /// The app the user thinks of as the player (Safari rather than its GPU helper).
    public var appBundleID: String { parentBundleID ?? bundleID }

    /// Identity of the track: a change means a new track (peek, new artwork).
    public var trackKey: String {
        [appBundleID, title, artist ?? "", album ?? ""].joined(separator: "\u{1F}")
    }

    /// The speed playback advances at right now.
    public var effectiveRate: Double { playing ? (rate.map { $0 > 0 ? $0 : 1 } ?? 1) : 0 }

    /// Elapsed seconds at `now`: `elapsed + (now − timestamp) × rate`, clamped to `[0, duration]`.
    public func position(at now: Date) -> TimeInterval? {
        guard let elapsed else { return nil }
        var t = elapsed
        if let timestamp { t += max(0, now.timeIntervalSince(timestamp)) * effectiveRate }
        t = max(0, t)
        if let duration, duration > 0 { t = min(t, duration) }
        return t
    }

    /// 0…1, or nil without a duration.
    public func fraction(at now: Date) -> Double? {
        guard let duration, duration > 0, let p = position(at: now) else { return nil }
        return min(1, max(0, p / duration))
    }

    /// "3:07", "1:02:03".
    public static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

/// One line of `mediaremote-adapter.pl stream` (or the output of `get`).
public enum AdapterUpdate: Equatable, Sendable {
    /// No player is reporting anything.
    case nothing
    case info(NowPlayingInfo)
}

/// Parses the adapter's JSON lines. Tolerant: unknown keys are ignored, every field but
/// `bundleIdentifier`, `playing` and `title` may be missing or null, numbers may be micros.
public enum AdapterParser {
    /// A `stream` line: `{"type":"data","diff":false,"payload":{…}}`. nil = not a data line.
    public static func parseStreamLine(_ line: Data) -> AdapterUpdate? {
        guard let obj = try? JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed]),
              let dict = obj as? [String: Any] else { return nil }
        if let type = dict["type"] as? String, type != "data" { return nil }
        guard let payload = dict["payload"] as? [String: Any] else {
            return dict["payload"] is NSNull ? .nothing : nil
        }
        return parsePayload(payload)
    }

    /// The `get` command's output: `null` or a payload dictionary.
    public static func parseGet(_ data: Data) -> (update: AdapterUpdate, artwork: Data?)? {
        let trimmed = data.trimmingTrailingWhitespace()
        guard !trimmed.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: trimmed, options: [.fragmentsAllowed]) else { return nil }
        if obj is NSNull { return (.nothing, nil) }
        guard let dict = obj as? [String: Any] else { return nil }
        let art = (dict["artworkData"] as? String).flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }
        return (parsePayload(dict), art)
    }

    public static func parsePayload(_ p: [String: Any]) -> AdapterUpdate {
        guard let bundle = string(p["bundleIdentifier"]) ?? string(p["parentApplicationBundleIdentifier"]),
              let title = string(p["title"]) else { return .nothing }
        let playing = bool(p["playing"]) ?? false
        let duration = number(p["durationMicros"]).map { $0 / 1_000_000 } ?? number(p["duration"])
        let elapsed = number(p["elapsedTimeMicros"]).map { $0 / 1_000_000 } ?? number(p["elapsedTime"])
        var timestamp: Date?
        if let micros = number(p["timestampEpochMicros"]) {
            timestamp = Date(timeIntervalSince1970: micros / 1_000_000)
        } else if let s = p["timestamp"] as? String {
            timestamp = isoDate(s)
        } else if let n = number(p["timestamp"]) {
            timestamp = Date(timeIntervalSince1970: n)
        }
        let parent = string(p["parentApplicationBundleIdentifier"])
        return .info(NowPlayingInfo(
            bundleID: bundle, parentBundleID: parent == bundle ? nil : parent,
            pid: number(p["processIdentifier"]).map { Int32($0) },
            playing: playing, title: title, artist: string(p["artist"]), album: string(p["album"]),
            duration: duration.flatMap { $0 > 0 ? $0 : nil }, elapsed: elapsed, timestamp: timestamp,
            rate: number(p["playbackRate"])))
    }

    private static func string(_ v: Any?) -> String? {
        guard let s = v as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, !(v is NSNull) else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    private static func bool(_ v: Any?) -> Bool? { (v as? NSNumber)?.boolValue }

    private static func isoDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

/// Music and Spotify announce every change on the distributed notification center (no polling,
/// no Automation permission). The payloads are close but not identical.
public enum PlayerNotification {
    public static let music = "com.apple.Music.playerInfo"
    public static let spotify = "com.spotify.client.PlaybackStateChanged"
    public static let musicBundle = "com.apple.Music"
    public static let spotifyBundle = "com.spotify.client"

    /// nil when the player stopped or the payload has no track.
    public static func parse(name: String, userInfo: [AnyHashable: Any], now: Date = .now) -> NowPlayingInfo? {
        let bundle = name == spotify ? spotifyBundle : musicBundle
        let state = userInfo["Player State"] as? String ?? ""
        guard state != "Stopped", let title = (userInfo["Name"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) else { return nil }
        // Music: "Total Time" in ms. Spotify: "Duration" in ms.
        let ms = (userInfo["Total Time"] as? NSNumber ?? userInfo["Duration"] as? NSNumber)?.doubleValue
        let position = (userInfo["Playback Position"] as? NSNumber)?.doubleValue
        let playing = state == "Playing"
        return NowPlayingInfo(bundleID: bundle, playing: playing, title: title,
                              artist: (userInfo["Artist"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                              album: (userInfo["Album"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                              duration: ms.flatMap { $0 > 0 ? $0 / 1000 : nil },
                              elapsed: position, timestamp: position == nil ? nil : now,
                              rate: playing ? 1 : 0)
    }
}

fileprivate extension Data {
    func trimmingTrailingWhitespace() -> Data {
        var end = endIndex
        while end > startIndex, [0x0A, 0x0D, 0x20, 0x09].contains(self[index(before: end)]) { end = index(before: end) }
        return self[startIndex..<end]
    }
}
