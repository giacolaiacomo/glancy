import Foundation
import Observation

/// Lyrics preferences (Settings → Media, and the Media tab's lyrics button).
@MainActor @Observable
public final class LyricsSettings {
    static let tabKey = "glancy.media.lyrics.tab"
    static let wingKey = "glancy.media.lyrics.wing"
    static let shownKey = "glancy.media.lyrics.shown"

    /// Lyrics in the Media tab (default on). Looked up only while the tab is on screen.
    public var tabEnabled: Bool { didSet { defaults.set(tabEnabled, forKey: Self.tabKey) } }
    /// The current line in the right wing while playing (opt-in: one wake per line).
    public var wingEnabled: Bool { didSet { defaults.set(wingEnabled, forKey: Self.wingKey) } }
    /// The tab shows the lyrics page rather than the artwork page when there are lyrics.
    public var shown: Bool { didSet { defaults.set(shown, forKey: Self.shownKey) } }

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        tabEnabled = defaults.object(forKey: Self.tabKey) as? Bool ?? true
        wingEnabled = defaults.object(forKey: Self.wingKey) as? Bool ?? false
        shown = defaults.object(forKey: Self.shownKey) as? Bool ?? true
    }

    public var anyEnabled: Bool { tabEnabled || wingEnabled }
}

/// What the lyrics views render. `index` moves once per line, and only while someone looks.
@MainActor @Observable
public final class LyricsModel {
    public enum State: Equatable, Sendable {
        /// Lyrics are off, or nothing is playing.
        case idle
        case loading
        case ready(LyricsContent)
        /// The lookup failed (no connection, timeout): retried the next time the tab opens.
        case offline
    }

    public internal(set) var state: State = .idle
    /// The synced line being sung, nil before the first one.
    public internal(set) var index: Int?

    public init() {}

    public var lines: [LyricLine] {
        if case .ready(.synced(let l)) = state { return l }
        return []
    }

    /// There is something worth a lyrics page (timed or plain words).
    public var hasWords: Bool {
        switch state {
        case .ready(.synced), .ready(.plain): return true
        default: return false
        }
    }

    /// The line for the wing: the current words, or a note glyph in a break / before the first line.
    public var currentText: String {
        guard let index, lines.indices.contains(index) else { return "♪" }
        let t = lines[index].text
        return t.isEmpty ? "♪" : t
    }
}

/// Fetches lyrics once per track, only when something will show them, and moves the current line
/// with a single scheduled wake at the next line's timestamp (no ticker): while the Media tab is on
/// screen, or while the opt-in wing is showing, and only while playing.
@MainActor
public final class LyricsController {
    public let model = LyricsModel()
    public let settings: LyricsSettings
    private let provider: LyricsProvider?
    private let cache: LyricsCache?
    private let now: () -> Date
    private let debounce: Duration

    /// The lyric wing appeared or went (the media module re-posts its activity).
    var onWingChange: () -> Void = {}
    /// Shown instead of a lookup (renderer). Never touches the network or the cache.
    var fixture: LyricsContent?

    private var info: NowPlayingInfo?
    /// The track the current lookup belongs to (nil = none started for this track yet).
    private var lookedUp: String?
    private var lastAttempt: Date = .distantPast
    private var tabVisible = false
    private var collapsed = false
    private var fetchTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?

    /// Tests: when the next line wake is due, and how many wakes fired.
    private(set) var nextWake: Date?
    private(set) var wakes = 0
    private(set) var lookups = 0

    public init(settings: LyricsSettings, provider: LyricsProvider?, cache: LyricsCache?,
                debounce: Duration = .milliseconds(600), now: @escaping () -> Date = { .now }) {
        self.settings = settings
        self.provider = provider
        self.cache = cache
        self.debounce = debounce
        self.now = now
    }

    // MARK: Inputs

    /// Every now-playing change (new track, play/pause, seek, a fresh timestamp).
    func update(_ new: NowPlayingInfo?) {
        let trackChanged = new?.trackKey != info?.trackKey
        let wingBefore = wingActive
        info = new
        if trackChanged {
            fetchTask?.cancel(); fetchTask = nil
            lookedUp = nil
            model.state = .idle
            model.index = nil
            lookUpIfNeeded(delay: debounce)
        } else if new?.playing == true {
            // The wing may need lyrics now that the track plays again.
            lookUpIfNeeded(delay: .zero)
        }
        reschedule()
        if wingBefore != wingActive { onWingChange() }
    }

