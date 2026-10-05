import SwiftUI

/// Claude Code sessions in the notch (SPEC §3 Agents). Source: the cc-dashboard hook log.
public final class AgentsModule: GlancyModule {
    public nonisolated static let defaultLogURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/hooks/data/cc-dashboard/events.jsonl")

    public let id = ModuleID.agents
    public let model = AgentsModel()
    private let reader: JSONLTailReader
    private var running = false
    private var keyMonitor: Any?
    private var onAgentsOrHome = false

    public init(logURL: URL = AgentsModule.defaultLogURL) {
        reader = JSONLTailReader(url: logURL)
    }

    /// The tiler for ⌥-click and "Lay out sessions" (the Windows module), wired in Modules.make().
    var tiling: (any AgentsTiling)? {
        get { model.tiling }
        set { model.tiling = newValue }
    }

    public func start(hub: ActivityHub) {
        guard !running else { return }
        running = true
        model.hub = hub
        model.onWantsKeys = { [weak self] on in self?.wantsKeys(on) }
        // Parsing happens on the reader queue. The launch rebuild (thousands of lines) also runs
        // the state machine there, one line at a time; main only adopts the result. Then FIFO onto
        // main, in file order, so live batches always land after the rebuild.
        reader.start({ [weak self] events, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.deliver { $0.ingest(events, rebuild: false) } } }
        }, rebuild: { [weak self] lines in
            var store = AgentSessionStore()
            AgentEventParser.drain(&lines) { store.apply($0) }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.deliver { $0.adopt(store) } } }
        })
    }

    /// Drops batches that were already queued for main when `stop()` ran.
    private func deliver(_ body: (AgentsModel) -> Void) {
        if running { body(model) }
    }

    public func stop() {
        guard running else { return }
        running = false
        reader.stop()
        model.endTiling()
        model.onWantsKeys = nil
        wantsKeys(false)
        model.hub?.clearAll(from: .agents)
        model.reset()
        model.hub = nil
    }

    public func visibilityChanged(_ visibility: SurfaceVisibility) {
        model.visibilityChanged(visibility)
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
        PanelTab(module: .agents, symbol: "terminal", title: LocalizedStringKey(AgentsText.t("Agents"))) { [model] in
            AnyView(AgentsBoard(model: model))
        }
    }

    public func homeCard() -> AnyView? {
        model.highlights(limit: 1).isEmpty ? nil : AnyView(AgentsHomeCard(model: model))
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
        for s in store.live {
            let hosts = TerminalJumper.hostNames(projectPath: s.projectPath, cwd: s.cwd)
            out += "jump target \(s.label): \(hosts.isEmpty ? "no claude process found (would activate front-most terminal)" : hosts.joined(separator: ", "))\n"
        }
        return out
    }
}
