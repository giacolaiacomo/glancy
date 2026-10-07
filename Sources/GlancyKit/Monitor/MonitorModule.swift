import AppKit
import SwiftUI

/// System monitor (wave 4): six gauges on the left (CPU, memory, GPU, disk, network, energy), the
/// top five apps or processes for the selected one on the right, with Quit / Force quit / Reveal.
///
/// Zero idle cost: nothing is observed while collapsed. The sampler (1 s or 2 s) runs only while
/// the Monitor tab is on screen; the command bar takes one scan when it opens and one per query.
@MainActor
public final class MonitorModule: GlancyModule {
    public let id: ModuleID = .monitor
    public let model = MonitorModel()
    public let settings: MonitorSettings
    public let sampler: MonitorSampler
    let actions: MonitorActions
    private let source: MonitorSource

    var hub: ActivityHub?
    private var started = false
    private(set) var visibility: SurfaceVisibility = .collapsed
    private var keyMonitor: Any?
    private var noteClear: Task<Void, Never>?
    /// The command bar's own scanner (main thread, only while the bar asks).
    private var barScanner: ProcessScanner?
    private var barRows: (apps: [MonitorRow], at: UInt64)?
    private var barWarm: Task<Void, Never>?
    /// A gauge or a question the command bar asked for, applied when the tab shows.
    var pending: (MonitorIndicator?, MonitorConfirm?)?

    public convenience init() {
        self.init(source: LiveMonitorSource(), actions: LiveMonitorActions(), settings: MonitorSettings())
    }

    public init(source: MonitorSource, actions: MonitorActions, settings: MonitorSettings, engine: ProcessEngine = .live()) {
        self.source = source
        self.actions = actions
        self.settings = settings
        self.sampler = MonitorSampler(source: source, engine: engine)
        self.engine = engine
        L10n.addItalian(monitorItalian)
    }

    private let engine: ProcessEngine

    // MARK: Lifecycle

    public func start(hub: ActivityHub) {
        guard !started else { return }
        started = true
        self.hub = hub
        L10n.addItalian(monitorItalian)
    }

    public func stop() {
        started = false
        sampler.stop()
        removeKeys()
        noteClear?.cancel(); noteClear = nil
        endBar()
        model.confirm = nil
        MonitorIcons.clear()
        hub = nil
    }

    public func visibilityChanged(_ v: SurfaceVisibility) {
        let was = visibility
        visibility = v
        guard started else { return }
        if v == .expanded(.monitor) {
            if was != v {
                // Each visit opens on the default gauge; the choice then holds while the tab is open.
                model.selected = settings.indicator
                model.grouping = settings.grouping
                model.confirm = nil
                model.note = nil
            }
            applyPending()
            sampler.wantsGPUProcesses = model.selected == .gpu
            sampler.start(interval: settings.rate.duration)
            takeKeys()
        } else {
            sampler.stop()
            removeKeys()
            if was == .expanded(.monitor) {
                model.confirm = nil
                MonitorIcons.clear()
            }
            // The bar's scan is only good while the bar is open.
            if case .expanded(.command) = v {} else { endBar() }
        }
    }

    var tabVisible: Bool { visibility == .expanded(.monitor) }

    func applyPending() {
        guard let (i, confirm) = pending else { return }
        pending = nil
        if let i { select(i) }
        if let confirm { model.confirm = confirm }
    }

    func settingsChanged() {
        if tabVisible { sampler.start(interval: settings.rate.duration) }
    }

    // MARK: Selection

    public func select(_ i: MonitorIndicator) {
        guard available.contains(i) else { return }
        model.selected = i
        model.confirm = nil
        sampler.wantsGPUProcesses = i == .gpu
    }

    /// GPU shows only where the accelerator reports a utilisation.
    var available: [MonitorIndicator] {
        MonitorIndicator.allCases.filter { $0 != .gpu || sampler.snapshot.gpu != nil || sampler.samples == 0 }
    }

    func step(_ by: Int) {
        let list = available
        guard let i = list.firstIndex(of: model.selected) else { return }
        select(list[(i + by + list.count) % list.count])
    }

    // MARK: Keys (↑ ↓ ← → move between gauges, 1–6 pick one) — only while the tab is on screen

    enum Key: Equatable { case up, down, left, right, number(Int) }

