import AppKit
import Foundation

// Settings, the tab's state, the visible-only sampler and the process actions.

public enum MonitorRate: String, CaseIterable, Codable, Sendable {
    case s1, s2
    var duration: Duration { self == .s1 ? .seconds(1) : .seconds(2) }
}

@MainActor @Observable
public final class MonitorSettings {
    /// The indicator the tab opens on.
    public var indicator: MonitorIndicator { didSet { save() } }
    public var grouping: MonitorGrouping { didSet { save() } }
    public var sparklines: Bool { didSet { save() } }
    public var rate: MonitorRate { didSet { save() } }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var loading = true
    static let key = "glancy.monitor.settings"

    private struct Stored: Codable {
        var indicator: MonitorIndicator
        var grouping: MonitorGrouping
        var sparklines: Bool
        var rate: MonitorRate
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let s = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        indicator = s?.indicator ?? .cpu
        grouping = s?.grouping ?? .apps
        sparklines = s?.sparklines ?? true
        rate = s?.rate ?? .s1
        loading = false
    }

    var isDefault: Bool { indicator == .cpu && grouping == .apps && sparklines && rate == .s1 }

    public func reset() {
        indicator = .cpu; grouping = .apps; sparklines = true; rate = .s1
    }

    private func save() {
        guard !loading else { return }
        let s = Stored(indicator: indicator, grouping: grouping, sparklines: sparklines, rate: rate)
        if let d = try? JSONEncoder().encode(s) { defaults.set(d, forKey: Self.key) }
    }
}

/// What a row action is aimed at.
public struct MonitorTarget: Equatable, Sendable {
    public var name: String
    public var bundlePath: String?
    public var path: String?
    public var pids: [pid_t]
    public init(name: String, bundlePath: String?, path: String?, pids: [pid_t]) {
        self.name = name; self.bundlePath = bundlePath; self.path = path; self.pids = pids
    }
    init(_ row: MonitorRow) { self.init(name: row.name, bundlePath: row.bundlePath, path: row.path, pids: row.pids) }

    /// Never Glancy itself, launchd, the kernel, or the "System processes" remainder.
    var isActionable: Bool { !pids.isEmpty && !pids.contains { $0 <= 1 || $0 == getpid() } }
}

/// A question the right column asks before acting.
public enum MonitorConfirm: Equatable, Sendable {
    case forceQuit(MonitorTarget)
    /// A bare process (no app to ask politely): SIGTERM.
    case quitProcess(MonitorTarget)
}

@MainActor @Observable
public final class MonitorModel {
    public var selected: MonitorIndicator = .cpu
    public var grouping: MonitorGrouping = .apps
    public var confirm: MonitorConfirm?
    public var note: String?
    public init() {}
}

/// Quit, force quit, reveal, Activity Monitor. Injected so no test ever touches a real process.
@MainActor
public protocol MonitorActions: AnyObject {
    /// Politely: the app's own Quit (it may ask to save), SIGTERM for a bare process.
    func quit(_ t: MonitorTarget) -> Bool
    /// `forceTerminate` / SIGKILL.
    func forceQuit(_ t: MonitorTarget) -> Bool
    func reveal(_ path: String)
    func openActivityMonitor()
    /// The running GUI apps whose name starts a word with `query` (command bar).
    func runningApps(matching query: String) -> [MonitorTarget]
}

@MainActor
public final class LiveMonitorActions: MonitorActions {
    public init() {}

    private func app(_ t: MonitorTarget) -> NSRunningApplication? {
        if let bundle = t.bundlePath,
           let a = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == bundle }) { return a }
        return t.pids.lazy.compactMap { NSRunningApplication(processIdentifier: $0) }.first { $0.bundleURL != nil }
    }

    public func quit(_ t: MonitorTarget) -> Bool {
        guard t.isActionable else { return false }
        if let a = app(t) { return a.terminate() }
        return t.pids.allSatisfy { kill($0, SIGTERM) == 0 }
    }

    public func forceQuit(_ t: MonitorTarget) -> Bool {
        guard t.isActionable else { return false }
        if let a = app(t) { return a.forceTerminate() }
        return t.pids.allSatisfy { kill($0, SIGKILL) == 0 }
    }

    public func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    public func openActivityMonitor() {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor")
            ?? URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    public func runningApps(matching query: String) -> [MonitorTarget] {
        let q = PaletteMatcher.Query(query)
        return NSWorkspace.shared.runningApplications.compactMap { a -> MonitorTarget? in
            guard a.activationPolicy == .regular, let name = a.localizedName, a.processIdentifier != getpid(),
                  let s = PaletteMatcher.score(q, MatchText(name)), s >= PaletteMatcher.wordPrefix else { return nil }
            return MonitorTarget(name: name, bundlePath: a.bundleURL?.path, path: a.bundleURL?.path, pids: [a.processIdentifier])
        }
    }
}

