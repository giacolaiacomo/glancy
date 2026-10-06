import Foundation

// Where a session comes from: the coding agent (Claude Code, Codex, OpenCode…) and the app it runs
// in (a terminal, VS Code, the Codex app…). Every source turns its own record of what happened into
// `AgentEvent`s, so one state machine (`AgentSessionStore`) serves them all.

/// The coding agent behind a session.
public enum AgentKind: String, Sendable, CaseIterable, Codable, Comparable {
    case claudeCode, codex, opencode

    public var name: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        }
    }

    /// The agent's own glyph (SF Symbols available on macOS 14).
    public var symbol: String {
        switch self {
        case .claudeCode: "asterisk"
        case .codex: "circle.hexagonpath"
        case .opencode: "curlybraces"
        }
    }

    /// The process name that runs this agent in a terminal (host lookup by process tree).
    var processNames: Set<String> {
        switch self {
        case .claudeCode: ["claude"]
        case .codex: ["codex"]
        case .opencode: ["opencode"]
        }
    }

    /// Short prefix that keeps row ids of different agents apart.
    var idPrefix: String {
        switch self {
        case .claudeCode: ""
        case .codex: "codex:"
        case .opencode: ""   // OpenCode ids already start with "ses_"
        }
    }

    public static func < (a: AgentKind, b: AgentKind) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// The kind of app a session runs in. Decides how a click brings it forward.
public enum AgentHostKind: String, Sendable, Codable {
    case terminal       // Terminal, iTerm2, Ghostty, Warp, kitty… (or an unknown terminal)
    case vscode, cursor, windsurf, zed, xcode, jetbrains
    case codexApp       // the Codex desktop app
    case opencodeApp    // the OpenCode desktop app
    case claudeApp      // the Claude desktop app (its Code tab)
    case unknown

    /// Editors: a click opens the session's folder window, not a terminal.
    var isEditor: Bool {
        switch self {
        case .vscode, .cursor, .windsurf, .zed, .xcode, .jetbrains: true
        default: false
        }
    }
}

/// The app a session runs in: a kind and, when known, the app's bundle id (for its icon).
public struct AgentHost: Sendable, Equatable, Codable {
    public var kind: AgentHostKind
    public var bundleID: String?

    public init(kind: AgentHostKind, bundleID: String? = nil) {
        self.kind = kind
        self.bundleID = bundleID
    }

    public static let unknown = AgentHost(kind: .unknown)

    /// Known apps by bundle id: their kind and display name.
    static let apps: [String: (kind: AgentHostKind, name: String)] = [
        "com.apple.Terminal": (.terminal, "Terminal"),
        "com.googlecode.iterm2": (.terminal, "iTerm2"),
        "com.mitchellh.ghostty": (.terminal, "Ghostty"),
        "dev.warp.Warp-Stable": (.terminal, "Warp"),
        "dev.warp.Warp": (.terminal, "Warp"),
        "net.kovidgoyal.kitty": (.terminal, "kitty"),
        "org.alacritty": (.terminal, "Alacritty"),
        "com.github.wez.wezterm": (.terminal, "WezTerm"),
        "co.zeit.hyper": (.terminal, "Hyper"),
        "com.microsoft.VSCode": (.vscode, "VS Code"),
        "com.microsoft.VSCodeInsiders": (.vscode, "VS Code Insiders"),
        "com.vscodium": (.vscode, "VSCodium"),
        "com.todesktop.230313mzl4w4u92": (.cursor, "Cursor"),
        "com.exafunction.windsurf": (.windsurf, "Windsurf"),
        "dev.zed.Zed": (.zed, "Zed"),
        "com.apple.dt.Xcode": (.xcode, "Xcode"),
        "com.openai.codex": (.codexApp, "Codex"),
        "ai.opencode.desktop": (.opencodeApp, "OpenCode"),
        "com.anthropic.claudefordesktop": (.claudeApp, "Claude"),
    ]

    /// `TERM_PROGRAM` values → the terminal's bundle id (when the bundle id itself is missing).
    static let termPrograms: [String: String] = [
        "Apple_Terminal": "com.apple.Terminal",
        "iTerm.app": "com.googlecode.iterm2",
        "ghostty": "com.mitchellh.ghostty",
        "WarpTerminal": "dev.warp.Warp-Stable",
        "WezTerm": "com.github.wez.wezterm",
        "Hyper": "co.zeit.hyper",
    ]

