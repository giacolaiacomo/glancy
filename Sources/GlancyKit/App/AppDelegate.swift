import AppKit
import EventKit
import Observation

/// The app shell: accessory app, one instance, modules started lazily, one surface per display.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let demo: Bool
    private var lock: SingleInstanceLock?
    private var context: SurfaceContext?
    private var manager: SurfaceManager?
    private var running: Set<ModuleID> = []

    public init(demo: Bool) { self.demo = demo }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        if Lab.isActive { launchLab(); return }
        LegacyMigration.run()
        guard let lock = SingleInstanceLock.acquire() else {
            // Another Glancy is already running: leave quietly.
            NSApp.terminate(nil)
            return
        }
        self.lock = lock
        NSApp.setActivationPolicy(.accessory)

        let settings = AppSettings()
        let hub = ActivityHub()
        let context = SurfaceContext(hub: hub, settings: settings, launchAtLogin: LaunchAtLogin(),
                                     modules: Modules.make(demo: demo))
        context.setModuleEnabled = { [weak self] id, on in self?.setModule(id, enabled: on) }
        context.quit = { NSApp.terminate(nil) }
        self.context = context

        for m in context.enabledModules { start(m) }

        let manager = SurfaceManager(context: context)
        self.manager = manager
        manager.start()
        startUpdates(defaults: .standard)
        startPermissions()
        // Glancy crashed since the last launch? One look, a few seconds in, off main.
        if !demo { CrashReports.checkAtLaunch(hub: hub) }
        if CommandLine.arguments.contains("--selftest") { manager.runSelfTest() }
        if let i = CommandLine.arguments.firstIndex(of: "--tour") {
            // `--tour [home|tabs|all|<module>] [rounds]`: see SurfaceManager.runTour (diagnostics).
            let rest = CommandLine.arguments.dropFirst(i + 1)
            let scope = rest.first.flatMap { ["home", "tabs", "all"].contains($0) || ModuleID(rawValue: $0) != nil ? $0 : nil }
            let rounds = rest.dropFirst(scope == nil ? 0 : 1).first.flatMap { Int($0) } ?? 1
            manager.runTour(after: 3, scope: scope ?? "all", rounds: rounds)
        }
        if settings.needsOnboarding, !CommandLine.arguments.contains("--selftest") {
            welcomeTask = Task { [weak self] in
                // Let the surfaces settle after launch, then open once.
                try? await Delay.sleep(for: .milliseconds(700))
                self?.showWelcome()
            }
        }
    }

    /// `--lab` (App/Lab.swift): demo data in a scratch root, no lock, no permissions, an off-screen
    /// surface driven by signals. Never touches the installed app or anything of the user's.
    private var labActivity: NSObjectProtocol?
    private var labSuites: (() -> Void)?
    private func launchLab() {
        NSApp.setActivationPolicy(.accessory)
        // The real notch is always on screen, so it is never napped; the off-screen lab would be.
        labActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "memory lab")
        let defaults = UserDefaults(suiteName: Lab.defaultsSuite)!
        defaults.removePersistentDomain(forName: Lab.defaultsSuite)
        let settings = AppSettings(defaults: defaults)
        settings.markOnboarded()
        settings.permissions.probe = Lab.permissions
        for id in AppSettings.defaultDisabled { settings.setEnabled(id, true) }
        let set = DemoData.make(root: Lab.root.appendingPathComponent("data", isDirectory: true))
        labSuites = set.removeDefaults
        let context = SurfaceContext(hub: ActivityHub(), settings: settings, launchAtLogin: LaunchAtLogin(), modules: set.modules)
        context.quit = { NSApp.terminate(nil) }
        self.context = context
        for m in context.enabledModules { start(m) }
        let screen = Lab.screen()
        let manager = SurfaceManager(context: context, screens: { [screen] }, fullscreenSpaces: { [] },
                                     events: SystemEvents(), menuBar: nil, presents: true)
        self.manager = manager
        manager.start()
        // Inert unless GLANCY_UPDATE_FEED points the lab at a test feed (scripts/update-e2e.sh).
        startUpdates(defaults: defaults)
        Lab.installSignals { [weak manager] in manager?.runTour(after: 0, scope: Lab.scope, rounds: Lab.rounds) }
        print("lab: ready pid=\(getpid()) root=\(Lab.root.path) surface=\(Int(screen.frame.minX)),\(Int(screen.frame.minY))")
        fflush(stdout)
    }

    public func applicationWillTerminate(_ notification: Notification) {
        if Lab.isActive {
            UserDefaults(suiteName: Lab.defaultsSuite)?.removePersistentDomain(forName: Lab.defaultsSuite)
            labSuites?()
        }
        guard let context else { return }
        welcomeTask?.cancel()
        updatesTask?.cancel()
        context.settings.permissions.stop()
        for m in context.modules where running.contains(m.id) { m.stop() }
        manager?.stop()
    }

    // MARK: Updates

    private var updatesTask: Task<Void, Never>?

    /// The updater (built on its first check) and the launch check, once the surface is up.
    private func startUpdates(defaults: UserDefaults) {
        guard let context else { return }
        let updates = AppUpdates.live(defaults: defaults)
        context.updates = updates
        updatesTask = Task {
            try? await Delay.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            updates.appLaunched()
        }
    }

    // MARK: Permissions and first run

    private var welcomeTask: Task<Void, Never>?

    /// Live statuses for the checklist; a change reaches every running module at once, so a grant
    /// made in System Settings takes effect without a relaunch.
    private func startPermissions() {
        guard let context else { return }
        let permissions = context.settings.permissions
        permissions.calendarRequester = { [weak self] in
            guard let self, let calendar = self.runningModule(CalendarModule.self) else {
                if EventKitSource.usable { _ = try? await EKEventStore().requestFullAccessToEvents() }
                return
            }
            await calendar.requestAccess()
        }
        permissions.onChange = { [weak self] in
            guard let self, let context = self.context else { return }
            for m in context.modules where self.running.contains(m.id) {
                (m as? PermissionAware)?.permissionsChanged()
            }
        }
        permissions.start()
    }

    private func runningModule<T>(_ type: T.Type) -> T? {
        context?.modules.first { running.contains($0.id) && $0 is T } as? T
    }

    /// First launch: the notch opens once on the welcome checklist (Settings → Permissions).
    private func showWelcome() {
        guard let context, let manager else { return }
        context.settings.navigation.showWelcome()
        manager.open(tab: nil)
        // The manager's surfaces (same module); the open one switches to the settings page.
        guard let surface = manager.surfacesForTest.first(where: { $0.model.expanded }) else { return }
        if !surface.model.showingSettings { surface.model.toggleSettings() }
        context.settings.markOnboarded()
    }

    private func start(_ m: any GlancyModule) {
        guard let context, !running.contains(m.id) else { return }
        running.insert(m.id)
        let t0 = ProcessInfo.processInfo.systemUptime
        m.start(hub: context.hub)
        Diagnostics.recordStart(m.id, seconds: ProcessInfo.processInfo.systemUptime - t0)
    }

    private func setModule(_ id: ModuleID, enabled: Bool) {
        guard let context, let m = context.modules.first(where: { $0.id == id }) else { return }
        context.settings.setEnabled(id, enabled)
        if enabled {
            start(m)
            manager?.resendVisibility(to: m)
        } else if running.contains(id) {
            m.stop()
            running.remove(id)
            context.hub.clearAll(from: id)
        }
    }
}

/// One Glancy at a time: an exclusive `flock` on a file in Application Support. The kernel drops
/// it when the process dies, so a crash never leaves a stale lock behind.
final class SingleInstanceLock {
    private let fd: Int32

    private init(fd: Int32) { self.fd = fd }

    static func acquire() -> SingleInstanceLock? {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Glancy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("glancy.lock").path
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
        return SingleInstanceLock(fd: fd)
    }

    deinit { flock(fd, LOCK_UN); close(fd) }
}
