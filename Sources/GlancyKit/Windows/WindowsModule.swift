// Windows — tiling on the notch (SPEC §3 "Windows", RESEARCH §3.5). The tab is a live map of the
// target window's display; everything previews before it commits, everything is undoable, and
// outcomes are shown. Also: drag a window to the notch, a keyboard mode, direct hotkeys.
//
// Idle cost: Carbon hotkeys (no events until pressed) and, once Accessibility is granted, the
// registry's AX observers plus left-mouse down/dragged/up monitors (fire only on mouse buttons).

import AppKit
import SwiftUI

public final class WindowsModule: GlancyModule {
    public let id = ModuleID.windows
    public let engine: TilingEngine
    let model: WindowsModel
    private let overlay = PreviewOverlay()
    private let drag = DragMonitor()
    private let hotkeysURL: URL?
    public private(set) var hotkeys: WindowsHotkeys
    private var hub: ActivityHub?
    private var tokens: [HotkeyManager.Token] = []
    private var trustObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    private var lastVisibility: SurfaceVisibility = .collapsed
    private var tabVisible = false
    private var openedByHotkey = false
    private var running = false
    // Agents link
    private var linkPreviewShown = false
    private var removalWatch: (ids: Set<CGWindowID>, body: @MainActor (Set<CGWindowID>) -> Void)?
    private var removalArmed = false
    private var previewSink: ((ArrangePlan?, Display?) -> Void)?
    /// What the tab draws on the real screen: its preview and the hovered row's window.
    private var tabPreview: (plan: ArrangePlan?, display: Display?) = (nil, nil)
    private var tabHighlight: (window: TrackedWindow, display: Display?)?

    /// - Parameter hotkeysURL: where the bindings persist; nil = defaults, in memory (tests).
    public init(engine: TilingEngine = TilingEngine(), hotkeysURL: URL? = WindowsHotkeys.defaultURL) {
        self.engine = engine
        self.hotkeysURL = hotkeysURL
        hotkeys = hotkeysURL.map { WindowsHotkeys.load(from: $0) } ?? WindowsHotkeys()
        model = WindowsModel(backend: engine)
    }

    // MARK: Lifecycle

    public func start(hub: ActivityHub) {
        guard !running else { return }
        running = true
        self.hub = hub
        WindowsText.register()
        model.onPreview = { [weak self] plan, display in
            guard let self else { return }
            self.tabPreview = (plan, display)
            self.refreshOverlay()
        }
        model.onHighlight = { [weak self] window, display in
            guard let self else { return }
            self.tabHighlight = window.map { ($0, display) }
            self.refreshOverlay()
        }
        model.onRequestClose = { [weak hub] in hub?.requestClose() }
        model.onPeek = { [weak hub] text in
            hub?.show(PeekEvent(module: .windows, duration: 3, content: AnyView(WindowsPeek(text: text))))
        }
        drag.lookup = { [weak self] id in self?.engine.registry.window(id) }
        drag.onOpen = { [weak self] window, frame, zone in self?.dragReachedNotch(window, frame, zone) }
        drag.onTrack = { [weak self] p in self?.dragMoved(p) }
        drag.onDrop = { [weak self] p in self?.dropped(p) }
        registerHotkeys()
        if engine.isTrusted { startEngine() } else { watchTrust() }
    }

    public func stop() {
        guard running else { return }
        running = false
        for t in tokens { HotkeyManager.shared.unregister(t) }
        tokens.removeAll()
        stopWatchingTrust()
        removeKeyMonitor()
        drag.stop()
        removalWatch = nil
        linkPreviewShown = false
        engine.stop()
        model.close()
        overlay.destroy()
        AppIcons.clear()
        model.onPreview = nil
        model.onHighlight = nil
        tabPreview = (nil, nil)
        tabHighlight = nil
        model.onRequestClose = nil
        model.onPeek = nil
        hub = nil
    }

    private func startEngine() {
        guard engine.isTrusted else { return }
        stopWatchingTrust()
        if !engine.registry.isRunning { engine.start() }
        drag.start()
        model.trustChanged()
    }

