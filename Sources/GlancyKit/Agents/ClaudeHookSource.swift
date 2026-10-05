import Foundation

/// Claude Code sessions from the cc-dashboard hook log (terminal, VS Code / Cursor extension,
/// Claude desktop: the same `~/.claude/settings.json` hooks fire everywhere). Read-only.
@MainActor
final class ClaudeHookSource: AgentSource {
    nonisolated static let installedHook = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/hooks/cc-dashboard-event.sh")

    let kind = AgentKind.claudeCode
    let reader: JSONLTailReader
    let hookURL: URL

    init(logURL: URL, hookURL: URL = ClaudeHookSource.installedHook) {
        reader = JSONLTailReader(url: logURL)
        self.hookURL = hookURL
    }

    func start(_ sink: @escaping @MainActor (AgentKind, AgentSourceUpdate) -> Void) {
        // Parsing happens on the reader queue. The launch rebuild (thousands of lines) also runs
        // the state machine there, one line at a time; main only adopts the result. Then FIFO onto
        // main, in file order, so live batches always land after the rebuild.
        reader.start({ events, _ in
            // The OpenCode plugin writes its own log; a line from another agent here is skipped.
            let mine = events.filter { $0.agent == .claudeCode }
            DispatchQueue.main.async { MainActor.assumeIsolated { sink(.claudeCode, .events(mine, quiet: false)) } }
        }, rebuild: { lines in
            var store = AgentSessionStore()
            AgentEventParser.drain(&lines) { if $0.agent == .claudeCode { store.apply($0) } }
            DispatchQueue.main.async { MainActor.assumeIsolated { sink(.claudeCode, .rebuilt(store)) } }
        })
    }

    func stop() { reader.stop() }

    func status() -> AgentSourceStatus {
        let fm = FileManager.default
        guard fm.fileExists(atPath: reader.url.path) else {
            return AgentSourceStatus(.missing, AgentsText.t("No hook log: install the cc-dashboard hook"))
        }
        // An older hook does not record the app: hosts are then found from the process tree.
        if let script = try? String(contentsOf: hookURL, encoding: .utf8), !script.contains("host_bundle") {
            return AgentSourceStatus(.ok, AgentsText.t("Hook found · update it to tell terminals from VS Code"))
        }
        return AgentSourceStatus(.ok, AgentsText.t("Hook found"))
    }
}
