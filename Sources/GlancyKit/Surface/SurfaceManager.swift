import AppKit
import Observation

/// Owns one surface per display (keyed by display UUID), the system observers, the click-outside
/// monitor and the Esc hot key, and fans visibility out to the modules.
@MainActor
public final class SurfaceManager {
    private let context: SurfaceContext
    private var surfaces: [String: SurfaceController] = [:]
    private var geometries: [String: NotchGeometry] = [:]
    private let events: SystemEvents
    private let menuBar: MenuBarWatcher
    private var anyActivity = false
    private let escape: EscapeHotKey
    private var clickMonitor: Any?
    private var fullscreen: Set<String> = []
    private var lastVisibility: SurfaceVisibility?
    private var started = false
    private var settleTask: Task<Void, Never>?
    /// The one scheduled memory relief after a collapse (cancelled if the panel reopens first).
    private var reliefTask: Task<Void, Never>?
    /// How long after a collapse the memory is handed back: the close spring and the removal
    /// transitions have finished, so the panel's views are gone.
    var reliefDelay: Duration = .seconds(3)

    /// Where screens and fullscreen spaces come from; tests feed synthetic ones.
    private let screens: () -> [ScreenInfo]
    private let fullscreenSpaces: () -> Set<String>
    /// false in tests: panels are never put on screen and no global monitor / hot key is installed.
    private let presents: Bool
    private let systemInput: Bool
    /// The size in use (Settings → General → Size, clamped to the displays). The app's views read
    /// `UIScale.shared`; tests pass their own so they never resize what other tests measure.
    let uiScale: UIScale

    /// How long after a wake / unlock the displays are read once more: they often settle late
    /// (clamshell, external display waking after the built-in one) without a second notification.
    static let settleDelay: Duration = .milliseconds(1500)

    public convenience init(context: SurfaceContext) {
        self.init(context: context, screens: { NSScreen.screens.compactMap(\.info) },
                  fullscreenSpaces: FullscreenSpaces.current, events: SystemEvents(),
                  menuBar: MenuBarWatcher(), presents: true)
    }

    /// `menuBar` nil: an inert watcher (no reads, no observers) — wings keep their symmetric width.
    /// `systemInput` false: panels are shown but no global monitor or Esc hot key is installed
    /// (the lab, rendering tests); default: whenever panels are shown, never in the lab.
    init(context: SurfaceContext, screens: @escaping () -> [ScreenInfo], fullscreenSpaces: @escaping () -> Set<String>,
         events: SystemEvents, menuBar: MenuBarWatcher? = nil, presents: Bool, systemInput: Bool? = nil,
         uiScale: UIScale = .shared) {
        self.context = context
        self.uiScale = uiScale
        self.menuBar = menuBar ?? MenuBarWatcher(reader: nil, observes: false)
        self.screens = screens
        self.fullscreenSpaces = fullscreenSpaces
        self.events = events
        self.presents = presents
        let input = systemInput ?? (presents && !Lab.isActive)
        self.systemInput = input
        escape = EscapeHotKey(system: input)
    }

    public func start() {
        guard !started else { return }
        started = true
        events.onPauseChanged = { [weak self] paused in self?.pauseChanged(paused) }
        events.onScreensChanged = { [weak self] in self?.relayout() }
        events.onSpaceChanged = { [weak self] in self?.spaceChanged() }
        events.onMissionControl = { [weak self] on in self?.missionControl(on) }
        events.start()
        escape.onPress = { [weak self] in if SurfaceKeyFocus.escapeInterceptor?() != true { self?.closeAll() } }
        context.hub.onOpenRequest = { [weak self] tab in self?.open(tab: tab) }
        context.hub.onCloseRequest = { [weak self] in self?.closeAll() }
        SurfaceRoute.openSettings = { [weak self] route in self?.openSettings(route) }
        SurfaceKeyFocus.handler = { [weak self] on in
            guard let self else { return }
            if on { self.surfaces.values.first { $0.model.expanded }?.setKeyFocus(true) }
            else { self.surfaces.values.forEach { $0.setKeyFocus(false) } }
        }
        fullscreen = fullscreenSpaces()
        relayout()
        menuBar.onChange = { [weak self] in self?.applyClearance() }
        menuBar.start()
        observeSettings()
    }

    public func stop() {
        events.stop()
        menuBar.stop()
        menuBar.onChange = nil
        anyActivity = false
        escape.tearDown()
        escape.onPress = nil
        settleTask?.cancel(); settleTask = nil
        reliefTask?.cancel(); reliefTask = nil
        context.hub.onOpenRequest = nil
        context.hub.onCloseRequest = nil
        SurfaceRoute.openSettings = nil
        SurfaceKeyFocus.handler = nil
        SurfaceKeyFocus.reset()
        removeClickMonitor()
        surfaces.values.forEach { $0.tearDown() }
        surfaces.removeAll()
        geometries.removeAll()
        lastVisibility = nil
        started = false
    }

    // MARK: Displays

