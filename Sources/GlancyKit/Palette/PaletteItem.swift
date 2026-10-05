import AppKit

// One row of the command bar. Built-in rows (apps, answers, system) and every module's
// `GlancyCommand` end up as a `PaletteItem`.

public enum PaletteIcon: Equatable, Sendable {
    case symbol(String)
    case app(String)       // the .app path: its real icon, loaded when shown
}

public struct PaletteAction {
    public let title: String
    public let run: @MainActor () -> Void
}

public struct PaletteItem: Identifiable {
    public enum Kind: Equatable, Sendable {
        case command      // a module's command or a built-in action
        case app
        case answer       // calculator, units, currency: a big result line
        case fallback     // web search, open URL
        case notice       // not actionable ("Fetching rates…")
    }

    public var id: String
    public var title: String
    public var subtitle: String?
    public var icon: PaletteIcon
    /// Where it comes from: "Application", "Calendar", "Calculator"…
    public var tag: String
    public var kind: Kind = .command
    public var keywords: [String] = []
    public var rank = 0
    public var closesPanel = true
    /// Counts for frecency (answers and fallbacks don't: they change with every query).
    public var learns = true
    /// What ⏎ does ("Open", "Copy", "Run").
    public var primary: String
    /// What ⌘⏎ does, when anything.
    public var secondary: PaletteAction?
    public var run: (@MainActor () -> Void)?

    public init(id: String, title: String, subtitle: String? = nil, icon: PaletteIcon, tag: String, kind: Kind = .command,
                keywords: [String] = [], rank: Int = 0, closesPanel: Bool = true, learns: Bool = true, primary: String,
                secondary: PaletteAction? = nil, run: (@MainActor () -> Void)?) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.icon = icon; self.tag = tag; self.kind = kind
        self.keywords = keywords; self.rank = rank; self.closesPanel = closesPanel; self.learns = learns
        self.primary = primary; self.secondary = secondary; self.run = run
    }

    /// A module's command.
    @MainActor init(_ c: GlancyCommand) {
        self.init(id: c.id, title: c.title, subtitle: c.subtitle, icon: .symbol(c.symbol), tag: tr(SurfaceContext.name(c.module)),
                  keywords: c.keywords, rank: c.rank, closesPanel: c.closesPanel, primary: CommandText.t("Run"), run: c.run)
    }

    public var actionable: Bool { run != nil }
}

/// An item prepared for matching (once per open).
struct PaletteCandidate {
    let item: PaletteItem
    let title: MatchText
    let keywords: [MatchText]

    init(_ item: PaletteItem) {
        self.item = item
        title = MatchText(item.title)
        keywords = item.keywords.map(MatchText.init)
    }
}

// MARK: Built-in actions

@MainActor
enum PaletteActions {
    static func copy(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    static func open(_ url: URL) { NSWorkspace.shared.open(url) }

    static func launch(_ app: AppEntry) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: config) { _, _ in }
    }

    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// The login framework's immediate lock (what the menu's "Lock Screen" does); falls back to
    /// sleeping the displays, which locks when a password is required right away.
    static func lockScreen() {
        if let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
           let sym = dlsym(h, "SACLockScreenImmediate") {
            typealias Lock = @convention(c) () -> Int32
            _ = unsafeBitCast(sym, to: Lock.self)()
            return
        }
        pmset("displaysleepnow")
    }

    static func sleep() { pmset("sleepnow") }
    static func sleepDisplays() { pmset("displaysleepnow") }

    private static func pmset(_ arg: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = [arg]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}

// MARK: Typed URLs

public enum PaletteURL {
    /// "github.com", "https://x.y/z", "localhost:3000" → a URL to open; nil for anything else.
    public static func detect(_ raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        let lower = s.lowercased()
        for scheme in ["http://", "https://"] where lower.hasPrefix(scheme) {
            guard let u = URL(string: s), u.host?.isEmpty == false else { return nil }
            return u
        }
        // host[:port][/path…]
        let hostPart = lower.split(separator: "/", maxSplits: 1).first.map(String.init) ?? lower
        let host = hostPart.split(separator: ":", maxSplits: 1).first.map(String.init) ?? hostPart
        if hostPart.contains(":") {
            let port = hostPart.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
            guard !port.isEmpty, port.allSatisfy(\.isNumber) else { return nil }
        }
        let ok: Bool
        if host == "localhost" {
            ok = true
        } else {
            let labels = host.split(separator: ".", omittingEmptySubsequences: false)
            ok = labels.count >= 2
                && labels.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }
                && (labels.last.map { $0.count >= 2 && $0.allSatisfy(\.isLetter) } ?? false)
        }
        guard ok else { return nil }
        return URL(string: (host == "localhost" ? "http://" : "https://") + s)
    }

    public static func webSearch(_ q: String) -> URL? {
        var c = URLComponents(string: "https://www.google.com/search")!
        c.queryItems = [URLQueryItem(name: "q", value: q)]
        return c.url
    }
}
