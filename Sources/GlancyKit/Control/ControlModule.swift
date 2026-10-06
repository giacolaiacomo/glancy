import AppKit
import SwiftUI

/// Control center (wave 4): toggles (keep awake, dark mode, Wi-Fi, desktop icons, hidden files),
/// one-shot tools (lock, display off, screen saver, screenshot, colour picker, camera mirror, empty
/// Trash, eject all) and system stats.
///
/// Event-driven: toggle states are read when the tab opens and after each action; keep-awake ends
/// with one scheduled wake-up at its deadline (plus a check after system wake). The one periodic
/// task, the 1 Hz stats sampler, runs only while the Control tab is on screen.
@MainActor
public final class ControlModule: GlancyModule {
    public let id: ModuleID = .control
    public let model = ControlModel()
    public let settings: ControlSettings
    public let stats: StatsSampler

    let actions: SystemActions
    private let scheduler: WakeScheduling
    var hub: ActivityHub?
    private var started = false
    private var visibility: SurfaceVisibility = .collapsed
    private var expiry: WakeToken?
    private var noteClear: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    /// Delay between closing the panel and a tool that needs the screen clear (lock, loupe…).
    var closeDelay: Duration = .milliseconds(350)

    public convenience init() {
        self.init(actions: LiveSystemActions(), settings: ControlSettings(), scheduler: TaskWakeScheduler(), stats: StatsSampler())
    }

    public init(actions: SystemActions, settings: ControlSettings, scheduler: WakeScheduling, stats: StatsSampler) {
        self.actions = actions
        self.settings = settings
        self.scheduler = scheduler
        self.stats = stats
        // Settings → Control shows these strings even while the module is off.
        L10n.addItalian(controlItalian)
    }

    // MARK: Lifecycle

