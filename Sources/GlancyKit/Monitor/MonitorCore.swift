import Darwin
import Foundation

// The Monitor's pure side: what an indicator is, what a process row holds, the maths that turns
// two cumulative readings into rates (CPU from rusage ticks, disk bytes, energy), the roll-up of
// helpers under their app, and the ranking. No clock and no syscalls here: everything is given.

/// The six gauges on the left; the selected one decides what the right column ranks by.
public enum MonitorIndicator: String, CaseIterable, Codable, Sendable {
    case cpu, memory, gpu, disk, network, energy

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .gpu: "square.stack.3d.up"
        case .disk: "internaldrive"
        case .network: "network"
        case .energy: "bolt"
        }
    }

    /// English title (also the L10n key).
    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .gpu: "GPU"
        case .disk: "Disk"
        case .network: "Network"
        case .energy: "Energy"
        }
    }

    /// Whether the right column can rank processes by it (per-app network needs a private API).
    var ranksProcesses: Bool { self != .network }
}

/// Apps (helpers rolled up under their app) or every process on its own.
public enum MonitorGrouping: String, CaseIterable, Codable, Sendable { case apps, processes }

/// One cumulative reading of a process (`proc_pid_rusage`, RUSAGE_INFO_V6).
public struct ProcessUsage: Equatable, Sendable {
    public var pid: pid_t
    /// `ri_proc_start_abstime`: tells a reused pid from the process that had it before.
    public var start: UInt64
    /// user + system time, in mach absolute time units (ticks on Apple silicon, ns on Intel).
    public var cpuTime: UInt64
    public var footprint: UInt64
    public var diskRead: UInt64
    public var diskWritten: UInt64
    /// `ri_energy_nj`: the kernel's per-process energy estimate, nanojoules.
    public var energy: UInt64
    public init(pid: pid_t, start: UInt64, cpuTime: UInt64, footprint: UInt64, diskRead: UInt64 = 0, diskWritten: UInt64 = 0, energy: UInt64 = 0) {
        self.pid = pid; self.start = start; self.cpuTime = cpuTime; self.footprint = footprint
        self.diskRead = diskRead; self.diskWritten = diskWritten; self.energy = energy
    }
}

/// Who a process is and where it belongs. Resolved once per process (pid + start time).
public struct ProcessIdentity: Equatable, Sendable {
    public var pid: pid_t
    public var name: String
    /// The executable, when readable.
    public var path: String?
    /// The app this process counts towards (itself when it belongs to none).
    public var group: AppGroup
    public init(pid: pid_t, name: String, path: String?, group: AppGroup) {
        self.pid = pid; self.name = name; self.path = path; self.group = group
    }
}

public struct AppGroup: Hashable, Sendable {
    /// The bundle path for an app, "pid:<n>" for a process of its own.
    public var id: String
    public var name: String
    /// The .app bundle (icon, Reveal in Finder); nil for a bare process.
    public var bundlePath: String?
    public init(id: String, name: String, bundlePath: String?) { self.id = id; self.name = name; self.bundlePath = bundlePath }
}

/// One row of the right column: a process, or an app with its helpers.
public struct MonitorRow: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var bundlePath: String?
    /// The executable (processes view: icon fallback, Reveal in Finder).
    public var path: String?
    public var pids: [pid_t]
    /// Cores busy: 1 = one core flat out (Activity Monitor's 100 %).
    public var cpu: Double = 0
    public var memory: UInt64 = 0
    /// Bytes read + written per second.
    public var disk: Double = 0
    /// Watts.
    public var energy: Double = 0
    /// Share of the GPU's time, 0…1.
    public var gpu: Double = 0
    /// Processes of other users (root daemons, WindowServer…) aren't readable without privileges:
    /// their CPU is the host's busy time minus every readable process, shown as one row.
    public var isRemainder = false

    public init(id: String, name: String, bundlePath: String? = nil, path: String? = nil, pids: [pid_t] = []) {
        self.id = id; self.name = name; self.bundlePath = bundlePath; self.path = path; self.pids = pids
    }

    public func value(_ i: MonitorIndicator) -> Double {
        switch i {
        case .cpu: cpu
        case .memory: Double(memory)
        case .gpu: gpu
        case .disk: disk
        case .energy: energy
        case .network: 0
        }
    }
}

// MARK: - Rates

/// Turns successive process readings into per-process rates. Pure: the time and the timebase are
/// given, so tests are exact.
public struct ProcessEngine: Sendable {
    public let numer: UInt64, denom: UInt64
    private var last: [pid_t: ProcessUsage] = [:]
    private var lastTime: UInt64?

    public init(numer: UInt32, denom: UInt32) {
        self.numer = UInt64(max(numer, 1)); self.denom = UInt64(max(denom, 1))
    }

    /// The live timebase (125/3 on Apple silicon: 24 MHz ticks; 1/1 on Intel).
    public static func live() -> ProcessEngine {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return ProcessEngine(numer: tb.numer, denom: tb.denom)
    }

    /// Mach absolute units → nanoseconds (no overflow for decades of CPU time).
    public func nanoseconds(_ ticks: UInt64) -> Double { Double(ticks) * Double(numer) / Double(denom) }

