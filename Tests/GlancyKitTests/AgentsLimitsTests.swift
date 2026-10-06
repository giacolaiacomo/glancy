import Foundation
import SwiftUI
import Testing
@testable import GlancyKit

// Plan limits (ported from Burny): the /usage parser and its safety checks, Codex rate_limits,
// forecasts, the refresh policy, the store (no refresh while collapsed, min interval, refresh on
// open / turn end, the signature gate), the CLI runner (timeout, process group), the cache,
// alerts and "Where it went". Fixtures are Burny's self-test expectations.

private let rome = TimeZone(identifier: "Europe/Rome")!
private let hour: TimeInterval = 3600

/// Burny's /usage fixture (the CLI's text, as `result` of `claude -p /usage --output-format json`).
private let usageText = """
You are currently using your subscription to power your Claude Code usage

Current session: 5% used · resets Sep 28 at 12:40am (Europe/Rome)
Current week (all models): 28% used · resets Oct 3 at 2pm (Europe/Rome)
Current week (Fable): 6% used · resets Oct 3 at 2pm (Europe/Rome)

What's contributing to your limits usage?
"""

private func usageJSON(_ text: String = usageText, turns: Int = 0, cost: Double = 0, apiMS: Int = 0, isError: Bool = false) -> Data {
    try! JSONSerialization.data(withJSONObject: ["type": "result", "is_error": isError, "num_turns": turns, "total_cost_usd": cost,
                                                 "duration_api_ms": apiMS, "result": text])
}

// MARK: Parser

@Test func usageParsesBurnysFixture() {
    let now = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: rome, year: 2026, month: 9, day: 27, hour: 22).date!
    let l = UsageParser.claudeUsage(usageText, now: now)
    #expect(l.count == 3)
    #expect(l.map(\.percent) == [5, 28, 6])
    #expect(l.map(\.kind) == [.session(hours: 5), .week(model: "all models"), .week(model: "Fable")])
    var cal = Calendar(identifier: .gregorian); cal.timeZone = rome
    let reset = l[1].resetsAt.map { cal.dateComponents([.month, .day, .hour, .minute], from: $0) }
    #expect(reset?.month == 10 && reset?.day == 3 && reset?.hour == 14 && reset?.minute == 0)
    let session = l[0].resetsAt.map { cal.dateComponents([.month, .day, .hour, .minute], from: $0) }
    #expect(session?.month == 9 && session?.day == 28 && session?.hour == 0 && session?.minute == 40)
    #expect(l[0].window == 5 * hour && l[1].window == 7 * 86400)
}

@Test func usageParsesBareLinesDecimalsAndTimeOnly() {
    let now = Date()
    let bare = UsageParser.claudeUsage("Current session: 0% used\nCurrent week (all models): 12.5% used · resets 9:05pm (UTC)", now: now)
    #expect(bare.count == 2)
    #expect(bare[0].resetsAt == nil)
    #expect(bare[1].percent == 12.5)
    // A time with no date is the next one.
    #expect(bare[1].resetsAt.map { $0 > now && $0 < now.addingTimeInterval(86400 + 60) } == true)
}

@Test func usageIgnoresEverythingElse() {
    #expect(UsageParser.claudeUsage("Hello\nCurrent mood: 99% used\n$(rm -rf ~)\n", now: .now).isEmpty)
    #expect(UsageParser.claudeUsage("", now: .now).isEmpty)
}

@Test func usageInterpretProvesNoModelTurn() {
    let now = Date()
    if case let .ok(limits, plan) = ClaudeUsageCLI.interpret(usageJSON(), plan: "Max 20x", now: now) {
        #expect(limits.count == 3)
        #expect(plan == "Max 20x")
    } else {
        Issue.record("a 0-turn /usage must parse")
    }
    // Any sign that the model ran, an error, garbage or a changed format: stop calling it.
    #expect(ClaudeUsageCLI.interpret(usageJSON(turns: 1), plan: nil, now: now) == .unexpectedOutput)
    #expect(ClaudeUsageCLI.interpret(usageJSON(cost: 0.01), plan: nil, now: now) == .unexpectedOutput)
    #expect(ClaudeUsageCLI.interpret(usageJSON(apiMS: 900), plan: nil, now: now) == .unexpectedOutput)
    #expect(ClaudeUsageCLI.interpret(usageJSON(isError: true), plan: nil, now: now) == .unexpectedOutput)
    #expect(ClaudeUsageCLI.interpret(usageJSON("Usage looks different now"), plan: nil, now: now) == .unexpectedOutput)
    #expect(ClaudeUsageCLI.interpret(Data("not json".utf8), plan: nil, now: now) == .unexpectedOutput)
}