    public func start(hub: ActivityHub) {
        guard !started else { return }
        started = true
        self.hub = hub
        L10n.addItalian(controlItalian)
        model.recent = settings.loadRecent()
        // After sleep the expiry may have passed while the wake-up couldn't fire.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAwakeExpiry() }
        }
    }

    public func stop() {
        started = false
        stats.stop()
        if model.awake.isOn { _ = actions.holdAwake(false) }
        model.awake = AwakeState()
        expiry?.cancel(); expiry = nil
        noteClear?.cancel(); noteClear = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        model.mirror = .off
        hub?.clearAll(from: .control)
        hub = nil
    }

    public func visibilityChanged(_ v: SurfaceVisibility) {
        let was = visibility
        visibility = v
        guard started else { return }
        let onTab = v == .expanded(.control)
        if onTab {
            if was != v { refreshStates() }
            if settings.showStats { stats.start() } else { stats.stop() }
        } else {
            stats.stop()
            model.mirror = .off
            if was == .expanded(.control) {
                model.prompt = nil
                model.picked = nil
            }
        }
    }

    var tabVisible: Bool { visibility == .expanded(.control) }

    /// Re-reads every toggle (cheap: a preference, a CoreWLAN property, the mounted volumes).
    func refreshStates() {
        model.darkMode = actions.darkMode()
        model.wifi = actions.wifiPower()
        model.desktopIconsHidden = actions.finderFlag(.desktopIcons)
        model.hiddenFilesShown = actions.finderFlag(.hiddenFiles)
        Task { [weak self] in
            guard let self else { return }
            model.ejectable = await actions.ejectableVolumes()
        }
    }

    // MARK: Keep awake

    public func startAwake(_ duration: AwakeDuration) {
        startAwake(seconds: duration.seconds, duration: duration)
    }

    /// On for `seconds` (nil = until turned off). Replaces a running keep-awake.
    public func startAwake(seconds: TimeInterval?, duration: AwakeDuration? = nil, now: Date = .now) {
        guard actions.holdAwake(true) else {
            flash(ControlText.t("Couldn't keep the Mac awake"), symbol: "exclamationmark.triangle")
            return
        }
        model.awake = .on(now: now, seconds: seconds, duration: duration)
        armExpiry()
        publishAwake()
    }

    public func stopAwake() {
        guard model.awake.isOn else { return }
        _ = actions.holdAwake(false)
        model.awake = AwakeState()
        expiry?.cancel(); expiry = nil
        hub?.clear("control.awake")
    }

    public func toggleAwake() {
        model.awake.isOn ? stopAwake() : startAwake(settings.awakeDefault)
    }

    /// The duration chip: picks the next length; restarts the countdown when on.
    public func cycleAwakeDuration() {
        let next = (model.awake.isOn ? (model.awake.duration ?? settings.awakeDefault) : settings.awakeDefault).next
        settings.awakeDefault = next
        if model.awake.isOn { startAwake(next) }
    }

    private func armExpiry() {
        expiry?.cancel(); expiry = nil
        guard let until = model.awake.until else { return }
        expiry = scheduler.schedule(at: until) { [weak self] in self?.checkAwakeExpiry() }
    }

    func checkAwakeExpiry(now: Date = .now) {
        guard model.awake.isOn else { return }
        if model.awake.expired(now: now) {
            stopAwake()
            if !tabVisible {
                hub?.show(PeekEvent(module: .control, duration: 2.5, content: AnyView(
                    ControlPeek(symbol: "cup.and.saucer", title: ControlText.t("Keep awake ended"), detail: nil))))
            }
        } else {
            armExpiry()
        }
    }

    private func publishAwake() {
        guard let hub else { return }
        guard model.awake.isOn, settings.awakeInWings else { hub.clear("control.awake"); return }
        let until = model.awake.until
        hub.post(LiveActivity(id: "control.awake", module: .control, priority: 15, expires: until,
                              left: AnyView(AwakeWingLeft()), right: AnyView(AwakeWingRight(until: until))))
    }

    func settingsChanged() { publishAwake() }

    // MARK: Toggles

    public func toggle(_ tile: ControlTile) {
        switch tile {
        case .keepAwake: toggleAwake()
        case .darkMode: setDarkMode(!model.darkMode)
        case .wifi: setWiFi(!(model.wifi ?? false))
        case .desktopIcons: model.prompt = .confirmFinder(.desktopIcons, on: !model.desktopIconsHidden)
        case .hiddenFiles: model.prompt = .confirmFinder(.hiddenFiles, on: !model.hiddenFilesShown)
        default: run(tile)
        }
    }

    public func setDarkMode(_ on: Bool) {
        guard !model.busy.contains(.darkMode) else { return }
        model.busy.insert(.darkMode)
        Task { [weak self] in
            guard let self else { return }
            let outcome = await actions.setDarkMode(on)
            model.busy.remove(.darkMode)
            switch outcome {
            // The preference can lag the script by a moment: trust the answer.
            case .ok: model.darkMode = on
            case .needsPermission:
                model.prompt = .needsAutomation("System Events")
                model.darkMode = actions.darkMode()
            case .failed:
                flash(ControlText.t("Couldn't change the appearance"), symbol: "exclamationmark.triangle")
                model.darkMode = actions.darkMode()
            }
        }
    }

    public func setWiFi(_ on: Bool) {
        guard model.wifi != nil else {
            flash(ControlText.t("No Wi-Fi on this Mac"), symbol: "wifi.slash"); return
        }
        if !actions.setWiFiPower(on) { flash(ControlText.t("Couldn't change Wi-Fi"), symbol: "wifi.exclamationmark") }
        model.wifi = actions.wifiPower()
    }

    /// The answer to the bar's question.
    public func confirm() {
        guard let p = model.prompt else { return }
        model.prompt = nil
        switch p {
        case .confirmFinder(let flag, let on):
            let tile: ControlTile = flag == .desktopIcons ? .desktopIcons : .hiddenFiles
            model.busy.insert(tile)
            Task { [weak self] in
                guard let self else { return }
                let ok = await actions.setFinderFlag(flag, on)
                model.busy.remove(tile)
                if !ok { flash(ControlText.t("Couldn't restart Finder"), symbol: "exclamationmark.triangle") }
                model.desktopIconsHidden = actions.finderFlag(.desktopIcons)
                model.hiddenFilesShown = actions.finderFlag(.hiddenFiles)
            }
        case .confirmTrash:
            model.busy.insert(.emptyTrash)
            Task { [weak self] in
                guard let self else { return }
                let outcome = await actions.emptyTrash()
                model.busy.remove(.emptyTrash)
                switch outcome {
                case .ok: flash(ControlText.t("Trash emptied"), symbol: "trash")
                case .needsPermission: model.prompt = .needsAutomation("Finder")
                case .failed: flash(ControlText.t("Couldn't empty the Trash"), symbol: "exclamationmark.triangle")
                }
            }
        case .needsAutomation:
            actions.openAutomationSettings()
        case .needsCamera:
            actions.openCameraSettings()
        case .note:
            break
        }
    }

    public func dismissPrompt() {
        model.prompt = nil
        noteClear?.cancel(); noteClear = nil
    }

    // MARK: Tools

    public func run(_ tile: ControlTile) {
        switch tile {
        case .lock: afterClosing { $0.actions.lockScreen() }
        case .displaySleep: afterClosing { $0.actions.sleepDisplay() }
        case .screenSaver: afterClosing { $0.actions.startScreenSaver() }
        case .screenshot:
            let target: ScreenshotTarget = settings.screenshotTarget == .desktop ? .desktop : .clipboard
            afterClosing { $0.actions.screenshot(target) }
        case .colorPicker: pickColor()
        case .mirror: toggleMirror()
        case .emptyTrash: askEmptyTrash()
        case .eject: ejectAll()
        default: toggle(tile)
        }
    }

    public func screenshot(_ target: ScreenshotTarget) {
        afterClosing { $0.actions.screenshot(target) }
    }

    /// Closes the panel, then runs `work` once it's gone (a tool that needs the screen clear).
    private func afterClosing(_ work: @escaping @MainActor (ControlModule) -> Void) {
        let wasOpen: Bool = if case .expanded = visibility { true } else { false }
        hub?.requestClose()
        guard wasOpen else { work(self); return }
        let delay = closeDelay
        Task { [weak self] in
            try? await Delay.sleep(for: delay)
            guard let self else { return }
            work(self)
        }
    }

    public func pickColor() {
        afterClosing { me in
            me.actions.sampleColor { [weak me] rgb in
                guard let me, let rgb else { return }
                me.picked(rgb)
            }
        }
    }

    /// A colour chosen (loupe, recent swatch, command bar): copied as HEX, remembered, shown.
    public func picked(_ rgb: RGB, announce: Bool = true) {
        actions.copy(rgb.hex)
        model.recent.add(rgb)
        settings.saveRecent(model.recent)
        model.picked = rgb
        if announce, !tabVisible {
            hub?.show(PeekEvent(module: .control, duration: 3, content: AnyView(ColorPeek(color: rgb))))
        }
    }

    public func dismissColor() { model.picked = nil }

    public func clearRecentColors() {
        model.recent.clear()
        settings.saveRecent(model.recent)
        model.picked = nil
    }

    public func toggleMirror() {
        if model.mirror != .off { model.mirror = .off; return }
        switch actions.cameraAccess() {
        case .granted: model.mirror = .live
        case .denied: model.prompt = .needsCamera
        case .unavailable: flash(ControlText.t("Mirror works in the installed app"), symbol: "video.slash")
        case .notDetermined:
            Task { [weak self] in
                guard let self else { return }
                let ok = await actions.requestCamera()
                if ok, tabVisible { model.mirror = .live } else if !ok { model.prompt = .needsCamera }
            }
        }
    }

    public func askEmptyTrash() {
        guard !model.busy.contains(.emptyTrash) else { return }
        model.busy.insert(.emptyTrash)
        Task { [weak self] in
            guard let self else { return }
            let r = await actions.trashSummary()
            model.busy.remove(.emptyTrash)
            switch r {
            case .success(let s) where s.items == 0: flash(ControlText.t("The Trash is already empty"), symbol: "trash")
            case .success(let s):
                model.prompt = .confirmTrash(s)
                if !tabVisible { hub?.requestOpen(.control) }
            case .failure(.needsPermission): model.prompt = .needsAutomation("Finder")
            case .failure: flash(ControlText.t("Couldn't read the Trash"), symbol: "exclamationmark.triangle")
            }
        }
    }

    public func ejectAll() {
        guard !model.busy.contains(.eject) else { return }
        model.busy.insert(.eject)
        Task { [weak self] in
            guard let self else { return }
            model.ejectable = await actions.ejectableVolumes()
            guard !model.ejectable.isEmpty else {
                model.busy.remove(.eject)
                flash(ControlText.t("Nothing to eject"), symbol: "eject")
                return
            }
            let (ok, bad) = await actions.ejectAll()
            model.busy.remove(.eject)
            model.ejectable = await actions.ejectableVolumes()
            if bad > 0 {
                flash(L10n.tr("%d ejected, %d in use", ok, bad), symbol: "exclamationmark.triangle")
            } else {
                flash(ok == 1 ? ControlText.t("1 disk ejected") : L10n.tr("%d disks ejected", ok), symbol: "eject")
            }
        }
    }

    /// A short note: in the tab's bar while it's open, otherwise as a peek.
    func flash(_ text: String, symbol: String) {
        if tabVisible {
            model.prompt = .note(text, symbol: symbol)
            noteClear?.cancel()
            noteClear = Task { [weak self] in
                try? await Delay.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self else { return }
                if case .note = model.prompt { model.prompt = nil }
            }
        } else {
            hub?.show(PeekEvent(module: .control, duration: 2.5, content: AnyView(ControlPeek(symbol: symbol, title: text, detail: nil))))
        }
    }

    // MARK: Surface

    public var tab: PanelTab? {
        PanelTab(module: .control, symbol: "switch.2", title: "Control") { [unowned self] in
            AnyView(ControlTabView(module: self, model: model, settings: settings, stats: stats))
        }
    }

    public func homeCard() -> AnyView? {
        guard model.awake.isOn else { return nil }
        return AnyView(ControlHomeCard(module: self, model: model))
    }

    // MARK: Renderer

    public enum RenderState: String, CaseIterable, Sendable {
        case awake, colorPicked, mirror, confirmTrash, needsAutomation
    }

    /// Synthetic content for `glancy-render` (never touches the system: no assertion, no camera).
    public func prepareForRender(_ state: RenderState) {
        L10n.addItalian(controlItalian)
        model.prompt = nil
        model.mirror = .off
        model.picked = nil
        model.awake = .on(now: Self.renderNow, seconds: 3600, duration: .h1)
        model.darkMode = true
        model.wifi = true
        model.recent = RecentColors([RGB(r: 255, g: 136, b: 0), RGB(r: 52, g: 120, b: 246), RGB(r: 48, g: 209, b: 88),
                                     RGB(r: 191, g: 90, b: 242), RGB(r: 255, g: 69, b: 58), RGB(r: 242, g: 242, b: 247)])
        var s = StatsSnapshot()
        s.cpu = 0.23
        s.memory = MemoryReading(used: 11_400_000_000, total: 17_179_869_184, pressure: 1)
        s.disk = DiskReading(free: 212_000_000_000, total: 494_000_000_000)
        s.down = 1_240_000; s.up = 86_000
        s.battery = BatteryReading(cycles: 214, health: 0.93)
        s.uptime = TimeInterval(3 * 86_400 + 4 * 3_600 + 120)
        stats.show(s)
        switch state {
        case .awake: break
        case .colorPicked: model.picked = RGB(r: 255, g: 136, b: 0)
        case .mirror: model.mirror = .placeholder
        case .confirmTrash: model.prompt = .confirmTrash(TrashSummary(items: 34, bytes: 1_240_000_000))
        case .needsAutomation: model.prompt = .needsAutomation("System Events")
        }
        if let hub {
            hub.post(LiveActivity(id: "control.awake", module: .control, priority: 15, updated: .now, expires: nil,
                                  left: AnyView(AwakeWingLeft()), right: AnyView(AwakeWingRight(until: model.awake.until))))
        }
    }

    /// The peek a picked colour shows (renderer).
    public func showSampleColorPeek() {
        hub?.show(PeekEvent(module: .control, duration: 3, content: AnyView(ColorPeek(color: RGB(r: 255, g: 136, b: 0)))))
    }

    static var renderNow: Date {
        Calendar.current.date(bySettingHour: 9, minute: 41, second: 0, of: .now) ?? .now
    }
}
