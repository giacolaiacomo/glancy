import AppKit
import Foundation
import Testing
@testable import GlancyKit

// Lot MON: the system monitor. No test quits, kills or signals any process: actions go to a fake.

// MARK: - Fakes

final class FakeMonitorSource: MonitorSource, @unchecked Sendable {
    private let lock = NSLock()
    let stats: StatsSource = FakeStatsSource()
    private var _procs: [ProcessUsage] = []
    private var _ids: [pid_t: ProcessIdentity] = [:]
    private var _identityCalls: [pid_t] = []
    /// Added to every process's CPU time on each read (so successive scans have rates).
    var cpuStep: [pid_t: UInt64] = [:]

    var procs: [ProcessUsage] {
        get { lock.withLock { _procs } }
        set { lock.withLock { _procs = newValue } }
    }
    var ids: [pid_t: ProcessIdentity] {
        get { lock.withLock { _ids } }
        set { lock.withLock { _ids = newValue } }
    }
    var identityCalls: [pid_t] { lock.withLock { _identityCalls } }

    func cores() -> [CPUTicks]? { [CPUTicks(user: 1, system: 1, idle: 1, nice: 0), CPUTicks(user: 1, system: 1, idle: 1, nice: 0)] }
    func swap() -> SwapReading? { SwapReading(used: 1 << 30, total: 2 << 30) }
    func gpu() -> Double? { 0.25 }
    func diskIO() -> DiskIOCounters? { DiskIOCounters(read: 0, written: 0) }
    func power() -> PowerReading? { PowerReading(watts: 9.5, onBattery: false) }
    func thermal() -> Int { 0 }
    func gpuTimes() -> [pid_t: UInt64] { [:] }

    func processes() -> [ProcessUsage] {
        lock.withLock {
            for i in _procs.indices { _procs[i].cpuTime &+= cpuStep[_procs[i].pid] ?? 0 }
            return _procs
        }
    }

    func identity(_ pid: pid_t) -> ProcessIdentity? {
        lock.withLock {
            _identityCalls.append(pid)
            return _ids[pid]
        }
    }
}

@MainActor
final class FakeMonitorActions: MonitorActions {
    var quits: [MonitorTarget] = []
    var forced: [MonitorTarget] = []
    var revealed: [String] = []
    var activityMonitor = 0
    var apps: [MonitorTarget] = []
    func quit(_ t: MonitorTarget) -> Bool { quits.append(t); return true }
    func forceQuit(_ t: MonitorTarget) -> Bool { forced.append(t); return true }
    func reveal(_ path: String) { revealed.append(path) }
    func openActivityMonitor() { activityMonitor += 1 }
    func runningApps(matching query: String) -> [MonitorTarget] {
        apps.filter { $0.name.lowercased().hasPrefix(query.lowercased()) }
    }
}

private let chrome = "/Applications/Google Chrome.app"
private let helperPath = chrome + "/Contents/Frameworks/Google Chrome Framework.framework/Versions/130/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"

private func id(_ pid: pid_t, _ name: String, _ path: String?, responsible: String? = nil) -> ProcessIdentity {
    ProcessIdentity(pid: pid, name: name, path: path, group: AppGrouping.group(pid: pid, name: name, path: path, responsiblePath: responsible))
}

@MainActor
private func makeMonitor(_ source: FakeMonitorSource = FakeMonitorSource(), actions: FakeMonitorActions = FakeMonitorActions())
    -> (MonitorModule, FakeMonitorSource, FakeMonitorActions, ActivityHub) {
    let defaults = UserDefaults(suiteName: "glancy.test.monitor.\(UUID().uuidString)")!
    let m = MonitorModule(source: source, actions: actions, settings: MonitorSettings(defaults: defaults),
                          engine: ProcessEngine(numer: 1, denom: 1))
    let hub = ActivityHub()
    m.start(hub: hub)
    return (m, source, actions, hub)
}

