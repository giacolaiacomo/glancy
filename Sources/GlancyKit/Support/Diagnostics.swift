import AppKit
import ApplicationServices
import CoreBluetooth
import Darwin
import EventKit
import UserNotifications
import os

/// `--diagnose` (release-safe): module start times, permission states, child processes and what
/// each part holds (observers, monitors, sources, tasks). Printed to stdout and written to
/// `~/Library/Logs/Glancy/diagnose-<time>.txt`. With another Glancy already running, reports
/// on that process instead (footprint, threads, fds, children) and exits.
@MainActor
public enum Diagnostics {
    static let log = Logger(subsystem: "ai.glancy.app", category: "diagnostics")
    /// A module whose `start` takes longer than this is logged (main thread time at launch).
    static let slowStart: TimeInterval = 0.05

    private(set) static var launchUptime: TimeInterval?
    private(set) static var runLoopUptime: TimeInterval?
    private(set) static var moduleStarts: [(id: ModuleID, seconds: TimeInterval)] = []

    public static func markLaunch() { launchUptime = ProcessInfo.processInfo.systemUptime }
    public static func markRunLoopReached() {
        if runLoopUptime == nil { runLoopUptime = ProcessInfo.processInfo.systemUptime }
    }

    /// How long a module's `start(hub:)` held the main thread.
    public static func recordStart(_ id: ModuleID, seconds: TimeInterval) {
        moduleStarts.removeAll { $0.id == id }
        moduleStarts.append((id, seconds))
        if seconds > slowStart {
            log.error("module \(id.rawValue, privacy: .public) start took \(Int(seconds * 1000)) ms on main")
        }
    }

    // MARK: Report (this process)