    func visibility(_ v: SurfaceVisibility) {
        let wingBefore = wingActive
        tabVisible = v == .expanded(.media)
        collapsed = v == .collapsed
        lookUpIfNeeded(delay: .zero)
        reschedule()
        if wingBefore != wingActive { onWingChange() }
    }

    /// A lyrics setting changed.
    func settingsChanged() {
        if !settings.anyEnabled {
            fetchTask?.cancel(); fetchTask = nil
            lookedUp = nil
            model.state = .idle
            model.index = nil
        } else {
            lookUpIfNeeded(delay: .zero)
        }
        reschedule()
        onWingChange()
    }

    func stop() {
        fetchTask?.cancel(); wakeTask?.cancel()
        fetchTask = nil; wakeTask = nil; nextWake = nil
        info = nil; lookedUp = nil
        model.state = .idle; model.index = nil
        tabVisible = false; collapsed = false
    }

    public func clearCache() async { await cache?.clear() }
    public func cachedCount() async -> Int { await cache?.count() ?? 0 }

    // MARK: Derived

    /// The wing shows the current line (setting on, timed lyrics, playing).
    var wingActive: Bool {
        settings.wingEnabled && info?.playing == true && !model.lines.isEmpty
    }

    /// Someone will see lyrics now: the Media tab is open, or the wing is on while playing collapsed.
    private var wanted: Bool {
        (tabVisible && settings.tabEnabled) || (settings.wingEnabled && collapsed && info?.playing == true)
    }

    // MARK: Lookup

    private func lookUpIfNeeded(delay: Duration) {
        guard settings.anyEnabled, wanted, let info else { return }
        let key = info.trackKey
        if lookedUp == key {
            // Only a failed lookup is retried, and not more than twice a minute.
            guard model.state == .offline, now().timeIntervalSince(lastAttempt) > 30 else { return }
        }
        lookedUp = key
        guard let query = LyricsQuery(info) else {
            model.state = .ready(.notFound)
            return
        }
        if let fixture {
            model.state = .ready(fixture)
            reschedule()
            onWingChange()
            return
        }
        model.state = .loading
        fetchTask?.cancel()
        let provider = provider, cache = cache
        fetchTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            if let hit = await cache?.get(query) {
                self?.finish(.ready(hit), key: key)
                return
            }
            guard let provider else { self?.finish(.ready(.notFound), key: key); return }
            self?.lookups += 1
            self?.lastAttempt = self?.now() ?? .now
            do {
                let content = try await provider.lyrics(for: query)
                guard !Task.isCancelled else { return }
                await cache?.put(content, for: query)
                self?.finish(.ready(content), key: key)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.finish(.offline, key: key)
            }
        }
    }

    private func finish(_ state: LyricsModel.State, key: String) {
        guard info?.trackKey == key, lookedUp == key else { return }
        fetchTask = nil
        let wingBefore = wingActive
        model.state = state
        reschedule()
        if wingBefore != wingActive { onWingChange() }
    }

    // MARK: Line clock

    /// Sets the current line, then sleeps exactly until the next one — only while it is seen and
    /// playing. Paused, hidden, other tab, wing off: no task at all.
    private func reschedule() {
        wakeTask?.cancel(); wakeTask = nil; nextWake = nil
        let lines = model.lines
        guard let info, !lines.isEmpty else { return }
        let seen = (tabVisible && settings.tabEnabled) || (collapsed && settings.wingEnabled)
        guard seen else { return }
        let t = now()
        let idx = info.position(at: t).flatMap { LyricsTimeline.index(in: lines, at: $0) }
        if idx != model.index { model.index = idx }
        guard let delay = LyricsTimeline.delayToNextLine(lines, info: info, now: t) else { return }
        // A hair late rather than early, so the lookup lands on the new line.
        let wait = delay + 0.03
        nextWake = t.addingTimeInterval(wait)
        wakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled else { return }
            self.wakes += 1
            self.reschedule()
        }
    }
}