@Test func claudePlanFromTheAccountTierOnly() {
    func plan(_ tier: String) -> String? {
        UsageParser.claudePlan(json: Data(#"{"oauthAccount":{"organizationRateLimitTier":"\#(tier)"},"projects":{}}"#.utf8))
    }
    #expect(plan("default_claude_max_20x") == "Max 20x")
    #expect(plan("default_claude_max_5x") == "Max 5x")
    #expect(plan("claude_pro") == "Pro")
    #expect(plan("something") == nil)
    #expect(UsageParser.claudePlan(json: Data("{}".utf8)) == nil)
}

@Test func codexReadingFromRateLimits() {
    let rl: [String: Any] = ["limit_id": "codex", "primary": ["used_percent": 97.0, "window_minutes": 300, "resets_at": 1790131440],
                             "secondary": ["used_percent": 31.0, "window_minutes": 10080, "resets_at": 1790679309], "plan_type": "plus"]
    let r = UsageParser.codexRateLimits(rl, at: Date(timeIntervalSince1970: 1790100000))
    #expect(r?.limits.map(\.kind) == [.session(hours: 5), .week(model: nil)])
    #expect(r?.limits.map(\.percent) == [97, 31])
    #expect(r?.plan == "Plus")
    #expect(UsageParser.codexRateLimits(["limit_id": "premium", "primary": NSNull(), "secondary": NSNull()], at: .now) == nil)
    #expect(UsageParser.codexRateLimits(["limit_id": "codex"], at: .now) == nil)
}

@Test func codexLastReadingAcrossChunks() throws {
    // Burny's check: the rate_limits line sits before a > 256 KB line, so the backwards reader crosses chunks.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glancy-limits-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = dir.appendingPathComponent("rollout.jsonl")
    let rl = #"{"timestamp":"2026-09-22T22:16:05.696Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":97.0,"window_minutes":300,"resets_at":1790131440},"secondary":{"used_percent":31.0,"window_minutes":10080,"resets_at":1790679309},"plan_type":"plus"}}}"#
    let premium = #"{"timestamp":"2026-09-22T22:17:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"premium","primary":null,"secondary":null}}}"#
    let noise = #"{"type":"response_item","payload":{"text":"\#(String(repeating: "x", count: 300_000))"}}"#
    try ([#"{"type":"session_meta"}"#, rl, noise, premium].joined(separator: "\n") + "\n").write(to: log, atomically: true, encoding: .utf8)
    let r = UsageParser.lastCodexReading(in: log)
    #expect(r?.limits.first?.percent == 97)
    #expect(r?.updated == CodexRollout.parseTimestamp("2026-09-22T22:16:05.696Z"))
    // First line of the file.
    let first = dir.appendingPathComponent("first.jsonl")
    try (rl + "\n").write(to: first, atomically: true, encoding: .utf8)
    #expect(UsageParser.lastCodexReading(in: first)?.limits.count == 2)
}

// MARK: Forecasts (Burny's rules)

@Test func forecastsFollowBurnysRules() {
    let now = Date()
    var f = UsageLimit(kind: .session(hours: 5), percent: 50, resetsAt: now.addingTimeInterval(2 * hour), window: 5 * hour, measuredAt: now)
    f.recentRate = 60 / hour   // out in 50 minutes, well before the reset
    #expect(f.runsOutAt(now: now).map { abs($0.timeIntervalSince(now) - 50 * 60) < 5 } == true)
    f.recentRate = 20 / hour   // 2.5 h ahead: too far for a session forecast
    #expect(f.runsOutAt(now: now) == nil)
    f.recentRate = 1 / hour
    #expect(f.runsOutAt(now: now) == nil)
    let wk2 = UsageLimit(kind: .week(model: nil), percent: 50, resetsAt: now.addingTimeInterval(5 * 86400), window: 7 * 86400, measuredAt: now)
    #expect(wk2.runsOutAt(now: now).map { abs($0.timeIntervalSince(now) - 2 * 86400) < 60 } == true)
    let wk3 = UsageLimit(kind: .week(model: nil), percent: 30, resetsAt: now.addingTimeInterval(6.6 * 86400), window: 7 * 86400, measuredAt: now)
    #expect(wk3.runsOutAt(now: now) == nil)   // no week forecast in its first day
    let stale = UsageLimit(kind: .week(model: nil), percent: 50, resetsAt: now.addingTimeInterval(5 * 86400), window: 7 * 86400,
                           measuredAt: now.addingTimeInterval(-7 * hour))
    #expect(stale.runsOutAt(now: now) == nil)  // no forecasts from stale data
    let wk = UsageLimit(kind: .week(model: nil), percent: 40, resetsAt: now.addingTimeInterval(3 * 86400 + 60), window: 7 * 86400, measuredAt: now)
    #expect(wk.dailyBudget(at: now).map { abs($0 - 20) < 0.1 } == true)
    #expect(wk.pace(at: now).map { abs($0 - 4.0 / 7) < 0.01 } == true)
    let past = UsageLimit(kind: .session(hours: 5), percent: 80, resetsAt: now.addingTimeInterval(-60), window: 5 * hour, measuredAt: now)
    #expect(past.effective(at: now) == 0)   // a window whose reset passed is empty again
}

@Test func switchHintWhenOneBucketIsNearlyUsedUp() {
    let fable = UsageReading(service: .claude, plan: nil, limits: [
        UsageLimit(kind: .week(model: "all models"), percent: 50, resetsAt: nil, window: 7 * 86400),
        UsageLimit(kind: .week(model: "Fable"), percent: 93, resetsAt: nil, window: 7 * 86400)], updated: .now)
    #expect(fable.switchHint(at: .now)?.limit.kind == .week(model: "Fable"))
    #expect(fable.switchHint(at: .now)?.left == 50)
}

@Test func compactCountdownsAndLabels() {
    let now = Date()
    #expect(LimitsText.compactUntil(now.addingTimeInterval(3 * hour + 5 * 60 + 30), now: now) == "3h05")
    #expect(LimitsText.compactUntil(now.addingTimeInterval(45 * 60 + 30), now: now) == "45m")
    #expect(LimitsText.compactUntil(now.addingTimeInterval(-1), now: now) == nil)
    #expect(LimitsText.short(.week(model: "Fable")) == "Fable")
    #expect(LimitsText.short(.session(hours: 5)) == "5h")
}

// MARK: Refresh policy

@Test func refreshPolicy() {
    let p = UsageRefreshPolicy(minInterval: 60, staleAfter: 300)
    let now = Date()
    let old = now.addingTimeInterval(-600), fresh = now.addingTimeInterval(-120)
    func ok(_ t: UsageRefreshPolicy.Trigger, attempt: Date? = nil, reading: Date? = nil, v: SurfaceVisibility = .expanded(.agents),
            running: Bool = false, blocked: Bool = false) -> Bool {
        p.shouldRefresh(t, now: now, lastAttempt: attempt, lastReading: reading, visibility: v, running: running, blocked: blocked)
    }
    // Opening the tab: only a stale (or missing) reading, only while expanded.
    #expect(ok(.panelOpened))
    #expect(ok(.panelOpened, reading: old))
    #expect(!ok(.panelOpened, reading: fresh))
    #expect(!ok(.panelOpened, reading: old, v: .collapsed))
    // Never while the Mac / its screens sleep or the session is locked.
    #expect(!ok(.panelOpened, reading: old, v: .hidden))
    #expect(!ok(.agentStopped, reading: old, v: .hidden))
    #expect(!ok(.manual, v: .hidden))
    // A turn ending (an event, not a timer) refreshes a stale reading, even with the notch closed.
    #expect(ok(.agentStopped, reading: old, v: .collapsed))
    #expect(!ok(.agentStopped, reading: fresh, v: .collapsed))
    // Never more often than once a minute, whatever asks.
    #expect(!ok(.manual, attempt: now.addingTimeInterval(-30)))
    #expect(ok(.manual, attempt: now.addingTimeInterval(-61), reading: fresh))
    #expect(!ok(.agentStopped, attempt: now.addingTimeInterval(-30), reading: old, v: .collapsed))
    // Never two at once; never again after a failed signature or an unexpected answer.
    #expect(!ok(.manual, running: true))
    #expect(!ok(.manual, blocked: true))
}

// MARK: Store

final class FakeFetcher: ClaudeUsageFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0, _cancels = 0
    var outcome: ClaudeUsageOutcome
    let installed: Bool
    /// Blocks each fetch until released (cancel releases it).
    let gate = DispatchSemaphore(value: 0)
    var blocks = false

    init(_ outcome: ClaudeUsageOutcome = .ok([UsageLimit(kind: .session(hours: 5), percent: 42, resetsAt: Date().addingTimeInterval(7200),
                                                         window: 18000)], plan: "Max 5x"), installed: Bool = true) {
        self.outcome = outcome
        self.installed = installed
    }
    var count: Int { lock.withLock { _count } }
    var cancels: Int { lock.withLock { _cancels } }
    var isInstalled: Bool { installed }
    func fetch(now: @Sendable () -> Date) -> ClaudeUsageOutcome {
        lock.withLock { _count += 1 }
        if blocks { gate.wait() }
        return lock.withLock { outcome }
    }
    func cancel() {
        lock.withLock { _cancels += 1 }
        if blocks { gate.signal() }
    }
}

@MainActor
private func makeStore(_ fetcher: FakeFetcher = FakeFetcher(), cache: URL? = nil) -> (UsageLimitsStore, ActivityHub, UserDefaults, String) {
    let suite = "glancy.test.limits.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    let store = UsageLimitsStore(fetcher: fetcher, cacheURL: cache, defaults: d, codexPresent: { true })
    let hub = ActivityHub()
    store.start(hub: hub)
    return (store, hub, d, suite)
}

@MainActor
private func settle(_ store: UsageLimitsStore, _ timeout: Double = 5) async {
    let end = Date().addingTimeInterval(timeout)
    while store.fetching, Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
}

@MainActor @Test func storeNeverRefreshesWhileCollapsedWithNothingHappening() async {
    let f = FakeFetcher()
    let (store, _, _, suite) = makeStore(f)
    defer { store.stop(); UserDefaults().removePersistentDomain(forName: suite) }
    store.visibilityChanged(.collapsed)
    try? await Task.sleep(for: .milliseconds(300))
    #expect(f.count == 0)
    // Even asked as if the panel opened, a closed notch fetches nothing.
    #expect(!store.refresh(.panelOpened))
    store.visibilityChanged(.expanded(.calendar))   // another tab: not the Agents one
    #expect(f.count == 0)
    store.visibilityChanged(.hidden)
    #expect(!store.refresh(.agentStopped))
    #expect(f.count == 0)
}

@MainActor @Test func storeRefreshesOnOpenOnceAMinuteAndOnTurnEnd() async {
    let f = FakeFetcher()
    let (store, _, _, suite) = makeStore(f)
    defer { store.stop(); UserDefaults().removePersistentDomain(forName: suite) }
    var clock = Date()
    store.now = { clock }
    store.visibilityChanged(.expanded(.agents))
    await settle(store)
    #expect(f.count == 1)
    #expect(store.claude?.limits.first?.percent == 42)
    #expect(store.claude?.plan == "Max 5x")
    #expect(store.claudeStatus == .ok)
    // Reopened at once: the reading is fresh, nothing runs; the button too waits a minute.
    store.visibilityChanged(.collapsed)
    store.visibilityChanged(.expanded(.agents))
    #expect(!store.refresh(.manual))
    #expect(f.count == 1)
    clock = clock.addingTimeInterval(61)
    #expect(store.refresh(.manual))
    await settle(store)
    #expect(f.count == 2)
    // A Claude turn ends with the notch closed: refreshed once the reading is older than 5 minutes.
    store.visibilityChanged(.collapsed)
    clock = clock.addingTimeInterval(120)
    store.claudeTurnEnded()
    #expect(f.count == 2)
    clock = clock.addingTimeInterval(240)
    store.claudeTurnEnded()
    await settle(store)
    #expect(f.count == 3)
}

@MainActor @Test func storeStopsCallingAfterSignatureFailure() async {
    let f = FakeFetcher(.notGenuine)
    let (store, _, _, suite) = makeStore(f)
    defer { store.stop(); UserDefaults().removePersistentDomain(forName: suite) }
    var clock = Date()
    store.now = { clock }
    store.visibilityChanged(.expanded(.agents))
    await settle(store)
    #expect(store.claudeStatus == .notGenuine)
    clock = clock.addingTimeInterval(3600)
    #expect(!store.refresh(.manual))
    store.claudeTurnEnded()
    #expect(f.count == 1)
    // Turning it off and on is the explicit retry.
    store.claudeEnabled = false
    f.outcome = .unexpectedOutput
    store.claudeEnabled = true
    await settle(store)
    #expect(f.count == 2)
    #expect(store.claudeStatus == .unexpectedOutput)
    clock = clock.addingTimeInterval(3600)
    #expect(!store.refresh(.manual))
}

@MainActor @Test func storeCancelsTheRunOnStopAndSleep() async {
    let f = FakeFetcher()
    f.blocks = true
    let (store, _, _, suite) = makeStore(f)
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    store.visibilityChanged(.expanded(.agents))
    #expect(store.fetching)
    store.visibilityChanged(.hidden)   // the Mac goes to sleep: the child is let go
    #expect(f.cancels >= 1)
    await settle(store)
    #expect(!store.fetching)
    f.blocks = false
    store.stop()
    #expect(f.cancels >= 2)
}

@MainActor @Test func claudeOnByDefaultOnlyWhenTheCLIIsInstalled() {
    let (on, _, _, s1) = makeStore(FakeFetcher(installed: true))
    let (off, _, _, s2) = makeStore(FakeFetcher(installed: false))
    defer { on.stop(); off.stop(); UserDefaults().removePersistentDomain(forName: s1); UserDefaults().removePersistentDomain(forName: s2) }
    #expect(on.claudeEnabled)
    #expect(!off.claudeEnabled)
    let suite = "glancy.test.limits.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let noCodex = UsageLimitsStore(fetcher: nil, cacheURL: nil, defaults: UserDefaults(suiteName: suite)!, codexPresent: { false })
    #expect(!noCodex.codexEnabled)
    // Isolated (renderer, demo, self-test): nothing read from the user's defaults.
    let isolated = UsageLimitsStore(fetcher: nil, cacheURL: nil, defaults: nil, codexPresent: { true })
    #expect(!isolated.claudeEnabled && !isolated.codexEnabled)
}

@MainActor @Test func storeShowsTheCachedReadingAtLaunch() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glancy-limits-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let cache = dir.appendingPathComponent("limits.json")
    let (store, _, _, suite) = makeStore(FakeFetcher(), cache: cache)
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    store.visibilityChanged(.expanded(.agents))
    await settle(store)
    store.adoptCodex(UsageReading(service: .codex, plan: "Plus", limits: [
        UsageLimit(kind: .week(model: nil), percent: 31, resetsAt: Date().addingTimeInterval(86400 * 3), window: 7 * 86400)], updated: .now))
    store.stop()
    let end = Date().addingTimeInterval(5)
    while Date() < end, (try? Data(contentsOf: cache)).map({ String(decoding: $0, as: UTF8.self).contains("\"codex\"") }) != true {
        try? await Task.sleep(for: .milliseconds(20))
    }
    let (again, _, _, suite2) = makeStore(FakeFetcher(), cache: cache)
    defer { again.stop(); UserDefaults().removePersistentDomain(forName: suite2) }
    #expect(again.claude?.limits.first?.percent == 42)
    #expect(again.codex?.limits.first?.percent == 31)
    #expect(again.codex?.plan == "Plus")
}

@MainActor @Test func alertsOncePerLimitWindowAndLevel() async {
    let (store, hub, _, suite) = makeStore(FakeFetcher(installed: false))
    defer { store.stop(); UserDefaults().removePersistentDomain(forName: suite) }
    let reset = Date().addingTimeInterval(2 * 86400)
    func codex(_ p: Double, at: Date = .now) -> UsageReading {
        UsageReading(service: .codex, plan: nil, limits: [UsageLimit(kind: .week(model: nil), percent: p, resetsAt: reset, window: 7 * 86400,
                                                                     measuredAt: at)], updated: at)
    }
    store.adoptCodex(codex(50))
    #expect(hub.peek == nil)
    store.adoptCodex(codex(91, at: .now.addingTimeInterval(1)))
    #expect(hub.peek != nil)   // 90%
    let first = hub.peek?.id
    store.adoptCodex(codex(93, at: .now.addingTimeInterval(2)))
    #expect(hub.peek?.id == first)   // same level, same window: no second drop-down
    // Used up: a quiet wing until the reset.
    store.adoptCodex(codex(100, at: .now.addingTimeInterval(3)))
    #expect(hub.top?.id == UsageLimitsStore.wingID)
    #expect(hub.top?.expires == reset)
    store.alertsEnabled = false
    #expect(hub.top == nil)
}

// MARK: The CLI runner (safety, timeout, process group)

@Test func signatureFailureMeansTheCLINeverRuns() {
    let ran = Box(false)
    let cli = ClaudeUsageCLI(home: URL(fileURLWithPath: "/tmp"), workDir: FileManager.default.temporaryDirectory, timeout: 5)
    cli.locate = { "/bin/echo" }
    cli.verify = { _ in false }
    cli.run = { _, _, _, _, _, _ in ran.value = true; return ChildRun.Result(status: 0, output: usageJSON(), killed: false) }
    #expect(cli.fetch() == .notGenuine)
    #expect(!ran.value)
    cli.locate = { nil }
    #expect(cli.fetch() == .notInstalled)
    #expect(!ran.value)
}

@Test func theCLIRunsLockedDown() {
    let seen = Box<(String, [String], [String: String])?>(nil)
    let cli = ClaudeUsageCLI(home: URL(fileURLWithPath: "/Users/someone"), workDir: FileManager.default.temporaryDirectory, timeout: 5)
    cli.locate = { "/bin/echo" }
    cli.verify = { _ in true }
    cli.run = { exe, args, env, _, timeout, _ in
        seen.value = (exe, args, env)
        #expect(timeout == 5)
        return ChildRun.Result(status: 0, output: usageJSON(), killed: false)
    }
    guard case .ok(let limits, _) = cli.fetch() else { Issue.record("expected a reading"); return }
    #expect(limits.count == 3)
    let (exe, args, env) = seen.value!
    #expect(exe == "/usr/bin/sandbox-exec")
    #expect(args[0] == "-p" && args[1].contains("(deny file-read* file-write*") && args[1].contains("/Users/someone/Documents"))
    #expect(args[2] == "/bin/echo")
    let rest = Array(args.dropFirst(3))
    #expect(rest == ClaudeUsageCLI.arguments)
    #expect(rest.contains("/usage") && rest.contains("--no-session-persistence") && rest.contains("--strict-mcp-config"))
    #expect(rest[rest.firstIndex(of: "--tools")! + 1] == "")
    #expect(rest[rest.firstIndex(of: "--settings")! + 1] == #"{"disableAllHooks":true}"#)
    #expect(Set(env.keys).isSubset(of: ["HOME", "USER", "PATH", "LANG", "TMPDIR"]))
    // A killed / timed-out run is a plain failure (a later refresh may try again).
    cli.run = { _, _, _, _, _, _ in ChildRun.Result(status: -2, output: Data(), killed: true) }
    #expect(cli.fetch() == .failed)
}

@Test func signatureIsVerifiedOncePerBinary() {
    let calls = Box(0)
    let cli = ClaudeUsageCLI(home: URL(fileURLWithPath: "/tmp"), workDir: FileManager.default.temporaryDirectory)
    cli.verify = { _ in calls.value += 1; return true }
    #expect(cli.isGenuine("/bin/echo"))
    #expect(cli.isGenuine("/bin/echo"))
    #expect(calls.value == 1)
}

@Test func codesignRejectsANonAnthropicBinary() {
    // Apple's own /bin/echo is validly signed, but not by Anthropic's team.
    #expect(!ClaudeUsageCLI.codesignVerify("/bin/echo"))
}

@Test func childRunTimesOutAndKillsTheWholeGroup() throws {
    let child = ChildRun()
    let start = Date()
    // The shell starts a grandchild, prints its pid and waits: the timeout must take both.
    let r = child.run("/bin/sh", ["-c", "sleep 30 & echo $!; wait"], env: [:], cwd: "/", timeout: 0.5)
    #expect(Date().timeIntervalSince(start) < 5)
    #expect(r.killed)
    let grandchild = pid_t(String(decoding: r.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    #expect(grandchild > 1)
    var gone = false
    for _ in 0..<100 where !gone { gone = kill(grandchild, 0) != 0; if !gone { Thread.sleep(forTimeInterval: 0.02) } }
    #expect(gone)
    #expect(child.runningPID == 0)
    #expect(!ChildProcesses.current.contains(grandchild))
}

@Test func childRunKillFromAnotherThread() {
    let child = ChildRun()
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { child.kill() }
    let start = Date()
    let r = child.run("/bin/sleep", ["30"], env: [:], cwd: "/", timeout: 30)
    #expect(r.killed)
    #expect(Date().timeIntervalSince(start) < 5)
    // Killed before it starts: never started.
    let early = ChildRun()
    early.kill()
    #expect(early.run("/bin/sleep", ["30"], env: [:], cwd: "/", timeout: 30).status == -1)
}

@Test func childRunReadsOutputAndStatus() {
    let r = ChildRun().run("/bin/sh", ["-c", "echo hello; exit 3"], env: [:], cwd: "/", timeout: 5)
    #expect(String(decoding: r.output, as: UTF8.self) == "hello\n")
    #expect(r.status == 3)
    #expect(!r.killed)
}

// MARK: Where it went (Burny's ledger checks)

@Test func ledgerCountsARepeatedReplyOnceAndReadsIncrementally() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glancy-ledger-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("claude/p"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let ts = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
    func reply(_ id: String, _ out: Int) -> String {
        #"{"type":"assistant","timestamp":"\#(ts)","cwd":"/Users/x/demo","message":{"id":"\#(id)","model":"claude-sonnet-5","usage":{"input_tokens":1000000,"output_tokens":\#(out)}}}"#
    }
    let log = dir.appendingPathComponent("claude/p/s.jsonl")
    try ([reply("a", 0), reply("a", 1_000_000), #"{"type":"user"}"#].joined(separator: "\n") + "\n").write(to: log, atomically: true, encoding: .utf8)
    func ledger() -> UsageLedger {
        UsageLedger(claudeRoot: dir.appendingPathComponent("claude"), codexRoot: dir.appendingPathComponent("codex"),
                    cacheURL: dir.appendingPathComponent("usage.json"))
    }
    let l = ledger()
    l.update()
    #expect(abs(l.split("Claude Code", from: Date().addingTimeInterval(-hour), to: Date()).cost - 18) < 0.001)   // $3 in + $15 out
    let h = try FileHandle(forWritingTo: log)
    h.seekToEndOfFile(); h.write(Data((reply("b", 0) + "\n").utf8)); try h.close()
    let again = ledger()
    again.update()
    let after = again.split("Claude Code", from: Date().addingTimeInterval(-hour), to: Date())
    #expect(abs(after.cost - 21) < 0.001)
    #expect(after.projects.first?.0 == "demo")
    // The app reads only the totals.
    let buckets = UsageLedger.loadBuckets(dir.appendingPathComponent("usage.json"))
    #expect(buckets?.count == 1)
    let spans = [UsageWindowSpan(service: .claude, sessionStart: Date().addingTimeInterval(-hour), sessionPercent: 40,
                                 weekStart: Date().addingTimeInterval(-86400), weekPercent: 20)]
    let b = UsageBreakdown(buckets: buckets ?? [:], windows: spans, now: .now)
    #expect(b.byWeek.first?.rows(limit: 2).first?.name == "demo")
    #expect(b.bySession.first?.percent == 40)
}

@Test func ledgerNames() {
    #expect(usageModelName("claude-opus-5-5") == "Opus 5.5")
    #expect(usageModelName("claude-haiku-4-5-20251001") == "Haiku 4.5")
    #expect(usageModelName("gpt-6-astra") == "GPT-6 Astra")
    #expect(usageModelName("codex-auto-review") == "Codex Auto Review")
    #expect(usageProjectName("/Users/x/Projects/app/.claude/worktrees/agent-1") == "app")
    #expect(usageProjectName("/private/var/folders/a/T/tmp.x") == usageTempProject)
    #expect(usageProjectName("/Users/x", home: "/Users/x") == "~")
}

// MARK: Module wiring

@MainActor @Test func moduleRoutesCodexLimitsAndClaudeTurnEnds() async {
    let f = FakeFetcher()
    let suite = "glancy.test.limits.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let d = UserDefaults(suiteName: suite)!
    let limits = UsageLimitsStore(fetcher: f, cacheURL: nil, defaults: d, codexPresent: { true })
    let source = ScriptedSource()
    let module = AgentsModule(sources: [source], defaults: d, limits: limits)
    module.start(hub: ActivityHub())
    defer { module.stop() }
    module.visibilityChanged(.collapsed)
    let reading = UsageReading(service: .codex, plan: "Plus", limits: [
        UsageLimit(kind: .session(hours: 5), percent: 12, resetsAt: Date().addingTimeInterval(3600), window: 18000)], updated: .now)
    source.send(.limits(reading))
    #expect(module.limits.codex == reading)
    // A Claude turn ends while collapsed: one /usage (no reading yet).
    source.send(.events([AgentEvent(ts: .now, kind: .stop, sessionID: "s", cwd: "/tmp/x")], quiet: false))
    await settle(limits)
    #expect(f.count == 1)
    // A quiet (catch-up) batch never triggers anything.
    source.send(.events([AgentEvent(ts: .now, kind: .stop, sessionID: "s", cwd: "/tmp/x")], quiet: true))
    #expect(f.count == 1)
}

@MainActor
final class ScriptedSource: AgentSource {
    let kind = AgentKind.claudeCode
    private var sink: (@MainActor (AgentKind, AgentSourceUpdate) -> Void)?
    func start(_ sink: @escaping @MainActor (AgentKind, AgentSourceUpdate) -> Void) { self.sink = sink }
    func stop() { sink = nil }
    func status() -> AgentSourceStatus { AgentSourceStatus(.ok, "") }
    func send(_ u: AgentSourceUpdate) { sink?(kind, u) }
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

@MainActor @Test func collapsedLimitStatesReallyShowTheirWingAndPeek() {
    let module = AgentsModule(sources: [], defaults: UserDefaults(suiteName: "glancy.test.limits.\(UUID().uuidString)")!)
    let hub = ActivityHub()
    module.start(hub: hub)
    defer { module.stop() }
    module.prepareLimitsForRender(.usedUpWing)
    #expect(hub.top?.id == UsageLimitsStore.wingID)
    #expect(hub.peek == nil)
    let other = AgentsModule(sources: [], defaults: UserDefaults(suiteName: "glancy.test.limits.\(UUID().uuidString)")!)
    let hub2 = ActivityHub()
    other.start(hub: hub2)
    defer { other.stop() }
    other.seedLimitsSample()
    other.prepareLimitsForRender(.alertPeek)
    #expect(hub2.peek != nil)
}