@MainActor
private func settle(_ cond: @MainActor () -> Bool, timeout: Double = 10) async -> Bool {
    let end = Date.now.addingTimeInterval(timeout)
    while Date.now < end {
        if cond() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return cond()
}

// MARK: - Rates

@Suite("Monitor rates")
struct MonitorRateTests {
    @Test func cpuFromRusageDeltasWithAppleSiliconTimebase() {
        // 125/3: 24 MHz ticks. 24 000 000 ticks = 1 s of CPU over 1 s of wall time = one core.
        var e = ProcessEngine(numer: 125, denom: 3)
        let a = ProcessUsage(pid: 10, start: 7, cpuTime: 1_000, footprint: 100)
        _ = e.step([a], identities: [:], now: 1_000_000_000)
        var b = a
        b.cpuTime += 24_000_000
        let rows = e.step([b], identities: [:], now: 2_000_000_000)
        #expect(abs(rows[0].cpu - 1.0) < 1e-9)
        #expect(e.nanoseconds(3) == 125)
    }

    @Test func cpuWithIntelTimebaseAndHalfASecond() {
        var e = ProcessEngine(numer: 1, denom: 1)
        _ = e.step([ProcessUsage(pid: 1, start: 1, cpuTime: 0, footprint: 0)], identities: [:], now: 0)
        let rows = e.step([ProcessUsage(pid: 1, start: 1, cpuTime: 750_000_000, footprint: 0)], identities: [:], now: 500_000_000)
        #expect(abs(rows[0].cpu - 1.5) < 1e-9, "1.5 cores = 150 %")
    }

    @Test func churnNewReusedAndVanishedPids() {
        var e = ProcessEngine(numer: 1, denom: 1)
        _ = e.step([ProcessUsage(pid: 1, start: 1, cpuTime: 5_000, footprint: 10),
                    ProcessUsage(pid: 2, start: 1, cpuTime: 9_000_000_000, footprint: 20)], identities: [:], now: 0)
        // pid 2 is gone and comes back as another process (new start) with a smaller counter; pid 3 is new.
        let rows = e.step([ProcessUsage(pid: 1, start: 1, cpuTime: 5_000, footprint: 10),
                           ProcessUsage(pid: 2, start: 99, cpuTime: 1_000, footprint: 30),
                           ProcessUsage(pid: 3, start: 5, cpuTime: 1_000_000, footprint: 40)], identities: [:], now: 1_000_000_000)
        let by = Dictionary(uniqueKeysWithValues: rows.map { ($0.pids[0], $0) })
        #expect(by[1]?.cpu == 0)
        #expect(by[2]?.cpu == 0, "a reused pid starts over, never a huge or negative jump")
        #expect(by[2]?.memory == 30)
        #expect(by[3]?.cpu == 0 && by[3]?.memory == 40, "first sight: memory only")
        // Vanished: pid 1 not in the next reading, and not in the rows.
        let next = e.step([ProcessUsage(pid: 3, start: 5, cpuTime: 2_000_000, footprint: 40)], identities: [:], now: 2_000_000_000)
        #expect(next.map(\.pids[0]) == [3])
        #expect(next[0].cpu > 0)
    }

    @Test func counterGoingBackwardsIsZero() {
        var e = ProcessEngine(numer: 1, denom: 1)
        _ = e.step([ProcessUsage(pid: 1, start: 1, cpuTime: 10_000, footprint: 0, diskRead: 500, energy: 900)], identities: [:], now: 0)
        let r = e.step([ProcessUsage(pid: 1, start: 1, cpuTime: 1, footprint: 0, diskRead: 1, energy: 1)], identities: [:], now: 1_000_000_000)
        #expect(r[0].cpu == 0 && r[0].disk == 0 && r[0].energy == 0)
    }

    @Test func diskAndEnergyRates() {
        var e = ProcessEngine(numer: 1, denom: 1)
        _ = e.step([ProcessUsage(pid: 1, start: 1, cpuTime: 0, footprint: 0, diskRead: 0, diskWritten: 0, energy: 0)], identities: [:], now: 0)
        let r = e.step([ProcessUsage(pid: 1, start: 1, cpuTime: 0, footprint: 0, diskRead: 3_000_000, diskWritten: 1_000_000,
                                     energy: 4_000_000_000)], identities: [:], now: 2_000_000_000)
        #expect(r[0].disk == 2_000_000, "4 MB in 2 s")
        #expect(r[0].energy == 2, "4 J in 2 s = 2 W")
    }

    @Test func gpuShares() {
        var g = GPUEngine()
        #expect(g.step([5: 100], now: 0).isEmpty)
        let s = g.step([5: 250_000_100, 6: 10], now: 1_000_000_000)
        #expect(abs((s[5] ?? 0) - 0.25) < 1e-9)
        #expect(s[6] == nil, "a new client has no share yet")
    }

    @Test func systemSplitUserAndSystem() {
        var snap = MonitorSnapshot()
        MonitorSystemEngine.split(from: CPUTicks(user: 0, system: 0, idle: 0, nice: 0),
                                  to: CPUTicks(user: 20, system: 10, idle: 60, nice: 10), into: &snap)
        #expect(snap.cpuUser == 0.3 && snap.cpuSystem == 0.1 && snap.cpu == 0.4)
    }
}

// MARK: - Grouping and ranking

@Suite("Monitor grouping")
struct MonitorGroupingTests {
    @Test func outerAppOfNestedHelpers() {
        #expect(AppGrouping.outerApp(helperPath) == chrome)
        #expect(AppGrouping.outerApp("/Applications/Safari.app") == "/Applications/Safari.app")
        #expect(AppGrouping.outerApp("/usr/sbin/cfprefsd") == nil)
        #expect(AppGrouping.outerApp(nil) == nil)
        #expect(AppGrouping.appName(chrome) == "Google Chrome")
    }

    @Test func helpersRollUpUnderTheirApp() {
        let ids: [pid_t: ProcessIdentity] = [
            1: id(1, "Google Chrome", chrome + "/Contents/MacOS/Google Chrome"),
            2: id(2, "Google Chrome Helper (Renderer)", helperPath),
            3: id(3, "Google Chrome Helper (Renderer)", helperPath),
            // WebKit's WebContent lives in /System, Safari is responsible for it.
            4: id(4, "com.apple.WebKit.WebContent", "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent",
                  responsible: "/Applications/Safari.app/Contents/MacOS/Safari"),
            5: id(5, "cfprefsd", "/usr/sbin/cfprefsd"),
        ]
        func row(_ pid: pid_t, cpu: Double, mem: UInt64) -> MonitorRow {
            var r = MonitorRow(id: "pid:\(pid)", name: ids[pid]?.name ?? "pid \(pid)", pids: [pid])
            r.cpu = cpu; r.memory = mem
            return r
        }
        // pid 6 has no identity (exited while being read): it stays a row of its own.
        let rows = [row(1, cpu: 0.2, mem: 100), row(2, cpu: 0.5, mem: 200), row(3, cpu: 0.3, mem: 300),
                    row(4, cpu: 0.1, mem: 50), row(5, cpu: 0.05, mem: 5), row(6, cpu: 0.01, mem: 1)]
        let apps = AppGrouping.rollUp(rows, identities: ids)
        let c = apps.first { $0.id == chrome }
        #expect(c?.name == "Google Chrome")
        #expect(c.map { abs($0.cpu - 1.0) < 1e-9 } == true)
        #expect(c?.memory == 600)
        #expect(Set(c?.pids ?? []) == [1, 2, 3])
        #expect(apps.first { $0.id == "/Applications/Safari.app" }?.pids == [4])
        #expect(apps.first { $0.id == "pid:5" }?.name == "cfprefsd")
        #expect(apps.first { $0.id == "pid:6" }?.name == "pid 6")
        #expect(apps.count == 4)
    }

    @Test func sortingTopFiveByEachIndicator() {
        func r(_ n: String, cpu: Double, mem: UInt64, disk: Double = 0) -> MonitorRow {
            var x = MonitorRow(id: n, name: n); x.cpu = cpu; x.memory = mem; x.disk = disk; return x
        }
        let rows = [r("a", cpu: 0.1, mem: 900), r("b", cpu: 0.9, mem: 10), r("c", cpu: 0.5, mem: 500), r("d", cpu: 0.5, mem: 400),
                    r("e", cpu: 0.2, mem: 300), r("f", cpu: 0.3, mem: 200), r("g", cpu: 0, mem: 100, disk: 5)]
        #expect(MonitorRanking.top(rows, by: .cpu).map(\.name) == ["b", "c", "d", "f", "e"], "ties by name")
        #expect(MonitorRanking.top(rows, by: .memory).map(\.name) == ["a", "c", "d", "e", "f"])
        #expect(MonitorRanking.top(rows, by: .disk).map(\.name) == ["g"], "zero rows are left out")
        #expect(MonitorRanking.top(rows, by: .cpu, limit: 3).count == 3)
    }

    @Test func remainderIsHostMinusReadable() {
        var a = MonitorRow(id: "a", name: "a"); a.cpu = 0.5
        let rest = MonitorRanking.remainder(hostBusyCores: 2.0, rows: [a])
        #expect(rest?.isRemainder == true && abs((rest?.cpu ?? 0) - 1.5) < 1e-9)
        #expect(MonitorRanking.remainder(hostBusyCores: 0.51, rows: [a]) == nil, "under 2 % of a core")
        #expect(MonitorRanking.remainder(hostBusyCores: nil, rows: [a]) == nil)
    }

    @Test func scannerResolvesEachProcessOnceAndAgainAfterPidReuse() {
        let src = FakeMonitorSource()
        src.procs = [ProcessUsage(pid: 10, start: 1, cpuTime: 0, footprint: 1), ProcessUsage(pid: 11, start: 1, cpuTime: 0, footprint: 1)]
        src.ids = [10: id(10, "a", "/usr/bin/a"), 11: id(11, "b", helperPath)]
        src.cpuStep = [10: 100_000_000]
        var s = ProcessScanner(engine: ProcessEngine(numer: 1, denom: 1))
        let first = s.scan(src, now: 0, busyCores: 4, gpu: false)
        #expect(!first.apps.contains { $0.isRemainder }, "no remainder before there are rates")
        let second = s.scan(src, now: 1_000_000_000, busyCores: 4, gpu: false)
        #expect(src.identityCalls == [10, 11] || src.identityCalls == [11, 10] || src.identityCalls.sorted() == [10, 11])
        #expect(second.apps.contains { $0.id == chrome })
        #expect(second.apps.contains { $0.isRemainder })
        // pid 10 now belongs to a different process.
        src.procs = [ProcessUsage(pid: 10, start: 2, cpuTime: 0, footprint: 1)]
        _ = s.scan(src, now: 2_000_000_000, busyCores: nil, gpu: false)
        #expect(src.identityCalls.filter { $0 == 10 }.count == 2)
    }
}

// MARK: - Module: sampler, actions, keys, commands

@Suite("Monitor module", .serialized)
@MainActor
struct MonitorModuleTests {
    @Test func samplerRunsOnlyWhileTheTabIsOnScreen() async {
        let (m, src, _, _) = makeMonitor()
        src.procs = [ProcessUsage(pid: 10, start: 1, cpuTime: 0, footprint: 5)]
        #expect(!m.sampler.isRunning)
        m.visibilityChanged(.collapsed)
        m.visibilityChanged(.expanded(nil))
        #expect(!m.sampler.isRunning, "Home is not the Monitor tab")
        m.visibilityChanged(.expanded(.control))
        #expect(!m.sampler.isRunning)
        m.visibilityChanged(.expanded(.monitor))
        #expect(m.sampler.isRunning)
        #expect(await settle { m.sampler.samples >= 1 })
        #expect(m.sampler.snapshot.processCount == 1)
        #expect(m.sampler.snapshot.power?.watts == 9.5)
        m.visibilityChanged(.collapsed)
        #expect(!m.sampler.isRunning)
        let n = m.sampler.samples
        try? await Task.sleep(for: .milliseconds(1200))
        #expect(m.sampler.samples == n, "nothing ticks while collapsed")
        m.visibilityChanged(.expanded(.monitor))
        #expect(m.sampler.isRunning)
        m.visibilityChanged(.hidden)
        #expect(!m.sampler.isRunning)
        m.visibilityChanged(.expanded(.monitor))
        m.stop()
        #expect(!m.sampler.isRunning)
    }

    @Test func controlAndMonitorNeverSampleTogether() {
        let (m, _, _, _) = makeMonitor()
        let defaults = UserDefaults(suiteName: "glancy.test.control.\(UUID().uuidString)")!
        let c = ControlModule(actions: FakeSystemActions(), settings: ControlSettings(defaults: defaults), scheduler: FakeScheduler(),
                              stats: StatsSampler(source: FakeStatsSource(), interval: .milliseconds(10)))
        c.start(hub: ActivityHub())
        for v: SurfaceVisibility in [.expanded(.control), .expanded(.monitor), .expanded(nil), .expanded(.control), .collapsed] {
            m.visibilityChanged(v); c.visibilityChanged(v)
            #expect(!(m.sampler.isRunning && c.stats.isRunning))
        }
        m.stop(); c.stop()
    }

    @Test func tabOpensOnTheDefaultAndKeepsTheChoiceWhileOpen() {
        let (m, _, _, _) = makeMonitor()
        m.settings.indicator = .memory
        m.visibilityChanged(.expanded(.monitor))
        #expect(m.model.selected == .memory)
        m.select(.disk)
        m.visibilityChanged(.expanded(.monitor))
        #expect(m.model.selected == .disk)
        m.visibilityChanged(.collapsed)
        m.visibilityChanged(.expanded(.monitor))
        #expect(m.model.selected == .memory)
        m.stop()
    }

    @Test func keysMoveBetweenGauges() {
        let (m, _, _, _) = makeMonitor()
        m.visibilityChanged(.expanded(.monitor))
        m.select(.cpu)
        m.handle(.right); #expect(m.model.selected == .memory)
        m.handle(.down); #expect(m.model.selected == .disk)
        m.handle(.up); #expect(m.model.selected == .memory)
        m.handle(.number(6)); #expect(m.model.selected == .energy)
        m.handle(.right); #expect(m.model.selected == .cpu, "wraps")
        #expect(!m.handle(.number(9)))
        m.stop()
    }

    @Test func actionsNeedAClickAndForceQuitAsks() {
        let (m, _, acts, _) = makeMonitor()
        var app = MonitorRow(id: chrome, name: "Google Chrome", bundlePath: chrome, path: chrome, pids: [901, 902])
        app.cpu = 1
        m.quit(app)
        #expect(acts.quits.map(\.name) == ["Google Chrome"], "an app quits politely at once")
        m.askForceQuit(app)
        #expect(acts.forced.isEmpty)
        #expect(m.model.confirm == .forceQuit(MonitorTarget(app)))
        m.cancelConfirm()
        #expect(acts.forced.isEmpty && m.model.confirm == nil)
        m.askForceQuit(app)
        m.confirmAction()
        #expect(acts.forced.map(\.pids) == [[901, 902]])
        // A bare process gets SIGTERM only after a confirmation.
        let proc = MonitorRow(id: "pid:777", name: "node", path: "/usr/local/bin/node", pids: [777])
        m.quit(proc)
        #expect(acts.quits.count == 1)
        #expect(m.model.confirm == .quitProcess(MonitorTarget(proc)))
        m.confirmAction()
        #expect(acts.quits.count == 2)
        // Never Glancy itself, launchd, or the remainder row.
        m.quit(MonitorRow(id: "self", name: "Glancy", bundlePath: "/x/Glancy.app", pids: [getpid()]))
        m.askForceQuit(MonitorRow(id: "launchd", name: "launchd", pids: [1]))
        var rest = MonitorRow(id: "system.remainder", name: "System processes"); rest.isRemainder = true
        m.askForceQuit(rest)
        #expect(acts.quits.count == 2 && m.model.confirm == nil)
        m.reveal(app)
        #expect(acts.revealed == [chrome])
        m.stop()
    }

    @Test func commandsEnglishAndItalian() {
        let (m, _, _, _) = makeMonitor()
        L10n.apply(.en)
        let en = m.commands()
        #expect(Set(en.map(\.id)) == ["monitor.open", "monitor.topCPU", "monitor.topMemory", "monitor.activityMonitor"])
        #expect(en.first { $0.id == "monitor.open" }?.title == "System monitor")
        let words = en.flatMap(\.keywords)
        for w in ["activity", "cpu", "ram", "memoria", "monitor di sistema"] { #expect(words.contains(w)) }
        L10n.apply(.it)
        let it = m.commands()
        #expect(it.first { $0.id == "monitor.open" }?.title == "Monitor di sistema")
        #expect(it.first { $0.id == "monitor.topMemory" }?.title == "Più memoria")
        #expect(it.first { $0.id == "monitor.activityMonitor" }?.title == "Apri Monitoraggio Attività")
        L10n.apply(.en)
        m.stop()
    }

    @Test func typedCPUAndRAMListTheTopThree() {
        let src = FakeMonitorSource()
        src.procs = (1...5).map { ProcessUsage(pid: pid_t(100 + $0), start: 1, cpuTime: 0, footprint: UInt64($0) * 1_000_000) }
        src.ids = Dictionary(uniqueKeysWithValues: (1...5).map { (pid_t(100 + $0), id(pid_t(100 + $0), "p\($0)", "/usr/bin/p\($0)")) })
        src.cpuStep = [101: 50_000_000, 102: 40_000_000, 103: 30_000_000, 104: 20_000_000, 105: 10_000_000]
        let (m, _, _, _) = makeMonitor(src)
        L10n.apply(.en)
        _ = m.commands()                       // the bar opens: baseline
        let cpu = m.results(for: "cpu")
        #expect(cpu.map(\.title) == ["p1", "p2", "p3"])
        #expect(cpu.allSatisfy { $0.module == .monitor && ($0.subtitle ?? "").hasPrefix("CPU ") })
        let ram = m.results(for: "memoria")
        #expect(ram.map(\.title) == ["p5", "p4", "p3"])
        #expect(m.results(for: "ra").isEmpty, "under three characters")
        #expect(m.results(for: "zzz").isEmpty)
        m.stop()
    }

    @Test func typedAppNameOffersQuitAndForceQuitThatAsksFirst() {
        let src = FakeMonitorSource()
        src.procs = [ProcessUsage(pid: 901, start: 1, cpuTime: 0, footprint: 2_000_000_000)]
        src.ids = [901: id(901, "Google Chrome", chrome + "/Contents/MacOS/Google Chrome")]
        let acts = FakeMonitorActions()
        acts.apps = [MonitorTarget(name: "Google Chrome", bundlePath: chrome, path: chrome, pids: [901])]
        let (m, _, _, hub) = makeMonitor(src, actions: acts)
        var opened: [ModuleID?] = []
        hub.onOpenRequest = { opened.append($0) }
        L10n.apply(.it)
        let rows = m.results(for: "goog")
        #expect(rows.map(\.title) == ["Esci da Google Chrome", "Uscita forzata da Google Chrome…"])
        #expect(rows[0].subtitle?.contains("GB") == true)
        rows[1].run()
        #expect(acts.forced.isEmpty, "force quit from the bar only asks")
        #expect(opened == [.monitor])
        m.visibilityChanged(.expanded(.monitor))
        #expect(m.model.confirm == .forceQuit(MonitorTarget(name: "Google Chrome", bundlePath: chrome, path: chrome, pids: [901])))
        rows[0].run()
        #expect(acts.quits.map(\.name) == ["Google Chrome"])
        L10n.apply(.en)
        m.stop()
    }

    @Test func linkFromControlExistsOnlyWhileRunning() {
        let (m, _, _, _) = makeMonitor()
        #expect(MonitorLink.open != nil)
        m.stop()
        #expect(MonitorLink.open == nil)
    }

    @Test func settingsPersist() {
        let defaults = UserDefaults(suiteName: "glancy.test.monitor.settings.\(UUID().uuidString)")!
        let s = MonitorSettings(defaults: defaults)
        #expect(s.isDefault)
        s.indicator = .energy; s.grouping = .processes; s.sparklines = false; s.rate = .s2
        let t = MonitorSettings(defaults: defaults)
        #expect(t.indicator == .energy && t.grouping == .processes && !t.sparklines && t.rate == .s2)
        t.reset()
        #expect(MonitorSettings(defaults: defaults).isDefault)
    }
}

// MARK: - This Mac, read-only

@Suite("Monitor live scan")
struct MonitorLiveTests {
    @Test func scansThisMacQuickly() {
        let source = LiveMonitorSource()
        var s = ProcessScanner()
        var t: [Double] = []
        var first = 0.0
        var last: (processes: [MonitorRow], apps: [MonitorRow]) = ([], [])
        for i in 0..<11 {
            last = s.scan(source, now: DispatchTime.now().uptimeNanoseconds, busyCores: nil, gpu: false)
            if i > 0 { t.append(s.lastMillis) } else { first = s.lastMillis }   // the first also resolves every identity
        }
        let avg = t.reduce(0, +) / Double(t.count)
        print("monitor live scan: \(s.lastCount) readable processes, first scan \(String(format: "%.2f", first)) ms, steady scan \(String(format: "%.2f", avg)) ms")
        #expect(s.lastCount > 50)
        #expect(last.processes.contains { $0.pids == [getpid()] })
        #expect(!last.apps.isEmpty)
        if !CI.isCI { #expect(avg < 10) }
    }

    @Test func systemReadingsAreSane() {
        let source = LiveMonitorSource()
        let t0 = DispatchTime.now().uptimeNanoseconds
        var snap = MonitorSnapshot()
        var engine = MonitorSystemEngine()
        engine.sample(source, into: &snap, now: t0)
        print("monitor system sample: \(String(format: "%.2f", Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)) ms; GPU per-process walk: \(source.gpuTimes().count) pids")
        #expect((source.cores()?.count ?? 0) >= 1)
        #expect(source.swap() != nil)
        #expect((0...3).contains(source.thermal()))
        if let g = source.gpu() { #expect((0...1).contains(g)) }
        #expect(LiveMonitorSource.creatorPID("pid 405, WindowServer") == 405)
        #expect(LiveMonitorSource.creatorPID("kernel") == nil)
    }
}

// MARK: - Tab strip

@Suite("Tab strip room")
@MainActor
struct TabStripRoomTests {
    @Test func thirteenAndFourteenSlotsFitAtFullSize() {
        // Home + 11 tabs (+ gear) by default; + Notifications when it's on.
        #expect(TabBandLayout.slot(notchWidth: 185, items: 12) == TabBandLayout.fullSlot)
        #expect(TabBandLayout.slot(notchWidth: 185, items: 13) == TabBandLayout.fullSlot)
        // A wider notch still leaves every icon its capsule.
        #expect(TabBandLayout.slot(notchWidth: 200, items: 13) >= TabBandLayout.iconWidth)
        // The old 640 pt panel would squeeze 13 slots below the capsule.
        #expect(TabBandLayout.slot(width: 640, notchWidth: 185, inset: Theme.openTopRadius + 10, items: 13) < TabBandLayout.iconWidth)
        #expect(SurfaceContext.order(.monitor) == SurfaceContext.order(.control) + 1)
        #expect(NSImage(systemSymbolName: SurfaceContext.symbol(.monitor), accessibilityDescription: nil) != nil)
    }
}

@Suite("Monitor command bar warm-up", .serialized)
@MainActor
struct MonitorBarWarmTests {
    @Test func barOpenScansOffMainThenTypedCPUHasRates() async {
        let src = FakeMonitorSource()
        src.procs = [ProcessUsage(pid: 201, start: 1, cpuTime: 0, footprint: 1_000_000),
                     ProcessUsage(pid: 202, start: 1, cpuTime: 0, footprint: 2_000_000)]
        src.ids = [201: id(201, "busy", "/usr/bin/busy"), 202: id(202, "calm", "/usr/bin/calm")]
        src.cpuStep = [201: 80_000_000, 202: 1_000_000]
        let (m, _, _, _) = makeMonitor(src)
        _ = m.commands()
        #expect(await settle { src.identityCalls.count == 2 }, "identities resolved by the warm-up")
        try? await Task.sleep(for: .milliseconds(30))
        let cpu = m.results(for: "cpu")
        #expect(cpu.first?.title == "busy")
        #expect(src.identityCalls.count == 2, "typed queries reuse the warm scanner")
        m.visibilityChanged(.collapsed)       // the bar closed: its scan is dropped
        m.stop()
    }
}
