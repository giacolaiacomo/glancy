import AppKit
import ApplicationServices
import Darwin

/// Brings a Claude Code session's terminal window forward.
///
/// 1. Find the app hosting the session: walk up the parent chain of every `claude` process whose
///    working directory is the session's folder (libproc, no permission needed).
/// 2. With Accessibility, score the windows of the host app (and of every other known terminal /
///    editor) by AX title and AX document against the folder, then AXRaise the best one.
/// 3. Without Accessibility (or with no window match), activate the most likely app: the host,
///    else the front-most known terminal.
/// Never moves or resizes anything.
enum TerminalJumper {
    enum Outcome: Sendable, Equatable {
        case raisedWindow(app: String)
        case activatedApp(app: String)
        case notFound
    }

    /// Terminals and editors that run coding agents, by bundle id (the agents' own apps are
    /// reached by `AgentJump`, not by searching their windows).
    static let knownApps: [String: String] = AgentHost.apps
        .filter { $0.value.kind == .terminal || $0.value.kind.isEditor }
        .mapValues(\.name)

    static var isTrusted: Bool { AXIsProcessTrusted() }

    struct Target: Sendable {
        let projectPath: String
        let cwd: String
        let label: String
        /// The board row it belongs to (window resolution keys its answer by it).
        var rowID: String = ""
        /// How a click reaches the session (a terminal by default).
        var plan: AgentJumpPlan = .terminal(processNames: ["claude"])
        /// The agent's process names, for the process-tree lookup.
        var processNames: Set<String> {
            if case .terminal(let names) = plan { return names }
            return ["claude"]
        }
    }

    /// A session's terminal window, as the window registry keys it.
    struct ResolvedWindow: Sendable, Equatable {
        let windowID: CGWindowID
        let pid: pid_t
    }

    static func jump(_ target: Target) async -> Outcome {
        let plan = await Task.detached(priority: .userInitiated) { () -> (pid: pid_t, name: String, raised: Bool)? in
            locateAndRaise(target)
        }.value
        guard let plan else { return .notFound }
        await MainActor.run {
            if let app = NSRunningApplication(processIdentifier: plan.pid) {
                NSApp.yieldActivation(to: app)
                app.activate()
            }
        }
        return plan.raised ? .raisedWindow(app: plan.name) : .activatedApp(app: plan.name)
    }

    /// Off the main thread: picks the app (and window, when AX allows) and raises the window.
    private static func locateAndRaise(_ t: Target) -> (pid: pid_t, name: String, raised: Bool)? {
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier.map { knownApps[$0] != nil } ?? false
        }
        guard !running.isEmpty else { return nil }
        let hosts = hostApps(forPaths: [t.projectPath, t.cwd], among: Set(running.map(\.processIdentifier)), names: t.processNames)
        let zOrder = frontToBackPIDs()
        let ordered = running.sorted { a, b in
            let ha = hosts.contains(a.processIdentifier), hb = hosts.contains(b.processIdentifier)
            if ha != hb { return ha }
            return (zOrder.firstIndex(of: a.processIdentifier) ?? .max) < (zOrder.firstIndex(of: b.processIdentifier) ?? .max)
        }
        func name(_ app: NSRunningApplication) -> String {
            app.localizedName ?? knownApps[app.bundleIdentifier ?? ""] ?? "Terminal"
        }

        if isTrusted {
            var best: (score: Int, window: AXUIElement, app: NSRunningApplication)?
            for app in ordered {
                let isHost = hosts.contains(app.processIdentifier)
                let windows = axWindows(of: app.processIdentifier)
                for w in windows {
                    let s = windowScore(w, windowCount: windows.count, target: t, isHost: isHost)
                    if s > (best?.score ?? 0) { best = (s, w.element, app) }
                }
            }
            if let best {
                AXUIElementSetAttributeValue(best.window, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementPerformAction(best.window, kAXRaiseAction as CFString)
                return (best.app.processIdentifier, name(best.app), true)
            }
        }
        // The most likely app: the host, else the front-most known terminal.
        guard let app = ordered.first else { return nil }
        return (app.processIdentifier, name(app), false)
    }

    // MARK: Window resolution (Agents ↔ Windows link)

    /// Each target's terminal window, scored like `jump` (AX title / document + the host app),
    /// one window per session: the best pairs win first. Read-only (no raise, no move). Needs
    /// Accessibility; empty without it. `excluding`: windows already claimed by other sessions.
    static func resolveWindows(_ targets: [Target], excluding: Set<CGWindowID> = []) async -> [String: ResolvedWindow] {
        guard !targets.isEmpty else { return [:] }
        return await Task.detached(priority: .userInitiated) { resolve(targets, excluding: excluding) }.value
    }

