import AppKit
import SwiftUI

/// Now playing in the notch (SPEC §3 Media). Reads through mediaremote-adapter's stream, kept
/// alive only while a player is around; Music and Spotify push over distributed notifications;
/// AppleScript when the adapter is broken. Commands go in-process through MediaRemote.
@MainActor
public final class MediaModule: GlancyModule {
    public let id = ModuleID.media
    public let model: MediaModel
    /// Synced lyrics (LRCLIB): looked up per track, only while something shows them.
    public let lyrics: LyricsController

    /// Apps whose launch is worth restarting the adapter for (players and browsers).
    static let knownPlayers: Set<String> = [
        "com.apple.Music", "com.spotify.client", "com.apple.podcasts", "com.apple.TV", "com.apple.QuickTimePlayerX",
        "org.videolan.vlc", "com.colliderli.iina", "com.tidal.desktop", "com.deezer.deezer-desktop", "com.amazon.music",
        "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "company.thebrowser.Browser",
        "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    private var session = MediaSession()
    private var hub: ActivityHub?
    private var started = false
    private var generation = 0
    private var adapter: MediaAdapter?
    private let stream: AdapterStream
    private let locateAdapter: () -> MediaAdapter?
    /// A `get` payload to show instead of the live reader (demo images, `--self-test`); also
    /// `GLANCY_MEDIA_FIXTURE`. Nothing is spawned and no player is asked.
    var fixturePath: String? = ProcessInfo.processInfo.environment["GLANCY_MEDIA_FIXTURE"]
    private var visibility: SurfaceVisibility = .collapsed
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private let output = OutputDeviceWatcher()

    private var healthTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var peekTask: Task<Void, Never>?
    private var lingerTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var probeTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var triggerTask: Task<Void, Never>?

    private var artworkKey: String?
    private var postedSignature: String?
    private var peekShownUntil: Date = .distantPast
    private var unexpectedExits: [Date] = []
    private var iconBundle: String?
    /// Where the last track is kept across launches; nil (tests, renders, the lab) = this run only.
    private let lastTrackDefaults: UserDefaults?

    public convenience init() {
        // The renderer never sends the user's track anywhere.
        let render = ProcessInfo.processInfo.processName == "glancy-render"
        let lyrics = LyricsController(settings: LyricsSettings(), provider: render ? nil : LRCLIBClient(),
                                      cache: render ? nil : LyricsCache())
        self.init(stream: AdapterStream(), locate: { MediaAdapter.locate() }, lyrics: lyrics, lastTrack: render ? nil : .standard)
    }

    /// Tests: a private pid file and a fake adapter. Without `lyrics`, lookups never leave the Mac.
    init(stream: AdapterStream, locate: @escaping () -> MediaAdapter?, lyrics: LyricsController? = nil,
         lastTrack: UserDefaults? = nil) {
        self.stream = stream
        self.lastTrackDefaults = lastTrack
        self.locateAdapter = locate
        let lyrics = lyrics ?? LyricsController(settings: LyricsSettings(defaults: UserDefaults(suiteName: "ai.glancy.media.lyrics.offline")!),
                                                provider: nil, cache: nil)
        self.lyrics = lyrics
        self.model = MediaModel(lyrics: lyrics.model, lyricsSettings: lyrics.settings)
        lyrics.onWingChange = { [weak self] in self?.publish() }
        // Settings → Media is reachable while the module is off: the lyrics strings must be there too.
        L10n.addItalian(MediaText.lyricsItalian)
        model.onToggle = { [weak self] in self?.toggle() }
        model.onNext = { [weak self] in self?.skip(.next) }
        model.onPrevious = { [weak self] in self?.skip(.previous) }
        model.onSeek = { [weak self] in self?.seek(to: $0) }
        model.onOpenApp = { [weak self] in self?.openApp() }
        model.onPlayLast = { [weak self] in self?.playLast() }
        model.lastTrack = LastTrack.load(lastTrack)
    }

    // MARK: Lifecycle

    public func start(hub: ActivityHub) {
        guard !started else { return }
        started = true
        generation &+= 1
        self.hub = hub
        L10n.addItalian(MediaText.italian)
        L10n.addItalian(MediaText.lyricsItalian)
        if let fixture = fixturePath {
            loadFixture(fixture)
            return
        }
        observe()
        guard let adapter = locateAdapter() else {
            enterScriptsMode()
            return
        }
        self.adapter = adapter
        let gen = generation
        healthTask = Task { [weak self] in
            // One retry: the test client occasionally misses its 3 s setup window under load.
            var ok = await adapter.healthCheck()
            if !ok, !Task.isCancelled {
                try? await Delay.sleep(for: .seconds(2))
                ok = await adapter.healthCheck()
            }
            guard let self, self.started, self.generation == gen else { return }
            if ok {
                self.model.source = .adapter
                // Launch: start once to learn the state; the linger rules stop it if nothing plays.
                self.ensureStream()
            } else {
                self.enterScriptsMode()
            }
        }
    }

    public func stop() {
        guard started else { return }
        started = false
        generation &+= 1
        for t in [healthTask, artworkTask, peekTask, lingerTask, tickTask, probeTask, restartTask, triggerTask] { t?.cancel() }
        healthTask = nil; artworkTask = nil; peekTask = nil; lingerTask = nil
        tickTask = nil; probeTask = nil; restartTask = nil; triggerTask = nil
        stream.stop()
        lyrics.stop()
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        output.stop()
        hub?.clearAll(from: .media)
        hub = nil
        session = MediaSession()
        artworkKey = nil; postedSignature = nil; iconBundle = nil; unexpectedExits = []
        model.info = nil; model.artwork = nil; model.tint = Theme.primary; model.source = .starting
        model.appIcon = nil; model.appName = nil; model.outputName = nil
    }

    public func visibilityChanged(_ v: SurfaceVisibility) {
        let wasShowing = showsMedia(visibility)
        visibility = v
        lyrics.visibility(v)
        if case .expanded = v {
            if output.isIdle { output.start { [weak self] in self?.model.outputName = $0 } }
            model.now = .now
            probeIfIdle()
        } else {
            output.stop()
        }
        if wasShowing != showsMedia(v) { updateTick() }
    }

    /// The panel is open on Home or on the Media tab.
    private func showsMedia(_ v: SurfaceVisibility) -> Bool {
        if case .expanded(let tab) = v { return tab == nil || tab == .media }
        return false
    }

    // MARK: Observation

    private func observe() {
        let ws = NSWorkspace.shared.notificationCenter
        func add(_ c: NotificationCenter, _ name: Notification.Name, _ body: @escaping @MainActor (Notification) -> Void) {
            let token = c.addObserver(forName: name, object: nil, queue: .main) { note in
                // Delivered on the main queue; the note never leaves it.
                nonisolated(unsafe) let note = note
                MainActor.assumeIsolated { body(note) }
            }
            observers.append((c, token))
        }
        add(ws, NSWorkspace.didTerminateApplicationNotification) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundle = app.bundleIdentifier else { return }
            self?.appTerminated(bundle, pid: app.processIdentifier)
        }
        add(ws, NSWorkspace.didLaunchApplicationNotification) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundle = app.bundleIdentifier, MediaModule.knownPlayers.contains(bundle) else { return }
            self?.trigger()
        }
        let dist = DistributedNotificationCenter.default()
        for name in [PlayerNotification.music, PlayerNotification.spotify] {
            add(dist, Notification.Name(name)) { [weak self] note in
                self?.playerPushed(name: name, userInfo: note.userInfo ?? [:])
            }
        }
        MediaRemoteCommands.registerForNotifications()
        for name in [MediaRemoteCommands.isPlayingDidChange, MediaRemoteCommands.appDidChange] {
            add(NotificationCenter.default, name) { [weak self] _ in self?.trigger() }
        }
    }

    /// Something suggests a player woke up: restart the stream if it isn't running. Debounced.
    private func trigger() {
        guard started, model.source == .adapter, !stream.isRunning, triggerTask == nil else { return }
        triggerTask = Task { [weak self] in
            try? await Delay.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            self.triggerTask = nil
            self.ensureStream()
        }
    }

    private func playerPushed(name: String, userInfo: [AnyHashable: Any]) {
        switch model.source {
        case .adapter:
            trigger()
        case .scripts:
            let bundle = name == PlayerNotification.spotify ? PlayerNotification.spotifyBundle : PlayerNotification.musicBundle
            if let info = PlayerNotification.parse(name: name, userInfo: userInfo) {
                let c = session.apply(info)
                handle(c)
                // Music's push carries no position; artwork only once per track.
                queryScripts(bundle, artwork: c.trackChanged)
            } else if session.info?.bundleID == bundle {
                handle(session.clear())
            }
        case .starting:
            break
        }
    }

    private func appTerminated(_ bundle: String, pid: Int32) {
        handle(session.appTerminated(bundleID: bundle, pid: pid))
    }

    // MARK: Adapter stream

    private func ensureStream() {
        guard started, model.source == .adapter, let adapter, !stream.isRunning else { return }
        let gen = generation
        let ok = stream.start(adapter, onUpdate: { [weak self] update in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.ingest(update, gen: gen) } }
        }, onExit: { [weak self] expected in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.streamExited(expected: expected, gen: gen) } }
        })
        if ok {
            session.restartNoPlayerClock()
            armLinger()
        } else {
            enterScriptsMode()
        }
    }

    private func ingest(_ update: AdapterUpdate, gen: Int) {
        guard started, gen == generation else { return }
        handle(session.apply(update))
    }

    private func streamExited(expected: Bool, gen: Int) {
        guard started, gen == generation, !expected else { return }
        let now = Date.now
        unexpectedExits = unexpectedExits.filter { now.timeIntervalSince($0) < 60 } + [now]
        if unexpectedExits.count >= 3 {
            enterScriptsMode()
            return
        }
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Delay.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.ensureStream()
        }
    }

    /// Opening the panel while the stream sleeps: one cheap `get`; a player → stream again.
    private func probeIfIdle() {
        guard started, model.source == .adapter, let adapter, !stream.isRunning, probeTask == nil else { return }
        let gen = generation
        probeTask = Task { [weak self] in
            let r = await adapter.fetch(artwork: false)
            guard let self, self.started, self.generation == gen else { return }
            self.probeTask = nil
            if case .info = r?.update { self.ensureStream() }
        }
    }

    private func enterScriptsMode() {
        guard started else { return }
        stream.stop()
        model.source = .scripts
        for bundle in PlayerScripts.players where PlayerScripts.isRunning(bundle) {
            queryScripts(bundle, artwork: true)
        }
    }

    private func queryScripts(_ bundle: String, artwork: Bool) {
        guard PlayerScripts.isRunning(bundle) else { return }
        let gen = generation
        Task { [weak self] in
            guard let r = await PlayerScripts.query(bundle) else { return }
            guard let self, self.started, self.generation == gen, self.model.source == .scripts else { return }
            // Don't let a paused Spotify override a playing Music.
            if let cur = self.session.info, cur.bundleID != bundle, cur.playing, !r.info.playing { return }
            self.handle(self.session.apply(r.info))
            if artwork, let data = r.artwork { await self.applyArtwork(data, key: r.info.trackKey) }
        }
    }

    // MARK: State → surface

    private func handle(_ c: MediaSession.Change) {
        guard started else { return }
        if c.changed { model.info = session.info; lyrics.update(session.info) }
        if c.trackChanged {
            artworkTask?.cancel()
            artworkKey = nil
            model.artwork = nil
            model.lastArtwork = nil
            model.tint = Theme.primary
            updateAppInfo()
            fetchArtwork()
        }
        if c.changed, let info = session.info { remember(info) }
        if c.cleared {
            artworkTask?.cancel(); peekTask?.cancel()
            artworkKey = nil
            model.artwork = nil
            model.tint = Theme.primary
        }
        if c.peek { schedulePeek() }
        if c.changed { publish() }
        armLinger()
        updateTick()
    }

    private func publish() {
        guard let hub else { return }
        let now = Date.now
        guard session.showsActivity(at: now), let info = session.info else {
            if postedSignature != nil { hub.clear("media"); postedSignature = nil }
            return
        }
        let art = model.artwork.map { "\(ObjectIdentifier($0).hashValue)" } ?? "-"
        let words = lyrics.wingActive
        let signature = "\(info.trackKey)|\(info.playing)|\(art)|\(words)"
        guard signature != postedSignature else { return }
        postedSignature = signature
        let tint = model.tint
        let right = words ? AnyView(MediaWingLyrics(lyrics: lyrics.model, tint: tint))
                          : AnyView(MediaWingRight(playing: info.playing, tint: tint))
        hub.post(LiveActivity(
            id: "media", module: .media, priority: 30, updated: now, expires: session.pausedDeadline,
            left: AnyView(MediaWingLeft(artwork: model.artwork, tint: tint)),
            right: right))
    }

    /// One wake-up at the next deadline (paused too long / no player too long), never a ticker.
    private func armLinger() {
        lingerTask?.cancel(); lingerTask = nil
        let deadline: Date?
        switch session.phase {
        case .playing: deadline = nil
        case .paused: deadline = session.pausedDeadline
        // The adapter stream stays up for good (~6 MB in its own process, 0 % CPU while idle):
        // a player started from a browser is seen at once instead of on the next panel open.
        case .none: deadline = nil
        }
        guard let deadline else { return }
        lingerTask = Task { [weak self] in
            try? await Delay.sleep(for: .seconds(max(0.5, deadline.timeIntervalSinceNow + 0.5)))
            guard !Task.isCancelled else { return }
            self?.lingerFired()
        }
    }

    private func lingerFired() {
        guard started else { return }
        let now = Date.now
        let c = session.expireIfPausedTooLong(now: now)
        if c.cleared {
            // Paused for 5 min: drop the activity; the stream keeps listening.
            handle(c)
            lingerTask?.cancel(); lingerTask = nil
        } else {
            armLinger()
        }
    }

    // MARK: Visible-only clock

    /// Ticks only while the panel shows media and something plays: progress and level bars.
    private func updateTick() {
        let should = started && session.isPlaying && showsMedia(visibility)
        if !should { tickTask?.cancel(); tickTask = nil; return }
        guard tickTask == nil else { return }
        model.now = .now
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Delay.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                self.model.now = .now
                self.model.level &+= 1
            }
        }
    }

    // MARK: Artwork

    private func fetchArtwork() {
        guard let info = session.info else { return }
        let key = info.trackKey
        guard model.source == .adapter, let adapter else { return }  // scripts mode fetches its own
        let gen = generation
        artworkTask = Task { [weak self] in
            // Players publish artwork a beat after the title; try three times, then give up.
            for delay in [0.25, 1.5, 4.0] {
                try? await Delay.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                guard let r = await adapter.fetch(artwork: true), !Task.isCancelled else { continue }
                guard let self, self.started, self.generation == gen, self.session.info?.trackKey == key else { return }
                guard case .info(let got) = r.update, got.trackKey == key else { continue }
                if let data = r.artwork {
                    await self.applyArtwork(data, key: key)
                    return
                }
            }
        }
    }

    private func applyArtwork(_ data: Data, key: String) async {
        let decoded = await Task.detached(priority: .utility) { Artwork.decode(data) }.value
        guard started, session.info?.trackKey == key, let decoded else { return }
        artworkKey = key
        model.artwork = NSImage(cgImage: decoded.image, size: NSSize(width: decoded.image.width / 2, height: decoded.image.height / 2))
        model.lastArtwork = model.artwork
        model.tint = Color(.sRGB, red: decoded.tint.r, green: decoded.tint.g, blue: decoded.tint.b)
        publish()
    }

    /// The track playing now is the one Home's idle tile offers once it stops.
    private func remember(_ info: NowPlayingInfo) {
        guard let track = LastTrack(info), track != model.lastTrack else { return }
        model.lastTrack = track
        track.save(lastTrackDefaults)
    }

    // MARK: Peek

    /// Rapid skips coalesce: one peek for the track that stays, never during an open panel.
    private func schedulePeek() {
        guard let key = session.info?.trackKey else { return }
        peekTask?.cancel()
        peekTask = Task { [weak self] in
            try? await Delay.sleep(for: .milliseconds(700))
            guard let self, !Task.isCancelled, self.started, self.session.info?.trackKey == key,
                  self.session.isPlaying else { return }
            self.showPeek()
        }
    }

    /// Shows the track peek now (also used by the renderer).
    public func showPeek() {
        guard let hub, session.info != nil else { return }
        if case .expanded = visibility { return }
        if visibility == .hidden { return }
        let now = Date.now
        // A peek of ours is still on screen: it is bound to the model and already shows this track.
        guard now >= peekShownUntil else { return }
        peekShownUntil = now.addingTimeInterval(2.5)
        hub.show(PeekEvent(module: .media, duration: 2.5, content: AnyView(MediaPeek(model: model))))
    }

    // MARK: Commands

    func toggle() {
        guard let info = session.info else { return }
        let target = !info.playing
        if !MediaRemoteCommands.send(.toggle) { script(info.appBundleID, "playpause") }
        session.assume(playing: target)
        model.info = session.info
        lyrics.update(session.info)
        publish(); armLinger(); updateTick()
    }

    /// Home's idle Play: MediaRemote's play goes to the system's now-playing app (the last one
    /// used); if it refuses, the last player by AppleScript when it runs. The stream wakes on the
    /// player's own notifications.
    func playLast() {
        guard started, fixturePath == nil else { return }
        if !MediaRemoteCommands.send(.play), let bundle = model.lastTrack?.bundleID { script(bundle, "play") }
        trigger()
    }

    func skip(_ cmd: MediaRemoteCommands.Command) {
        guard let info = session.info else { return }
        if !MediaRemoteCommands.send(cmd) { script(info.appBundleID, cmd == .next ? "next track" : "previous track") }
    }

    private func seek(to t: TimeInterval) {
        guard let info = session.info else { return }
        MediaRemoteCommands.seek(to: t)
        if model.source == .scripts { script(info.appBundleID, "set player position to \(Int(t))") }
        session.assume(position: t)
        model.info = session.info
        lyrics.update(session.info)
        model.now = .now
    }

    /// AppleScript command for Music/Spotify, only if MediaRemote refused and the app runs.
    private func script(_ bundle: String, _ verb: String) {
        guard PlayerScripts.players.contains(bundle), PlayerScripts.isRunning(bundle) else { return }
        PlayerScripts.command(bundle, verb)
    }

    /// Opens the panel on the Media tab (command bar, "show lyrics").
    func openTab() { hub?.requestOpen(.media) }

    /// A lyrics setting changed (Settings → Media): look up, stop, or re-post the wing.
    public func lyricsSettingsChanged() { lyrics.settingsChanged() }

    private func openApp() {
        guard let bundle = session.info?.appBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        hub?.requestClose()
    }

    private func updateAppInfo() {
        guard let bundle = session.info?.appBundleID, bundle != iconBundle else { return }
        iconBundle = bundle
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 32, height: 32)
            model.appIcon = icon
            model.appName = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        } else {
            model.appIcon = nil
            model.appName = nil
        }
    }

    // MARK: Surface

    public var tab: PanelTab? {
        PanelTab(module: .media, symbol: "music.note", title: "Media") { [model] in
            AnyView(MediaTabView(model: model))
        }
    }

    public func homeCard() -> AnyView? {
        model.info == nil ? nil : AnyView(MediaHomeTile(model: model))
    }

    /// At rest (Always): the last track with Play, or "Nothing playing" with Play for the
    /// system's player.
    public func homeIdleCard(_ widget: HomeWidget) -> AnyView? {
        guard widget == .media, model.info == nil else { return nil }
        return AnyView(MediaIdleTile(model: model))
    }

    // MARK: Fixture (renderer / review only)

    /// `GLANCY_MEDIA_FIXTURE=/path/payload.json`: an adapter `get` payload (optionally with
    /// `"artworkPath"`), shown as if it were playing. No child process, no observers.
    private func loadFixture(_ path: String) {
        guard let data = FileManager.default.contents(atPath: path),
              let r = AdapterParser.parseGet(data) else { return }
        model.source = .adapter
        var art = r.artwork
        if art == nil, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let p = obj["artworkPath"] as? String { art = FileManager.default.contents(atPath: p) }
        handle(session.apply(r.update))
        if let art, let d = Artwork.decode(art), let key = session.info?.trackKey {
            artworkKey = key
            model.artwork = NSImage(cgImage: d.image, size: NSSize(width: d.image.width / 2, height: d.image.height / 2))
            model.lastArtwork = model.artwork
            model.tint = Color(.sRGB, red: d.tint.r, green: d.tint.g, blue: d.tint.b)
            publish()
        }
        let fixed = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["outputName"] as? String
        model.outputName = fixed ?? OutputDeviceWatcher.currentName()
    }
}
