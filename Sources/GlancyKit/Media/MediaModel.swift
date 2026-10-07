import AppKit
import SwiftUI

/// Observable state the media views render from. Fine-grained: the collapsed wings get plain
/// values (they observe nothing); only the expanded views read `now` and `level`, which tick only
/// while the panel shows media and something plays.
@MainActor @Observable
public final class MediaModel {
    public enum Source: Equatable, Sendable {
        case starting      // health check running
        case adapter       // mediaremote-adapter works
        case scripts       // adapter missing or broken → Music/Spotify via notifications + AppleScript
    }

    public internal(set) var info: NowPlayingInfo?
    public internal(set) var artwork: NSImage?
    public internal(set) var tint: Color = Theme.primary
    public internal(set) var source: Source = .starting
    /// Re-stamped only by the visible-only tick (progress maths uses it).
    public internal(set) var now: Date = .now
    /// Advances with the tick; drives the level bars while expanded and playing.
    public internal(set) var level: Int = 0
    public internal(set) var outputName: String?
    public internal(set) var appIcon: NSImage?
    public internal(set) var appName: String?
    /// The last track seen (kept after it stops, saved across launches): Home's idle tile.
    public internal(set) var lastTrack: LastTrack?
    /// Its artwork while Glancy runs (never saved).
    public internal(set) var lastArtwork: NSImage?

    /// Synced lyrics for the current track (its own observable: only the lyrics views read it).
    @ObservationIgnored public let lyrics: LyricsModel
    @ObservationIgnored public let lyricsSettings: LyricsSettings

    @ObservationIgnored var onToggle: () -> Void = {}
    @ObservationIgnored var onNext: () -> Void = {}
    @ObservationIgnored var onPrevious: () -> Void = {}
    @ObservationIgnored var onSeek: (TimeInterval) -> Void = { _ in }
    @ObservationIgnored var onOpenApp: () -> Void = {}
    @ObservationIgnored var onPlayLast: () -> Void = {}

    public convenience init() { self.init(lyrics: LyricsModel(), lyricsSettings: LyricsSettings()) }

    init(lyrics: LyricsModel, lyricsSettings: LyricsSettings) {
        self.lyrics = lyrics
        self.lyricsSettings = lyricsSettings
    }

    public var playing: Bool { info?.playing == true }

    public func toggle() { onToggle() }
    public func next() { onNext() }
    public func previous() { onPrevious() }
    public func seek(to t: TimeInterval) { onSeek(t) }
    public func openApp() { onOpenApp() }
    /// Play with nothing playing: the last player (or the system's) picks up.
    public func playLast() { onPlayLast() }
}

/// The last track, as Home's idle tile shows it.
public struct LastTrack: Codable, Equatable, Sendable {
    public var title: String
    public var artist: String?
    public var bundleID: String

    public init(title: String, artist: String?, bundleID: String) {
        self.title = title; self.artist = artist; self.bundleID = bundleID
    }

    init?(_ info: NowPlayingInfo) {
        guard !info.title.isEmpty else { return nil }
        self.init(title: info.title, artist: info.artist, bundleID: info.appBundleID)
    }

    static let key = "glancy.media.lastTrack"

    static func load(_ d: UserDefaults?) -> LastTrack? {
        d?.data(forKey: key).flatMap { try? JSONDecoder().decode(LastTrack.self, from: $0) }
    }

    func save(_ d: UserDefaults?) {
        guard let d, let data = try? JSONEncoder().encode(self) else { return }
        d.set(data, forKey: Self.key)
    }
}
