import Foundation

// Plan limits of the coding agents (ported from Burny, the owner's menu-bar app): Claude Code's
// 5-hour session, weekly (all models) and per-model weekly buckets; Codex's 5-hour and weekly
// windows. % used, the pace marker, the burn forecast, reset countdowns.
//
// Where the numbers come from, and why it is safe (Burny's guarantees, unchanged):
//   - Claude Code: the official CLI's local `/usage` (0 tokens, the model is never called), run only
//     after the binary's Anthropic signature checks out, with no tools, no MCP servers, no hooks, no
//     settings, a $0.0001 cap, no saved session, sandboxed away from personal folders
//     (`ClaudeUsageCLI`).
//   - Codex: the `rate_limits` the Codex CLI already writes in ~/.codex/sessions, read from the
//     rollout stream the Codex source already follows (`CodexRollout`).
// Glancy never reads tokens, cookies or passwords, never calls a private endpoint and never sends
// a message on anyone's behalf.

/// The two services whose plan limits are shown.
public enum UsageService: String, Sendable, CaseIterable, Codable {
    case claude, codex

    public var name: String { self == .claude ? "Claude Code" : "Codex" }
    var agent: AgentKind { self == .claude ? .claudeCode : .codex }
}

/// What a limit is: a 5-hour session, a week (all models or one model's bucket), or another window.
public enum UsageLimitKind: Hashable, Sendable, Codable {
    case session(hours: Int)
    case week(model: String?)   // nil (Codex) or "all models" (Claude) = every model
    case other(hours: Int)

    var isSession: Bool { if case .session = self { return true }; return false }
    /// The week every model counts toward (Claude's "all models", Codex's only week).
    var isAllModelsWeek: Bool { self == .week(model: nil) || self == .week(model: "all models") }
    /// A per-model weekly bucket (e.g. Fable).
    var bucketModel: String? {
        if case .week(let m?) = self, m != "all models" { return m }
        return nil
    }
}

public struct UsageLimit: Sendable, Equatable, Codable, Identifiable {
    public var kind: UsageLimitKind
    /// % used when measured, 0…100.
    public var percent: Double
    public var resetsAt: Date?
    /// The window's length (for the pace marker): 5 h, a week.
    public var window: TimeInterval
    /// When `percent` was observed.
    public var measuredAt: Date
    /// Sessions: % per second over the last 30 minutes of readings (`UsageLimits` sets it).
    public var recentRate: Double?

    public var id: UsageLimitKind { kind }

    public init(kind: UsageLimitKind, percent: Double, resetsAt: Date?, window: TimeInterval,
                measuredAt: Date = .now, recentRate: Double? = nil) {
        self.kind = kind; self.percent = percent; self.resetsAt = resetsAt; self.window = window
        self.measuredAt = measuredAt; self.recentRate = recentRate
    }

    static let hour: TimeInterval = 3600
    static let week: TimeInterval = 7 * 86400

    /// A window whose reset has passed is empty again.
    public func effective(at now: Date) -> Double {
        if let r = resetsAt, r < now { return 0 }
        return percent
    }

    /// Fraction of the window already elapsed: where an even pace would be (the tick on the bar).
    public func pace(at now: Date) -> Double? {
        guard let r = resetsAt, r > now, window > 0 else { return nil }
        return min(1, max(0, 1 - r.timeIntervalSince(now) / window))
    }

    /// Burn rate in % per second. Burny's rules, from replaying ten weeks of real usage:
    ///  - session: the last 30 minutes predict best;
    ///  - longer windows: the average since the window opened, once a day of it (or a fifth of the
    ///    window) has passed.
    var rate: Double? {
        if kind.isSession { return recentRate }
        guard let r = resetsAt, window > 0, percent > 0 else { return nil }
        let elapsed = window - r.timeIntervalSince(measuredAt)
        guard elapsed >= min(24 * Self.hour, window * 0.2) else { return nil }
        return percent / elapsed
    }

    /// Weekly limits: the share you can use per day and still last until the reset.
    public func dailyBudget(at now: Date) -> Double? {
        guard case .week = kind, let r = resetsAt, r.timeIntervalSince(now) > 86400, effective(at: now) < 100 else { return nil }
        return (100 - effective(at: now)) / (r.timeIntervalSince(now) / 86400)
    }

