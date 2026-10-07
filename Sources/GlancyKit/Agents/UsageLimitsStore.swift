import SwiftUI

/// What fetches Claude Code's `/usage` (the real CLI, or a test double).
public protocol ClaudeUsageFetching: AnyObject, Sendable {
    var isInstalled: Bool { get }
    /// Blocking: called off the main actor.
    func fetch(now: @Sendable () -> Date) -> ClaudeUsageOutcome
    /// Stops a run in flight.
    func cancel()
}

extension ClaudeUsageCLI: ClaudeUsageFetching {}

/// When a Claude `/usage` refresh may run. Pure: the tests drive it.
///
/// - Never on a timer: only on an event (the Agents tab opens, a Claude Code turn or session ends,
///   the refresh button), so a closed notch with nothing happening never runs anything.
/// - Never while the surface is hidden (the Mac or its screens asleep, the session locked).
/// - Never more often than `minInterval` (60 s), never two at once, never again after the CLI
///   proved not genuine or answered unexpectedly.
/// - The tab opening and a turn ending refresh only a reading older than `staleAfter` (5 min by
///   default, Settings); the refresh button only respects `minInterval`.
public struct UsageRefreshPolicy: Sendable, Equatable {
    public enum Trigger: Sendable, Equatable { case panelOpened, agentStopped, manual }

    public var minInterval: TimeInterval = 60
    public var staleAfter: TimeInterval = 5 * 60

    public init(minInterval: TimeInterval = 60, staleAfter: TimeInterval = 5 * 60) {
        self.minInterval = minInterval
        self.staleAfter = staleAfter
    }

    public func shouldRefresh(_ trigger: Trigger, now: Date, lastAttempt: Date?, lastReading: Date?,
                              visibility: SurfaceVisibility, running: Bool, blocked: Bool) -> Bool {
        if blocked || running { return false }
        if visibility == .hidden { return false }
        if let a = lastAttempt, now.timeIntervalSince(a) < minInterval { return false }
        switch trigger {
        case .manual:
            return true
        case .panelOpened:
            guard case .expanded = visibility else { return false }
            return lastReading.map { now.timeIntervalSince($0) >= staleAfter } ?? true
        case .agentStopped:
            return lastReading.map { now.timeIntervalSince($0) >= staleAfter } ?? true
        }
    }
}

/// The Claude CLI's state, for the empty card and Settings.
public enum ClaudeUsageStatus: String, Sendable, Codable {
    case unknown, ok, notInstalled, notGenuine, unexpectedOutput, failed
    var blocksRefresh: Bool { self == .notGenuine || self == .unexpectedOutput }
}

/// Plan limits on the main actor: the last readings (shown at once from the disk cache), the
/// refresh policy, burn rates, threshold alerts, the "Where it went" breakdown. Views observe it;
/// the collapsed surface sees it only through an alert peek or the used-up wing.
@MainActor @Observable
public final class UsageLimitsStore {
    public private(set) var claude: UsageReading?
    public private(set) var codex: UsageReading?
    public private(set) var claudeStatus = ClaudeUsageStatus.unknown
    public private(set) var fetching = false
    /// The clock the countdowns read: moved once a minute, only while the Agents tab or Home is on screen.
    public private(set) var clock = Date.now
    public private(set) var breakdown: UsageBreakdown?
    public private(set) var readingLogs = false

    nonisolated public static let defaultCacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Glancy", isDirectory: true)

