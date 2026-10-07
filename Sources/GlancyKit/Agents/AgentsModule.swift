import SwiftUI

/// Coding agents in the notch (SPEC §3 Agents): Claude Code (hook log), Codex (session rollouts)
/// and OpenCode (its database, plus an optional plugin), wherever they run — a terminal, VS Code,
/// Cursor, the Codex app. One board, one state machine; each source can be turned off.
public final class AgentsModule: GlancyModule {
    public nonisolated static let defaultLogURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/hooks/data/cc-dashboard/events.jsonl")

    public let id = ModuleID.agents
    public let model = AgentsModel()
    /// Claude Code and Codex plan limits (the column and pages in the tab, the Home card, alerts).
    public let limits: UsageLimitsStore
    /// The page the tab opens on (the renderer; otherwise the sessions).
    var tabPage: AgentsTabPage = .sessions
    /// Every source this module can read, in display order.
    let sources: [any AgentSource]
    private let defaults: UserDefaults
    private var running = false
    /// Sources started in this run (turning one off stops it at once).
    private var started = Set<AgentKind>()
    private var keyMonitor: Any?
    private var onAgentsOrHome = false

    /// The real sources: the Claude hook log, ~/.codex/sessions, OpenCode's data folder.
    public convenience init() {
        let limits = UsageLimitsStore(fetcher: ClaudeUsageCLI(),
                                      cacheURL: UsageLimitsStore.defaultCacheDir.appendingPathComponent("limits.json"))
        // "Where it went" reads the logs in a short-lived `Glancy --usage-scan` child (only from the app's own binary).
        if let exe = Bundle.main.executableURL, exe.lastPathComponent == "Glancy" {
            limits.breakdownLoader = UsageLedger.childLoader(executable: exe.path)
        }
        self.init(sources: [ClaudeHookSource(logURL: Self.defaultLogURL), CodexSource(), OpenCodeSource()], limits: limits)
    }

    /// Claude Code only, from `logURL` (isolated runs, tests, the demo): nothing else of the user's is read.
    public convenience init(logURL: URL) {
        self.init(sources: [ClaudeHookSource(logURL: logURL)])
    }

    /// - Parameter limits: nil = an isolated store: nothing fetched or read, settings in memory.
    init(sources: [any AgentSource], defaults: UserDefaults = .standard, limits: UsageLimitsStore? = nil) {
        self.sources = sources
        self.defaults = defaults
        self.limits = limits ?? UsageLimitsStore(fetcher: nil, cacheURL: nil, defaults: nil, codexPresent: { false })
    }

    /// The tiler for ⌥-click and "Lay out sessions" (the Windows module), wired in Modules.make().
    var tiling: (any AgentsTiling)? {
        get { model.tiling }
        set { model.tiling = newValue }
    }

    // MARK: Sources

    static let disabledKey = "agents.disabledSources"

    public var availableSources: [AgentKind] { sources.map(\.kind) }

    public func isSourceEnabled(_ kind: AgentKind) -> Bool {
        !(defaults.stringArray(forKey: Self.disabledKey) ?? []).contains(kind.rawValue)
    }

    /// Turns one source on or off (remembered). Off: its watcher stops and its rows go at once.
    public func setSource(_ kind: AgentKind, enabled: Bool) {
        var off = Set(defaults.stringArray(forKey: Self.disabledKey) ?? [])
        if enabled { off.remove(kind.rawValue) } else { off.insert(kind.rawValue) }
        defaults.set(off.sorted(), forKey: Self.disabledKey)
        guard running, let source = sources.first(where: { $0.kind == kind }) else { return }
        if enabled, !started.contains(kind) {
            startSource(source)
        } else if !enabled, started.contains(kind) {
            source.stop()
            started.remove(kind)
            model.removeSource(kind)
        }
    }

    /// One line per source for Settings → Agents.
    public func sourceStatus(_ kind: AgentKind) -> AgentSourceStatus {
        guard isSourceEnabled(kind) else { return AgentSourceStatus(.off, AgentsText.t("Off")) }
        return sources.first { $0.kind == kind }?.status() ?? AgentSourceStatus(.missing, "")
    }

