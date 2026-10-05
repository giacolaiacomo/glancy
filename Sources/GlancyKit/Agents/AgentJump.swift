import AppKit
import ApplicationServices

/// How a click reaches a session, from where it runs. Pure: tests check the choice.
enum AgentJumpPlan: Sendable, Equatable {
    /// The Codex app, on that thread (`codex://threads/<id>`).
    case codexThread(threadID: String)
    /// An editor (VS Code, Cursor, Xcode…): the window showing the session's folder, else the
    /// folder opened in that editor (which focuses the window that already has it).
    case editor(bundleID: String, folder: String, opensFolders: Bool)
    /// An app with no per-session window to pick (OpenCode or Claude desktop): bring it forward.
    case app(bundleID: String)
    /// A terminal: the window whose agent process runs in the folder (process tree + AX titles).
    case terminal(processNames: Set<String>)
}

enum AgentJump {
    /// Default bundle id per editor kind, when the host's own is unknown.
    static let editorBundles: [AgentHostKind: String] = [
        .vscode: "com.microsoft.VSCode",
        .cursor: "com.todesktop.230313mzl4w4u92",
        .windsurf: "com.exafunction.windsurf",
        .zed: "dev.zed.Zed",
        .xcode: "com.apple.dt.Xcode",
    ]

    static func plan(for s: AgentSession) -> AgentJumpPlan {
        let host = s.host ?? .unknown
        switch host.kind {
        case .codexApp:
            if s.agent == .codex, s.id.hasPrefix(AgentKind.codex.idPrefix) {
                return .codexThread(threadID: String(s.id.dropFirst(AgentKind.codex.idPrefix.count)))
            }
            return .app(bundleID: host.bundleID ?? "com.openai.codex")
        case .opencodeApp:
            return .app(bundleID: host.bundleID ?? "ai.opencode.desktop")
        case .claudeApp:
            return .app(bundleID: host.bundleID ?? "com.anthropic.claudefordesktop")
        case .vscode, .cursor, .windsurf, .zed, .xcode, .jetbrains:
            guard let bundle = host.bundleID ?? editorBundles[host.kind] else {
                return .terminal(processNames: s.agent.processNames)
            }
            // Xcode and JetBrains IDEs open projects, not plain folders: only their windows are searched.
            let opens = host.kind != .xcode && host.kind != .jetbrains
            return .editor(bundleID: bundle, folder: s.projectPath, opensFolders: opens)
        case .terminal, .unknown:
            return .terminal(processNames: s.agent.processNames)
        }
    }

    /// Carries out a plan. Never moves or resizes a window.
    static func perform(_ t: TerminalJumper.Target) async -> TerminalJumper.Outcome {
        switch t.plan {
        case .terminal:
            return await TerminalJumper.jump(t)
        case .codexThread(let id):
            let url = URL(string: "codex://threads/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)")
            return await MainActor.run {
                guard let url, NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
                    return activate(bundleID: "com.openai.codex")
                }
                NSWorkspace.shared.open(url)
                return .activatedApp(app: "Codex")
            }
        case .app(let bundle):
            return await MainActor.run { activate(bundleID: bundle) }
        case let .editor(bundle, folder, opens):
            let raised = await Task.detached(priority: .userInitiated) { () -> (pid: pid_t, name: String)? in
                raiseEditorWindow(bundleID: bundle, target: t)
            }.value
            return await MainActor.run {
                if let raised, let app = NSRunningApplication(processIdentifier: raised.pid) {
                    NSApp.yieldActivation(to: app)
                    app.activate()
                    return .raisedWindow(app: raised.name)
                }
                guard opens, !folder.isEmpty, FileManager.default.fileExists(atPath: folder),
                      let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else {
                    return activate(bundleID: bundle)
                }
                // The editor focuses the window that has this folder open (or opens it).
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.open([URL(fileURLWithPath: folder, isDirectory: true)], withApplicationAt: appURL,
                                        configuration: config)
                return .activatedApp(app: AgentHost.from(bundleID: bundle).name)
            }
        }
    }

    /// Off the main thread: the editor window whose title / document matches the folder, raised.
    private static func raiseEditorWindow(bundleID: String, target t: TerminalJumper.Target) -> (pid: pid_t, name: String)? {
        guard TerminalJumper.isTrusted,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return nil }
        var best: (score: Int, window: AXUIElement)?
        for w in TerminalJumper.axWindows(of: app.processIdentifier) {
            let s = TerminalJumper.score(title: w.title, document: w.document, projectPath: t.projectPath, cwd: t.cwd, label: t.label)
            // A folder-name match at least (VS Code titles: "file — folder").
            if s >= 50, s > (best?.score ?? 0) { best = (s, w.element) }
        }
        guard let best else { return nil }
        AXUIElementSetAttributeValue(best.window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(best.window, kAXRaiseAction as CFString)
        return (app.processIdentifier, app.localizedName ?? AgentHost.from(bundleID: bundleID).name)
    }

    @MainActor
    private static func activate(bundleID: String) -> TerminalJumper.Outcome {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            NSApp.yieldActivation(to: app)
            app.activate()
            return .activatedApp(app: app.localizedName ?? AgentHost.from(bundleID: bundleID).name)
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return .notFound }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return .activatedApp(app: AgentHost.from(bundleID: bundleID).name)
    }
}
