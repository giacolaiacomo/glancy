import Darwin
import Foundation
import IOKit

// The system readings the Monitor tab samples (only while it is on screen): raw counters from a
// `StatsSource` (live: Mach host statistics, sysctl, IOKit) and the pure maths over them (deltas,
// load), tested with a fake source.

/// Raw cumulative CPU ticks (all cores).
public struct CPUTicks: Equatable, Sendable {
    public var user: UInt64, system: UInt64, idle: UInt64, nice: UInt64
    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user; self.system = system; self.idle = idle; self.nice = nice
    }
    var busy: UInt64 { user &+ system &+ nice }
    var total: UInt64 { busy &+ idle }
}

public struct MemoryReading: Equatable, Sendable {
    public var used: UInt64          // active + wired + compressed
    public var total: UInt64
    /// 1 normal, 2 warning, 4 critical (`kern.memorystatus_vm_pressure_level`).
    public var pressure: Int
    public init(used: UInt64, total: UInt64, pressure: Int) { self.used = used; self.total = total; self.pressure = pressure }
}

public struct DiskReading: Equatable, Sendable {
    public var free: Int64, total: Int64
    public init(free: Int64, total: Int64) { self.free = free; self.total = total }
}

public struct BatteryReading: Equatable, Sendable {
    public var cycles: Int
    /// Full-charge capacity / design capacity, 0…1+.
    public var health: Double
    public init(cycles: Int, health: Double) { self.cycles = cycles; self.health = health }
}

/// Cumulative bytes through every non-loopback interface.
public struct NetworkCounters: Equatable, Sendable {
    public var received: UInt64, sent: UInt64
    public init(received: UInt64, sent: UInt64) { self.received = received; self.sent = sent }
}

/// Where readings come from. Cheap calls (< 1 ms) except `disk` and `battery`, which the Monitor's
/// worker reads once when sampling starts and then rarely.
public protocol StatsSource: Sendable {
    func cpu() -> CPUTicks?
    func memory() -> MemoryReading?
    func network() -> NetworkCounters?
    func disk() -> DiskReading?
    func battery() -> BatteryReading?
    func bootTime() -> Date?
}

/// Counter maths. Pure.
public enum StatsEngine {
    /// Busy share of the ticks between two readings; nil when no time passed.
    static func cpuLoad(from a: CPUTicks, to b: CPUTicks) -> Double? {
        let total = Double(delta(a.total, b.total))
        guard total > 0 else { return nil }
        return min(1, max(0, Double(delta(a.busy, b.busy)) / total))
    }

    /// A counter step that tolerates a reset (interface gone, counter restarted): 0, not a huge jump.
    static func delta(_ a: UInt64, _ b: UInt64) -> UInt64 { b >= a ? b - a : 0 }
}

// MARK: - Live source

public struct LiveStatsSource: StatsSource {
    public init() {}

    public func cpu() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        return CPUTicks(user: UInt64(t.0), system: UInt64(t.1), idle: UInt64(t.2), nice: UInt64(t.3))
    }

    public func memory() -> MemoryReading? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return nil }
        var page: vm_size_t = 0
        host_page_size(host, &page)
        let pages = UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) != 0 { level = 1 }
        return MemoryReading(used: pages * UInt64(page), total: ProcessInfo.processInfo.physicalMemory, pressure: Int(level))
    }

    /// 64-bit interface counters through `NET_RT_IFLIST2` (getifaddrs' `if_data` wraps at 4 GB).
    public func network() -> NetworkCounters? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &len, nil, 0) == 0, len > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, UInt32(mib.count), &buf, &len, nil, 0) == 0 else { return nil }
        var rx: UInt64 = 0, tx: UInt64 = 0
        var offset = 0
        buf.withUnsafeBytes { raw in
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.load(fromByteOffset: offset, as: if_msghdr.self)
                let msgLen = Int(hdr.ifm_msglen)
                guard msgLen > 0 else { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= len {
                    let h2 = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    let loopback = (h2.ifm_flags & IFF_LOOPBACK) != 0
                    if !loopback {
                        rx &+= h2.ifm_data.ifi_ibytes
                        tx &+= h2.ifm_data.ifi_obytes
                    }
                }
                offset += msgLen
            }
        }
        return NetworkCounters(received: rx, sent: tx)
    }

    public func disk() -> DiskReading? {
        let url = URL(fileURLWithPath: "/")
        guard let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
              let free = v.volumeAvailableCapacityForImportantUsage, let total = v.volumeTotalCapacity else { return nil }
        return DiskReading(free: free, total: Int64(total))
    }

    public func battery() -> BatteryReading? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        func int(_ key: String) -> Int? {
            (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
        }
        guard let cycles = int("CycleCount"), let design = int("DesignCapacity"), design > 0 else { return nil }
        // Apple silicon reports MaxCapacity as a percentage; the raw mAh value has its own key.
        let full = int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity") ?? int("MaxCapacity") ?? 0
        guard full > 0 else { return nil }
        return BatteryReading(cycles: cycles, health: Double(full) / Double(design))
    }

    public func bootTime() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }
}