    @ObservationIgnored let fetcher: (any ClaudeUsageFetching)?
    @ObservationIgnored let cacheURL: URL?
    /// nil: an isolated store (renderer, demo, self-test): settings live in memory only and a
    /// service counts as on when it has a reading. Nothing of the user's is read or written.
    @ObservationIgnored let defaults: UserDefaults?
    @ObservationIgnored private var memory: [String: Any] = [:]
    @ObservationIgnored var codexPresent: () -> Bool
    /// Runs the log scan behind "Where it went" and returns the totals (nil = not available).
    @ObservationIgnored var breakdownLoader: (@Sendable (_ windows: [UsageWindowSpan]) async -> UsageBreakdown?)?
    @ObservationIgnored var now: () -> Date = { .now }
    @ObservationIgnored weak var hub: ActivityHub?
    @ObservationIgnored private(set) var visibility: SurfaceVisibility = .collapsed
    @ObservationIgnored private(set) var lastAttempt: Date?
    @ObservationIgnored private(set) var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var resetTask: Task<Void, Never>?
    @ObservationIgnored private var breakdownTask: Task<Void, Never>?
    @ObservationIgnored private var history: [String: [(at: Date, percent: Double)]] = [:]
    @ObservationIgnored private var postedWing: String?
    @ObservationIgnored private var running = false
    /// Refreshes started (tests).
    @ObservationIgnored private(set) var fetchCount = 0

    init(fetcher: (any ClaudeUsageFetching)?, cacheURL: URL?, defaults: UserDefaults? = .standard,
                codexPresent: @escaping () -> Bool = { FileManager.default.fileExists(atPath: CodexSource.defaultRoot.path) }) {
        self.fetcher = fetcher
        self.cacheURL = cacheURL
        self.defaults = defaults
        self.codexPresent = codexPresent
    }

    // MARK: Settings

    private func pref(_ key: String) -> Any? { defaults.map { $0.object(forKey: key) } ?? memory[key] }
    private func setPref(_ value: Any, _ key: String) {
        if let defaults { defaults.set(value, forKey: key) } else { memory[key] = value }
    }

    static let claudeKey = "agents.limits.claude"
    static let codexKey = "agents.limits.codex"
    static let alertsKey = "agents.limits.alerts"
    static let minutesKey = "agents.limits.refreshMinutes"
    static let alertedKey = "agents.limits.alerted"
    static let minuteChoices = [2, 5, 10, 15]

    /// On by default only when the CLI is installed.
    public var claudeEnabled: Bool {
        get { access(keyPath: \.claudeEnabled); return pref(Self.claudeKey) as? Bool ?? (defaults == nil ? claude != nil : fetcher?.isInstalled ?? false) }
        set {
            withMutation(keyPath: \.claudeEnabled) { setPref(newValue, Self.claudeKey) }
            if newValue {
                if claudeStatus.blocksRefresh { claudeStatus = .unknown }   // turning it on again retries
                refresh(.manual)
            } else {
                fetcher?.cancel()
                claude = nil
                afterChange()
            }
        }
    }

    /// On by default only when ~/.codex/sessions exists.
    public var codexEnabled: Bool {
        get { access(keyPath: \.codexEnabled); return pref(Self.codexKey) as? Bool ?? (defaults == nil ? codex != nil : codexPresent()) }
        set {
            withMutation(keyPath: \.codexEnabled) { setPref(newValue, Self.codexKey) }
            if !newValue { codex = nil; afterChange() }
        }
    }

    public var alertsEnabled: Bool {
        get { access(keyPath: \.alertsEnabled); return pref(Self.alertsKey) as? Bool ?? true }
        set {
            withMutation(keyPath: \.alertsEnabled) { setPref(newValue, Self.alertsKey) }
            updateWing()
            armResetWatch()
        }
    }

    public var refreshMinutes: Int {
        get {
            access(keyPath: \.refreshMinutes)
            let m = pref(Self.minutesKey) as? Int ?? 5
            return Self.minuteChoices.contains(m) ? m : 5
        }
        set { withMutation(keyPath: \.refreshMinutes) { setPref(newValue, Self.minutesKey) } }
    }

    var policy: UsageRefreshPolicy { UsageRefreshPolicy(minInterval: 60, staleAfter: TimeInterval(refreshMinutes * 60)) }

