import Darwin
import Foundation

// The Monitor's readings: one `MonitorSource` (live: Mach, sysctl, IOKit, libproc; tests: a fake),
// the system maths (CPU split, per-core load, disk and network rates) and the process scanner.
// CPU, memory, network, disk space and uptime come from Control's `StatsSource`: one reader for
// both tabs, never two samplers at once (each runs only while its own tab is on screen).

public struct PowerReading: Equatable, Sendable {
    /// What the Mac draws: from the adapter on AC (`SystemPowerIn`), from the battery otherwise.
    public var watts: Double
    public var onBattery: Bool
    public init(watts: Double, onBattery: Bool) { self.watts = watts; self.onBattery = onBattery }
}

public struct SwapReading: Equatable, Sendable {
    public var used: UInt64, total: UInt64
    public init(used: UInt64, total: UInt64) { self.used = used; self.total = total }
}

/// Cumulative bytes read and written by every block-storage driver.
public struct DiskIOCounters: Equatable, Sendable {
    public var read: UInt64, written: UInt64
    public init(read: UInt64, written: UInt64) { self.read = read; self.written = written }
}

public protocol MonitorSource: Sendable {
    /// CPU, memory, network, disk space, boot time (shared with the Control tab).
    var stats: StatsSource { get }
    func cores() -> [CPUTicks]?
    func swap() -> SwapReading?
    /// The GPU's "Device Utilization %", 0…1; nil when the accelerator doesn't publish it.
    func gpu() -> Double?
    func diskIO() -> DiskIOCounters?
    func power() -> PowerReading?
    /// `ProcessInfo.ThermalState.rawValue`: 0 nominal … 3 critical.
    func thermal() -> Int
    /// Every readable process (other users' processes refuse `proc_pid_rusage`).
    func processes() -> [ProcessUsage]
    /// Name, path and app of a process; asked once per process.
    func identity(_ pid: pid_t) -> ProcessIdentity?
    /// GPU time per pid (ns, summed over its accelerator clients). Read only while GPU is selected.
    func gpuTimes() -> [pid_t: UInt64]
}

/// What the tab draws.
public struct MonitorSnapshot: Equatable, Sendable {
    public var cpu: Double?                 // 0…1 of the whole machine
    public var cpuUser: Double?
    public var cpuSystem: Double?
    public var cores: [Double] = []         // 0…1 each
    public var memory: MemoryReading?
    public var swap: SwapReading?
    public var gpu: Double?
    public var disk: DiskReading?
    public var diskRead: Double?            // bytes per second
    public var diskWrite: Double?
    public var down: Double?
    public var up: Double?
    public var power: PowerReading?
    public var thermal = 0
    public var uptime: TimeInterval?
    /// The right column's sources, each already holding the "System processes" remainder. The
    /// live sampler leaves them empty on the main thread and hands over `top` instead.
    public var apps: [MonitorRow] = []
    public var processes: [MonitorRow] = []
    /// The top rows of each grouping for each gauge, ranked by the worker (off the main thread):
    /// the tab draws these, a few rows, instead of sorting ~600 processes on every update.
    public var top: [MonitorGrouping: [MonitorIndicator: [MonitorRow]]] = [:]
    /// Processes seen / readable, and what the last scan cost.
    public var processCount = 0
    public var scanMillis: Double = 0
    public init() {}

    func rows(_ g: MonitorGrouping) -> [MonitorRow] { g == .apps ? apps : processes }

    /// The `limit` biggest rows for a gauge: the worker's ranking, else ranked here (renders).
    func top(_ g: MonitorGrouping, by i: MonitorIndicator, limit: Int) -> [MonitorRow] {
        if let ranked = top[g]?[i] { return Array(ranked.prefix(limit)) }
        return MonitorRanking.top(rows(g), by: i, limit: limit)
    }

    /// Ranks every gauge that ranks processes, both groupings, and drops the full lists.
    mutating func rankAndTrim(limit: Int) {
        var t: [MonitorGrouping: [MonitorIndicator: [MonitorRow]]] = [:]
        for g in MonitorGrouping.allCases {
            let list = rows(g)
            var byIndicator: [MonitorIndicator: [MonitorRow]] = [:]
            for i in MonitorIndicator.allCases where i.ranksProcesses { byIndicator[i] = MonitorRanking.top(list, by: i, limit: limit) }
            t[g] = byIndicator
        }
        top = t
        apps = []
        processes = []
    }

    /// Busy cores, for the remainder row.
    var busyCores: Double? { cpu.map { $0 * Double(max(cores.count, 1)) } }
}