    /// The surfaces we want right now: every notched display, plus non-notched ones as a pill when
    /// the user opted in (the main display always gets one when no display has a notch). Two displays reporting the same UUID (identical monitors without a
    /// serial number) each keep their own surface.
    func wantedGeometries() -> [String: NotchGeometry] {
        let all = screens()
        let requested = context.settings.size
        let effective = Self.effectiveSize(requested, all, externalPill: context.settings.externalPill)
        uiScale.set(requested: requested, effective: effective)
        return Self.wanted(all, externalPill: context.settings.externalPill, menuBar: NSStatusBar.system.thickness,
                           uiScale: effective.factor)
    }

    /// The chosen size, or the largest that fits every display that gets a surface.
    nonisolated static func effectiveSize(_ requested: UISize, _ screens: [ScreenInfo], externalPill: Bool) -> UISize {
        var shown = screens.filter { $0.hasNotch || externalPill }
        if shown.isEmpty, let main = screens.first { shown = [main] }
        return requested.fitting(shown)
    }

    nonisolated static func wanted(_ screens: [ScreenInfo], externalPill: Bool, menuBar: CGFloat,
                                   uiScale: CGFloat = 1) -> [String: NotchGeometry] {
        var out: [String: NotchGeometry] = [:]
        // Menu bar auto-hidden: visibleFrame reaches the top, so fall back to the bar's thickness.
        func pill(_ info: ScreenInfo) -> NotchGeometry {
            let h = info.frame.maxY - info.visibleFrame.maxY
            return NotchGeometry.pill(for: info, menuBarHeight: h > 0 ? h : menuBar, uiScale: uiScale)
        }
        for info in screens {
            var key = info.uuid
            var n = 2
            while out[key] != nil { key = "\(info.uuid)#\(n)"; n += 1 }
            if let g = NotchGeometry.notch(for: info, uiScale: uiScale) {
                out[key] = g
            } else if externalPill {
                out[key] = pill(info)
            }
        }
        // No notch anywhere (a Mac without one, or a MacBook closed on an external display): without
        // a surface Glancy would run invisibly and look broken, so the main display gets the pill.
        if out.isEmpty, let main = screens.first { out[main.uuid] = pill(main) }
        return out
    }

    func relayout() {
        let wanted = wantedGeometries()
        let diff = ScreenDiff.between(geometries, wanted)
        guard !diff.isEmpty else { return }
        var removedExpanded = false
        for id in diff.removed {
            guard let s = surfaces.removeValue(forKey: id) else { continue }
            removedExpanded = removedExpanded || s.model.expanded
            s.tearDown()
        }
        for id in diff.changed { surfaces[id]?.model.updateGeometry(wanted[id]!) }
        for id in diff.added {
            surfaces[id] = SurfaceController(uuid: id, geometry: wanted[id]!, context: context, manager: self, presents: presents)
        }
        geometries = wanted
        applyClearance()
        // A display went away while its panel was open (lid closed, cable pulled): its Esc hot
        // key, click monitor and keyboard focus must not outlive it.
        if removedExpanded { SurfaceKeyFocus.reset() }
        refreshInteraction()
        fullscreen = fullscreenSpaces()
        applyHidden()
        updateVisibility()
    }

    private func spaceChanged() {
        fullscreen = fullscreenSpaces()
        applyHidden()
        surfaces.values.forEach { $0.dip() }
    }

    func missionControl(_ on: Bool) {
        surfaces.values.forEach { $0.fade(out: on) }
    }