    /// Something to show: a service on with a reading, or the Claude card's reason.
    public var hasAnything: Bool { claude != nil || codex != nil }

    // MARK: Lifecycle

    func start(hub: ActivityHub) {
        guard !running else { return }
        running = true
        self.hub = hub
        loadCache()
        clock = now()
        afterChange(save: false)
    }

    func stop() {
        guard running else { return }
        running = false
        fetcher?.cancel()
        fetchTask?.cancel(); fetchTask = nil
        fetching = false
        clockTask?.cancel(); clockTask = nil
        resetTask?.cancel(); resetTask = nil
        breakdownTask?.cancel(); breakdownTask = nil
        readingLogs = false
        breakdown = nil
        hub?.clear(Self.wingID)
        postedWing = nil
        hub = nil
    }

    func visibilityChanged(_ v: SurfaceVisibility) {
        visibility = v
        if v == .hidden, fetching { fetcher?.cancel() }   // going to sleep: let the child go
        if ticksClock {
            clock = now()
            tick()
            // Only the Agents tab runs /usage on opening; Home shows the last reading with its age.
            if v == .expanded(.agents) { refresh(.panelOpened) }
        } else {
            clockTask?.cancel(); clockTask = nil
            if breakdown != nil || readingLogs {
                breakdownTask?.cancel(); breakdownTask = nil
                breakdown = nil
                readingLogs = false
            }
        }
    }

    /// A Claude Code turn or session ended (from the hook log): refresh if the reading is stale.
    func claudeTurnEnded() { refresh(.agentStopped) }

    // MARK: Refresh

    /// Runs `/usage` when the policy allows it. Returns whether a refresh started.
    @discardableResult
    public func refresh(_ trigger: UsageRefreshPolicy.Trigger) -> Bool {
        guard running, claudeEnabled, let fetcher else { return false }
        let t = now()
        guard policy.shouldRefresh(trigger, now: t, lastAttempt: lastAttempt, lastReading: claude?.updated,
                                   visibility: visibility, running: fetching, blocked: claudeStatus.blocksRefresh) else { return false }
        lastAttempt = t
        fetching = true
        fetchCount += 1
        fetchTask = Task { [weak self] in
            let outcome = await Task.detached(priority: .utility) { fetcher.fetch(now: { Date.now }) }.value
            guard let self else { return }
            self.fetching = false
            self.fetchTask = nil
            guard self.running, !Task.isCancelled else { return }
            self.adoptClaude(outcome)
        }
        return true
    }

    func adoptClaude(_ outcome: ClaudeUsageOutcome) {
        switch outcome {
        case let .ok(limits, plan):
            claudeStatus = .ok
            let at = now()
            let stamped = limits.map { l -> UsageLimit in var l = l; l.measuredAt = at; return l }
            claude = withRates(UsageReading(service: .claude, plan: plan ?? claude?.plan, limits: stamped, updated: at))
        case .notInstalled: claudeStatus = .notInstalled
        case .notGenuine: claudeStatus = .notGenuine
        case .unexpectedOutput: claudeStatus = .unexpectedOutput
        case .failed: claudeStatus = claude == nil ? .failed : claudeStatus
        }
        afterChange()
    }

    /// A Codex `rate_limits` from the rollout stream (only a newer one replaces the last).
    func adoptCodex(_ reading: UsageReading) {
        guard running, codexEnabled else { return }
        if let c = codex, c.updated >= reading.updated, c != reading { return }
        guard reading != codex else { return }
        codex = withRates(reading)
        afterChange()
    }

    private func afterChange(save: Bool = true) {
        if save { saveCache() }
        checkAlerts()
        updateWing()
        armResetWatch()
    }