    /// The OpenCode plugin's installer (Settings → Agents), nil when OpenCode is not a source here.
    var openCodeInstaller: OpenCodePluginInstaller? {
        (sources.first { $0.kind == .opencode } as? OpenCodeSource)?.installer
    }

    public func start(hub: ActivityHub) {
        guard !running else { return }
        running = true
        model.hub = hub
        model.onWantsKeys = { [weak self] on in self?.wantsKeys(on) }
        limits.start(hub: hub)
        for source in sources where isSourceEnabled(source.kind) { startSource(source) }
        model.refresh()   // sessions already held (the renderer's sample) reach the wings
    }

    private func startSource(_ source: any AgentSource) {
        started.insert(source.kind)
        source.start { [weak self] kind, update in
            guard let self, self.started.contains(kind) else { return }   // turned off meanwhile
            switch update {
            case .limits(let reading):
                if self.running { self.limits.adoptCodex(reading) }
            case let .events(events, quiet):
                self.deliver { $0.apply(update, from: kind) }
                // A Claude Code turn or session ended: the moment its limits moved.
                if self.running, !quiet, kind == .claudeCode,
                   events.contains(where: { $0.kind == .stop || $0.kind == .sessionEnd || $0.kind == .stopFailure }) {
                    self.limits.claudeTurnEnded()
                }
            case .rebuilt:
                self.deliver { $0.apply(update, from: kind) }
            }
        }
    }

    /// Drops batches that were already queued for main when `stop()` ran.
    private func deliver(_ body: (AgentsModel) -> Void) {
        if running { body(model) }
    }

    public func stop() {
        guard running else { return }
        running = false
        for source in sources where started.contains(source.kind) { source.stop() }
        started = []
        model.endTiling()
        model.onWantsKeys = nil
        wantsKeys(false)
        limits.stop()
        model.hub?.clearAll(from: .agents)
        model.reset()
        model.hub = nil
    }

    public func visibilityChanged(_ visibility: SurfaceVisibility) {
        model.visibilityChanged(visibility)
        limits.visibilityChanged(visibility)
        // A layout preview or an Undo offer lives only while Agents or Home is on screen.
        let showing = visibility == .expanded(.agents) || visibility == .expanded(nil)
        if onAgentsOrHome, !showing { model.endTiling() }
        onAgentsOrHome = showing
    }

    // MARK: Keys (⏎ apply, Esc cancel, ⌘Z undo) — only while a preview or an Undo is on offer

    private func wantsKeys(_ on: Bool) {
        if on {
            SurfaceKeyFocus.request(true)
            guard keyMonitor == nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let key = Self.tilingKey(for: event)
                let consumed = MainActor.assumeIsolated { () -> Bool in
                    guard let self, self.onAgentsOrHome, let key else { return false }
                    return self.model.handleKey(key)
                }
                return consumed ? nil : event
            }
        } else {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            SurfaceKeyFocus.request(false)
        }
    }

    static func tilingKey(for e: NSEvent) -> AgentsModel.TilingKey? {
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        if mods == .command, e.charactersIgnoringModifiers?.lowercased() == "z" { return .undo }
        guard mods.isEmpty else { return nil }
        switch Int(e.keyCode) {
        case 36, 76: return .enter
        case 53: return .escape
        default: return nil
        }
    }

    public var tab: PanelTab? {
        PanelTab(module: .agents, symbol: Self.symbol, title: LocalizedStringKey(AgentsText.t("Agents"))) { [weak self, model, limits] in
            AnyView(AgentsTab(model: model, limits: limits, page: self?.takeTabPage() ?? .sessions))
        }
    }

    /// The page asked for by Home's limits card, used once by the next tab built.
    private var pendingPage: AgentsTabPage?

    private func takeTabPage() -> AgentsTabPage {
        defer { pendingPage = nil }
        return pendingPage ?? tabPage
    }

    /// Opens the tab on the Limits page (Home's card).
    func openLimitsPage() {
        pendingPage = .limits
        model.hub?.requestOpen(.agents)
    }

    /// The tab's glyph: agents of every kind, not only terminals (SF Symbols 1, macOS 14 ok).
    public static let symbol = "sparkles"

    public func homeCard() -> AnyView? {
        model.highlights(limit: 1).isEmpty ? nil : AnyView(AgentsHomeCard(model: model))
    }

    /// The sessions card and the plan limits card (Settings → Home orders and hides each).
    public func homeWidgets() -> [HomeWidgetCard] {
        var out: [HomeWidgetCard] = []
        if let card = homeCard() { out.append(HomeWidgetCard(.agents, card)) }
        let now = limits.clock
        let items = LimitsLayout.homeItems(claude: limits.claudeEnabled ? limits.claude : nil,
                                           codex: limits.codexEnabled ? limits.codex : nil, now: now)
        if !items.isEmpty {
            // Nearly used up or on pace to run out: it goes before the calm cards.
            let hot = items.contains { !$0.stale && ($0.percent >= 90 || $0.limit.runsOutAt(now: now) != nil) }
            out.append(HomeWidgetCard(.limits, AnyView(LimitsHomeCard(limits: limits) { [weak self] in self?.openLimitsPage() }),
                                      priority: hot ? 70 : 0))
        }
        return out
    }
}

