import Darwin
import Foundation

/// What one `/usage` attempt came to.
public enum ClaudeUsageOutcome: Sendable, Equatable {
    case ok([UsageLimit], plan: String?)
    /// No `claude` in ~/.local/bin, /opt/homebrew/bin or /usr/local/bin.
    case notInstalled
    /// The binary is not signed by Anthropic: it is never run.
    case notGenuine
    /// The CLI answered with something that is not a 0-token `/usage`: Glancy stops calling it
    /// until it is turned off and on again (or relaunched).
    case unexpectedOutput
    /// Timed out, killed, could not start: a later refresh may try again.
    case failed
}

/// Runs Claude Code's official `/usage` the way Burny does. Defense in depth, any one layer is
/// enough:
///  - only the genuine CLI: its code signature must chain to Apple and belong to Anthropic's team
///    (checked by Apple's own `codesign`, once per binary path + modification date);
///  - the input is a constant local slash command, never text from anywhere else; the model is
///    never called;
///  - no tools, no MCP servers, no settings / hooks / CLAUDE.md, $0.0001 spending cap, no saved
///    session; sandboxed away from personal folders; a minimal environment;
///  - the output must prove that no model turn happened (0 turns, $0, 0 ms of API), else Glancy
///    stops calling it;
///  - only numbers and dates are taken from the output, with a strict pattern; nothing is executed.
/// The child runs in its own process group, is killed (the whole group) after `timeout` or on
/// `cancel()`, and is registered with `ChildProcesses` so it never outlives Glancy.
public final class ClaudeUsageCLI: @unchecked Sendable {
    /// Anthropic's Apple Developer team.
    static let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"Q6L2SF6YDW\""
    static let candidates = ["~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]

    /// The arguments after the binary: Burny's, verbatim.
    static let arguments = ["-p", "/usage", "--output-format", "json", "--no-session-persistence",
                            "--setting-sources", "", "--settings", "{\"disableAllHooks\":true}",
                            "--tools", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
                            "--max-budget-usd", "0.0001"]
    /// Folders the CLI is fenced off from (no "would like to access your Desktop" prompt on Glancy's behalf).
    static let fencedFolders = ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Library/Mobile Documents"]

    let home: URL
    /// Where the CLI runs (an empty folder of Glancy's own).
    let workDir: URL
    let timeout: TimeInterval
    /// The signature check (tests replace it). Returns true only for Anthropic's binary.
    var verify: @Sendable (String) -> Bool
    /// Runs a program and returns its stdout (tests replace it).
    var run: @Sendable (_ exe: String, _ args: [String], _ env: [String: String], _ cwd: String, _ timeout: TimeInterval,
                        _ child: ChildRun) -> ChildRun.Result
    /// Finds the binary (tests replace it).
    var locate: @Sendable () -> String?

    private let lock = NSLock()
    private var verified: (path: String, mtime: Date)?
    private var current: ChildRun?

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                workDir: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Glancy/usage-cwd", isDirectory: true),
                timeout: TimeInterval = 40) {
        self.home = home
        self.workDir = workDir
        self.timeout = timeout
        self.verify = { path in ClaudeUsageCLI.codesignVerify(path) }
        self.run = { exe, args, env, cwd, timeout, child in child.run(exe, args, env: env, cwd: cwd, timeout: timeout) }
        let h = home
        self.locate = { ClaudeUsageCLI.findBinary(home: h) }
    }