    /// Records each reading and gives sessions their burn rate over the last 30 minutes.
    private func withRates(_ r: UsageReading) -> UsageReading {
        var out = r
        let t = now()
        out.limits = r.limits.map { l in
            var l = l
            let k = Self.key(r.service, l)
            var h = history[k] ?? []
            if h.last?.at != l.measuredAt { h.append((l.measuredAt, l.percent)) }
            h.removeAll { $0.at < t.addingTimeInterval(-7 * UsageLimit.hour) }
            if h.count > 64 { h.removeFirst(h.count - 64) }
            history[k] = h
            let recent = h.filter { $0.at >= l.measuredAt.addingTimeInterval(-30 * 60) }
            if l.kind.isSession, let first = recent.first, let last = recent.last, last.at.timeIntervalSince(first.at) >= 20 * 60 {
                l.recentRate = max(0, last.percent - first.percent) / last.at.timeIntervalSince(first.at)
            }
            return l
        }
        // Old windows' histories go.
        let live = Set(out.limits.map { Self.key(r.service, $0) })
        history = history.filter { !$0.key.hasPrefix(r.service.rawValue + "|") || live.contains($0.key) }
        return out
    }

    static func key(_ s: UsageService, _ l: UsageLimit) -> String {
        "\(s.rawValue)|\(l.kind)|\(Int(l.resetsAt?.timeIntervalSince1970 ?? 0))"
    }

    /// The readings that are on, Claude first.
    public var readings: [UsageReading] {
        [claudeEnabled ? claude : nil, codexEnabled ? codex : nil].compactMap { $0 }
    }

    // MARK: Clock (visible only)

    /// The countdowns are on screen: the Agents tab, or Home with a reading to show.
    var ticksClock: Bool {
        visibility == .expanded(.agents) || (visibility == .expanded(nil) && !readings.isEmpty)
    }

    /// Moves `clock` at each minute boundary while the Agents tab (or Home's card) is on screen. One
    /// wait at a time; cancelled the moment the page goes.
    private func tick() {
        clockTask?.cancel()
        let t = now()
        let next = (t.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60 + 60
        let wait = max(1, next - t.timeIntervalSinceReferenceDate)
        clockTask = Task { [weak self] in
            try? await Delay.sleep(for: .seconds(wait + 0.05))
            guard !Task.isCancelled, let self, self.ticksClock else { return }
            self.clock = self.now()
            self.updateWing()
            self.tick()
        }
    }

    // MARK: Cache (~/Library/Caches/Glancy/limits.json)

    fileprivate struct Cache: Codable {
        var version = 1
        var claude: UsageReading?
        var codex: UsageReading?
    }

    /// The readings in a cache file, read-only (the renderer's "real" shots from the app's own cache).
    public nonisolated static func readCache(_ url: URL) -> (claude: UsageReading?, codex: UsageReading?) {
        guard let data = try? Data(contentsOf: url), let c = try? JSONDecoder.iso.decode(Cache.self, from: data),
              c.version == 1 else { return (nil, nil) }
        return (c.claude?.service == .claude ? c.claude : nil, c.codex?.service == .codex ? c.codex : nil)
    }

    private func loadCache() {
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL),
              let c = try? JSONDecoder.iso.decode(Cache.self, from: data), c.version == 1 else { return }
        if claude == nil, c.claude?.service == .claude { claude = c.claude }
        if codex == nil, c.codex?.service == .codex { codex = c.codex }
    }

    @ObservationIgnored private var savedData: Data?

