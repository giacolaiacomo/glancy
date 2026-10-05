import Foundation

/// The now-playing state machine, pure and testable. The module feeds it adapter lines, player
/// pushes and app terminations; it answers what changed so the module knows what to redraw,
/// peek, fetch or kill.
public struct MediaSession: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case none
        case playing
        case paused(since: Date)
    }

    /// What one input changed.
    public struct Change: Equatable, Sendable {
        public var changed = false          // anything visible changed
        public var trackChanged = false     // a different track (new artwork)
        public var peek = false             // worth a track-change peek (never the first track after launch)
        public var cleared = false          // nothing is playing any more
        public init() {}
    }

    /// Paused this long → the live activity goes away and the adapter may stop.
    public static let pausedLinger: TimeInterval = 5 * 60
    /// No player this long → the adapter stream is killed.
    public static let noPlayerLinger: TimeInterval = 5 * 60
    /// After the source app quits, late lines from it are ignored for this long.
    static let terminationGrace: TimeInterval = 3

    public private(set) var info: NowPlayingInfo?
    public private(set) var phase: Phase = .none
    /// When the last player went away (nil while one is around or before the first report).
    public private(set) var noPlayerSince: Date?
    private var sawTrack = false
    private var terminated: (bundle: String, pid: Int32?, at: Date)?

    public init() {}

    public static func == (a: MediaSession, b: MediaSession) -> Bool {
        a.info == b.info && a.phase == b.phase && a.noPlayerSince == b.noPlayerSince && a.sawTrack == b.sawTrack
    }

    public var isPlaying: Bool { phase == .playing }

    /// The live activity should show (playing, or paused for less than `pausedLinger`).
    public func showsActivity(at now: Date) -> Bool {
        switch phase {
        case .none: false
        case .playing: true
        case .paused(let since): now.timeIntervalSince(since) < Self.pausedLinger
        }
    }

    /// The moment the paused activity expires, if paused.
    public var pausedDeadline: Date? {
        if case .paused(let since) = phase { return since.addingTimeInterval(Self.pausedLinger) }
        return nil
    }

    /// The adapter stream is worth keeping: a player is playing, paused recently, or went away
    /// less than `noPlayerLinger` ago.
    public func wantsStream(at now: Date) -> Bool {
        switch phase {
        case .playing: return true
        case .paused(let since): return now.timeIntervalSince(since) < Self.pausedLinger
        case .none:
            guard let gone = noPlayerSince else { return true }
            return now.timeIntervalSince(gone) < Self.noPlayerLinger
        }
    }

    @discardableResult
    public mutating func apply(_ update: AdapterUpdate, now: Date = .now) -> Change {
        switch update {
        case .nothing: return clear(now: now)
        case .info(let new): return apply(new, now: now)
        }
    }

    @discardableResult
    public mutating func apply(_ new: NowPlayingInfo, now: Date = .now) -> Change {
        if let t = terminated, now.timeIntervalSince(t.at) < Self.terminationGrace,
           new.appBundleID == t.bundle || new.bundleID == t.bundle, t.pid == nil || new.pid == nil || new.pid == t.pid {
            return Change()  // a late line from the app that just quit
        }
        var c = Change()
        let old = info
        noPlayerSince = nil
        if old?.trackKey != new.trackKey {
            c.trackChanged = true
            c.peek = sawTrack && new.playing
            sawTrack = true
        }
        let newPhase: Phase
        if new.playing {
            newPhase = .playing
        } else if case .paused(let since) = phase, !c.trackChanged {
            newPhase = .paused(since: since)
        } else {
            newPhase = .paused(since: now)
        }
        c.changed = old != new || newPhase != phase
        info = new
        phase = newPhase
        return c
    }

    /// The player went away (empty payload, Music/Spotify "Stopped").
    @discardableResult
    public mutating func clear(now: Date = .now) -> Change {
        var c = Change()
        if info != nil || phase != .none {
            c.changed = true
            c.cleared = true
        }
        if info != nil || noPlayerSince == nil { noPlayerSince = now }
        info = nil
        phase = .none
        return c
    }

    /// Stale-state guard: the source app quit. Returns the change (cleared when it was ours).
    @discardableResult
    public mutating func appTerminated(bundleID: String, pid: Int32? = nil, now: Date = .now) -> Change {
        guard let info else { return Change() }
        let ours = info.bundleID == bundleID || info.parentBundleID == bundleID || (pid != nil && info.pid == pid)
        guard ours else { return Change() }
        terminated = (info.appBundleID, info.pid, now)
        return clear(now: now)
    }

    /// A stream (re)started: give a player that is still launching the full grace period.
    public mutating func restartNoPlayerClock(now: Date = .now) {
        if phase == .none { noPlayerSince = now }
    }

    /// Paused for longer than `pausedLinger`: forget the session (its activity has expired).
    @discardableResult
    public mutating func expireIfPausedTooLong(now: Date = .now) -> Change {
        guard case .paused(let since) = phase, now.timeIntervalSince(since) >= Self.pausedLinger else { return Change() }
        return clear(now: now)
    }

    /// Applies a command optimistically (the adapter confirms within ~200 ms).
    public mutating func assume(playing: Bool, now: Date = .now) {
        guard var i = info, i.playing != playing else { return }
        // Freeze or restart the clock at the current position.
        i.elapsed = i.position(at: now)
        i.timestamp = now
        i.playing = playing
        i.rate = playing ? 1 : 0
        info = i
        phase = playing ? .playing : .paused(since: now)
    }

    /// Applies a seek optimistically.
    public mutating func assume(position: TimeInterval, now: Date = .now) {
        guard var i = info else { return }
        i.elapsed = position
        i.timestamp = now
        info = i
    }
}