    /// The full report for the running app. `delegate` is walked by reflection for the surface
    /// manager and the module list (no new seams in the app shell).
    public static func report(delegate: AnyObject?) async -> String {
        var out: [String] = []
        let pid = getpid()
        out.append("Glancy diagnose — pid \(pid) — \(Date.now.formatted(.iso8601))")
        out.append("binary: \(Bundle.main.executablePath ?? CommandLine.arguments[0])")
        out.append("app support: \(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path)")
        if let a = launchUptime, let b = runLoopUptime {
            out.append(String(format: "launch → main run loop: %.0f ms", (b - a) * 1000))
        }

        out.append("")
        out.append("module start (main thread):")
        for s in moduleStarts.sorted(by: { $0.seconds > $1.seconds }) {
            out.append("  " + pad(s.id.rawValue, 11) + String(format: "%7.1f ms", s.seconds * 1000)
                       + (s.seconds > slowStart ? "  SLOW" : ""))
        }
        if moduleStarts.isEmpty { out.append("  (none recorded)") }

        out.append("")
        out.append("permissions:")
        for (k, v) in await permissions() { out.append("  \(k): \(v)") }

        out.append("")
        out.append("process: " + ProcessStats.read(pid).summary)
        let kids = ProcessStats.children(of: pid)
        out.append("child processes: \(kids.isEmpty ? "none" : "")")
        for k in kids { out.append("  \(k) " + ProcessStats.read(k).summary) }
        out.append("registered children: \(ChildProcesses.current.map(String.init).joined(separator: " "))")

        out.append("")
        out.append("held resources (observers / monitors / sources / tasks / processes):")
        let mirror = delegate.map { Mirror(reflecting: $0) }
        if let manager = mirror?.descendant("manager") as AnyObject? {
            out.append("  " + pad("surface", 11) + "     " + ResourceCensus.of(manager).description)
        }
        if let context = mirror?.descendant("context") as? SurfaceContext {
            let running = mirror?.descendant("running") as? Set<ModuleID> ?? []
            for m in context.modules.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
                let state = running.contains(m.id) ? "on " : "off"
                out.append("  " + pad(m.id.rawValue, 11) + state + "  " + ResourceCensus.of(m).description)
            }
        }
        out.append("  carbon hot keys registered: \(HotkeyManager.shared.registeredCount)")
        if let w = MainThreadWatchdog.lastReport { out += ["", "watchdog:", w] }
        return out.joined(separator: "\n")
    }

    /// Writes the report next to the other logs and returns its path.
    @discardableResult
    public static func write(_ report: String) -> URL? {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Glancy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("diagnose-\(f.string(from: .now)).txt")
        return (try? (report + "\n").write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil
    }

    static func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s + " " : s + String(repeating: " ", count: n - s.count) }

    // MARK: Permissions (never prompts)

    static func permissions() async -> [(String, String)] {
        var out: [(String, String)] = []
        out.append(("Accessibility", AXIsProcessTrusted() ? "granted" : "not granted"))
        out.append(("Input Monitoring", CGPreflightListenEventAccess() ? "granted" : "not granted"))
        let cal: String = switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: "full access"
        case .writeOnly: "write only"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not determined"
        default: "authorized (legacy)"
        }
        out.append(("Calendar", cal))
        // CoreBluetooth without a usage description in Info.plist kills the process: only bundled.
        if Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil {
            let bt: String = switch CBManager.authorization {
            case .allowedAlways: "allowed"
            case .denied: "denied"
            case .restricted: "restricted"
            case .notDetermined: "not determined"
            @unknown default: "unknown"
            }
            out.append(("Bluetooth", bt))
        } else {
            out.append(("Bluetooth", "n/a (no usage description: unbundled binary)"))
        }
        out.append(("Full Disk Access", fullDiskAccess()))
        if Bundle.main.bundleIdentifier != nil {
            let s = await UNUserNotificationCenter.current().notificationSettings()
            let n: String = switch s.authorizationStatus {
            case .authorized: "authorized"
            case .denied: "denied"
            case .notDetermined: "not determined"
            case .provisional: "provisional"
            default: "other"
            }
            out.append(("Notifications", n))
        } else {
            out.append(("Notifications", "n/a (unbundled binary)"))
        }
        return out
    }

    /// The notifications database is behind Full Disk Access: a read-only open tells.
    static func fullDiskAccess() -> String {
        let path = NSHomeDirectory() + "/Library/Group Containers/group.com.apple.usernoted/db2/db"
        let fd = open(path, O_RDONLY)
        if fd >= 0 { close(fd); return "granted" }
        return errno == ENOENT ? "unknown (no database)" : "not granted"
    }

    // MARK: Another instance

    /// Another Glancy already running (the installed app while a debug build runs `--diagnose`).
    static func otherInstance() -> NSRunningApplication? {
        let me = getpid()
        return NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier != me && ($0.bundleIdentifier == "ai.glancy.app" || $0.localizedName == "Glancy")
        }
    }

    static func reportOther(_ app: NSRunningApplication) -> String {
        let pid = app.processIdentifier
        var out = ["Glancy diagnose — another instance is running (pid \(pid)); reporting on it from outside."]
        out.append("path: \(app.executableURL?.path ?? "?")")
        out.append("process: " + ProcessStats.read(pid).summary)
        let kids = ProcessStats.children(of: pid)
        out.append("child processes: \(kids.isEmpty ? "none" : "")")
        for k in kids { out.append("  \(k) " + ProcessStats.read(k).summary) }
        out.append("Module start times and held resources are only known inside the process:")
        out.append("quit it and run `Glancy --diagnose`, or run a debug build with CFFIXED_USER_HOME set.")
        return out.joined(separator: "\n")
    }

    // MARK: Entry point

    /// Wired by `GlancyApp.run()` for `--diagnose`.
    static func scheduleReport(after delay: TimeInterval, stay: Bool) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            let text = await report(delegate: NSApp.delegate as AnyObject?)
            print(text)
            if let url = write(text) { print("written: \(url.path)") }
            fflush(stdout)
            if !stay { NSApp.terminate(nil) }
        }
    }
}

/// Per-process numbers from libproc: no `ps`, no child process.
public struct ProcessStats: Sendable {
    public var name = "?"
    public var footprintBytes: UInt64 = 0
    public var cpuSeconds: Double = 0
    public var threads = 0
    public var fds = 0

    public var summary: String {
        String(format: "%@ footprint %.1f MB, cpu %.2f s, threads %d, fds %d",
               name as NSString, Double(footprintBytes) / 1_048_576, cpuSeconds, threads, fds)
    }

    public static func read(_ pid: pid_t) -> ProcessStats {
        var s = ProcessStats()
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
            let bytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            s.name = (String(decoding: bytes, as: UTF8.self) as NSString).lastPathComponent
        }
        var usage = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &usage) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        if ok == 0 {
            s.footprintBytes = usage.ri_phys_footprint
            var tb = mach_timebase_info_data_t()
            mach_timebase_info(&tb)
            let ns = Double(usage.ri_user_time + usage.ri_system_time) * Double(tb.numer) / Double(tb.denom)
            s.cpuSeconds = ns / 1e9
        }
        var task = proc_taskinfo()
        if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 {
            s.threads = Int(task.pti_threadnum)
        }
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        if bytes > 0 {
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.size + 16)
            let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.size))
            if got > 0 { s.fds = Int(got) / MemoryLayout<proc_fdinfo>.size }
        }
        return s
    }

    public static func children(of pid: pid_t) -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 256)
        let n = proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return [] }
        // Returns a count of pids on current macOS (bytes on some older releases): bound both ways.
        let count = min(Int(n), pids.count)
        return Array(pids.prefix(count)).filter { $0 > 0 }
    }
}