    private static func resolve(_ targets: [Target], excluding: Set<CGWindowID>) -> [String: ResolvedWindow] {
        guard isTrusted else { return [:] }
        let running = knownRunning()
        guard !running.isEmpty else { return [:] }
        let paths = Set(targets.flatMap { [$0.projectPath, $0.cwd] }.filter { !$0.isEmpty })
        let names = targets.reduce(into: Set<String>()) { $0.formUnion($1.processNames) }
        let hostsByPath = claudeHosts(among: Set(running.map(\.processIdentifier)), cwds: paths, names: names)
        let windowsByApp = running.map { ($0.processIdentifier, axWindows(of: $0.processIdentifier)) }
        var candidates: [Candidate] = []
        for t in targets {
            let hosts = hostsByPath[t.projectPath, default: []].union(hostsByPath[t.cwd, default: []])
            for (pid, windows) in windowsByApp {
                for w in windows {
                    let s = windowScore(w, windowCount: windows.count, target: t, isHost: hosts.contains(pid))
                    guard s > 0, let id = w.element.windowID, !excluding.contains(id) else { continue }
                    candidates.append(Candidate(rowID: t.rowID, window: ResolvedWindow(windowID: id, pid: pid), score: s))
                }
            }
        }
        return assign(candidates)
    }

    struct Candidate: Sendable, Equatable {
        let rowID: String
        let window: ResolvedWindow
        let score: Int
    }

    /// Greedy one-to-one pairing, best score first (ties keep input order): a session gets at
    /// most one window, a window serves at most one session.
    static func assign(_ candidates: [Candidate]) -> [String: ResolvedWindow] {
        let ranked = candidates.enumerated().sorted { a, b in
            a.element.score != b.element.score ? a.element.score > b.element.score : a.offset < b.offset
        }
        var out: [String: ResolvedWindow] = [:]
        var used = Set<CGWindowID>()
        for (_, c) in ranked where out[c.rowID] == nil && !used.contains(c.window.windowID) {
            out[c.rowID] = c.window
            used.insert(c.window.windowID)
        }
        return out
    }

    /// Raises exactly this window and activates its app; falls back to `jump` when the window is
    /// gone or Accessibility is off. Never moves or resizes.
    static func raise(_ w: ResolvedWindow, fallback: Target) async -> Outcome {
        let raised = await Task.detached(priority: .userInitiated) { () -> Bool in
            guard isTrusted,
                  let el = axWindows(of: w.pid).first(where: { $0.element.windowID == w.windowID })?.element else { return false }
            AXUIElementSetAttributeValue(el, kAXMainAttribute as CFString, kCFBooleanTrue)
            return AXUIElementPerformAction(el, kAXRaiseAction as CFString) == .success
        }.value
        guard raised else { return await jump(fallback) }
        let name = await MainActor.run { () -> String in
            guard let app = NSRunningApplication(processIdentifier: w.pid) else { return "Terminal" }
            NSApp.yieldActivation(to: app)
            app.activate()
            return app.localizedName ?? "Terminal"
        }
        return .raisedWindow(app: name)
    }