/// Successive system readings → the gauges. Pure; time is given.
public struct MonitorSystemEngine: Sendable {
    private var lastCPU: CPUTicks?
    private var lastCores: [CPUTicks] = []
    private var lastNet: NetworkCounters?
    private var lastIO: DiskIOCounters?
    private var lastTime: UInt64?
    public init() {}

    public mutating func sample(_ s: MonitorSource, into snap: inout MonitorSnapshot, now: UInt64) {
        let dt = lastTime.map { now > $0 ? Double(now - $0) / 1e9 : 0 } ?? 0
        if let c = s.stats.cpu() {
            if let p = lastCPU { Self.split(from: p, to: c, into: &snap) }
            lastCPU = c
        }
        if let cores = s.cores() {
            if cores.count == lastCores.count {
                snap.cores = zip(lastCores, cores).map { StatsEngine.cpuLoad(from: $0, to: $1) ?? 0 }
            } else if snap.cores.count != cores.count {
                snap.cores = Array(repeating: 0, count: cores.count)
            }
            lastCores = cores
        }
        snap.memory = s.stats.memory()
        snap.swap = s.swap()
        snap.gpu = s.gpu()
        if let n = s.stats.network() {
            if let p = lastNet, dt > 0 {
                snap.down = Double(StatsEngine.delta(p.received, n.received)) / dt
                snap.up = Double(StatsEngine.delta(p.sent, n.sent)) / dt
            }
            lastNet = n
        }
        if let io = s.diskIO() {
            if let p = lastIO, dt > 0 {
                snap.diskRead = Double(StatsEngine.delta(p.read, io.read)) / dt
                snap.diskWrite = Double(StatsEngine.delta(p.written, io.written)) / dt
            }
            lastIO = io
        }
        snap.power = s.power()
        snap.thermal = s.thermal()
        if let boot = s.stats.bootTime() { snap.uptime = max(0, Date.now.timeIntervalSince(boot)) }
        lastTime = now
    }

    /// Whole-machine busy share, split into user (+nice) and system.
    static func split(from a: CPUTicks, to b: CPUTicks, into snap: inout MonitorSnapshot) {
        let total = Double(StatsEngine.delta(a.total, b.total))
        guard total > 0 else { return }
        let user = Double(StatsEngine.delta(a.user, b.user) + StatsEngine.delta(a.nice, b.nice)) / total
        let system = Double(StatsEngine.delta(a.system, b.system)) / total
        snap.cpuUser = min(1, user)
        snap.cpuSystem = min(1, system)
        snap.cpu = min(1, user + system)
    }
}

/// Reads every process, keeps who each one is, and turns readings into rows (per process and per
/// app). Owned by one thread at a time: the sampler's worker, or the command bar on main.
public struct ProcessScanner: Sendable {
    private var engine: ProcessEngine
    private var gpuEngine = GPUEngine()
    private var identities: [pid_t: ProcessIdentity] = [:]
    private var starts: [pid_t: UInt64] = [:]
    public private(set) var lastMillis: Double = 0
    public private(set) var lastCount = 0

    public init(engine: ProcessEngine = .live()) { self.engine = engine }

    public var hasBaseline: Bool { engine.hasBaseline }

    /// One scan at `now` (ns). `gpu`: also read per-process GPU time (costs an IOKit walk).
    public mutating func scan(_ source: MonitorSource, now: UInt64, busyCores: Double?, gpu: Bool,
                              clock: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds })
        -> (processes: [MonitorRow], apps: [MonitorRow]) {
        let t0 = clock()
        let readings = source.processes()
        var seen: [pid_t: ProcessIdentity] = [:]
        seen.reserveCapacity(readings.count)
        for r in readings {
            if let id = identities[r.pid], starts[r.pid] == r.start {
                seen[r.pid] = id
            } else if let id = source.identity(r.pid) {
                seen[r.pid] = id
                starts[r.pid] = r.start
            }
        }
        identities = seen
        starts = starts.filter { seen[$0.key] != nil }
        let based = engine.hasBaseline
        var rows = engine.step(readings, identities: seen, now: now)
        if gpu {
            let shares = gpuEngine.step(source.gpuTimes(), now: now)
            if !shares.isEmpty {
                for i in rows.indices { if let p = rows[i].pids.first, let g = shares[p] { rows[i].gpu = g } }
            }
        } else {
            gpuEngine.reset()
        }
        var apps = AppGrouping.rollUp(rows, identities: seen)
        // The first scan has no rates yet: no remainder either (it would be the whole machine).
        if based, let rest = MonitorRanking.remainder(hostBusyCores: busyCores, rows: rows) {
            rows.append(rest)
            apps.append(rest)
        }
        lastCount = readings.count
        lastMillis = Double(clock() &- t0) / 1e6
        return (rows, apps)
    }
}