// MARK: Renderer

extension AgentsModule {
    /// Tiling states the renderer can draw (no Accessibility needed, no window touched).
    public enum RenderState: String, CaseIterable, Sendable {
        case tilingOff, tilingReady, layoutPreview, layoutDone, waitingPeek
    }

    public func prepareForRender(_ state: RenderState) {
        switch state {
        case .tilingOff:
            model.prepareTilingForRender(trusted: false, preview: nil, undo: false, note: nil)
        case .tilingReady:
            model.prepareTilingForRender(trusted: true, preview: nil, undo: false, note: nil)
        case .layoutPreview:
            let n = max(1, model.dots.count)
            model.prepareTilingForRender(trusted: true, preview: .init(windowIDs: [], count: n), undo: false, note: nil)
        case .waitingPeek:
            model.prepareTilingForRender(trusted: true, preview: nil, undo: false, note: nil)
            model.showWaitingPeekForRender()
        case .layoutDone:
            model.prepareTilingForRender(trusted: true, preview: nil, undo: true,
                                         note: "3 exact · \(model.sessions.first?.label ?? "api") kept 800×600")
        }
    }
}

extension AgentsModule {
    /// A module with no source, seeded with made-up sessions from every source (renderer): Claude
    /// Code in Terminal and in VS Code, the Codex CLI and the Codex app, OpenCode. Nothing of the
    /// user's is read.
    public static func renderSample(now: Date = .now) -> AgentsModule {
        let m = AgentsModule(sources: [])
        m.seedSample(now: now)
        return m
    }

    /// A module with no source and no session (renderer: the limits' own wing and drop-down).
    public static func renderEmpty() -> AgentsModule {
        let m = AgentsModule(sources: [])
        m.model.ingest([], rebuild: true)   // loaded, with nothing: the empty board
        return m
    }