    /// Whether a window still exists (WindowServer; no Accessibility or Screen Recording needed).
    static func windowExists(_ id: CGWindowID) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]] else { return false }
        return list.contains { ($0[kCGWindowNumber as String] as? CGWindowID) == id }
    }

    /// Score of one AX window for a session, with the host-app bonus `jump` uses.
    static func windowScore(_ w: AXWindow, windowCount: Int, target t: Target, isHost: Bool) -> Int {
        var s = score(title: w.title, document: w.document, projectPath: t.projectPath, cwd: t.cwd, label: t.label)
        if isHost { s += s > 0 ? 25 : (windowCount == 1 ? 1 : 0) }
        return s
    }

    private static func knownRunning() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier.map { knownApps[$0] != nil } ?? false }
    }

    /// Read-only: the names of the apps hosting a `claude` process in this folder (debug snapshot).
    static func hostNames(projectPath: String, cwd: String) -> [String] {
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier.map { knownApps[$0] != nil } ?? false
        }
        let hosts = hostApps(forPaths: [projectPath, cwd], among: Set(running.map(\.processIdentifier)))
        return running.filter { hosts.contains($0.processIdentifier) }.compactMap(\.localizedName)
    }

    // MARK: Scoring (pure)

    /// How well a window (AX title, AX document URL) matches a session folder. 0 = no match.
    static func score(title: String, document: String?, projectPath: String, cwd: String, label: String) -> Int {
        let paths = [projectPath, cwd].filter { !$0.isEmpty }
        if let doc = document.flatMap({ URL(string: $0)?.path ?? $0 }).map(stripSlash), !doc.isEmpty {
            if paths.contains(where: { stripSlash($0) == doc }) { return 100 }
            if paths.contains(where: { doc.hasPrefix(stripSlash($0) + "/") }) { return 70 }
        }
        let home = NSHomeDirectory()
        for p in paths {
            let tilde = p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
            if title.contains(p) || (tilde != p && title.contains(tilde)) { return 80 }
        }
        let folder = (projectPath as NSString).lastPathComponent
        if !folder.isEmpty, containsToken(title, folder) { return 50 }
        let base = label.split(separator: " ").first.map(String.init) ?? label
        if !base.isEmpty, base != folder, containsToken(title, (base as NSString).lastPathComponent) { return 30 }
        return 0
    }

    private static func stripSlash(_ s: String) -> String {
        s.count > 1 && s.hasSuffix("/") ? String(s.dropLast()) : s
    }

    /// Case-insensitive match of `token` bounded by non-alphanumerics (so "site" ≠ "sitemap").
    static func containsToken(_ text: String, _ token: String) -> Bool {
        var range = text.startIndex..<text.endIndex
        while let r = text.range(of: token, options: .caseInsensitive, range: range) {
            let before = r.lowerBound == text.startIndex ? nil : text[text.index(before: r.lowerBound)]
            let after = r.upperBound == text.endIndex ? nil : text[r.upperBound]
            let isWord: (Character?) -> Bool = { $0.map { $0.isLetter || $0.isNumber } ?? false }
            if !isWord(before) && !isWord(after) { return true }
            range = r.upperBound..<text.endIndex
        }
        return false
    }

    // MARK: AX

    struct AXWindow {
        let element: AXUIElement
        let title: String
        let document: String?
    }

    static func axWindows(of pid: pid_t) -> [AXWindow] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows.map { w in
            AXWindow(element: w, title: string(w, kAXTitleAttribute) ?? "", document: string(w, kAXDocumentAttribute))
        }
    }

    private static func string(_ e: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    // MARK: Processes (libproc)

    /// PIDs of known apps that host an agent process (`names`) whose working directory is one of `paths`.
    static func hostApps(forPaths paths: [String], among appPIDs: Set<pid_t>, names: Set<String> = ["claude"]) -> Set<pid_t> {
        let wanted = Set(paths.filter { !$0.isEmpty })
        return claudeHosts(among: appPIDs, cwds: wanted, names: names).values.reduce(into: Set<pid_t>()) { $0.formUnion($1) }
    }

    /// One pass over every process: working directory of each agent process (`names`: claude,
    /// codex, opencode) → the apps hosting it. `cwds` limits the folders looked at (nil = all).
    static func claudeHosts(among appPIDs: Set<pid_t>, cwds: Set<String>? = nil, names: Set<String> = ["claude"]) -> [String: Set<pid_t>] {
        var hosts: [String: Set<pid_t>] = [:]
        for pid in allPIDs() {
            guard let cwd = processCWD(pid), cwds?.contains(cwd) ?? true, isAgent(pid, names: names) else { continue }
            var p = pid
            for _ in 0..<32 {
                guard let parent = parentPID(p), parent > 1 else { break }
                if appPIDs.contains(parent) { hosts[cwd, default: []].insert(parent); break }
                p = parent
            }
        }
        return hosts
    }

    static func allPIDs() -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return Array(pids.prefix(Int(max(0, got))))
    }

    static func processName(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Claude Code's native binary is named after its version (…/claude/versions/2.1.289) and
    /// launched as `claude`: match argv[0] or the executable path.
    static func isClaude(_ pid: pid_t) -> Bool { isAgent(pid, names: ["claude"]) }

    /// An agent's process: its name, executable or argv[0] is one of `names` (claude, codex, opencode).
    static func isAgent(_ pid: pid_t, names: Set<String>) -> Bool {
        if let n = processName(pid), names.contains(n) { return true }
        var path = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
            let p = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if names.contains((p as NSString).lastPathComponent) { return true }
            if names.contains("claude"), p.contains("/claude/versions/") { return true }
        }
        return argv0(pid).map { names.contains(($0 as NSString).lastPathComponent) } ?? false
    }

    /// The app (bundle id) hosting each folder's agent process: the first ancestor that is a
    /// running app with a bundle id. One pass over every process; read-only.
    static func hostBundles(cwds: Set<String>, names: Set<String>) -> [String: String] {
        var apps: [pid_t: String] = [:]
        for a in NSWorkspace.shared.runningApplications {
            if let b = a.bundleIdentifier { apps[a.processIdentifier] = b }
        }
        let ownPID = getpid()
        var out: [String: String] = [:]
        for pid in allPIDs() {
            guard let cwd = processCWD(pid), cwds.contains(cwd), out[cwd] == nil, isAgent(pid, names: names) else { continue }
            var p = pid
            for _ in 0..<32 {
                guard let parent = parentPID(p), parent > 1, parent != ownPID else { break }
                if let b = apps[parent] { out[cwd] = b; break }
                p = parent
            }
        }
        return out
    }

    /// argv[0] via KERN_PROCARGS2 (own-user processes only).
    static func argv0(_ pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        var i = MemoryLayout<Int32>.size
        while i < size, buf[i] != 0 { i += 1 }        // exec path
        while i < size, buf[i] == 0 { i += 1 }        // padding
        let start = i
        while i < size, buf[i] != 0 { i += 1 }        // argv[0]
        return i > start ? String(decoding: buf[start..<i], as: UTF8.self) : nil
    }

    static func processCWD(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// Short BSD info also works for root-owned ancestors such as `login` (the full one does not).
    static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbsi_ppid)
    }

    /// Owner PIDs of on-screen windows, front to back (no Screen Recording needed for the PID).
    static func frontToBackPIDs() -> [pid_t] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        var seen = [pid_t]()
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
            if let pid = w[kCGWindowOwnerPID as String] as? pid_t, !seen.contains(pid) { seen.append(pid) }
        }
        return seen
    }
}
