import Darwin
import Foundation
import IOKit

// The live readings. Every call here is read-only. Measured on a 10-core M-series Mac with ~560
// processes: listing + RUSAGE_INFO_V6 for every pid ≈ 2.5 ms; a new process's identity ≈ 10 µs.

public struct LiveMonitorSource: MonitorSource {
    public let stats: StatsSource
    public init(stats: StatsSource = LiveStatsSource()) { self.stats = stats }

    // MARK: System

    public func cores() -> [CPUTicks]? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let states = Int(CPU_STATE_MAX)
        return (0..<Int(count)).map { i in
            let b = i * states
            return CPUTicks(user: UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_USER)])),
                            system: UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_SYSTEM)])),
                            idle: UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_IDLE)])),
                            nice: UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_NICE)])))
        }
    }

    public func swap() -> SwapReading? {
        var x = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &x, &size, nil, 0) == 0 else { return nil }
        return SwapReading(used: x.xsu_used, total: x.xsu_total)
    }

    public func gpu() -> Double? {
        var best: Double?
        Self.forEach("IOAccelerator") { service in
            guard let stats = Self.property(service, "PerformanceStatistics") as? [String: Any],
                  let u = (stats["Device Utilization %"] as? NSNumber)?.doubleValue else { return }
            best = max(best ?? 0, min(100, max(0, u)) / 100)
        }
        return best
    }

    public func diskIO() -> DiskIOCounters? {
        var read: UInt64 = 0, written: UInt64 = 0, any = false
        Self.forEach("IOBlockStorageDriver") { service in
            guard let stats = Self.property(service, "Statistics") as? [String: Any] else { return }
            any = true
            read &+= (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            written &+= (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return any ? DiskIOCounters(read: read, written: written) : nil
    }

    public func power() -> PowerReading? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let external = (Self.property(service, "ExternalConnected") as? NSNumber)?.boolValue ?? false
        if external {
            // Apple silicon: what comes in from the adapter, mW.
            guard let t = Self.property(service, "PowerTelemetryData") as? [String: Any],
                  let mw = (t["SystemPowerIn"] as? NSNumber)?.doubleValue, mw > 0 else { return nil }
            return PowerReading(watts: mw / 1000, onBattery: false)
        }
        // On battery: current (mA, negative while discharging) × voltage (mV).
        guard let ma = (Self.property(service, "InstantAmperage") as? NSNumber)?.int64Value
                ?? (Self.property(service, "Amperage") as? NSNumber)?.int64Value,
              let mv = (Self.property(service, "Voltage") as? NSNumber)?.doubleValue else { return nil }
        let amps = Double(Int64(truncatingIfNeeded: ma))
        return PowerReading(watts: abs(amps * mv) / 1_000_000, onBattery: true)
    }

    public func thermal() -> Int { ProcessInfo.processInfo.thermalState.rawValue }

    // MARK: Processes

    public func processes() -> [ProcessUsage] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 32)
        let got = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard got > 0 else { return [] }
        var out: [ProcessUsage] = []
        out.reserveCapacity(got)
        var ri = rusage_info_v6()
        for pid in pids.prefix(got) where pid > 0 {
            let r = withUnsafeMutablePointer(to: &ri) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
            }
            guard r == 0 else { continue }      // another user's process: EPERM without root
            out.append(ProcessUsage(pid: pid, start: ri.ri_proc_start_abstime, cpuTime: ri.ri_user_time &+ ri.ri_system_time,
                                    footprint: ri.ri_phys_footprint, diskRead: ri.ri_diskio_bytesread,
                                    diskWritten: ri.ri_diskio_byteswritten, energy: ri.ri_energy_nj))
        }
        return out
    }

    public func identity(_ pid: pid_t) -> ProcessIdentity? {
        let path = Self.path(pid)
        var nameBuf = [CChar](repeating: 0, count: 256)
        var name = proc_name(pid, &nameBuf, UInt32(nameBuf.count)) > 0 ? Self.string(nameBuf) : ""
        if name.isEmpty { name = path.map { ($0 as NSString).lastPathComponent } ?? "pid \(pid)" }
        // Only asked when the process isn't inside an app bundle itself.
        var responsible: String?
        if AppGrouping.outerApp(path) == nil, let r = Self.responsiblePID(pid), r != pid, r > 0 { responsible = Self.path(r) }
        var group = AppGrouping.group(pid: pid, name: name, path: path, responsiblePath: responsible)
        if let bundle = group.bundlePath {
            group.name = Self.names.name(bundle)
        }
        return ProcessIdentity(pid: pid, name: name, path: path, group: group)
    }

    public func gpuTimes() -> [pid_t: UInt64] {
        var out: [pid_t: UInt64] = [:]
        Self.forEach("IOAccelerator") { accelerator in
            var children: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &children) == KERN_SUCCESS else { return }
            defer { IOObjectRelease(children) }
            var c = IOIteratorNext(children)
            while c != 0 {
                if let creator = Self.property(c, "IOUserClientCreator") as? String, let pid = Self.creatorPID(creator),
                   let usage = Self.property(c, "AppUsage") as? [[String: Any]] {
                    let ns = usage.reduce(UInt64(0)) { $0 &+ (($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0) }
                    out[pid, default: 0] &+= ns
                }
                IOObjectRelease(c)
                c = IOIteratorNext(children)
            }
        }
        return out
    }

    /// "pid 405, WindowServer" → 405.
    static func creatorPID(_ s: String) -> pid_t? {
        guard s.hasPrefix("pid ") else { return nil }
        let digits = s.dropFirst(4).prefix { $0.isNumber }
        return pid_t(digits)
    }

    // MARK: Helpers

    /// The Finder's name of each app bundle (localized, without ".app"), read once per bundle.
    private static let names = DisplayNames()
    private final class DisplayNames: @unchecked Sendable {
        private let lock = NSLock()
        private var cache: [String: String] = [:]
        func name(_ bundle: String) -> String {
            if let n = lock.withLock({ cache[bundle] }) { return n }
            let n = FileManager.default.displayName(atPath: bundle).replacingOccurrences(of: ".app", with: "")
            lock.withLock { if cache.count > 512 { cache.removeAll() }; cache[bundle] = n }
            return n
        }
    }

    /// A NUL-terminated C buffer as a String.
    static func string(_ buf: [CChar]) -> String {
        String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func path(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return string(buf)
    }

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    /// `responsibility_get_pid_responsible_for_pid` (libsystem, not in the SDK headers): the pid
    /// macOS bills a process to (Activity Monitor's grouping). Looked up once; nil if it's gone.
    private static let responsible: ResponsibleFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    static func responsiblePID(_ pid: pid_t) -> pid_t? { responsible.map { $0(pid) } }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func forEach(_ cls: String, _ body: (io_service_t) -> Void) {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &it) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(it) }
        var s = IOIteratorNext(it)
        while s != 0 {
            body(s)
            IOObjectRelease(s)
            s = IOIteratorNext(it)
        }
    }
}