    func seedSample(now: Date) {
        func e(_ ago: Double, _ k: AgentEvent.Kind, _ sid: String, _ folder: String, _ agent: AgentKind, _ host: AgentHost,
               tool: String? = nil, prompt: String? = nil, message: String? = nil, title: String? = nil) -> AgentEvent {
            AgentEvent(ts: now.addingTimeInterval(-ago), kind: k, sessionID: sid, cwd: "/Users/demo/Projects/\(folder)",
                       toolName: tool, prompt: prompt, agent: agent, host: host, message: message, title: title)
        }
        let terminal = AgentHost(kind: .terminal, bundleID: "com.apple.Terminal")
        let vscode = AgentHost(kind: .vscode, bundleID: "com.microsoft.VSCode")
        let ghostty = AgentHost(kind: .terminal, bundleID: "com.mitchellh.ghostty")
        let codexApp = AgentHost(kind: .codexApp, bundleID: "com.openai.codex")
        let iterm = AgentHost(kind: .terminal, bundleID: "com.googlecode.iterm2")
        let events = [
            e(400, .sessionStart, "s-api", "api", .claudeCode, terminal),
            e(390, .userPromptSubmit, "s-api", "api", .claudeCode, terminal, prompt: "Run the migrations on staging"),
            e(40, .postToolUse, "s-api", "api", .claudeCode, terminal, tool: "Read"),
            e(20, .permissionRequest, "s-api", "api", .claudeCode, terminal, tool: "Bash"),
            e(900, .sessionStart, "s-web", "web-app", .claudeCode, vscode),
            e(880, .userPromptSubmit, "s-web", "web-app", .claudeCode, vscode, prompt: "Add dark mode to the settings page"),
            e(8, .postToolUse, "s-web", "web-app", .claudeCode, vscode, tool: "Edit"),
            e(300, .sessionStart, "codex:cli", "cli-tools", .codex, ghostty),
            e(290, .userPromptSubmit, "codex:cli", "cli-tools", .codex, ghostty, prompt: "Port the config parser to the new format"),
            e(5, .postToolUse, "codex:cli", "cli-tools", .codex, ghostty, tool: "exec_command"),
            e(1500, .sessionStart, "codex:app", "docs-site", .codex, codexApp),
            e(1490, .userPromptSubmit, "codex:app", "docs-site", .codex, codexApp, prompt: "Write the install page"),
            e(1200, .postToolUse, "codex:app", "docs-site", .codex, codexApp, tool: "apply_patch"),
            e(70, .stop, "codex:app", "docs-site", .codex, codexApp, message: "Install page written; three files changed."),
            e(700, .sessionStart, "ses_mobile", "mobile", .opencode, iterm, title: "Flaky login test"),
            e(690, .userPromptSubmit, "ses_mobile", "mobile", .opencode, iterm, prompt: "Fix the flaky login test"),
            e(240, .postToolUse, "ses_mobile", "mobile", .opencode, iterm, tool: "bash"),
            e(200, .stop, "ses_mobile", "mobile", .opencode, iterm, message: "The test waited on a stale cookie; fixed and green."),
        ]
        model.ingest(events, rebuild: true)
        model.prepareTilingForRender(trusted: true, preview: nil, undo: false, note: nil)
    }
}

// MARK: Plan limits (renderer, demo, real-reading render)

extension AgentsModule {
    /// What the renderer can show of the plan limits.
    public enum LimitsRenderState: String, CaseIterable, Sendable {
        case column, columnNoSessions, limitsPage, whereItWent, alertPeek, usedUpWing
    }

    /// Made-up readings (Burny's demo data) and breakdown. Alerts off unless asked: a demo shot
    /// must not get an unasked drop-down.
    public func seedLimitsSample(now: Date = .now, alerts: Bool = false) {
        limits.alertsEnabled = alerts
        let s = UsageLimitsStore.sampleReadings(now: now)
        limits.seed(claude: s.claude, codex: s.codex, breakdown: UsageBreakdown.sample)
    }

    /// Real readings handed in from outside (the renderer's read-only "real" shot): nothing is fetched here.
    public func seedLimits(claude: UsageReading?, codex: UsageReading?, breakdown: UsageBreakdown?) {
        limits.alertsEnabled = false
        limits.seed(claude: claude, codex: codex, breakdown: breakdown)
    }

    /// Prepares a limits state; call after `start`.
    public func prepareLimitsForRender(_ state: LimitsRenderState, now: Date = .now) {
        switch state {
        case .column, .columnNoSessions: tabPage = .sessions
        case .limitsPage: tabPage = .limits
        case .whereItWent: tabPage = .whereItWent
        case .alertPeek:
            limits.showAlertForRender(now: now)
        case .usedUpWing:
            var s = UsageLimitsStore.sampleReadings(now: now)
            s.claude.limits[0].percent = 100
            s.claude.limits[0].recentRate = nil
            // Seeded quietly, then alerts on: the wing alone, without the drop-down.
            limits.alertsEnabled = false
            limits.seed(claude: s.claude, codex: s.codex, status: .ok)
            limits.alertsEnabled = true
        }
    }
}