// MARK: - Sampler (visible-only)

/// Owns the readings off the main thread.
actor MonitorWorker {
    private let source: MonitorSource
    private var system = MonitorSystemEngine()
    private var scanner: ProcessScanner
    private var snapshot = MonitorSnapshot()
    private var tick = 0
    static let slowEvery = 30

    init(source: MonitorSource, engine: ProcessEngine) {
        self.source = source
        self.scanner = ProcessScanner(engine: engine)
    }

    /// Forget every baseline (the next rates start from now, not from the last time it was open).
    func reset(engine: ProcessEngine) {
        system = MonitorSystemEngine()
        scanner = ProcessScanner(engine: engine)
        snapshot = MonitorSnapshot()
        tick = 0
    }

    func sample(gpu: Bool, now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> MonitorSnapshot {
        if tick % Self.slowEvery == 0 { snapshot.disk = source.stats.disk() }
        tick += 1
        system.sample(source, into: &snapshot, now: now)
        let (processes, apps) = scanner.scan(source, now: now, busyCores: snapshot.busyCores, gpu: gpu)
        snapshot.processes = processes
        snapshot.apps = apps
        snapshot.processCount = scanner.lastCount
        snapshot.scanMillis = scanner.lastMillis
        return snapshot
    }
}

/// Samples once per interval while `isRunning`. Started and stopped only by the module's
/// `visibilityChanged` (Monitor tab on screen): nothing runs while collapsed or on another tab.
@MainActor @Observable
public final class MonitorSampler {
    public private(set) var snapshot = MonitorSnapshot()
    /// The last ~60 values of each gauge, oldest first, for the sparklines.
    public private(set) var history: [MonitorIndicator: [Double]] = [:]
    public private(set) var samples = 0
    public var isRunning: Bool { task != nil }
    /// Per-process GPU time costs an IOKit walk: read only while GPU is the selected gauge.
    @ObservationIgnored public var wantsGPUProcesses = false

    @ObservationIgnored private let worker: MonitorWorker
    @ObservationIgnored private let engine: ProcessEngine
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private(set) var interval: Duration = .seconds(1)
    static let historyLength = 60

    public init(source: MonitorSource = LiveMonitorSource(), engine: ProcessEngine = .live()) {
        self.engine = engine
        self.worker = MonitorWorker(source: source, engine: engine)
    }

    public func start(interval: Duration) {
        if task != nil, interval == self.interval { return }
        task?.cancel()
        self.interval = interval
        let worker = self.worker, engine = self.engine
        let fresh = task == nil
        if fresh { history = [:] }
        task = Task { [weak self] in
            if fresh { await worker.reset(engine: engine) }
            while !Task.isCancelled {
                let gpu = self?.wantsGPUProcesses ?? false
                let snap = await worker.sample(gpu: gpu)
                guard !Task.isCancelled, let self else { return }
                self.adopt(snap)
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    private func adopt(_ s: MonitorSnapshot) {
        snapshot = s
        samples += 1
        push(.cpu, s.cpu)
        push(.memory, s.memory.map { Double($0.used) / Double(max($0.total, 1)) })
        push(.gpu, s.gpu)
        push(.disk, (s.diskRead ?? 0) + (s.diskWrite ?? 0))
        push(.network, (s.down ?? 0) + (s.up ?? 0))
        push(.energy, s.power?.watts)
    }

    private func push(_ i: MonitorIndicator, _ v: Double?) {
        guard let v else { return }
        var h = history[i] ?? []
        h.append(v)
        if h.count > Self.historyLength { h.removeFirst(h.count - Self.historyLength) }
        history[i] = h
    }

    /// For renders: fixed figures.
    func show(_ s: MonitorSnapshot, history h: [MonitorIndicator: [Double]]) {
        snapshot = s
        history = h
    }
}