    private func saveCache() {
        guard let cacheURL else { return }
        let c = Cache(claude: claude, codex: codex)
        guard let data = try? JSONEncoder.iso.encode(c), data != savedData else { return }
        savedData = data
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    // MARK: Alerts: a drop-down at 90% and 100%, when a session runs out within the hour, and when
    // a limit past 90% resets. Once per limit, window and level (remembered across launches).

    static let wingID = "agents.limits"

    private func checkAlerts() {
        guard running, alertsEnabled else { return }
        let t = now()
        var sent = pref(Self.alertedKey) as? [String: Int] ?? [:]
        var peeks: [(UsageReading, UsageLimit, String)] = []
        for r in readings where t.timeIntervalSince(r.updated) < UsageLimit.hour {
            for l in r.limits {
                let k = Self.key(r.service, l), p = Int(l.effective(at: t))
                if let level = [100, 90].first(where: { p >= $0 }), level > (sent[k] ?? 0) {
                    sent[k] = level
                    peeks.append((r, l, LimitsText.alert(r.service, l, level: level, now: t)))
                } else if sent[k + "|pace"] == nil, l.effective(at: t) < 90, let eta = l.runsOutAt(now: t) {
                    sent[k + "|pace"] = 1
                    peeks.append((r, l, LimitsText.paceAlert(r.service, l, eta: eta, now: t)))
                }
            }
        }
        if sent.count > 60 { sent = sent.filter { k, _ in readings.contains { r in r.limits.contains { k.hasPrefix(Self.key(r.service, $0)) } } } }
        setPref(sent, Self.alertedKey)
        // At most one drop-down per change: the fullest.
        if let (r, l, text) = peeks.max(by: { $0.1.effective(at: t) < $1.1.effective(at: t) }) {
            peek(text, service: r.service, percent: l.effective(at: t))
        }
    }

    private func peek(_ text: String, service: UsageService, percent: Double?) {
        hub?.show(PeekEvent(module: .agents, duration: 4,
                            content: AnyView(LimitsPeekView(text: text, service: service, percent: percent))))
    }

    /// One wait until the earliest reset of a limit that was alerted at 90%+; then "you're good to go".
    private func armResetWatch() {
        resetTask?.cancel(); resetTask = nil
        guard running, alertsEnabled else { return }
        let t = now()
        let sent = pref(Self.alertedKey) as? [String: Int] ?? [:]
        let watched = readings.flatMap { r in r.limits.compactMap { l -> (UsageService, UsageLimit, Date)? in
            guard let reset = l.resetsAt, reset > t, (sent[Self.key(r.service, l)] ?? 0) >= 90 else { return nil }
            return (r.service, l, reset)
        } }
        guard let first = watched.min(by: { $0.2 < $1.2 }) else { return }
        resetTask = Task { [weak self] in
            try? await Delay.sleep(for: .seconds(first.2.timeIntervalSince(t) + 1))
            guard !Task.isCancelled, let self, self.running else { return }
            self.resetTask = nil
            let late = self.now().timeIntervalSince(first.2)
            // Woken long after (the Mac slept through it): no stale news.
            if late < 10 * 60, self.alertsEnabled, self.visibility != .hidden {
                self.peek(LimitsText.resetAlert(first.0, first.1), service: first.0, percent: 0)
            }
            self.updateWing()
            self.armResetWatch()
        }
    }

    /// A used-up limit keeps a quiet wing until its reset (static text: when it comes back).
    private func updateWing() {
        guard running, let hub else { return }
        let t = now()
        let used = readings.filter { !$0.isStale(at: t) }.flatMap { r in r.limits.compactMap { l -> (UsageService, UsageLimit)? in
            guard l.effective(at: t) >= 100, let reset = l.resetsAt, reset > t else { return nil }
            return (r.service, l)
        } }
        // The one that comes back last is what blocks you.
        guard alertsEnabled, let worst = used.max(by: { ($0.1.resetsAt ?? t) < ($1.1.resetsAt ?? t) }), let reset = worst.1.resetsAt else {
            if postedWing != nil { hub.clear(Self.wingID); postedWing = nil }
            return
        }
        let id = "\(worst.0.rawValue)|\(Int(reset.timeIntervalSince1970))"
        guard id != postedWing else { return }
        postedWing = id
        hub.post(LiveActivity(id: Self.wingID, module: .agents, priority: 20, expires: reset,
                              left: AnyView(LimitsWingLeft(service: worst.0)),
                              right: AnyView(LimitsWingRight(reset: reset))))
    }

    // MARK: Where it went

    /// The windows the breakdown splits: each service's current session and week (or the last 5 h
    /// and 7 days) with the official % used.
    func windows() -> [UsageWindowSpan] {
        let t = now()
        return UsageService.allCases.map { s in
            let r = s == .claude ? claude : codex
            func window(_ match: (UsageLimitKind) -> Bool, _ length: TimeInterval) -> (Date, Double?) {
                if let l = r?.limits.first(where: { match($0.kind) }), let reset = l.resetsAt, reset > t {
                    return (reset.addingTimeInterval(-l.window), l.effective(at: t))
                }
                return (t.addingTimeInterval(-length), nil)
            }
            let session = window({ $0.isSession }, 5 * UsageLimit.hour)
            let week = window({ $0.isAllModelsWeek }, UsageLimit.week)
            return UsageWindowSpan(service: s, sessionStart: session.0, sessionPercent: session.1,
                                   weekStart: week.0, weekPercent: week.1)
        }
    }

    /// Reads the logs (only while the page is open), at most once per open.
    func loadBreakdown() {
        guard running, breakdown == nil, !readingLogs, let loader = breakdownLoader else { return }
        readingLogs = true
        let spans = windows()
        breakdownTask = Task { [weak self] in
            let b = await loader(spans)
            guard let self, !Task.isCancelled else { return }
            self.readingLogs = false
            self.breakdownTask = nil
            self.breakdown = b ?? UsageBreakdown(parts: [])
        }
    }

    // MARK: Renderer / demo

    /// Shows readings without fetching anything (renderer, demo, tests).
    func seed(claude: UsageReading?, codex: UsageReading?, status: ClaudeUsageStatus = .ok, breakdown: UsageBreakdown? = nil) {
        if let claude { self.claude = withRates(claude) } else { self.claude = nil }
        if let codex { self.codex = withRates(codex) } else { self.codex = nil }
        claudeStatus = status
        if let breakdown { self.breakdown = breakdown }
        clock = now()
        afterChange(save: false)
    }

    /// The 90% drop-down on the sample's Fable bucket (renderer).
    func showAlertForRender(now: Date) {
        guard let r = claude, let l = r.limits.first(where: { $0.kind.bucketModel != nil }) ?? r.limits.first else { return }
        peek(LimitsText.alert(.claude, l, level: 90, now: now), service: .claude, percent: l.effective(at: now))
    }

    /// Made-up readings for the renderer and the demo (Burny's demo data).
    static func sampleReadings(now: Date) -> (claude: UsageReading, codex: UsageReading) {
        func at(_ h: Double) -> Date { now.addingTimeInterval(h * UsageLimit.hour) }
        let session = UsageLimit(kind: .session(hours: 5), percent: 42, resetsAt: at(2.3), window: 5 * UsageLimit.hour,
                                 measuredAt: now, recentRate: 70 / UsageLimit.hour)
        let claude = UsageReading(service: .claude, plan: "Max 5x", limits: [
            session,
            UsageLimit(kind: .week(model: "all models"), percent: 58, resetsAt: at(76), window: UsageLimit.week, measuredAt: now),
            UsageLimit(kind: .week(model: "Fable"), percent: 92, resetsAt: at(76), window: UsageLimit.week, measuredAt: now),
        ], updated: now)
        let codexAt = now.addingTimeInterval(-12 * 60)
        let codex = UsageReading(service: .codex, plan: "Plus", limits: [
            UsageLimit(kind: .session(hours: 5), percent: 18, resetsAt: at(3.7), window: 5 * UsageLimit.hour, measuredAt: codexAt),
            UsageLimit(kind: .week(model: nil), percent: 31, resetsAt: at(122), window: UsageLimit.week, measuredAt: codexAt),
        ], updated: codexAt)
        return (claude, codex)
    }
}

extension JSONEncoder {
    static var iso: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