    static func findBinary(home: URL) -> String? {
        candidates.map { $0.hasPrefix("~/") ? home.appendingPathComponent(String($0.dropFirst(2))).path : $0 }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Whether the CLI is installed (Settings: on by default only then).
    public var isInstalled: Bool { locate() != nil }

    /// Stops a run in flight (the whole process group is killed).
    public func cancel() {
        lock.withLock { current }?.kill()
    }

    /// One `/usage`. Blocking: call off the main thread.
    public func fetch(now: @Sendable () -> Date = { .now }) -> ClaudeUsageOutcome {
        guard let bin = locate() else { return .notInstalled }
        guard isGenuine(bin) else { return .notGenuine }
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        var exe = bin, args = Self.arguments
        let sandbox = "/usr/bin/sandbox-exec"
        if FileManager.default.isExecutableFile(atPath: sandbox) {
            let fenced = Self.fencedFolders.map { "(subpath \"\(home.appendingPathComponent($0).path)\")" }.joined(separator: " ")
            exe = sandbox
            args = ["-p", "(version 1)(allow default)(deny file-read* file-write* \(fenced))", bin] + args
        }
        var env = ["HOME": home.path, "USER": NSUserName(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        env["TMPDIR"] = ProcessInfo.processInfo.environment["TMPDIR"]
        let child = ChildRun()
        lock.withLock { current = child }
        defer { lock.withLock { if current === child { current = nil } } }
        let result = run(exe, args, env, workDir.path, timeout, child)
        guard result.status == 0, !result.killed else { return .failed }
        return Self.interpret(result.output, plan: claudePlan(), now: now())
    }

    /// The CLI's JSON answer → limits, or why not. Pure (tests).
    static func interpret(_ data: Data, plan: String?, now: Date) -> ClaudeUsageOutcome {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["is_error"] as? Bool) != true, let text = obj["result"] as? String else { return .unexpectedOutput }
        let noModel = (obj["num_turns"] as? NSNumber)?.intValue == 0 && (obj["total_cost_usd"] as? NSNumber)?.doubleValue == 0
            && (obj["duration_api_ms"] as? NSNumber)?.intValue == 0
        let limits = UsageParser.claudeUsage(text, now: now)
        guard noModel, !limits.isEmpty else { return .unexpectedOutput }   // the CLI changed: stop, don't retry
        return .ok(limits, plan: plan)
    }

    func claudePlan() -> String? {
        guard let data = try? Data(contentsOf: home.appendingPathComponent(".claude.json")) else { return nil }
        return UsageParser.claudePlan(json: data)
    }

    /// The signature check, once per binary (path + modification date): verifying hashes the whole
    /// ~200 MB binary, in Apple's short-lived `codesign` so its buffers never stay in Glancy.
    func isGenuine(_ path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let mtime = (try? resolved.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if let v = lock.withLock({ verified }), v.path == resolved.path, v.mtime == mtime { return true }
        guard verify(resolved.path) else { return false }
        lock.withLock { verified = (resolved.path, mtime) }
        return true
    }

    static func codesignVerify(_ path: String) -> Bool {
        let r = ChildRun().run("/usr/bin/codesign", ["--verify", "-R=\(requirement)", path], env: [:], cwd: "/", timeout: 60)
        return r.status == 0 && !r.killed
    }
}

/// One short-lived child: posix_spawn in its own process group, stdout read to the end (capped),
/// stderr and stdin to /dev/null, the whole group SIGKILLed on timeout or `kill()`.
public final class ChildRun: @unchecked Sendable {
    public struct Result: Sendable {
        public var status: Int32
        public var output: Data
        /// Killed by the timeout or `kill()`.
        public var killed: Bool
        public init(status: Int32, output: Data, killed: Bool) { self.status = status; self.output = output; self.killed = killed }
    }

    static let maxOutput = 1 << 20

    private let lock = NSLock()
    private var pid: pid_t = 0
    private var cancelled = false
    private var wasKilled = false

    public init() {}

    /// The running child's pid (0 when none): tests check it is gone.
    public var runningPID: pid_t { lock.withLock { pid } }

    public func kill() {
        lock.withLock {
            cancelled = true
            if pid > 1 { wasKilled = true; Darwin.kill(-pid, SIGKILL); Darwin.kill(pid, SIGKILL) }
        }
    }

    /// Blocking. Returns status -1 when the program could not start.
    public func run(_ exe: String, _ args: [String], env: [String: String], cwd: String, timeout: TimeInterval) -> Result {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return Result(status: -1, output: Data(), killed: false) }
        let readFD = fds[0], writeFD = fds[1]
        _ = fcntl(readFD, F_SETFD, FD_CLOEXEC)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addclose(&actions, writeFD)
        posix_spawn_file_actions_addclose(&actions, readFD)
        _ = cwd.withCString { posix_spawn_file_actions_addchdir_np(&actions, $0) }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Its own process group (killed as one), close every other descriptor, default signals.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF))
        posix_spawnattr_setpgroup(&attr, 0)
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attr, &all)

        let argv: [UnsafeMutablePointer<CChar>?] = ([exe] + args).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }

        var child: pid_t = 0
        let started: Bool = lock.withLock {
            guard !cancelled else { return false }
            let rc = posix_spawn(&child, exe, &actions, &attr, argv, envp)
            guard rc == 0 else { return false }
            pid = child
            return true
        }
        close(writeFD)
        guard started else {
            close(readFD)
            return Result(status: -1, output: Data(), killed: lock.withLock { cancelled })
        }
        ChildProcesses.register(child)

        let killer = DispatchWorkItem { [weak self] in self?.kill() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)

        var output = Data()
        var buf = [UInt8](repeating: 0, count: 16 << 10)
        while true {
            let n = read(readFD, &buf, buf.count)
            if n > 0 {
                if output.count < Self.maxOutput { output.append(buf, count: min(n, Self.maxOutput - output.count)) }
            } else if n < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
        close(readFD)
        // Wait for the exit without reaping, so `kill()` can never hit a recycled pid; then let go
        // of the pid and reap. A normal exit is never killed afterwards: the CLI may still be
        // saving its own files.
        var info = siginfo_t()
        while waitid(P_PID, id_t(child), &info, WEXITED | WNOWAIT) < 0, errno == EINTR {}
        killer.cancel()
        let killed: Bool = lock.withLock { pid = 0; return wasKilled }
        var status: Int32 = 0
        while waitpid(child, &status, 0) < 0, errno == EINTR {}
        ChildProcesses.unregister(child)
        let exited = (status & 0x7f) == 0
        return Result(status: exited ? (status >> 8) & 0xff : -2, output: output, killed: killed)
    }
}
