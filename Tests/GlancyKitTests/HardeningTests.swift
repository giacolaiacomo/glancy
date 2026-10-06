import AppKit
import Darwin
import Foundation
import Testing
@testable import GlancyKit

// Lot J: every module survives start → stop → start → stop, holds nothing live after stop
// (observers, monitors, run-loop sources, tasks, child processes), and deallocates once released.
// Plus the child-process registry, the media child dying with its module, and the watchdog.

private func tempDir(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("glancy-hardening-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func defaults() -> UserDefaults { UserDefaults(suiteName: "glancy.test.hardening.\(UUID().uuidString)")! }

private final class NoCalendar: CalendarEventSource {
    var authorization: CalendarAccess = .granted
    func requestAccess() async -> Bool { true }
    func calendars() -> [CalendarInfo] { [] }
    func events(from: Date, to: Date, calendarIDs: Set<String>?) -> [CalendarEvent] { [] }
}

private final class SilentAlerts: TimerAlerting {
    func schedule(at date: Date, title: String, body: String) {}
    func cancel() {}
}

/// A stand-in for mediaremote-adapter: `/usr/bin/perl` runs this script with the same arguments.
/// `test` succeeds, `stream` stays alive printing nothing (like the real one with no player).
private func fakeAdapter() -> MediaAdapter {
    let dir = tempDir("adapter")
    let script = dir.appendingPathComponent("mediaremote-adapter.pl")
    try! """
    my $cmd = $ARGV[2];
    if ($cmd eq 'test') { exit 0; }
    if ($cmd eq 'get') { print "null\\n"; exit 0; }
    if ($cmd eq 'stream') { $| = 1; while (1) { sleep 1; } }
    exit 1;
    """.write(to: script, atomically: true, encoding: .utf8)
    let fw = dir.appendingPathComponent("MediaRemoteAdapter.framework")
    try? FileManager.default.createDirectory(at: fw, withIntermediateDirectories: true)
    let client = dir.appendingPathComponent("MediaRemoteAdapterTestClient")
    FileManager.default.createFile(atPath: client.path, contents: Data())
    return MediaAdapter(script: script, framework: fw, testClient: client)
}

private func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

/// Synchronously blocks the calling thread (here: main), like a frozen launch.
private func blockCurrentThread(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

@MainActor
private func waitUntil(_ seconds: Double = 10, _ cond: () -> Bool) async -> Bool {
    let end = Date.now.addingTimeInterval(seconds)
    while !cond() {
        if Date.now > end { return false }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return true
}

@MainActor
@Suite("Hardening: module lifecycles", .serialized)
struct ModuleLifecycleTests {
    /// Every module the app ships, built so that tests never touch user data, TCC or players.
    static func makeAll() -> [any GlancyModule] {
        [
            AgentsModule(logURL: tempDir("agents").appendingPathComponent("events.jsonl")),
            CalendarModule(source: NoCalendar(), settings: CalendarSettings(defaults: defaults())),
            MediaModule(stream: AdapterStream(pidFile: tempDir("media").appendingPathComponent("pid")), locate: { fakeAdapter() }),
            TimerModule(store: TimerStore(url: tempDir("timer").appendingPathComponent("timer.json")), alerts: SilentAlerts()),
            ShelfModule(store: ShelfStore(dir: tempDir("shelf"))),
            ClipboardModule(disk: ClipboardDisk(directory: tempDir("clip")), settings: ClipboardSettings(defaults: defaults()),
                            pasteboard: NSPasteboard(name: .init("glancy.test.\(UUID().uuidString)"))),
            WindowsModule(engine: TilingEngine(configURL: nil), hotkeysURL: nil),
            HUDModule(settings: HUDSettings(defaults: defaults()), usesHardware: false),
            PowerModule(settings: PowerSettings(defaults: defaults())),
            // Wave 4 (and Notifications), with fakes: no TCC, no system toggles, no network.
            NotificationsModule(databaseURL: tempDir("notifications").appendingPathComponent("db"),
                                settings: NotificationsSettings(defaults: defaults())),
            NotesModule(store: NotesStore(directory: tempDir("notes")), settings: NotesSettings(defaults: defaults()),
                        voiceSystem: .sample),
            ControlModule(actions: FakeSystemActions(), settings: ControlSettings(defaults: defaults()), scheduler: FakeScheduler(),
                          stats: StatsSampler(source: FakeStatsSource(), interval: .milliseconds(10))),
            MonitorModule(source: FakeMonitorSource(), actions: FakeMonitorActions(), settings: MonitorSettings(defaults: defaults()),
                          engine: ProcessEngine(numer: 1, denom: 1)),
            CommandModule(settings: CommandSettings(defaults: defaults()), history: PaletteHistory(url: nil),
                          apps: AppIndex(folders: [tempDir("apps")], extras: []), rates: CurrencyRates(cacheURL: nil)),
        ]
    }

    @Test func coversEveryModuleTheAppShips() {
        #expect(Set(Self.makeAll().map(\.id)) == Set(ModuleID.allCases))
    }

    /// Disable → enable a module (start, stop, start) must never register its hot keys twice or
    /// keep one after stop. Synchronous on the main actor (no other test can interleave), with the
    /// manager suspended so the count never depends on what the installed Glancy holds.
    @Test func startStopStartNeverDoublesHotkeys() {
        let manager = HotkeyManager.shared
        let wasSuspended = manager.isSuspended
        manager.setSuspended(true)
        defer { manager.setSuspended(wasSuspended) }
        var owners: [ModuleID: Int] = [:]
        for m in Self.makeAll() {
            let hub = ActivityHub()
            let base = manager.tokenCount
            m.start(hub: hub)
            m.start(hub: hub)
            let once = manager.tokenCount
            owners[m.id] = once - base
            m.stop()
            #expect(manager.tokenCount == base, "\(m.id) keeps hot keys after stop")
            m.start(hub: hub)
            #expect(manager.tokenCount == once, "\(m.id) registers \(manager.tokenCount - once) hot keys more on restart")
            m.stop()
            m.stop()   // a second stop is harmless
            #expect(manager.tokenCount == base, "\(m.id) keeps hot keys after the second stop")
        }
        // Not vacuous: the modules with default hot keys did register them.
        // (Calendar's join key is registered only while a meeting can be joined.)
        #expect(owners[.windows, default: 0] >= 19 && owners[.notes] == 2 && owners[.command] == 1 && owners[.clipboard] == 1,
                "\(owners)")
    }

    static let fanOut: [SurfaceVisibility] = [.collapsed, .expanded(nil), .hidden, .collapsed]

    private func cycle(_ m: any GlancyModule, _ hub: ActivityHub) async {
        m.start(hub: hub)
        m.start(hub: hub)    // idempotent
        for v in Self.fanOut { m.visibilityChanged(v) }
        if let tab = m.tab?.module { m.visibilityChanged(.expanded(tab)); m.visibilityChanged(.collapsed) }
        try? await Task.sleep(for: .milliseconds(150))   // let launch tasks run
        m.stop()
    }

    @Test func everyModuleHoldsNothingLiveAfterStop() async {
        for m in Self.makeAll() {
            let hub = ActivityHub()
            await cycle(m, hub)
            // stop() SIGTERMs a child; it is gone a moment later.
            _ = await waitUntil(2) { ResourceCensus.of(m).processes == 0 }
            let after = ResourceCensus.of(m)
            #expect(after.observers == 0 && after.monitors == 0 && after.sources == 0 && after.processes == 0,
                    "\(m.id) after stop: \(after)")
            #expect(after.tasks == 0, "\(m.id) still holds live tasks after stop: \(after)")
            // Restart and stop again: same clean state, nothing doubled.
            await cycle(m, hub)
            _ = await waitUntil(2) { ResourceCensus.of(m).processes == 0 }
            #expect(ResourceCensus.of(m) == after, "\(m.id) second cycle differs")
        }
    }

    @Test func theCensusSeesARunningModule() async {
        // The check above is only meaningful if a running module's handles are actually counted.
        var running: [ModuleID: ResourceCensus] = [:]
        for m in Self.makeAll() {
            m.start(hub: ActivityHub())
            try? await Task.sleep(for: .milliseconds(100))
            running[m.id] = ResourceCensus.of(m)
            m.stop()
        }
        try? await Task.sleep(for: .milliseconds(300))   // children SIGTERMed by stop() exit
        print("census while running:", running.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "; "))
        #expect(running[.calendar]!.observers >= 2)     // wake, day change (EKEventStoreChanged only with EventKit)
        #expect(running[.agents]!.sources >= 1)         // the log's dispatch source
        #expect(running[.timer]!.observers >= 1)
        #expect(running[.power]!.sources >= 1)          // IOPS run-loop source
        #expect(running[.media]!.observers >= 4)
        #expect(running[.shelf]!.monitors >= 1)          // the drag watcher's mouse-down monitor
    }

    @Test func everyModuleDeallocatesAfterStop() async {
        var refs: [(ModuleID, () -> AnyObject?)] = []
        for m in Self.makeAll() {
            await cycle(m, ActivityHub())
            weak let w = m as AnyObject
            refs.append((m.id, { w }))
        }
        // Tasks that captured `self` weakly wake up, see nil, and end.
        try? await Task.sleep(for: .milliseconds(300))
        for (id, ref) in refs { #expect(ref() == nil, "\(id) leaked after stop") }
    }

    @Test func hiddenStopsVisibleOnlyWork() async {
        // Media ticks only while the panel shows it; Agents pulses only expanded.
        let agents = AgentsModule(logURL: tempDir("agents").appendingPathComponent("events.jsonl"))
        agents.start(hub: ActivityHub())
        agents.visibilityChanged(.expanded(.agents))
        #expect(agents.model.pulse)
        agents.visibilityChanged(.hidden)
        #expect(!agents.model.pulse)
        agents.stop()
    }
}

@MainActor
@Suite("Hardening: child processes", .serialized)
struct ChildProcessTests {
    @Test func mediaChildDiesWithItsModuleAndIsNotOrphaned() async throws {
        let pidFile = tempDir("media").appendingPathComponent("pid")
        let stream = AdapterStream(pidFile: pidFile)
        let media = MediaModule(stream: stream, locate: { fakeAdapter() })
        media.start(hub: ActivityHub())
        #expect(await waitUntil { stream.pid != nil })
        let pid = try #require(stream.pid)
        #expect(alive(pid))
        #expect(ChildProcesses.current.contains(pid), "registered for the signal handlers")
        #expect(FileManager.default.fileExists(atPath: pidFile.path), "pid recorded for orphan reaping")
        media.stop()
        #expect(await waitUntil { !alive(pid) }, "perl child must exit on stop")
        #expect(await waitUntil { !ChildProcesses.current.contains(pid) })
        #expect(await waitUntil { !FileManager.default.fileExists(atPath: pidFile.path) })
        // And again: a restart spawns a new one, stop kills it too.
        media.start(hub: ActivityHub())
        #expect(await waitUntil { stream.pid != nil })
        let pid2 = try #require(stream.pid)
        #expect(pid2 != pid)
        media.stop()
        #expect(await waitUntil { !alive(pid2) })
    }

    @Test func orphanFromACrashedRunIsReapedOnNextStart() async throws {
        // A perl whose parent is gone (re-parented to launchd), as after a SIGKILL of Glancy.
        let adapter = fakeAdapter()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The outer shell exits at once; the inner perl is adopted by launchd.
        p.arguments = ["-c", "/usr/bin/perl '\(adapter.script.path)' fw tc stream </dev/null >/dev/null 2>&1 & echo $!"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let orphan = try #require(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await waitUntil { var info = proc_bsdinfo(); return proc_pidinfo(orphan, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 && info.pbi_ppid == 1 })
        let pidFile = tempDir("media").appendingPathComponent("pid")
        AdapterStream.writePID(orphan, to: pidFile)
        AdapterStream.reapOrphan(pidFile)
        #expect(await waitUntil { !alive(orphan) }, "the orphan perl is killed on the next launch")
        if alive(orphan) { kill(orphan, SIGKILL) }
    }

    @Test func terminationSignalHandlerRunsOffMainKillsChildrenThenQuitsOnMain() async throws {
        // The SIGTERM path, minus the signal: the handler as the dispatch source calls it, on a
        // background queue (a main-actor-inferred closure trapped right here in the real app).
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        try p.run()
        ChildProcesses.register(p.processIdentifier)
        defer { ChildProcesses.unregister(p.processIdentifier) }
        final class Flag: @unchecked Sendable { var quitOnMain: Bool? }
        let flag = Flag()
        let handler = ChildProcesses.terminationHandler(grace: nil) { flag.quitOnMain = Thread.isMainThread }
        DispatchQueue.global(qos: .userInitiated).async(execute: handler)
        #expect(await waitUntil { flag.quitOnMain != nil })
        #expect(flag.quitOnMain == true)
        p.waitUntilExit()
        #expect(p.terminationReason == .uncaughtSignal && p.terminationStatus == SIGTERM)
    }

    @Test func registryTerminatesRegisteredChildren() async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        try p.run()
        let pid = p.processIdentifier
        ChildProcesses.register(pid)
        #expect(ChildProcesses.current.contains(pid))
        ChildProcesses.terminateAll()     // what the crash / SIGTERM handlers call
        p.waitUntilExit()
        #expect(p.terminationReason == .uncaughtSignal && p.terminationStatus == SIGTERM)
        ChildProcesses.unregister(pid)
        #expect(!ChildProcesses.current.contains(pid))
    }
}

@MainActor
@Suite("Hardening: watchdog and census", .serialized)
struct WatchdogTests {
    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var reports: [String] = []
        func add(_ s: String) { lock.withLock { reports.append(s) } }
        var all: [String] { lock.withLock { reports } }
    }

    @Test func aBlockedMainThreadIsReportedWithItsStack() async {
        let box = Box()
        MainThreadWatchdog.arm("test", timeout: 0.2, force: true) { box.add($0) }
        blockCurrentThread(0.8)    // the "stuck launch": main never returns to its run loop
        for _ in 0..<40 where box.all.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
        let report = box.all.first ?? ""
        #expect(report.contains("did not reach the run loop"))
        // The sampled stack is the main thread's, caught inside the sleep.
        #expect(report.contains("nanosleep") || report.contains("sleep"), "\(report.prefix(600))")
    }

    @Test(.disabled(if: CI.isCI, "300 ms main-thread budget: shared runners stall main under parallel tests"))
    func aFreeMainThreadIsNotReported() async {
        let box = Box()
        MainThreadWatchdog.arm("test", timeout: 0.3, force: true) { box.add($0) }
        try? await Task.sleep(for: .milliseconds(600))
        #expect(box.all.isEmpty)
    }

    @Test func censusCountsWhatIsHeld() {
        final class Holder {
            var token: NSObjectProtocol? = NotificationCenter().addObserver(forName: .init("x"), object: nil, queue: nil) { _ in }
            var task: Task<Void, Never>? = Task { try? await Task.sleep(for: .seconds(5)) }
            var list: [(NotificationCenter, NSObjectProtocol)] = [(NotificationCenter(), NotificationCenter().addObserver(forName: .init("y"), object: nil, queue: nil) { _ in })]
            var source: CFRunLoopSource? = { var c = CFRunLoopSourceContext(); return CFRunLoopSourceCreate(nil, 0, &c) }()
        }
        let h = Holder()
        let c = ResourceCensus.of(h)
        #expect(c.observers == 2 && c.tasks == 1 && c.sources == 1)
        h.task?.cancel()
        #expect(ResourceCensus.of(h).tasks == 0, "a cancelled task is not live")
    }
}