    /// When the limit hits 100% at the current burn rate, only when that is likely: the pace must
    /// reach 115% before the reset, a session forecast looks one hour ahead, and stale data (> 6 h)
    /// forecasts nothing.
    public func runsOutAt(now: Date) -> Date? {
        guard percent < 100, let rate, rate > 0, let r = resetsAt, r > now,
              now.timeIntervalSince(measuredAt) < 6 * Self.hour else { return nil }
        guard measuredAt.addingTimeInterval((115 - percent) / rate) < r else { return nil }
        let eta = max(measuredAt.addingTimeInterval((100 - percent) / rate), now)
        if kind.isSession && eta.timeIntervalSince(now) > Self.hour { return nil }
        return eta
    }
}

/// One service's last reading.
public struct UsageReading: Sendable, Equatable, Codable {
    public var service: UsageService
    /// "Max 20x", "Pro", "Plus"…
    public var plan: String?
    public var limits: [UsageLimit]
    public var updated: Date

    public init(service: UsageService, plan: String?, limits: [UsageLimit], updated: Date) {
        self.service = service; self.plan = plan; self.limits = limits; self.updated = updated
    }

    /// The limit closest to running out.
    public func peak(at now: Date) -> UsageLimit? { limits.max { $0.effective(at: now) < $1.effective(at: now) } }

    /// Claude is read every few minutes; Codex only updates when it is used.
    public func isStale(at now: Date) -> Bool {
        now.timeIntervalSince(updated) > (service == .codex ? 6 * UsageLimit.hour : 30 * 60)
    }

    /// A model's bucket that resets together with the all-models week.
    func sharesWeekReset(_ l: UsageLimit) -> Bool {
        guard l.kind.bucketModel != nil, let r = l.resetsAt else { return false }
        return limits.contains { $0.kind.isAllModelsWeek && $0.resetsAt.map { abs($0.timeIntervalSince(r)) < 120 } == true }
    }

    /// A per-model weekly bucket past 90% while the all-models week still has room: suggest
    /// switching. (limit, % left on the other models)
    public func switchHint(at now: Date) -> (limit: UsageLimit, left: Int)? {
        guard let all = limits.first(where: { $0.kind == .week(model: "all models") }), all.effective(at: now) < 90,
              let tight = limits.first(where: { $0.kind.bucketModel != nil && $0.effective(at: now) >= 90 }) else { return nil }
        return (tight, Int((100 - all.effective(at: now)).rounded()))
    }
}

// MARK: Parsing

enum UsageParser {
    /// The text of Claude Code's `/usage`:
    ///   "Current session: 5% used · resets Sep 28 at 12:40am (Europe/Rome)"
    ///   "Current week (all models): 28% used · resets Oct 3 at 2pm (Europe/Rome)"
    ///   "Current week (Fable): 6% used · resets Oct 3 at 2pm (Europe/Rome)"
    /// Only numbers and dates are taken, with a strict pattern; nothing else of the output is kept.
    static func claudeUsage(_ text: String, now: Date = .now) -> [UsageLimit] {
        guard let re = try? NSRegularExpression(
            pattern: #"^Current (session|week \((.+?)\)): ([\d.]+)% used(?: · resets (.+?)(?: \(([^)]+)\))?)?\s*$"#,
            options: .anchorsMatchLines) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            func g(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
            guard let pct = g(3).flatMap(Double.init), pct >= 0, pct <= 1000 else { return nil }
            let isSession = g(1) == "session"
            let reset = g(4).flatMap { resetDate($0, tz: g(5), now: now) }
            return UsageLimit(kind: isSession ? .session(hours: 5) : .week(model: g(2).map { String($0.prefix(40)) }),
                              percent: pct, resetsAt: reset,
                              window: isSession ? 5 * UsageLimit.hour : UsageLimit.week, measuredAt: now)
        }
    }