    /// One step at `now` (nanoseconds, monotonic). A process seen for the first time, or a pid now
    /// held by a different process, reports memory only; vanished pids are forgotten.
    public mutating func step(_ readings: [ProcessUsage], identities: [pid_t: ProcessIdentity], now: UInt64) -> [MonitorRow] {
        let dt = lastTime.map { now > $0 ? Double(now - $0) : 0 } ?? 0
        var rows: [MonitorRow] = []
        rows.reserveCapacity(readings.count)
        var next: [pid_t: ProcessUsage] = [:]
        next.reserveCapacity(readings.count)
        for r in readings {
            next[r.pid] = r
            let id = identities[r.pid]
            var row = MonitorRow(id: "pid:\(r.pid)", name: id?.name ?? "pid \(r.pid)", bundlePath: id?.group.bundlePath,
                                 path: id?.path, pids: [r.pid])
            row.memory = r.footprint
            if dt > 0, let p = last[r.pid], p.start == r.start {
                row.cpu = nanoseconds(Self.delta(p.cpuTime, r.cpuTime)) / dt
                row.disk = Double(Self.delta(p.diskRead, r.diskRead) &+ Self.delta(p.diskWritten, r.diskWritten)) / (dt / 1e9)
                row.energy = Double(Self.delta(p.energy, r.energy)) / dt          // nJ per ns = W
            }
            rows.append(row)
        }
        last = next
        lastTime = now
        return rows
    }

    /// Wall time since the previous step, seconds (0 before the second step).
    public func elapsed(to now: UInt64) -> Double {
        guard let lastTime, now > lastTime else { return 0 }
        return Double(now - lastTime) / 1e9
    }

    public var hasBaseline: Bool { lastTime != nil }

    static func delta(_ a: UInt64, _ b: UInt64) -> UInt64 { b >= a ? b - a : 0 }
}

/// GPU time per process from the accelerator's user clients (`AppUsage.accumulatedGPUTime`, ns).
/// A pid may hold several clients; their times are summed before they get here.
public struct GPUEngine: Sendable {
    private var last: [pid_t: UInt64] = [:]
    private var lastTime: UInt64?
    public init() {}

    /// Share of the GPU per pid since the previous step (empty on the first).
    public mutating func step(_ times: [pid_t: UInt64], now: UInt64) -> [pid_t: Double] {
        defer { last = times; lastTime = now }
        guard let t0 = lastTime, now > t0 else { return [:] }
        let dt = Double(now - t0)
        var out: [pid_t: Double] = [:]
        for (pid, t) in times {
            guard let p = last[pid] else { continue }
            let share = Double(ProcessEngine.delta(p, t)) / dt
            if share > 0 { out[pid] = min(1, share) }
        }
        return out
    }

    public mutating func reset() { last = [:]; lastTime = nil }
}

// MARK: - Grouping

public enum AppGrouping {
    /// The outermost `.app` bundle in a path: "/Applications/Google Chrome.app" for every Chrome
    /// helper nested inside its frameworks. nil when the path isn't inside an app.
    public static func outerApp(_ path: String?) -> String? {
        guard let path, let r = path.range(of: ".app/") ?? (path.hasSuffix(".app") ? path.range(of: ".app", options: .backwards) : nil)
        else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    /// "Google Chrome" from "/Applications/Google Chrome.app".
    public static func appName(_ bundle: String) -> String {
        (bundle as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
    }

    /// Where a process belongs: its own app bundle when its executable sits inside one (Chrome's
    /// helpers, an app's XPC services); otherwise the app macOS holds responsible for it (WebKit's
    /// WebContent → Safari, a command in Terminal → Terminal); otherwise itself.
    public static func group(pid: pid_t, name: String, path: String?, responsiblePath: String?) -> AppGroup {
        if let app = outerApp(path) ?? outerApp(responsiblePath) {
            return AppGroup(id: app, name: appName(app), bundlePath: app)
        }
        return AppGroup(id: "pid:\(pid)", name: name, bundlePath: nil)
    }

    /// Sums processes into their app; an app's name comes from the group.
    public static func rollUp(_ rows: [MonitorRow], identities: [pid_t: ProcessIdentity]) -> [MonitorRow] {
        var byGroup: [String: MonitorRow] = [:]
        var order: [String] = []
        for r in rows {
            guard let pid = r.pids.first else { continue }
            let g = identities[pid]?.group ?? AppGroup(id: r.id, name: r.name, bundlePath: r.bundlePath)
            if var acc = byGroup[g.id] {
                acc.pids += r.pids
                acc.cpu += r.cpu; acc.memory &+= r.memory; acc.disk += r.disk; acc.energy += r.energy; acc.gpu = min(1, acc.gpu + r.gpu)
                byGroup[g.id] = acc
            } else {
                var acc = r
                acc.id = g.id; acc.name = g.name; acc.bundlePath = g.bundlePath
                acc.path = g.bundlePath ?? r.path
                byGroup[g.id] = acc
                order.append(g.id)
            }
        }
        return order.compactMap { byGroup[$0] }
    }
}

// MARK: - Ranking

public enum MonitorRanking {
    /// The `limit` biggest rows for an indicator; ties by name so the list doesn't shuffle.
    public static func top(_ rows: [MonitorRow], by i: MonitorIndicator, limit: Int = 5) -> [MonitorRow] {
        Array(rows.filter { $0.value(i) > 0 }.sorted { a, b in
            let va = a.value(i), vb = b.value(i)
            return va != vb ? va > vb : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }.prefix(limit))
    }

    /// CPU nobody readable accounts for (other users' processes): host busy cores minus the sum.
    /// nil when it's negligible (< 2 % of a core).
    public static func remainder(hostBusyCores: Double?, rows: [MonitorRow]) -> MonitorRow? {
        guard let host = hostBusyCores else { return nil }
        let rest = host - rows.reduce(0) { $0 + $1.cpu }
        guard rest >= 0.02 else { return nil }
        var r = MonitorRow(id: "system.remainder", name: "System processes")
        r.cpu = rest
        r.isRemainder = true
        return r
    }
}