    private func pauseChanged(_ paused: Bool) {
        if paused {
            settleTask?.cancel(); settleTask = nil
            applyHidden()
            return
        }
        // Wake / unlock: displays may have changed while we slept without telling us (lid opened
        // or closed asleep). Read them now, and once more when they have settled.
        resume()
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Delay.sleep(for: Self.settleDelay)
            guard !Task.isCancelled, let self, self.started, !self.events.paused else { return }
            self.settleTask = nil
            self.resume()
        }
    }

    private func resume() {
        relayout()
        fullscreen = fullscreenSpaces()
        applyHidden()
        surfaces.values.forEach { $0.reassert() }
    }

    /// Paused (sleep, lock, screens off) hides everything; a fullscreen space hides its display.
    private func applyHidden() {
        let mainUUID = screens().first?.uuid
        for (id, s) in surfaces {
            let full = fullscreen.contains(id) || (fullscreen.contains("Main") && id == mainUUID)
            s.model.setHidden(events.paused || full)
        }
        updateVisibility()
    }

    // MARK: Open / close

    func open(_ surface: SurfaceController) {
        for s in surfaces.values where s !== surface && s.model.expanded { s.collapse() }
        let tab = tabToOpen(last: surface.model.lastTab, closedAt: surface.model.closedAt, now: .now,
                            available: context.stripTabs.map(\.module))
        surface.expand(tab: tab)
    }

    /// Opens on a given tab, on the surface under the pointer (else the built-in notch).
    func open(tab: ModuleID?) {
        let mouse = NSEvent.mouseLocation
        let target = surfaces.values.first { $0.model.geometry.screenFrame.contains(mouse) } ?? surfaces.values.first
        guard let target else { return }
        for s in surfaces.values where s !== target && s.model.expanded { s.collapse() }
        target.expand(tab: tab)
    }

    /// Opens the panel (or keeps it open) on Settings, at the index or a section.
    func openSettings(_ route: SettingsRoute?) {
        let target = surfaces.values.first { $0.model.expanded }
        if target == nil { open(tab: nil) }
        guard let surface = target ?? surfaces.values.first(where: { $0.model.expanded }) else { return }
        context.settings.navigation.go(route ?? .index, animated: false)
        if !surface.model.showingSettings { surface.model.toggleSettings() }
    }

    func close(_ surface: SurfaceController) { surface.collapse() }

    func closeAll() { surfaces.values.forEach { $0.collapse() } }

    func surfaceStateChanged(_ surface: SurfaceController) {
        refreshInteraction()
        updateVisibility()
        // An activity is about to show its wings: read the menu bar once more (a status item may
        // have appeared since the last app switch). Event-driven, once per appearance.
        let now = surfaces.values.contains { $0.model.hasActivity }
        if now, !anyActivity { menuBar.refresh() }
        anyActivity = now
    }

    // MARK: Menu bar

    /// Each notched surface gets the free room beside its notch; pills are unaffected.
    private func applyClearance() {
        let snapshot = menuBar.snapshot
        let frames = screens().map(\.frame)
        for (id, s) in surfaces {
            guard let g = geometries[id] else { continue }
            s.model.setClearance(snapshot.flatMap { MenuBarClearance.compute(for: g, screens: frames, snapshot: $0) })
        }
    }

    /// The wings would avoid the app's menus with Accessibility (Settings / Permissions copy:
    /// "Accessibility lets the wings avoid the menus").
    public var menuBarNeedsAccessibility: Bool { menuBar.needsAccessibility }
    var menuBarForTest: MenuBarWatcher { menuBar }

    /// The click-outside monitor and the Esc hot key exist exactly while something is expanded.
    private func refreshInteraction() {
        if surfaces.values.contains(where: { $0.model.expanded }) {
            installClickMonitor()
            escape.register()
        } else {
            removeClickMonitor()
            escape.unregister()
        }
    }

    /// Clicks in other apps close the panel. Exists only while something is expanded.
    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        guard systemInput else { clickMonitor = NSNull(); return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeAll() }
        }
    }

    private func removeClickMonitor() {
        if let clickMonitor, !(clickMonitor is NSNull) { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    // MARK: Visibility fan-out

    /// A surface is about to collapse: modules hear it before its expanded views are removed
    /// (a pulse still repeating at removal kept the removed views animating, ~4.5% CPU).
    func surfaceWillCollapse(_ surface: SurfaceController) {
        updateVisibility(collapsing: surface)
    }

    private func updateVisibility(collapsing: SurfaceController? = nil) {
        let models = surfaces.values.filter { $0 !== collapsing }.map(\.model)
        let v: SurfaceVisibility
        if let open = models.first(where: { $0.expanded }) {
            v = open.visibility
        } else if models.contains(where: { !$0.hidden }) || collapsing.map({ !$0.model.hidden }) == true {
            v = .collapsed
        } else {
            v = .hidden
        }
        guard v != lastVisibility else { return }
        let wasExpanded = if case .expanded = lastVisibility { true } else { false }
        lastVisibility = v
        for m in context.enabledModules { m.visibilityChanged(v) }
        if case .expanded = v {
            reliefTask?.cancel(); reliefTask = nil
            // Opening the panel is the moment to look for an update (at most once a day).
            if !wasExpanded { context.updates?.panelOpened() }
        } else if wasExpanded {
            scheduleRelief()
        }
    }

    /// One task, a few seconds after the panel closed: modules drop their per-open caches and the
    /// freed pages go back to the system. Reopening first cancels it.
    private func scheduleRelief() {
        reliefTask?.cancel()
        let delay = reliefDelay
        reliefTask = Task { [weak self] in
            try? await Delay.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.reliefTask = nil
            MemoryRelief.run()
        }
    }

    /// Re-sends the current visibility (a module was just enabled).
    public func resendVisibility(to module: any GlancyModule) {
        if let lastVisibility { module.visibilityChanged(lastVisibility) }
    }

    var surfacesForTest: [SurfaceController] { Array(surfaces.values) }
    func surface(_ uuid: String) -> SurfaceController? { surfaces[uuid] }
    var contextForTest: SurfaceContext { context }
    var visibility: SurfaceVisibility? { lastVisibility }
    var escapeRegistered: Bool { escape.isRegistered }
    var clickMonitorInstalled: Bool { clickMonitor != nil }
    var systemObserverCount: Int { events.observerCount }
    var isPaused: Bool { events.paused }
    var pendingSettle: Bool { settleTask != nil }
    var pendingRelief: Bool { reliefTask != nil }

    // MARK: Settings

    private func observeSettings() {
        withObservationTracking {
            _ = context.settings.hideFromCapture
            _ = context.settings.externalPill
            _ = context.settings.size
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.started else { return }
                self.surfaces.values.forEach { $0.applyCapture() }
                self.relayout()
                self.observeSettings()
            }
        }
    }
}