    /// Without Accessibility: re-check when any app activates (coming back from System Settings),
    /// and on panel open. Never polls; the observer goes away once trust arrives.
    private func watchTrust() {
        guard trustObserver == nil else { return }
        trustObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.running, self.engine.isTrusted else { return }
                    self.startEngine()
                }
            }
    }

    private func stopWatchingTrust() {
        if let trustObserver { NSWorkspace.shared.notificationCenter.removeObserver(trustObserver) }
        trustObserver = nil
    }

    // MARK: Visibility

    public func visibilityChanged(_ visibility: SurfaceVisibility) {
        lastVisibility = visibility
        let showing = visibility == .expanded(.windows)
        if showing, !tabVisible {
            tabVisible = true
            if engine.isTrusted, !engine.registry.isRunning { startEngine() }
            model.open(keyboard: openedByHotkey)
            openedByHotkey = false
            if model.trusted, model.dragWindowID == nil { takeKeyboard() }
        } else if !showing, tabVisible {
            tabVisible = false
            if model.dragWindowID != nil { drag.cancel() }
            model.close()
            removeKeyMonitor()
            SurfaceKeyFocus.request(false)
            AppIcons.clear()
        } else if !showing, model.dragWindowID != nil {
            // The open request did not land on the Windows tab (hidden display, other surface).
            drag.cancel()
            model.cancelDrag()
        }
    }

    // MARK: Keyboard

    private func takeKeyboard() {
        SurfaceKeyFocus.request(true)
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors run on the main thread. The key is decoded first so only a Bool
            // crosses into the isolated closure.
            let key = Self.key(for: event)
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.tabVisible, let key else { return false }
                return self.model.handle(key)
            }
            return consumed ? nil : event
        }
    }

    /// The preview (numbered when it arranges the selection) plus the hovered row's outline.
    private func refreshOverlay() {
        let display = tabPreview.display ?? tabHighlight?.display
        overlay.show(tabPreview.plan, on: display, highlight: tabHighlight?.window, numbers: model.previewNumbers) { [model] id in
            let w = model.backend.window(id)
            return (w?.appName ?? "", w?.bundleID)
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    static func key(for e: NSEvent) -> WindowsModel.Key? {
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        if mods == .command, e.charactersIgnoringModifiers?.lowercased() == "z" { return .undo }
        guard mods.subtracting(.shift).isEmpty else { return nil }
        let shift = mods.contains(.shift)
        switch Int(e.keyCode) {
        case 123: return .arrow(.left, shift: shift)
        case 124: return .arrow(.right, shift: shift)
        case 125: return .arrow(.down, shift: shift)
        case 126: return .arrow(.up, shift: shift)
        case 36, 76: return .enter
        case 53: return .escape
        case 48: return .cycle(forward: !shift)
        case 49 where !shift: return .togglePick
        default: break
        }
        guard !shift, let c = e.charactersIgnoringModifiers?.lowercased() else { return nil }
        if c == "a" { return .arrangeAll }
        if c == "s" { return .swapPicks }
        if let n = Int(c), (1...9).contains(n) { return .digit(n) }
        return nil
    }

    // MARK: Hotkeys

    private func registerHotkeys() {
        for t in tokens { HotkeyManager.shared.unregister(t) }
        tokens.removeAll()
        guard hotkeys.enabled else { model.failedHotkeys = []; return }
        var failed: [String] = []
        for (action, key) in hotkeys.bindings where key.modifiers != 0 {   // no modifiers = cleared
            let token = HotkeyManager.shared.register(key) { [weak self] in
                guard let self else { return }
                if let action { self.direct(action) } else { self.openFromHotkey() }
            }
            if let token { tokens.append(token) } else { failed.append(key.description) }
        }
        for (strategy, key) in hotkeys.arrangeBindings where key.modifiers != 0 {
            let token = HotkeyManager.shared.register(key) { [weak self] in self?.arrange(strategy, appOnly: false) }
            if let token { tokens.append(token) } else { failed.append(key.description) }
            // The ⇧ variant (front app only) is a bonus: when the system refuses it, nothing is lost.
            if let app = WindowsHotkeys.appVariant(key), !hotkeys.allCombos.contains(app),
               let t = HotkeyManager.shared.register(app, action: { [weak self] in self?.arrange(strategy, appOnly: true) }) {
                tokens.append(t)
            }
        }
        model.failedHotkeys = failed
    }

    /// Combinations the system refused (taken elsewhere), as "⌃⌥←" (Settings → Windows).
    public var failedHotkeys: [String] { model.failedHotkeys }

    /// A permission may have changed: start the engine as soon as Accessibility arrives.
    public func permissionsChanged() {
        guard running, engine.isTrusted, !engine.registry.isRunning else { return }
        startEngine()
    }

    /// Changes the bindings (Settings → Windows recorder) and re-registers them.
    public func setHotkeys(_ h: WindowsHotkeys) {
        guard h != hotkeys else { return }
        hotkeys = h
        if let hotkeysURL { try? h.save(to: hotkeysURL) }
        if running { registerHotkeys() }
    }

    private func openFromHotkey() {
        guard let hub else { return }
        if tabVisible { hub.requestClose(); return }
        openedByHotkey = true
        // Open on another tab: the surface ignores an open while expanded, so close first.
        if case .expanded = lastVisibility { hub.requestClose() }
        hub.requestOpen(.windows)
    }

    private func direct(_ action: DirectAction) {
        guard engine.registry.isRunning else { openFromHotkey(); return }   // shows the permission page
        Task { [weak self] in
            guard let self else { return }
            if let line = await self.model.direct(action) { self.model.onPeek?(line) }
        }
    }

    /// An arrange shortcut: the display under the pointer, committed at once, outcome as a peek.
    /// Without Accessibility it moves nothing and the peek says why.
    private func arrange(_ strategy: ArrangeStrategy, appOnly: Bool) {
        Task { [weak self] in
            guard let self else { return }
            let line = await self.model.arrangeShortcut(strategy, appOnly: appOnly)
            self.hub?.show(PeekEvent(module: .windows, duration: 3, content: AnyView(WindowsPeek(text: line))))
        }
    }

    // MARK: Drag to the notch

    private func dragReachedNotch(_ window: CGWindowID, _ frame: CGRect, _ zone: CGRect) {
        guard let hub else { return }
        let all = engine.displays()
        let display = all.first { $0.frame.contains(CGPoint(x: zone.midX, y: zone.midY)) }
        model.beginDrag(window: window, frame: frame, display: display, hotZone: zone)
        if case .expanded = lastVisibility, !tabVisible { hub.requestClose() }
        if tabVisible { model.open(keyboard: false) } else { hub.requestOpen(.windows) }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    private func dragMoved(_ p: CGPoint) {
        let before = model.hoverCell
        if model.dragMoved(to: p) == .cancelled {
            drag.cancel()
            hub?.requestClose()
        } else if model.hoverCell != before, model.hoverCell != nil {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private func dropped(_ p: CGPoint) {
        if model.dragEnded(at: p) == .cancelled { hub?.requestClose() }
    }

    // MARK: Tab

    public var tab: PanelTab? {
        PanelTab(module: .windows, symbol: "rectangle.split.2x2", title: LocalizedStringKey(WindowsText.t("Windows"))) { [model] in
            AnyView(WindowsTab(model: model))
        }
    }

    // MARK: Agents link

    /// Arranges exactly these windows (e.g. every Claude Code terminal) on the target window's
    /// display, with the default strategy. One undoable operation.
    @discardableResult
    public func layOut(windowIDs: [CGWindowID]) async -> [PlacementResult] {
        guard model.backend.isRunning else { return [] }
        return await model.layOut(windowIDs: windowIDs)
    }

    /// Puts a window into the focused cell (the cell last placed into on the target display, else
    /// the focused window's cells, whose window swaps out). Undoable.
    @discardableResult
    public func place(windowID: CGWindowID, inFocusedCell cell: CellRect? = nil) async -> PlacementResult? {
        guard model.backend.isRunning else { return nil }
        return await model.place(windowID: windowID, inFocusedCell: cell)
    }

    /// Accessibility granted and the registry running.
    public var tilingReady: Bool { model.backend.isTrusted && model.backend.isRunning }

    public var canUndoTiling: Bool { model.backend.canUndo }

    /// Previews, on the real screen, `layOut` of these windows with Balanced, the first ID in the
    /// first cell (reading order). Moves nothing. Returns the number of windows previewed.
    /// `titles`: what each box on the screen says (default: the window's title).
    @discardableResult
    public func previewLayOut(windowIDs: [CGWindowID], titles: [CGWindowID: String] = [:]) -> Int {
        guard tilingReady, !tabVisible,
              let plan = model.planLayOut(windowIDs: windowIDs, strategy: .balanced, readingOrder: true) else {
            cancelLayOutPreview()
            return 0
        }
        linkPreviewShown = true
        showLinkPreview(plan, titles: titles)
        return plan.moves.count
    }

    public func cancelLayOutPreview() {
        guard linkPreviewShown else { return }
        linkPreviewShown = false
        showLinkPreview(nil)
    }

    /// Commits what `previewLayOut` showed (re-planned from the current frames). Undoable.
    @discardableResult
    public func commitLayOut(windowIDs: [CGWindowID]) async -> [PlacementResult] {
        cancelLayOutPreview()
        guard tilingReady,
              let plan = model.planLayOut(windowIDs: windowIDs, strategy: .balanced, readingOrder: true) else { return [] }
        let r = await model.backend.commit(plan, label: WindowsText.t("Arrange"))
        model.backendChanged()
        return r
    }

    @discardableResult
    public func undoTiling() async -> Bool {
        guard model.backend.canUndo else { return false }
        _ = await model.direct(.undo)
        return true
    }

    /// One removal watch at a time, armed on the registry's change notification only while
    /// there is something to watch.
    public func watchWindowRemovals(_ ids: Set<CGWindowID>, _ body: @escaping @MainActor (Set<CGWindowID>) -> Void) {
        let known = ids.filter { model.backend.window($0) != nil }
        removalWatch = known.isEmpty ? nil : (known, body)
        armRemovalWatch()
    }

    private func armRemovalWatch() {
        guard removalWatch != nil, !removalArmed, model.backend.isRunning else { return }
        removalArmed = true
        model.backend.onWindowsChange { [weak self] in
            guard let self else { return }
            self.removalArmed = false
            guard let (ids, body) = self.removalWatch else { return }
            let gone = ids.filter { self.model.backend.window($0) == nil }
            if !gone.isEmpty {
                let left = ids.subtracting(gone)
                self.removalWatch = left.isEmpty ? nil : (left, body)
                body(gone)
            }
            self.armRemovalWatch()
        }
    }

    private func showLinkPreview(_ plan: ArrangePlan?, titles: [CGWindowID: String] = [:]) {
        let display = plan.flatMap { p in model.backend.displays().first { $0.id == p.displayID } }
        if let previewSink { previewSink(plan, display); return }
        overlay.show(plan, on: display) { [model] id in
            let w = model.backend.window(id)
            return (titles[id] ?? w?.appName ?? "", w?.bundleID)
        }
    }

    /// Tests: the backend and where previews go (instead of the real-screen overlay).
    func useForTests(backend: WindowsBackend, previewSink: @escaping (ArrangePlan?, Display?) -> Void) {
        model.replaceBackend(backend)
        self.previewSink = previewSink
    }

    // MARK: Renderer

    /// States the renderer draws, on a synthetic screen (no Accessibility needed).
    public enum RenderState: String, CaseIterable, Sendable {
        case map, hover, arrange, keyboard, drag, outcome, diagnostics, ultrawide, permission
        /// The frontmost window is on the other display: nothing is targeted, the map asks for a pick.
        case noTarget
        /// App scope (Safari, two windows) previewing Balanced.
        case appScope
        /// Window scope: arrange off, the target placed by hover.
        case windowScope
        /// Five windows in the list, a row hovered (outlined on the map).
        case list
        /// Two windows ⌘-picked (Mail #1, Notes #2) previewed in 2×1: #1 left, #2 right, others dimmed.
        case selection
    }

    public func prepareForRender(_ state: RenderState) {
        WindowsText.register()
        let sample = SampleWindowsBackend()
        sample.isTrusted = state != .permission
        model.replaceBackend(sample)
        model.showDiagnostics = state == .diagnostics
        if state == .diagnostics {
            model.setProbeLines([
                "[com.apple.mail] AXEnhancedUserInterface=absent settable=false",
                "[com.apple.mail] window id=4211 role=AXWindow subrole=AXStandardWindow frame(AX)=(30,512 640×430)",
                "[com.apple.mail] AXMinSize=absent AXMinimumSize=absent",
                "[com.google.Chrome] AXEnhancedUserInterface=true settable=true",
                "[com.google.Chrome] settable position=true size=true minimized=false fullscreen=false",
                "[com.apple.Terminal] AXMinSize=absent AXMinimumSize=absent",
            ])
        }
        let terminal: CGWindowID = 11
        switch state {
        case .map, .diagnostics, .permission:
            model.prepare(mode: .browse, display: nil, hover: nil, selection: nil, strategy: nil, outcome: nil)
        case .hover:
            model.prepare(mode: .browse, display: nil, hover: CellRect(col: 0, row: 0, w: 2, h: 2), selection: nil, strategy: nil, outcome: nil)
        case .arrange:
            model.prepare(mode: .browse, display: nil, hover: nil, selection: nil, strategy: .balanced, outcome: nil)
        case .keyboard:
            var s = KeyboardSelection(at: GridCoord(col: 1, row: 0))
            s.extend(.right, grid: GridSpec(cols: 3, rows: 2))
            model.prepare(mode: .keyboard, display: nil, hover: nil, selection: s, strategy: nil, outcome: nil)
        case .drag:
            let frame = sample.window(13)!.frame
            model.prepare(mode: .drag(window: 13, frame: frame), display: nil, hover: CellRect(col: 2, row: 0), selection: nil,
                          strategy: nil, outcome: nil)
        case .outcome:
            sample.outcomes = [terminal: .appSized]
            let plan = sample.planArrange(on: SampleWindowsBackend.builtIn, strategy: .balanced, grid: nil, windowIDs: nil)
            let results = plan.moves.map { m in
                PlacementResult(windowID: m.windowID, outcome: m.windowID == terminal ? .appSized : .exact, requested: m.to,
                                original: m.from, landed: m.windowID == terminal ? m.to.insetBy(dx: 3, dy: 2) : m.to,
                                attempts: 1, euiWasOn: false, note: nil, elapsed: 0.05)
            }
            for m in plan.moves { if let i = sample.windows.firstIndex(where: { $0.id == m.windowID }) { sample.windows[i].frame = m.to } }
            model.prepare(mode: .browse, display: nil, hover: nil, selection: nil, strategy: nil, outcome: results)
        case .ultrawide:
            model.prepare(mode: .browse, display: SampleWindowsBackend.ultrawide.id, hover: CellRect(col: 1, row: 0, w: 1, h: 2),
                          selection: nil, strategy: nil, outcome: nil, switched: true)
        case .noTarget:
            sample.targetWindowID = 21
            model.prepare(mode: .browse, display: SampleWindowsBackend.builtIn.id, hover: nil, selection: nil, strategy: nil,
                          outcome: nil, pick: 12)
        case .appScope:
            sample.windows.append(SampleWindowsBackend.window(15, "com.apple.Safari", "Safari", "Apple",
                                                              CGRect(x: 300, y: 420, width: 760, height: 470), z: 2, pid: 1012))
            sample.targetWindowID = 12
            model.prepare(mode: .browse, display: nil, hover: nil, selection: nil, strategy: .balanced, outcome: nil, scope: .app)
        case .list, .selection:
            sample.windows.insert(SampleWindowsBackend.window(15, "com.apple.MobileSMS", "Messages", "Alex",
                                                              CGRect(x: 760, y: 90, width: 520, height: 520), z: 2), at: 2)
            if state == .list {
                model.prepare(mode: .browse, display: nil, hover: nil, selection: nil, strategy: nil, outcome: nil, rowHover: 14)
            } else {
                sample.setGrid(GridSpec(cols: 2, rows: 1), for: SampleWindowsBackend.builtIn)
                model.prepare(mode: .browse, display: nil, hover: nil, selection: nil, strategy: .cells, outcome: nil,
                              picked: [13, 14])
            }
        case .windowScope:
            model.prepare(mode: .browse, display: nil, hover: CellRect(col: 2, row: 0, w: 1, h: 2), selection: nil, strategy: nil,
                          outcome: nil, scope: .window)
        }
    }
}

/// The drop-down after a hotkey or keyboard commit that did not land exactly.
private struct WindowsPeek: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.split.2x2")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(WindowsStyle.accent)
            Text(verbatim: text)
                .font(Theme.font(.m, .medium))
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .fixedSize()
    }
}