    /// "Oct 3 at 2pm", "Sep 28 at 12:40am", "9:05pm", "Oct 3", in the given time zone.
    static func resetDate(_ s: String, tz: String?, now: Date) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz.flatMap(TimeZone.init(identifier:)) ?? .current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = f.timeZone
        f.defaultDate = cal.startOfDay(for: now)   // fields the text omits must not come from the clock
        let str = s.uppercased().replacingOccurrences(of: " AT ", with: " at ")
        for fmt in ["MMM d 'at' h:mma", "MMM d 'at' ha", "h:mma", "ha", "MMM d"] {
            f.dateFormat = fmt
            if var d = f.date(from: str) {
                if fmt.hasPrefix("h"), d < now { d = cal.date(byAdding: .day, value: 1, to: d) ?? d }   // time only: next one
                if d < now.addingTimeInterval(-86400) { d = cal.date(byAdding: .year, value: 1, to: d) ?? d }
                return d
            }
        }
        return nil
    }

    /// The plan badge from ~/.claude.json's `oauthAccount` tier ("Max 20x", "Pro"…). Only that
    /// account record is looked at; no token lives in that file (they are in the keychain).
    static func claudePlan(json data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let acct = obj["oauthAccount"] as? [String: Any] else { return nil }
        let tier = ((acct["organizationRateLimitTier"] as? String) ?? (acct["organizationType"] as? String) ?? "").lowercased()
        if tier.contains("20x") { return "Max 20x" }
        if tier.contains("5x") { return "Max 5x" }
        if tier.contains("max") { return "Max" }
        if tier.contains("pro") { return "Pro" }
        if tier.contains("team") { return "Team" }
        return nil
    }

    /// A Codex `token_count` event's `rate_limits` object:
    ///   {"limit_id":"codex","primary":{"used_percent":97.0,"window_minutes":300,"resets_at":1790131440},
    ///    "secondary":{…,"window_minutes":10080,…},"plan_type":"plus"}
    /// Other limit ids (e.g. "premium", with null windows) are not the plan's windows: nil.
    static func codexRateLimits(_ rl: [String: Any], at ts: Date) -> UsageReading? {
        if let id = rl["limit_id"] as? String, id != "codex" { return nil }
        func lim(_ k: String) -> UsageLimit? {
            guard let d = rl[k] as? [String: Any], let p = (d["used_percent"] as? NSNumber)?.doubleValue else { return nil }
            let mins = (d["window_minutes"] as? NSNumber)?.intValue ?? 0
            let kind: UsageLimitKind = mins >= 10080 ? .week(model: nil)
                : mins > 0 && mins < 1440 ? .session(hours: max(1, mins / 60)) : .other(hours: mins / 60)
            return UsageLimit(kind: kind, percent: p, resetsAt: epoch(d["resets_at"]), window: Double(mins) * 60, measuredAt: ts)
        }
        let limits = [lim("primary"), lim("secondary")].compactMap { $0 }
        guard !limits.isEmpty else { return nil }
        return UsageReading(service: .codex, plan: (rl["plan_type"] as? String).map { $0.capitalized },
                            limits: limits, updated: ts)
    }

    static func epoch(_ v: Any?) -> Date? {
        guard let n = (v as? NSNumber)?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
    }

    /// The last line of a Codex rollout carrying the plan's `rate_limits`, read backwards 256 KB at
    /// a time (at most 8 MB): the launch fallback when no followed rollout has one yet.
    static func lastCodexReading(in url: URL) -> UsageReading? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let needle = Data("\"primary\":{".utf8), chunk: UInt64 = 256 * 1024
        let size = (try? h.seekToEnd()) ?? 0
        var offset = size, buf = Data(), searchEnd = 0
        func parse(_ d: Data) -> UsageReading? {
            guard d.count < 64 << 10,
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let rl = (obj["payload"] as? [String: Any])?["rate_limits"] as? [String: Any] else { return nil }
            let ts = (obj["timestamp"] as? String).flatMap(CodexRollout.parseTimestamp) ?? .distantPast
            return codexRateLimits(rl, at: ts)
        }
        while offset > 0 && size - offset < 8 * 1024 * 1024 {
            let start = offset > chunk ? offset - chunk : 0
            try? h.seek(toOffset: start)
            guard let part = try? h.read(upToCount: Int(offset - start)) else { return nil }
            buf = part + buf
            searchEnd += part.count
            offset = start
            while let r = buf.range(of: needle, options: .backwards, in: 0..<searchEnd) {
                guard let nl = buf[..<r.lowerBound].lastIndex(of: 10) else {
                    if offset == 0 {
                        let end = buf.firstIndex(of: 10) ?? buf.endIndex
                        if let found = parse(buf[..<end]) { return found }
                        searchEnd = 0
                        break
                    }
                    break   // the line began in an earlier chunk
                }
                let end = buf[r.upperBound...].firstIndex(of: 10) ?? buf.endIndex
                if let found = parse(Data(buf[(nl + 1)..<end])) { return found }
                searchEnd = nl
            }
            buf = Data(buf[..<min(buf.count, searchEnd + 64 * 1024)])   // drop the searched tail, keep a margin
            searchEnd = min(searchEnd, buf.count)
        }
        return nil
    }
}
