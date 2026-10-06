import AppKit
import SwiftUI

// The command bar (Raycast-style launcher in the notch). A page of the expanded panel with no icon
// in the strip, opened by its hotkey (default ⌃⌥K). Apps, calculator, units, currency, Glancy and
// system actions, and every enabled module's `commands()` / `results(for:)`.
//
// Idle cost: one Carbon hotkey. The app index, history and exchange rates load on first open; the
// FSEvents stream on the app folders starts after the first index and only marks the list stale.

@MainActor
public final class CommandModule: GlancyModule, SurfaceContextAware {
    public let id: ModuleID = .command
    public let model: CommandModel
    private var hub: ActivityHub?
    private var hotkey: HotkeyManager.Token?
    private var started = false
    /// The hotkey is set but the system refused it (taken by another app).
    public private(set) var hotkeyFailed = false
    /// No observers, no disk, no network (the renderer).
    let sample: Bool

    /// Every module, for `commands()` / `results(for:)`. Set in `Modules.make()`.
    public var sources: () -> [any GlancyModule] {
        get { model.sources }
        set { model.sources = newValue }
    }

    public convenience init() {
        let sample = ProcessInfo.processInfo.processName == "glancy-render"
        if sample {
            let suite = "ai.glancy.command.sample"
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            self.init(settings: CommandSettings(defaults: UserDefaults(suiteName: suite)!), history: PaletteHistory(url: nil),
                      apps: AppIndex(), rates: CurrencyRates(cacheURL: nil), sample: true)
        } else {
            self.init(settings: CommandSettings(), history: PaletteHistory(url: PaletteHistory.defaultURL), apps: AppIndex(),
                      rates: CurrencyRates(cacheURL: CurrencyRates.defaultURL))
        }
    }

    public init(settings: CommandSettings, history: PaletteHistory, apps: AppIndex, rates: CurrencyRates, sample: Bool = false) {
        model = CommandModel(settings: settings, history: history, apps: apps, rates: rates)
        self.sample = sample
        L10n.addItalian(CommandText.italian)
    }

    /// A closure over weak references: the bar never keeps another module alive.
    public static func weakly(_ modules: [any GlancyModule]) -> () -> [any GlancyModule] {
        let boxes = modules.map { WeakModule($0) }
        return { boxes.compactMap(\.module) }
    }

    public func attach(_ context: SurfaceContext) {
        let settings = context.settings
        model.isEnabled = { [weak settings] id in settings?.isEnabled(id) ?? true }
    }

    // MARK: Lifecycle

    public func start(hub: ActivityHub) {
        guard !started else { return }
        started = true
        self.hub = hub
        L10n.addItalian(CommandText.italian)
        model.close = { [weak hub] in hub?.requestClose() }
        model.openTab = { [weak hub] tab in hub?.requestOpen(tab) }
        if !sample { registerHotkey() }
        // A few seconds after the panel closes: the app list and its icons go, rebuilt on the next open.
        MemoryRelief.register(self) { [weak self] in
            guard let self, !self.open else { return }
            self.model.apps.release()
            PaletteIcons.clear()
        }
    }

    public func stop() {
        guard started else { return }
        started = false
        MemoryRelief.unregister(self)
        if let hotkey { HotkeyManager.shared.unregister(hotkey) }
        hotkey = nil
        model.setVisible(false)
        model.apps.stop()
        model.rates.cancel()
        model.close = {}
        model.openTab = { _ in }
        hub = nil
    }

    public func visibilityChanged(_ visibility: SurfaceVisibility) {
        guard started else { return }
        let on = visibility == .expanded(.command)
        open = on
        model.setVisible(on, keyboard: !sample)
    }

    private var open = false

    // MARK: Hotkey

    private func registerHotkey() {
        if let hotkey { HotkeyManager.shared.unregister(hotkey) }
        hotkey = nil
        let combo = model.settings.hotkey
        guard combo.modifiers != 0 else { hotkeyFailed = false; return }
        hotkey = HotkeyManager.shared.register(combo) { [weak self] in self?.hotkeyPressed() }
        hotkeyFailed = hotkey == nil
    }

    /// Opens the bar; pressed again while it is open, closes the panel.
    func hotkeyPressed() {
        if open { hub?.requestClose() } else { hub?.requestOpen(.command) }
    }

    /// Settings → Command bar. A combination without modifiers clears it.
    public func setHotkey(_ combo: Hotkey) {
        guard combo != model.settings.hotkey else { return }
        model.settings.hotkey = combo
        if started, !sample { registerHotkey() }
    }

    // MARK: Surface

    public var tab: PanelTab? {
        PanelTab(module: .command, symbol: "command", title: "Command bar") { [model] in
            AnyView(CommandBarView(model: model))
        }
    }

    // MARK: Renderer

    /// Puts the bar in a fixed state for `glancy-render`: real apps, made-up history, fixed rates.
    /// `history: false` = first run (nothing learnt yet).
    public func prepareForRender(query: String, history: Bool = true) {
        guard sample else { return }
        if !history { model.history.clear() }
        if model.apps.stale { model.apps.indexNow() }
        if model.rates.table == nil {
            model.rates.useFixed(RateTable(date: "2026-10-02", rates: ["USD": 1.1684, "GBP": 0.8712, "JPY": 172.35, "CHF": 0.9361]))
        }
        if history, !model.history.isLoaded || model.history.store.entries.isEmpty {
            model.history.clear()
            let base = Date.now.addingTimeInterval(-3600)
            for (n, id) in ["glancy.settings", "system.lock"].enumerated() {
                model.history.record(id, query: "", now: base.addingTimeInterval(Double(n)))
            }
            for path in ["/Applications/Safari.app", "/System/Applications/Safari.app", "/System/Applications/Notes.app",
                         "/System/Applications/Calendar.app"] where FileManager.default.fileExists(atPath: path) {
                model.history.record("app." + path, query: "", now: .now)
            }
        }
        model.setVisible(false, keyboard: false)
        model.setVisible(true, keyboard: false)
        model.query = query
    }
}

private struct WeakModule {
    weak var module: (any GlancyModule)?
    init(_ m: any GlancyModule) { module = m }
}