    /// The host for a bundle id: known apps by kind; JetBrains IDEs by prefix; anything else is
    /// treated as a terminal-like app (its windows are searched like a terminal's).
    public static func from(bundleID: String) -> AgentHost {
        if let app = apps[bundleID] { return AgentHost(kind: app.kind, bundleID: bundleID) }
        if bundleID.hasPrefix("com.jetbrains.") || bundleID == "com.google.android.studio" {
            return AgentHost(kind: .jetbrains, bundleID: bundleID)
        }
        return AgentHost(kind: .terminal, bundleID: bundleID)
    }

    /// What the hook saw in its environment, most specific first: the app's bundle id
    /// (`__CFBundleIdentifier`, inherited from the app that launched the shell), Claude Code's own
    /// entry point (`CLAUDE_CODE_ENTRYPOINT`), then `TERM_PROGRAM`. nil when nothing was recorded
    /// (an older hook): the host is then looked up from the process tree.
    public static func detect(bundleID: String?, termProgram: String?, entrypoint: String?) -> AgentHost? {
        // tmux/screen keep the launching terminal's bundle id: still the right app to raise.
        if let b = bundleID, !b.isEmpty { return from(bundleID: b) }
        if let e = entrypoint?.lowercased() {
            if e.contains("vscode") { return AgentHost(kind: .vscode, bundleID: "com.microsoft.VSCode") }
            if e.contains("desktop") { return AgentHost(kind: .claudeApp, bundleID: "com.anthropic.claudefordesktop") }
            if e.contains("jetbrains") { return AgentHost(kind: .jetbrains) }
        }
        if let t = termProgram, !t.isEmpty {
            if t == "vscode" { return AgentHost(kind: .vscode, bundleID: "com.microsoft.VSCode") }
            if let b = termPrograms[t] { return from(bundleID: b) }
            return AgentHost(kind: .terminal)
        }
        if let e = entrypoint, e == "cli" { return AgentHost(kind: .terminal) }
        return nil
    }

    /// The app's name for tooltips and settings.
    public var name: String {
        if let b = bundleID, let app = Self.apps[b] { return app.name }
        switch kind {
        case .terminal: return AgentsText.t("Terminal")
        case .vscode: return "VS Code"
        case .cursor: return "Cursor"
        case .windsurf: return "Windsurf"
        case .zed: return "Zed"
        case .xcode: return "Xcode"
        case .jetbrains: return "JetBrains"
        case .codexApp: return "Codex"
        case .opencodeApp: return "OpenCode"
        case .claudeApp: return "Claude"
        case .unknown: return AgentsText.t("Unknown app")
        }
    }

    /// A glyph when the app's icon is not available.
    public var symbol: String {
        switch kind {
        case .terminal: "terminal"
        case .vscode, .cursor, .windsurf, .zed, .jetbrains: "chevron.left.forwardslash.chevron.right"
        case .xcode: "hammer"
        case .codexApp, .opencodeApp, .claudeApp: "macwindow"
        case .unknown: "questionmark.app"
        }
    }
}

/// What one source says about itself in Settings → Agents.
public struct AgentSourceStatus: Sendable, Equatable {
    public enum Level: Sendable, Equatable { case ok, off, missing }
    public var level: Level
    public var line: String

    public init(_ level: Level, _ line: String) {
        self.level = level
        self.line = line
    }
}

/// What a source hands the model: a store rebuilt off the main actor (launch, no peeks), or new
/// events (live, may peek).
public enum AgentSourceUpdate: Sendable {
    case rebuilt(AgentSessionStore)
    /// `quiet`: catching up on history (a newly followed file): applied without peeks.
    case events([AgentEvent], quiet: Bool)
    /// The plan's limits (Codex `rate_limits`), newer than the last delivered.
    case limits(UsageReading)
}

/// One provider of sessions. Implementations watch their data with file-system events (never a
/// timer), parse off the main actor and deliver on the main actor through `sink`.
@MainActor
protocol AgentSource: AnyObject {
    var kind: AgentKind { get }
    /// Starts watching. `sink` is called on the main actor, in order.
    func start(_ sink: @escaping @MainActor (AgentKind, AgentSourceUpdate) -> Void)
    /// Stops every watcher; nothing keeps running afterwards.
    func stop()
    /// A one-line status for Settings (read on demand, cheap).
    func status() -> AgentSourceStatus
}
