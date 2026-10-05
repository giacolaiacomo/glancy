import AppKit
import Foundation

/// AppleScript fallback for Music and Spotify, used only when the adapter's health check fails
/// (boring.notch v2.7, PR #460). Needs the Automation permission; runs one script at a time on
/// `AppleScriptRunner`'s queue, and never talks to a player that isn't running (a `tell` would launch it).
enum PlayerScripts {
    static let players = [PlayerNotification.musicBundle, PlayerNotification.spotifyBundle]

    @MainActor static func isRunning(_ bundle: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty
    }

    /// The current state of one player, or nil (not running, stopped, or no permission).
    static func query(_ bundle: String) async -> (info: NowPlayingInfo, artwork: Data?)? {
        let isSpotify = bundle == PlayerNotification.spotifyBundle
        let source = """
        tell application id "\(bundle)"
            if player state is stopped then return {"stopped"}
            set t to current track
            return {player state as text, name of t, artist of t, album of t, duration of t, player position}
        end tell
        """
        return await withCheckedContinuation { cont in
            AppleScriptRunner.queue.async {
                guard let d = AppleScriptRunner.execute(source).result, d.numberOfItems >= 6,
                      let state = d.atIndex(1)?.stringValue, state != "stopped",
                      let title = d.atIndex(2)?.stringValue, !title.isEmpty else {
                    cont.resume(returning: nil); return
                }
                let rawDuration = d.atIndex(5)?.doubleValue ?? 0
                let duration = isSpotify ? rawDuration / 1000 : rawDuration  // Spotify: ms
                let playing = state == "playing"
                let info = NowPlayingInfo(
                    bundleID: bundle, playing: playing, title: title,
                    artist: d.atIndex(3)?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
                    album: d.atIndex(4)?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
                    duration: duration > 0 ? duration : nil, elapsed: d.atIndex(6)?.doubleValue,
                    timestamp: .now, rate: playing ? 1 : 0)
                var art: Data?
                if !isSpotify {  // Spotify only offers an artwork URL; no network in v1.
                    let artScript = """
                    tell application id "\(bundle)"
                        try
                            return data of artwork 1 of current track
                        end try
                    end tell
                    """
                    art = AppleScriptRunner.execute(artScript).result?.data
                    if art?.isEmpty == true { art = nil }
                }
                cont.resume(returning: (info, art))
            }
        }
    }

    /// Fire-and-forget command ("playpause", "next track", "set player position to 42").
    static func command(_ bundle: String, _ verb: String) {
        let source = "tell application id \"\(bundle)\" to \(verb)"
        AppleScriptRunner.run(source)
    }
}