    private func takeKeys() {
        SurfaceKeyFocus.request(true)
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let key = Self.key(for: event)
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.tabVisible, let key else { return false }
                return self.handle(key)
            }
            return consumed ? nil : event
        }
    }

    private func removeKeys() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            SurfaceKeyFocus.request(false)
        }
        keyMonitor = nil
    }

    static func key(for e: NSEvent) -> Key? {
        guard e.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return nil }
        switch Int(e.keyCode) {
        case 126: return .up
        case 125: return .down
        case 123: return .left
        case 124: return .right
        default:
            guard let c = e.charactersIgnoringModifiers, let n = Int(c), (1...6).contains(n) else { return nil }
            return .number(n)
        }
    }

    /// The gauges sit in two columns: ←/→ cross the row, ↑/↓ move by a row.
    @discardableResult
    func handle(_ key: Key) -> Bool {
        let list = available
        guard let i = list.firstIndex(of: model.selected) else { return false }
        switch key {
        case .left: step(-1)
        case .right: step(1)
        case .up: if i >= 2 { select(list[i - 2]) }
        case .down: if i + 2 < list.count { select(list[i + 2]) }
        case .number(let n):
            guard n - 1 < list.count else { return false }
            select(list[n - 1])
        }
        return true
    }

    // MARK: Actions (each from an explicit click; force quit and SIGTERM ask first)

    public func quit(_ row: MonitorRow) {
        let t = MonitorTarget(row)
        guard t.isActionable else { return }
        if row.bundlePath == nil {
            model.confirm = .quitProcess(t)
        } else if !actions.quit(t) {
            flash(L10n.tr("%@ didn't quit", t.name))
        }
    }

    public func askForceQuit(_ row: MonitorRow) {
        let t = MonitorTarget(row)
        guard t.isActionable else { return }
        model.confirm = .forceQuit(t)
    }

    public func confirmAction() {
        guard let c = model.confirm else { return }
        model.confirm = nil
        switch c {
        case .forceQuit(let t):
            if !actions.forceQuit(t) { flash(L10n.tr("Couldn't force quit %@", t.name)) }
        case .quitProcess(let t):
            if !actions.quit(t) { flash(L10n.tr("%@ didn't quit", t.name)) }
        }
    }

    public func cancelConfirm() { model.confirm = nil }

    public func reveal(_ row: MonitorRow) {
        guard let p = row.bundlePath ?? row.path else { return }
        actions.reveal(p)
    }

    public func openActivityMonitor() { actions.openActivityMonitor() }

    private func flash(_ text: String) {
        model.note = text
        noteClear?.cancel()
        noteClear = Task { [weak self] in
            try? await Delay.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.model.note = nil
        }
    }

    // MARK: Command bar scans

    /// Apps with their CPU since the previous bar scan (the first one has memory only). Rescanned at
    /// most every half second, so typing doesn't cost a scan per key.
    func barApps(maxAge: UInt64 = 500_000_000, now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> [MonitorRow] {
        if let r = barRows, now &- r.at < maxAge { return r.apps }
        var s = barScanner ?? ProcessScanner(engine: engine)
        let (_, apps) = s.scan(source, now: now, busyCores: nil, gpu: false)
        barScanner = s
        barRows = (apps, now)
        return apps
    }

    /// The bar opened: take the first scan off the main thread (it resolves every process's name
    /// and app, ~20 ms cold); typed queries then reuse it and only rescan (~1 ms).
    func warmBar() {
        guard barScanner == nil, barWarm == nil else { return }
        let source = self.source, engine = self.engine
        barWarm = Task { [weak self] in
            let (scanner, apps, at) = await Task.detached(priority: .userInitiated) { () -> (ProcessScanner, [MonitorRow], UInt64) in
                var s = ProcessScanner(engine: engine)
                let now = DispatchTime.now().uptimeNanoseconds
                let apps = s.scan(source, now: now, busyCores: nil, gpu: false).apps
                return (s, apps, now)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.barWarm = nil
            guard self.barScanner == nil else { return }       // a typed query got there first
            self.barScanner = scanner
            self.barRows = (apps, at)
        }
    }

    private func endBar() {
        barWarm?.cancel(); barWarm = nil
        barScanner = nil; barRows = nil
    }

    var barHasRates: Bool { barScanner?.hasBaseline == true && barRows != nil && (barRows?.apps.contains { $0.cpu > 0 } ?? false) }

    // MARK: Surface

    public var tab: PanelTab? {
        PanelTab(module: .monitor, symbol: SurfaceContext.symbol(.monitor), title: "Monitor") { [unowned self] in
            AnyView(MonitorTabView(module: self, model: model, settings: settings, sampler: sampler))
        }
    }

    // MARK: Renderer

    public enum RenderState: String, CaseIterable, Sendable {
        case cpu, memory, gpu, disk, network, energy, processes, confirm
    }

    /// Synthetic figures for `glancy-render` (no process is read or touched).
    public func prepareForRender(_ state: RenderState) {
        L10n.addItalian(monitorItalian)
        model.confirm = nil
        model.note = nil
        model.grouping = state == .processes ? .processes : .apps
        model.selected = MonitorIndicator(rawValue: state.rawValue) ?? .cpu
        if state == .processes { model.selected = .cpu }
        if state == .confirm { model.selected = .memory }
        let (snap, history) = MonitorSample.make()
        sampler.show(snap, history: history)
        if state == .confirm, let chrome = snap.apps.first(where: { $0.name == "Google Chrome" }) {
            model.confirm = .forceQuit(MonitorTarget(chrome))
        }
    }
}

/// App icons for the rows, cached while the tab is open and dropped when it closes.
@MainActor
enum MonitorIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(_ bundlePath: String?) -> NSImage? {
        guard let bundlePath else { return nil }
        if let i = cache[bundlePath] { return i }
        guard cache.count < 48, FileManager.default.fileExists(atPath: bundlePath) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: bundlePath)
        image.size = NSSize(width: 32, height: 32)
        cache[bundlePath] = image
        return image
    }

    static func clear() { cache.removeAll() }
}
