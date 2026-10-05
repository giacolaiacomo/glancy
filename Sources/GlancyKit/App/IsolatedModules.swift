import AppKit
import Foundation

/// Every module the app ships, wired to throwaway state under `root`: private defaults suites,
/// a private pasteboard, temp files, no EventKit, no players, no hardware taps, no Bluetooth.
/// Nothing the user owns is read or written and macOS is never asked for a permission.
/// Used by `--self-test` and, filled with made-up data, by the renderer's `--demo` mode.
@MainActor
enum IsolatedModules {
    struct Set {
        let modules: [any GlancyModule]
        let agentsLog: URL
        let calendar: FixedCalendar
        let media: MediaModule
        let power: PowerModule
        let shelf: ShelfModule
        let timer: TimerModule
        let windows: WindowsModule
        /// The private defaults suites, for `removeDefaults()`.
        let suites: [String]

        func removeDefaults() {
            for s in suites { UserDefaults(suiteName: s)?.removePersistentDomain(forName: s) }
        }
    }

    static func make(root: URL) -> Set {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        func dir(_ name: String) -> URL {
            let d = root.appendingPathComponent(name, isDirectory: true)
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
            return d
        }
        var suites: [String] = []
        func defaults(_ name: String) -> UserDefaults {
            let suite = "ai.glancy.isolated.\(name).\(UUID().uuidString)"
            suites.append(suite)
            let d = UserDefaults(suiteName: suite)!
            d.removePersistentDomain(forName: suite)
            return d
        }
        let agentsLog = dir("agents").appendingPathComponent("events.jsonl")
        let agents = AgentsModule(logURL: agentsLog)
        let calendarSource = FixedCalendar()
        let calendar = CalendarModule(source: calendarSource, settings: CalendarSettings(defaults: defaults("calendar")))
        let mediaFixture = dir("media").appendingPathComponent("now-playing.json")
        if !fm.fileExists(atPath: mediaFixture.path) { try? Data("null\n".utf8).write(to: mediaFixture) }
        let media = MediaModule(stream: AdapterStream(pidFile: dir("media").appendingPathComponent("adapter.pid")),
                                locate: { nil })
        media.fixturePath = mediaFixture.path
        let timer = TimerModule(store: TimerStore(url: dir("timer").appendingPathComponent("timer.json")), alerts: SilentTimerAlerts())
        let shelf = ShelfModule(store: ShelfStore(dir: dir("shelf")))
        let clipboard = ClipboardModule(disk: ClipboardDisk(directory: dir("clipboard")),
                                        settings: ClipboardSettings(defaults: defaults("clipboard")),
                                        pasteboard: NSPasteboard(name: .init("ai.glancy.isolated.\(UUID().uuidString)")),
                                        sample: true)
        let windows = WindowsModule(engine: TilingEngine(configURL: nil), hotkeysURL: nil)
        windows.prepareForRender(.map)   // a synthetic two-display Mac: no real window is listed
        agents.tiling = windows
        let hud = HUDModule(settings: HUDSettings(defaults: defaults("hud")), usesHardware: false)
        let power = PowerModule(settings: PowerSettings(defaults: defaults("power")))
        power.fixed = .init(battery: PowerState(hasBattery: true, percent: 76, onAC: false, isCharging: false), devices: [])
        let notifications = NotificationsModule(databaseURL: dir("notifications").appendingPathComponent("db"),
                                                settings: NotificationsSettings(defaults: defaults("notifications")),
                                                sample: true)
        // Wave 4: sample notes (no hot keys, no microphone), the bar in sample mode (no hot key, no
        // cache, rates only on demand), Control and Monitor live but read-only until a user acts.
        let notes = NotesModule(store: NotesStore(directory: dir("notes")), settings: NotesSettings(defaults: defaults("notes")),
                                sample: true, voiceSystem: .sample)
        notes.micControl = hud
        power.sound = hud
        let control = ControlModule(actions: LiveSystemActions(), settings: ControlSettings(defaults: defaults("control")),
                                    scheduler: TaskWakeScheduler(), stats: StatsSampler())
        let monitor = MonitorModule(source: LiveMonitorSource(), actions: LiveMonitorActions(),
                                    settings: MonitorSettings(defaults: defaults("monitor")))
        var modules: [any GlancyModule] = [agents, calendar, media, timer, shelf, clipboard, windows, hud, power, notifications,
                                           notes, control, monitor]
        let command = CommandModule(settings: CommandSettings(defaults: defaults("command")), history: PaletteHistory(url: nil),
                                    apps: AppIndex(), rates: CurrencyRates(cacheURL: nil), sample: true)
        command.sources = CommandModule.weakly(modules)
        modules.append(command)
        return Set(modules: modules,
                   agentsLog: agentsLog, calendar: calendarSource, media: media, power: power, shelf: shelf,
                   timer: timer, windows: windows, suites: suites)
    }
}

/// A calendar that is always authorised and holds whatever events it is given.
@MainActor
final class FixedCalendar: CalendarEventSource {
    var authorization: CalendarAccess = .granted
    var calendarList: [CalendarInfo] = []
    var eventList: [CalendarEvent] = []
    func requestAccess() async -> Bool { true }
    func calendars() -> [CalendarInfo] { calendarList }
    func events(from start: Date, to end: Date, calendarIDs: Swift.Set<String>?) -> [CalendarEvent] {
        eventList.filter { $0.end > start && $0.start < end && (calendarIDs?.contains($0.calendarID) ?? true) }
    }
}

final class SilentTimerAlerts: TimerAlerting {
    func schedule(at date: Date, title: String, body: String) {}
    func cancel() {}
}