extension AgentsModule {
    /// The owner's real readings for the renderer, read-only: Claude's `/usage` exactly as the app
    /// runs it (signature check, sandbox, no tools/MCP/hooks), but in `scratch` (its work folder and
    /// the breakdown's cache live there, never in ~/Library/Caches/Glancy); Codex's last
    /// `rate_limits` read backwards from the newest rollouts; the 15-day breakdown. When
    /// `scratch/limits-real.json` exists it is reused and nothing is run again.
    public nonisolated static func realLimitsSnapshot(scratch: URL) -> (claude: UsageReading?, codex: UsageReading?,
                                                                         breakdown: UsageBreakdown?, log: String) {
        struct Saved: Codable { var claude: UsageReading?; var codex: UsageReading? }
        let fm = FileManager.default
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        let saved = scratch.appendingPathComponent("limits-real.json")
        var log = ""
        var claude: UsageReading?, codex: UsageReading?
        if let d = try? Data(contentsOf: saved), let s = try? JSONDecoder.iso.decode(Saved.self, from: d) {
            claude = s.claude; codex = s.codex
            log += "reused \(saved.path)\n"
        } else {
            let cli = ClaudeUsageCLI(workDir: scratch.appendingPathComponent("usage-cwd", isDirectory: true))
            let started = Date()
            var before = rusage(); getrusage(RUSAGE_CHILDREN, &before)
            let outcome = cli.fetch()
            var after = rusage(); getrusage(RUSAGE_CHILDREN, &after)
            func secs(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
            let cpu = secs(after.ru_utime) - secs(before.ru_utime) + secs(after.ru_stime) - secs(before.ru_stime)
            log += String(format: "claude /usage: %@ in %.1f s wall, %.2f s child CPU, child max RSS %.0f MB\n",
                          String(describing: outcome), Date().timeIntervalSince(started), cpu, Double(after.ru_maxrss) / 1_048_576)
            if case let .ok(limits, plan) = outcome {
                claude = UsageReading(service: .claude, plan: plan, limits: limits, updated: .now)
            }
            for (url, _) in CodexSessionsReader(root: CodexSource.defaultRoot).recentRolloutsAll().prefix(10) {
                if let r = UsageParser.lastCodexReading(in: url) { codex = r; log += "codex from \(url.lastPathComponent)\n"; break }
            }
            if let d = try? JSONEncoder.iso.encode(Saved(claude: claude, codex: codex)) { try? d.write(to: saved) }
        }
        let start = Date()
        let ledger = UsageLedger(cacheURL: scratch.appendingPathComponent("usage.json"))
        ledger.update()
        log += String(format: "breakdown scan: %.1f s\n", Date().timeIntervalSince(start))
        var spans: [UsageWindowSpan] = []
        let now = Date()
        for s in UsageService.allCases {
            let r = s == .claude ? claude : codex
            func window(_ match: (UsageLimitKind) -> Bool, _ length: TimeInterval) -> (Date, Double?) {
                if let l = r?.limits.first(where: { match($0.kind) }), let reset = l.resetsAt, reset > now {
                    return (reset.addingTimeInterval(-l.window), l.effective(at: now))
                }
                return (now.addingTimeInterval(-length), nil)
            }
            let a = window({ $0.isSession }, 5 * 3600), b = window({ $0.isAllModelsWeek }, 7 * 86400)
            spans.append(UsageWindowSpan(service: s, sessionStart: a.0, sessionPercent: a.1, weekStart: b.0, weekPercent: b.1))
        }
        return (claude, codex, UsageBreakdown(buckets: ledger.saved.buckets, windows: spans, now: now), log)
    }
}

// MARK: Debug

extension AgentsModule {
    /// Loads the real log the way launch does (last 2 MB, borrowing `.1` when short), runs the
    /// state machine, and returns the sessions table as text. Read-only.
    public nonisolated static func debugSnapshot(logURL: URL = defaultLogURL, now: Date = .now) -> String {
        let reader = JSONLTailReader(url: logURL)
        let cur = JSONLTailReader.readTail(of: logURL, bytes: reader.rebuildBytes)
        var data = JSONLTailReader.readTail(of: reader.rotatedURL, bytes: max(0, reader.rebuildBytes - cur.count))
        if let last = data.last, last != 0x0A { data.append(0x0A) }
        data.append(cur)
        let events = AgentEventParser.drain(&data)
        var store = AgentSessionStore()
        for e in events { store.apply(e) }
        store.expire(now: now)

        func pad(_ s: String, _ n: Int) -> String {
            s.count > n ? String(s.prefix(n - 1)) + "…" : s + String(repeating: " ", count: n - s.count)
        }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        var out = "events parsed: \(events.count)"
        if let a = events.first?.ts, let b = events.last?.ts { out += "  span: \(f.string(from: a)) → \(f.string(from: b))" }
        out += "  now: \(f.string(from: now))\n"
        out += "live dots: " + store.live.map { "\($0.label)=\($0.state.rawValue)\($0.isFresh(at: now) ? "*" : "")" }.joined(separator: " ") + "\n"
        out += [pad("LABEL", 26), pad("STATE", 8), pad("SINCE", 7), pad("LAST EVENT", 15), pad("TOOL", 22), pad("SESSION", 9), "PROMPT"].joined(separator: " ") + "\n"
        for s in store.board {
            let since = AgentsText.age(now.timeIntervalSince(s.stateSince))
            let tool = s.lastTool.map { t in s.lastToolAgent.map { "\(t)·\($0)" } ?? t } ?? "-"
            out += [pad(s.label, 26), pad(s.state.rawValue, 8), pad(since, 7), pad(f.string(from: s.lastEventAt), 15),
                    pad(tool, 22), pad(String(s.id.prefix(8)), 9), String((s.lastPrompt ?? "").prefix(48))].joined(separator: " ") + "\n"
        }
        out += "accessibility trusted: \(TerminalJumper.isTrusted)\n"
        let hosts = TerminalJumper.hostBundles(cwds: Set(store.live.flatMap { [$0.cwd, $0.projectPath] }), names: ["claude"])
        for s in store.live {
            let host = s.host.map { "\($0.kind.rawValue) \($0.bundleID ?? "")" } ?? "from process tree: \(hosts[s.cwd] ?? hosts[s.projectPath] ?? "none")"
            out += "host \(s.label): \(host)\n"
        }
        for s in store.live {
            let hosts = TerminalJumper.hostNames(projectPath: s.projectPath, cwd: s.cwd)
            out += "jump target \(s.label): \(hosts.isEmpty ? "no claude process found (would activate front-most terminal)" : hosts.joined(separator: ", "))\n"
        }
        return out
    }
}

extension AgentsModule {
    /// Codex rollouts and OpenCode's database read the way launch reads them, as a table.
    /// Read-only (nothing under ~/.codex or OpenCode's folders is written).
    public nonisolated static func debugSourcesSnapshot(now: Date = .now) -> String {
        final class Box: @unchecked Sendable { var store: AgentSessionStore?; var events: [AgentEvent] = [] }
        let box = Box()
        // Seen from just after the last write, so a Mac where Codex last ran days ago still shows rows.
        let codex = CodexSessionsReader(root: CodexSource.defaultRoot, forgetAfter: 3 * 86400)
        let latest = codex.recentRolloutsAll().first?.1 ?? now
        codex.now = { latest.addingTimeInterval(60) }
        codex.start { if case .rebuilt(let s) = $0 { box.store = s } }
        codex.sync()
        codex.stop()
        var store = box.store ?? AgentSessionStore()
        let db = OpenCodeSource.defaultDataFolder.appendingPathComponent("opencode.db").path
        var seen: [String: OpenCodeSnapshot.Seen] = [:]
        let rows = OpenCodeDatabase.recentSessions(db: db, since: now.addingTimeInterval(-365 * 86400), limit: 12) ?? []
        for e in OpenCodeSnapshot.events(rows.reversed(), seen: &seen) { store.apply(e) }
        // No expiry here: old OpenCode rows stay visible in this snapshot.
        func pad(_ s: String, _ n: Int) -> String {
            s.count > n ? String(s.prefix(n - 1)) + "…" : s + String(repeating: " ", count: n - s.count)
        }
        var out = "codex rollouts followed: \(codex.trackedCount)  opencode rows: \(rows.count)\n"
        for s in store.board {
            let host = s.host.map { "\($0.kind.rawValue)\($0.bundleID.map { "(\($0))" } ?? "")" } ?? "-"
            out += [pad(s.agent.rawValue, 9), pad(s.label, 22), pad(s.state.rawValue, 8), pad(host, 34),
                    pad(s.lastTool ?? "-", 18), pad(s.title ?? "-", 40), String((s.lastMessage ?? "").prefix(40))]
                .joined(separator: " ") + "\n"
            out += "    plan: \(AgentJump.plan(for: s))\n"
        }
        return out
    }
}
