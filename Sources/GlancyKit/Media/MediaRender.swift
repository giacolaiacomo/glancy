import AppKit
import Foundation

/// Renderer / review only: a made-up track with made-up timed lyrics, no player, no network.
extension MediaModule {
    public enum RenderState: String, CaseIterable, Sendable {
        case lyrics       // the Media tab with the lyrics page
        case lyricsWing   // collapsed, the current line in the right wing
    }

    /// Call before `start(hub:)`. `nil` puts the live reader back.
    public func prepareForRender(_ state: RenderState?) {
        guard let state else {
            fixturePath = ProcessInfo.processInfo.environment["GLANCY_MEDIA_FIXTURE"]
            lyrics.fixture = nil
            lyrics.settings.wingEnabled = false
            lyrics.settings.shown = true
            return
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glancy-render-lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let art = dir.appendingPathComponent("artwork.png")
        if let png = Self.sampleArtwork() { try? png.write(to: art) }
        let now = Date.now
        let payload: [String: Any] = [
            "bundleIdentifier": "com.apple.Music", "title": "Golden Hour Drive", "artist": "Paper Lanterns",
            "album": "Night Roads", "playing": true, "durationMicros": 236_000_000, "elapsedTimeMicros": 36_000_000,
            "timestampEpochMicros": Int(now.timeIntervalSince1970 * 1_000_000), "playbackRate": 1,
            "artworkPath": art.path, "outputName": "MacBook Pro Speakers",
        ]
        let url = dir.appendingPathComponent("now-playing.json")
        if let d = try? JSONSerialization.data(withJSONObject: payload) { try? d.write(to: url) }
        fixturePath = url.path
        lyrics.fixture = .synced(LRC.parse(Self.sampleLRC))
        lyrics.settings.tabEnabled = true
        lyrics.settings.shown = true
        lyrics.settings.wingEnabled = state == .lyricsWing
    }

    /// Original words written for the renders.
    static let sampleLRC = """
    [ti:Golden Hour Drive]
    [ar:Paper Lanterns]
    [00:00.00]
    [00:12.40]Streetlights hum a slower tune
    [00:16.80]We count the exits one by one
    [00:21.10]Your hand outside is catching June
    [00:25.60]The radio forgets the sun
    [00:30.20]Golden hour, keep on driving
    [00:34.50]Every mile a little brighter
    [00:38.90]Golden hour, we're arriving
    [00:43.30]Where the night is holding tighter
    [00:48.00]
    [00:52.10]Paper lanterns on the dashboard
    [00:56.40]Glowing like we never left
    """

    private static func sampleArtwork() -> Data? {
        let s = 300
        guard let ctx = CGContext(data: nil, width: s, height: s, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors = [CGColor(red: 0.99, green: 0.55, blue: 0.33, alpha: 1), CGColor(red: 0.55, green: 0.20, blue: 0.50, alpha: 1),
                      CGColor(red: 0.16, green: 0.10, blue: 0.30, alpha: 1)]
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.55, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
        }
        ctx.setFillColor(CGColor(red: 1, green: 0.86, blue: 0.55, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 95, y: 125, width: 110, height: 110))
        ctx.setFillColor(CGColor(red: 0.10, green: 0.06, blue: 0.18, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: s, height: 125))
        guard let img = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }
}
