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
                try? await Task.sleep(for: .milliseconds(700))
                self?.showWelcome()
            }
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        guard let context else { return }
        welcomeTask?.cancel()
        context.settings.permissions.stop()
        for m in context.modules where running.contains(m.id) { m.stop() }
        manager?.stop()
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
