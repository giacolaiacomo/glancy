import AppKit
import GlancyKit
import SwiftUI

// Renders every surface state to PNG at 2×, off-screen, over a real-looking menu-bar strip, using
// the real modules from Modules.swift plus the demo ones. SPEC §5. Usage:
//   glancy-render [out-dir] [--it] [--demo]
// --demo replaces every module's data with made-up content (DemoData): no real sessions, calendar,
// music, clipboard, shelf, devices or windows. Use it for anything published.

@MainActor
enum Render {
    static let scale: CGFloat = 2
    static let standardCrop = CGSize(width: 900, height: 290)
    /// The strip of desktop around the notch in each shot (wider for the larger sizes).
    static var crop = standardCrop
    /// The menu bar clock: fixed, or the real time with --demo so it agrees with the demo calendar.
    nonisolated(unsafe) static var clock = "Mon 5 Oct  09:41"

    static func run() {
        let args = CommandLine.arguments.dropFirst()
        let out = URL(fileURLWithPath: args.first(where: { !$0.hasPrefix("--") }) ?? "render-out")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        let geometry = builtInGeometry()
        let suite = "ai.glancy.render"
        UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.language = args.contains("--it") ? .it : .en
        let launch = LaunchAtLogin()

        // The real modules (plus the demo) started on a live hub; empty hubs for the quiet states.
        // --demo: made-up data only (DemoData), for README and release images.
        let demo = args.contains("--demo")
        let demoRoot = FileManager.default.temporaryDirectory.appendingPathComponent("glancy-demo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: demoRoot) }
        let modules = demo ? DemoData.modules(root: demoRoot) : Modules.make(demo: true)
        if demo {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_GB")
            f.dateFormat = "EEE d MMM  HH:mm"
            clock = f.string(from: .now)
        }
        for m in modules { (m as? DemoModule)?.cyclesPeeks = false }
        func context(_ started: Bool, _ list: [any GlancyModule]? = nil) -> SurfaceContext {
            let hub = ActivityHub()
            if started { for m in modules { m.stop(); m.start(hub: hub) } }
            return SurfaceContext(hub: hub, settings: settings, launchAtLogin: launch, modules: list ?? modules)
        }
        let live = context(true)
        let quiet = context(false)
        let media = modules.compactMap { $0 as? DemoModule }.first { $0.id == .media }
        let suffix = settings.language == .it ? "-it" : ""

        func shot(_ name: String, _ ctx: SurfaceContext, dark: Bool = false, geometry: NotchGeometry = geometry,
                  menus: MenuBarClearance? = nil, crop: CGSize = Render.standardCrop, _ setup: (SurfaceModel) -> Void = { _ in }) {
            Render.crop = crop
            defer { Render.crop = Render.standardCrop }
            let model = SurfaceModel(geometry: geometry)
            model.animates = false
            setup(model)
            let file = out.appendingPathComponent("\(name)\(suffix).png")
            render(model: model, context: ctx, geometry: geometry, dark: dark, menus: menus, to: file)
            let l = model.layout
            print("wrote \(file.lastPathComponent)  state=\(model.state) shape=\(Int(l.size.width))×\(Int(l.size.height)) wings=\(Int(l.wingLeft))/\(Int(l.wingRight))")
        }

        shot("01-idle", quiet)
        shot("01-idle-dark", quiet, dark: true)
        shot("02-activity", live)
        shot("02-activity-dark", live, dark: true)
        // Menus reaching the notch (Chrome on a 14"): no left wing; the right one stops 6 pt short
        // of the first status item (92 pt right of the notch, as measured on this Mac).
        let crowded = MenuBarClearance(left: 8, right: 92, source: .measured)
        shot("02-activity-crowded", live, menus: crowded) { $0.setClearance(crowded) }
        let blocked = MenuBarClearance(left: 8, right: 18, source: .measured)   // both sides full: notch only
        shot("02-activity-blocked", live, menus: blocked) { $0.setClearance(blocked) }
        shot("03-peek", live) { $0.setHovering(true) }
        shot("03-peek-idle", quiet) { $0.setHovering(true) }
        for (n, name) in ["track", "airpods"].enumerated() {
            let ctx = context(true)
            media?.showSamplePeek(n)
            shot("04-peekEvent-\(name)", ctx)
        }
        // Glancy crashed since the last launch (GlancyKit/App/CrashReports.swift).
        do {
            let ctx = context(false)
            CrashReports.show(hub: ctx.hub, summary: URL(fileURLWithPath: "/tmp/2026-10-06-001206.txt"), count: 1)
            shot("04-peekEvent-crash", ctx)
        }
        shot("05-expanded-home", live) { $0.expand(tab: nil) }
        shot("05-expanded-home-empty", context(false, [])) { $0.expand(tab: nil) }
        for (i, tab) in live.stripTabs.enumerated() {
            shot("06-tab-\(i + 1)-\(tab.module.rawValue)", live) { $0.expand(tab: tab.module) }
        }
        // Windows tab states on a synthetic two-display Mac (no Accessibility needed here).
        if let windows = modules.compactMap({ $0 as? WindowsModule }).first {
            for state in WindowsModule.RenderState.allCases {
                windows.prepareForRender(state)
                shot("09-windows-\(state.rawValue)", live) { $0.expand(tab: .windows) }
            }
        }
        // Devices (Power + HUD): headphones peek, battery peeks and wings, microphone wings, the
        // Devices tab. Samples only: no Bluetooth, nothing written to CoreAudio.
        if let power = modules.compactMap({ $0 as? PowerModule }).first, let hud = modules.compactMap({ $0 as? HUDModule }).first {
            func devices() -> SurfaceContext {
                let hub = ActivityHub()
                for m in [hud, power] as [any GlancyModule] { m.stop(); m.start(hub: hub) }
                return SurfaceContext(hub: hub, settings: settings, launchAtLogin: launch, modules: [hud, power])
            }
            var ctx = devices(); power.showSamplePeek(); shot("11-devices-airpods-peek", ctx)
            ctx = devices(); power.showSamplePeek(name: "AirPods Max", battery: BluetoothBattery(main: 64)); shot("11-devices-airpodsmax-peek", ctx)
            ctx = devices(); power.showSamplePeek(name: "Beats Studio Buds", battery: BluetoothBattery(left: 15, right: 18)); shot("11-devices-beats-peek", ctx)
            ctx = devices(); power.showSampleAlert(.low(20)); shot("11-devices-low-peek", ctx)
            ctx = devices(); power.showSampleAlert(.full(limit: nil)); shot("11-devices-full-peek", ctx)
            ctx = devices(); power.showSampleAlert(.full(limit: 80)); shot("11-devices-limit-peek", ctx)
            ctx = devices(); power.showSample(.pluggedIn); shot("11-devices-plug-wing", ctx)
            ctx = devices()
            power.showSample(.unplugged, state: PowerState(hasBattery: true, percent: 64, onAC: false, minutesToEmpty: 245))
            shot("11-devices-unplug-wing", ctx)
            ctx = devices(); hud.showMicSample(.muted); shot("11-devices-mic-muted", ctx)
            ctx = devices(); hud.showMicSample(.mutedInUse); shot("11-devices-mic-muted-inuse", ctx)
            ctx = devices(); hud.showMicSample(.flashOn); shot("11-devices-mic-flash", ctx)
            ctx = devices(); hud.showMicSample(.inUse); shot("11-devices-inuse-dot", ctx)
            ctx = devices(); hud.showMicSample(.cameraInUse); shot("11-devices-camera-dot", ctx)
            // The tab, with the full tab strip.
            let outputs = [AudioDevice(id: 1, uid: "s1", name: "MacBook Pro Speakers", hasInput: false, hasOutput: true, transport: .builtIn),
                           AudioDevice(id: 2, uid: "s2", name: "AirPods Pro", hasInput: true, hasOutput: true, transport: .bluetooth),
                           AudioDevice(id: 3, uid: "s3", name: "Studio Display Speakers", hasInput: false, hasOutput: true, transport: .display),
                           AudioDevice(id: 4, uid: "s4", name: "MacBook Pro Microphone", hasInput: true, hasOutput: false, transport: .builtIn)]
            let pods = BluetoothDeviceInfo(address: "00:00:00:00:00:01", name: "AirPods Pro", symbol: "airpodspro", isAudio: true,
                                           battery: BluetoothBattery(left: 82, right: 90, case: 40))
            hud.audio.setSampleDevices(outputs, output: 2, input: 4)
            hud.audio.setSample(muted: false, micInUse: true, apps: ["Zoom"])
            power.prepareForRender(battery: PowerState(hasBattery: true, percent: 64, onAC: false, lowPowerMode: true, minutesToEmpty: 245),
                                   devices: [pods])
            shot("11-devices-tab", live) { $0.expand(tab: .power) }
            hud.audio.setSampleDevices(outputs, output: 1, input: 4)
            hud.audio.setSample(muted: true)
            power.prepareForRender(battery: PowerState(hasBattery: true, percent: 41, onAC: true, isCharging: true, minutesToFull: 72),
                                   devices: [],
                                   paired: [BluetoothDeviceInfo(address: "00:00:00:00:00:02", name: "AirPods Max", symbol: "airpodsmax", isAudio: true, battery: BluetoothBattery()),
                                            BluetoothDeviceInfo(address: "00:00:00:00:00:03", name: "Beats Studio Pro", symbol: "beats.headphones", isAudio: true, battery: BluetoothBattery())])
            shot("11-devices-tab-paired", live) { $0.expand(tab: .power) }
        }
        // Command bar: empty (recents), a calculation, apps, currency (fixed rates), units.
        if let command = modules.compactMap({ $0 as? CommandModule }).first {
            let it = settings.language == .it
            let states: [(String, String)] = [("empty", ""), ("calc", it ? "12% di 340" : "12% of 340"), ("apps", "saf"),
                                              ("currency", it ? "100 dollari in euro" : "100 usd to eur"),
                                              ("units", it ? "3 ore in min" : "5 km in mi"), ("hex", "0xff + 1")]
            command.prepareForRender(query: "", history: false)
            shot("11-command-first", live) { $0.expand(tab: .command) }
            for (name, query) in states {
                command.prepareForRender(query: query)
                shot("11-command-\(name)", live) { $0.expand(tab: .command) }
            }
        }
        // Notifications (opt-in, off by default): turned on for these shots only, synthetic data.
        if let notes = modules.compactMap({ $0 as? NotificationsModule }).first {
            settings.setEnabled(.notifications, true)
            for state in NotificationsModule.RenderState.allCases {
                notes.prepareForRender(state)
                shot("10-notifications-\(state.rawValue)", live) { $0.expand(tab: .notifications) }
            }
            let ctx = context(true)
            notes.showSamplePeek()
            shot("10-notifications-peek", ctx)
            settings.setEnabled(.notifications, false)
        }
        // Control: synthetic states (no assertion, no camera, nothing toggled), then the keep-awake
        // wing and the colour peek with Control alone on a hub.
        if let control = modules.compactMap({ $0 as? ControlModule }).first {
            let ctx = context(true)
            for state in ControlModule.RenderState.allCases {
                control.prepareForRender(state)
                shot("11-control-\(state.rawValue)", ctx) { $0.expand(tab: .control) }
            }
            let hub = ActivityHub()
            control.stop()
            control.start(hub: hub)
            control.prepareForRender(.awake)
            let solo = SurfaceContext(hub: hub, settings: settings, launchAtLogin: launch, modules: [control])
            shot("11-control-wing", solo)
            shot("11-control-home", solo) { $0.expand(tab: nil) }
            control.showSampleColorPeek()
            shot("11-control-peek-color", solo)
        }
        // Monitor (lot MON): synthetic figures for each gauge, the processes view and the force-quit
        // question (nothing read or touched), then the strip with every tab on (Notifications too).
        if let monitor = modules.compactMap({ $0 as? MonitorModule }).first {
            // This Mac, read-only: two samples a second apart, then the synthetic states.
            monitor.visibilityChanged(.expanded(.monitor))
            RunLoop.main.run(until: Date().addingTimeInterval(2.3))
            shot("12-monitor-live", live) { $0.expand(tab: .monitor) }
            monitor.visibilityChanged(.collapsed)
            for state in MonitorModule.RenderState.allCases {
                monitor.prepareForRender(state)
                shot("12-monitor-\(state.rawValue)", live) { $0.expand(tab: .monitor) }
            }
            settings.setEnabled(.notifications, true)
            monitor.prepareForRender(.cpu)
            shot("12-monitor-strip-all", live) { $0.expand(tab: .monitor) }
            settings.setEnabled(.notifications, false)
        }
        // Shelf: drop targets while dragging, item actions, screenshot and download drop-downs
        // (sample files in a scratch folder; the real shelf is never saved over).
        if let shelf = modules.compactMap({ $0 as? ShelfModule }).first {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("glancy-render-shelf-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: scratch) }
            for state in ShelfModule.RenderState.allCases {
                let ctx = context(true)
                shelf.prepareForRender(state, scratch: scratch)
                if state.isPeek {
                    shot("11-shelf-\(state.rawValue)", ctx)
                } else {
                    shot("11-shelf-\(state.rawValue)", ctx) { $0.expand(tab: .shelf) }
                }
            }
            shelf.endRender()
        }
        // Lyrics (lot NL): the Media tab's lyrics page and the opt-in lyric wing, on a made-up track
        // with made-up words; no player is read and nothing goes to the network.
        if let media = modules.compactMap({ $0 as? MediaModule }).first {
            for state in MediaModule.RenderState.allCases {
                media.prepareForRender(state)
                let hub = ActivityHub()
                media.stop()
                media.start(hub: hub)
                let ctx = SurfaceContext(hub: hub, settings: settings, launchAtLogin: launch, modules: [media])
                switch state {
                case .lyrics:
                    media.visibilityChanged(.expanded(.media))
                    shot("11-media-lyrics", ctx) { $0.expand(tab: .media) }
                case .lyricsWing:
                    media.visibilityChanged(.collapsed)
                    shot("11-media-lyrics-wing", ctx)
                }
            }
            media.prepareForRender(nil)
            media.stop()
            media.start(hub: live.hub)
        }
        // Voice notes (lot VOICE): mixed text/voice list, recording (meter + time), the recording
        // wing collapsed, playback with waveform + transcript, the transcription ask, the cards.
        // Sample notes and fixed states only: no microphone, no permission asked, nothing played.
        if let notesModule = modules.compactMap({ $0 as? NotesModule }).first {
            for state in NotesModule.VoiceRenderState.allCases {
                let hub = ActivityHub()
                notesModule.stop()
                notesModule.start(hub: hub)
                notesModule.prepareForRender(state)
                let ctx = SurfaceContext(hub: hub, settings: settings, launchAtLogin: launch, modules: [notesModule])
                if state == .wing {
                    shot("12-voice-\(state.rawValue)", ctx)
                } else {
                    shot("12-voice-\(state.rawValue)", ctx) { $0.expand(tab: .notes) }
                }
            }
            notesModule.prepareForRender(.list)
            notesModule.stop()
            notesModule.start(hub: live.hub)
        }
        // Focus & meetings (FO): synthetic meetings and Pomodoro on a hub of their own; the Focus
        // controller is frozen (no `shortcuts` is run, Focus is never touched).
        FocusController.shared.prepareForRender(.missing([FocusController.offShortcut]))
        func solo(_ m: any GlancyModule) -> SurfaceContext {
            let hub = ActivityHub()
            m.stop(); m.start(hub: hub)
            return SurfaceContext(hub: hub, settings: settings, launchAtLogin: launch, modules: [m])
        }
        let calendarModule = modules.compactMap { $0 as? CalendarModule }.first
        let timerModule = modules.compactMap { $0 as? TimerModule }.first
        if let cal = calendarModule {
            for state in CalendarModule.RenderState.allCases {
                let ctx = solo(cal)
                cal.prepareForRender(state)
                shot("11-fo-\(state.rawValue)", ctx)
                if state == .ending {
                    // Chrome's menus up to the notch: narrow in the menu bar, wide below it.
                    let crowded = MenuBarClearance(left: 8, right: 92, source: .measured)
                    shot("11-fo-ending-crowded", ctx, menus: crowded) { $0.setClearance(crowded) }
                }
            }
        }
        if let timer = timerModule {
            for state in TimerModule.RenderState.allCases {
                let ctx = solo(timer)
                timer.prepareForRender(state)
                shot("11-fo-\(state.rawValue)-wings", ctx)
                shot("11-fo-\(state.rawValue)-tab", ctx) { $0.expand(tab: .timer) }
            }
        }
        // The setup card shows in Settings → Calendar / Timer with the options on (reset below).
        calendarModule?.settings.focusDuringMeetings = true
        timerModule?.settings.focusDuringWork = true
        defer {
            calendarModule?.settings.focusDuringMeetings = false
            timerModule?.settings.focusDuringWork = false
        }
        // Agents from every source (lot AG): made-up sessions — Claude Code in Terminal and in VS
        // Code, the Codex CLI and the Codex app, OpenCode — the waiting wing, the board, Home, the
        // waiting peek. Nothing of the user's is read; no window is touched.
        do {
            let agents = AgentsModule.renderSample()
            let hub = ActivityHub()
            agents.start(hub: hub)
            let ctx = SurfaceContext(hub: hub, settings: settings, launchAtLogin: launch, modules: [agents])
            shot("13-agents-sources-wing", ctx)
            agents.visibilityChanged(.expanded(.agents))
            shot("13-agents-sources-tab", ctx) { $0.expand(tab: .agents) }
            shot("13-agents-sources-home", ctx) { $0.expand(tab: nil) }
            agents.visibilityChanged(.collapsed)
            agents.prepareForRender(.waitingPeek)
            shot("13-agents-sources-peek", ctx)
            agents.stop()
        }
        // Plan limits (Agents tab): the strip under the sessions, the Limits page, "Where it went",
        // the 90% drop-down and the used-up wing. Made-up readings (no CLI run, nothing read).
        // `--limits-real <dir>`: the same with the owner's real readings (AgentsModule.realLimitsSnapshot:
        // read-only, one /usage at most, cached in <dir>); files named 15-limits-real-*.
        do {
            var real: (claude: UsageReading?, codex: UsageReading?, breakdown: UsageBreakdown?, log: String)?
            if let i = CommandLine.arguments.firstIndex(of: "--limits-real"), i + 1 < CommandLine.arguments.count {
                real = AgentsModule.realLimitsSnapshot(scratch: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
                print(real!.log, terminator: "")
            }
            let prefix = real == nil ? "15-limits" : "15-limits-real"
            for state in AgentsModule.LimitsRenderState.allCases {
                if real != nil, state == .alertPeek || state == .usedUpWing { continue }
                let agents = state == .alertPeek || state == .usedUpWing ? AgentsModule.renderEmpty() : AgentsModule.renderSample()
                if let real { agents.seedLimits(claude: real.claude, codex: real.codex, breakdown: real.breakdown) } else { agents.seedLimitsSample() }
                let hub = ActivityHub()
                agents.start(hub: hub)
                let ctx = SurfaceContext(hub: hub, settings: settings, launchAtLogin: launch, modules: [agents])
                agents.prepareLimitsForRender(state)
                switch state {
                case .strip, .limitsPage, .whereItWent:
                    agents.visibilityChanged(.expanded(.agents))
                    shot("\(prefix)-\(state.rawValue)", ctx) { $0.expand(tab: .agents) }
                case .alertPeek, .usedUpWing:
                    agents.visibilityChanged(.collapsed)
                    shot("\(prefix)-\(state.rawValue)", ctx)
                }
                agents.stop()
            }
        }
        // Settings: the index, every section, and the first-run welcome. Permission statuses are
        // fixed (a mix of every state) so nothing is asked of macOS.
        let fixed: [PermissionKind: PermissionStatus] = [.calendar: .granted, .accessibility: .notDetermined, .bluetooth: .denied,
                                                         .notifications: .notDetermined, .automation: .notDetermined,
                                                         .fullDiskAccess: .denied]
        settings.permissions.probe = .fixed(fixed)
        settings.permissions.apply(fixed)
        let routes: [(String, SettingsRoute)] = [("index", .index), ("general", .general), ("modules", .modules),
                                                 ("permissions", .permissions)]
            + live.modules.map(\.id).filter { $0 != .notifications }.map { ("module-\($0.rawValue)", .module($0)) }
        live.updates = AppUpdates.sample(available: nil)
        for (name, route) in routes {
            settings.navigation.go(route, animated: false)
            shot(name == "index" ? "07-settings" : "07-settings-\(name)", live) { $0.expand(tab: nil); $0.toggleSettings() }
        }
        // A quiet check found an update: the dot on the gear, "Update to" in the index and General.
        live.updates = AppUpdates.sample(available: "0.3.0")
        for (name, route) in [("index", SettingsRoute.index), ("general", .general)] {
            settings.navigation.go(route, animated: false)
            shot("07-settings-\(name)-update", live) { $0.expand(tab: nil); $0.toggleSettings() }
        }
        shot("07-home-update", live) { $0.expand(tab: nil) }
        live.updates = nil
        settings.navigation.showWelcome()
        shot("07-settings-welcome", live) { $0.expand(tab: nil); $0.toggleSettings() }
        settings.navigation.go(.index, animated: false)
        // The opt-in pill on a display without a notch (menu bar 24 pt).
        let external = ScreenInfo(uuid: "external", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                  visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 958), safeTop: 0,
                                  auxLeft: nil, auxRight: nil, isBuiltin: false, scale: 2)
        let pill = NotchGeometry.pill(for: external, menuBarHeight: 24)
        shot("08-pill-idle", quiet, geometry: pill)
        shot("08-pill-activity", context(true), geometry: pill)

        // Size (Settings → General → Size): Home, Agents, Calendar, Monitor, Settings → General,
        // the wings and a drop-down, at each size, on this Mac's notch and on a pill on a 27" display
        // (MacBook closed). The notch keeps the hardware's size; everything else grows.
        let display27 = ScreenInfo(uuid: "external27", frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                                   visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1416), safeTop: 0,
                                   auxLeft: nil, auxRight: nil, isBuiltin: false, scale: 2)
        let wide = CGSize(width: 1080, height: 340)
        let monitorModule = modules.compactMap { $0 as? MonitorModule }.first
        for size in UISize.allCases {
            UIScale.shared.set(requested: size, effective: size)
            settings.size = size
            let f = size.factor
            for (place, g) in [("notch", builtInGeometry(uiScale: f)), ("pill", NotchGeometry.pill(for: display27, menuBarHeight: 24, uiScale: f))] {
                func name(_ page: String) -> String { "14-size-\(size.rawValue)-\(place)-\(page)" }
                shot(name("home"), live, geometry: g, crop: wide) { $0.expand(tab: nil) }
                shot(name("calendar"), live, geometry: g, crop: wide) { $0.expand(tab: .calendar) }
                if let monitorModule {
                    monitorModule.prepareForRender(.cpu)
                    shot(name("monitor"), live, geometry: g, crop: wide) { $0.expand(tab: .monitor) }
                }
                settings.navigation.go(.general, animated: false)
                shot(name("settings-general"), live, geometry: g, crop: wide) { $0.expand(tab: nil); $0.toggleSettings() }
                settings.navigation.go(.index, animated: false)
                // Agents: the wings, the tab, the waiting drop-down.
                let sizeAgents = AgentsModule.renderSample()
                let hub = ActivityHub()
                sizeAgents.start(hub: hub)
                let ctx = SurfaceContext(hub: hub, settings: settings, launchAtLogin: launch, modules: [sizeAgents])
                shot(name("wings"), ctx, geometry: g, crop: wide)
                sizeAgents.visibilityChanged(.expanded(.agents))
                shot(name("agents"), ctx, geometry: g, crop: wide) { $0.expand(tab: .agents) }
                sizeAgents.visibilityChanged(.collapsed)
                sizeAgents.prepareForRender(.waitingPeek)
                shot(name("peek"), ctx, geometry: g, crop: wide)
                sizeAgents.stop()
            }
            // Every other tab at the largest size, on the notch: nothing clipped or overlapping.
            if size == .extraLarge {
                for tab in live.stripTabs {
                    shot("14-size-extraLarge-notch-tab-\(tab.module.rawValue)", live, geometry: builtInGeometry(uiScale: f), crop: wide) {
                        $0.expand(tab: tab.module)
                    }
                }
            }
        }
        // Extra large chosen on a display it does not fit (a 13" at "More Space" off, 1024 pt wide
        // visible, a short one): Large in use, and Settings says so.
        let small = ScreenInfo(uuid: "small", frame: CGRect(x: 0, y: 0, width: 1024, height: 640),
                               visibleFrame: CGRect(x: 0, y: 0, width: 1024, height: 300), safeTop: 0,
                               auxLeft: nil, auxRight: nil, isBuiltin: false, scale: 2)
        let fitted = UISize.extraLarge.fitting([small])
        UIScale.shared.set(requested: .extraLarge, effective: fitted)
        settings.size = .extraLarge
        settings.navigation.go(.general, animated: false)
        shot("14-size-limited-settings-general", live, geometry: NotchGeometry.pill(for: small, menuBarHeight: 24, uiScale: fitted.factor),
             crop: wide) { $0.expand(tab: nil); $0.toggleSettings() }
        settings.navigation.go(.index, animated: false)
        UIScale.shared.set(requested: .normal, effective: .normal)
        settings.size = .normal
        for m in modules { m.stop() }
    }

    /// This Mac's notched display if there is one, otherwise a 14" MacBook Pro.
    static func builtInGeometry(uiScale: CGFloat = 1) -> NotchGeometry {
        for s in NSScreen.screens {
            if let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea, s.safeAreaInsets.top > 0 {
                let dx = -s.frame.minX, dy = -s.frame.minY
                let info = ScreenInfo(uuid: "builtin", frame: s.frame.offsetBy(dx: dx, dy: dy),
                                      visibleFrame: s.visibleFrame.offsetBy(dx: dx, dy: dy), safeTop: s.safeAreaInsets.top,
                                      auxLeft: l.offsetBy(dx: dx, dy: dy), auxRight: r.offsetBy(dx: dx, dy: dy),
                                      isBuiltin: true, scale: 2)
                if let g = NotchGeometry.notch(for: info, uiScale: uiScale) { return g }
            }
        }
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let info = ScreenInfo(uuid: "builtin", frame: frame, visibleFrame: frame, safeTop: 32,
                              auxLeft: CGRect(x: 0, y: 950, width: 665, height: 32),
                              auxRight: CGRect(x: 850, y: 950, width: 662, height: 32), isBuiltin: true, scale: 2)
        return NotchGeometry.notch(for: info, uiScale: uiScale)!
    }

    static func render(model: SurfaceModel, context: SurfaceContext, geometry g: NotchGeometry, dark: Bool,
                       menus: MenuBarClearance? = nil, to url: URL) {
        let cropX = (g.notchRect.midX - crop.width / 2).rounded()
        let scene = Scene(model: model, context: context, geometry: g, cropX: cropX, dark: dark, menus: menus)
            .frame(width: crop.width, height: crop.height)
        let host = NSHostingView(rootView: scene)
        host.frame = CGRect(origin: .zero, size: crop)
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: crop.width, height: crop.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        // Let measurements (wings, peek content) land in the model and the layout follow.
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        }
        host.layoutSubtreeIfNeeded()
        host.display()

        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(crop.width * scale), pixelsHigh: Int(crop.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = crop
        // Inside the panel: the AppKit capture, which renders every control (scroll views, lists,
        // switches). Outside it: SwiftUI's ImageRenderer, which also draws the panel's shadow.
        host.cacheDisplay(in: host.bounds, to: rep)
        let layout = model.layout
        let frame = layout.windowFrame(in: g)
        let shapeRect = CGRect(x: frame.minX - cropX + (frame.width - layout.size.width) / 2,
                               y: crop.height - layout.size.height,
                               width: layout.size.width, height: layout.size.height)
        // The hardware notch sits physically above every pixel: draw it last, so anything the
        // panel puts under it shows up as hidden in the render, exactly as on the real screen.
        let hardware = g.kind == .notch
            ? CGRect(x: g.notchRect.minX - cropX, y: crop.height - g.notchRect.height,
                     width: g.notchRect.width, height: g.notchRect.height) : nil
        let output = composite(inside: rep, outside: ImageRenderer(content: scene).withScale(scale).cgImage,
                               shape: NotchShape(topRadius: layout.topRadius, bottomRadius: layout.bottomRadius),
                               in: shapeRect, hardwareNotch: hardware)
        try? output.representation(using: .png, properties: [:])?.write(to: url)
        window.contentView = nil
        window.close()
    }
}

/// `outside` everywhere, then `inside` clipped to the panel shape (y-up crop coordinates).
@MainActor
private func composite(inside: NSBitmapImageRep, outside: CGImage?, shape: NotchShape, in rect: CGRect,
                       hardwareNotch: CGRect? = nil) -> NSBitmapImageRep {
    guard let outside, let insideCG = inside.cgImage else { return inside }
    let w = inside.pixelsWide, h = inside.pixelsHigh
    let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    out.size = inside.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    let ctx = NSGraphicsContext.current!.cgContext
    // The context is in points (the rep's size), already scaled to pixels.
    let full = CGRect(origin: .zero, size: inside.size)
    ctx.draw(outside, in: full)
    // NotchShape is drawn y-down; flip it into the y-up context.
    var t = CGAffineTransform(translationX: rect.minX, y: rect.maxY).scaledBy(x: 1, y: -1)
    let path = shape.path(in: CGRect(origin: .zero, size: rect.size)).cgPath
    if let clip = path.copy(using: &t) {
        ctx.addPath(clip)
        ctx.clip()
        ctx.draw(insideCG, in: full)
    }
    if let n = hardwareNotch {
        ctx.resetClip()
        var tn = CGAffineTransform(translationX: n.minX, y: n.maxY).scaledBy(x: 1, y: -1)
        if let p = NotchShape(topRadius: 6, bottomRadius: 10).path(in: CGRect(origin: .zero, size: n.size)).cgPath.copy(using: &tn) {
            ctx.addPath(p)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fillPath()
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return out
}

@MainActor private extension ImageRenderer {
    func withScale(_ s: CGFloat) -> ImageRenderer { scale = s; return self }
}

/// The surface over a strip of desktop: wallpaper, menu bar (menus left, status items right), and
/// the hardware notch drawn underneath, so the blend can be judged.
private struct Scene: View {
    let model: SurfaceModel
    let context: SurfaceContext
    let geometry: NotchGeometry
    let cropX: CGFloat
    let dark: Bool
    let menus: MenuBarClearance?

    var body: some View {
        let screen = geometry.screenFrame
        // The surface view is laid out centred on the notch, like the app's hosting view.
        let frame = SurfaceLayout.hostFrame(in: geometry, window: model.layout.windowFrame(in: geometry))
        let notch = geometry.notchRect
        ZStack(alignment: .topLeading) {
            Wallpaper(dark: dark)
            // A pill may be taller than the menu bar (larger sizes): the bar stays 24 pt.
            MenuBar(width: screen.width, height: geometry.kind == .pill ? min(notch.height, 24) : notch.height, dark: dark, menus: menus,
                    notch: notch.offsetBy(dx: -screen.minX, dy: 0))
                .offset(x: -cropX)
            // The hardware notch the panel must disappear into.
            if geometry.kind == .notch {
                NotchShape(topRadius: 6, bottomRadius: 10)
                    .fill(Color.black)
                    .frame(width: notch.width, height: notch.height)
                    .offset(x: notch.minX - cropX)
            }
            SurfaceView(model: model, context: context)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX - cropX)
        }
        .frame(width: Render.crop.width, height: Render.crop.height, alignment: .topLeading)
        .clipped()
    }
}

private struct Wallpaper: View {
    let dark: Bool
    var body: some View {
        if dark {
            LinearGradient(colors: [Color(red: 0.10, green: 0.12, blue: 0.22), Color(red: 0.20, green: 0.14, blue: 0.28),
                                    Color(red: 0.08, green: 0.08, blue: 0.12)], startPoint: .top, endPoint: .bottom)
        } else {
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(red: 0.80, green: 0.86, blue: 0.96), Color(red: 0.86, green: 0.80, blue: 0.93),
                                        Color(red: 0.96, green: 0.84, blue: 0.80)], startPoint: .top, endPoint: .bottom)
                // A window below the menu bar, for scale.
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.15), radius: 18, y: 8)
                    .frame(width: 560, height: 260)
                    .offset(x: 40, y: 96)
            }
        }
    }
}

private struct MenuBar: View {
    let width: CGFloat
    let height: CGFloat
    let dark: Bool
    /// When set, the menus end `left` before the notch and the status items start `right` after it.
    var menus: MenuBarClearance? = nil
    var notch: CGRect = .zero

    var body: some View {
        if let menus { crowded(menus) } else { standard }
    }

    /// Chrome's menus packed up to the notch, the status items at the measured distance.
    private func crowded(_ c: MenuBarClearance) -> some View {
        let ink = dark ? Color.white.opacity(0.92) : Color.black.opacity(0.85)
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 19) {
                Image(systemName: "apple.logo").font(.system(size: 14, weight: .medium))
                Text("Google Chrome").fontWeight(.bold)
                ForEach(["File", "Edit", "View", "History", "Bookmarks", "Profiles", "Tab", "Window", "Help"], id: \.self) { Text($0) }
            }
            .fixedSize()
            .frame(width: notch.minX - c.left, height: height, alignment: .trailing)
            HStack(spacing: 17) {
                Image(systemName: "shippingbox")
                Image(systemName: "chart.bar")
                Image(systemName: "rectangle.3.group")
                Image(systemName: "shield")
                Image(systemName: "battery.75percent")
                Image(systemName: "wifi")
                Text(Render.clock)
            }
            .fixedSize()
            .frame(height: height)
            .offset(x: notch.maxX + c.right)
        }
        .font(.system(size: 13))
        .foregroundStyle(ink)
        .frame(width: width, height: height, alignment: .topLeading)
        .background(dark ? Color.black.opacity(0.18) : Color.white.opacity(0.18))
    }

    private var standard: some View {
        let ink = dark ? Color.white.opacity(0.92) : Color.black.opacity(0.85)
        return HStack(spacing: 0) {
            HStack(spacing: 19) {
                Image(systemName: "apple.logo").font(.system(size: 14, weight: .medium))
                Text("Code").fontWeight(.bold)
                ForEach(["File", "Edit", "Selection", "View", "Go", "Run", "Terminal", "Window", "Help"], id: \.self) { Text($0) }
            }
            .padding(.leading, 20)
            Spacer()
            HStack(spacing: 17) {
                Image(systemName: "record.circle")
                Image(systemName: "cloud")
                Image(systemName: "rectangle.3.group")
                Image(systemName: "battery.75percent")
                Image(systemName: "wifi")
                Image(systemName: "magnifyingglass")
                Image(systemName: "switch.2")
                Text(Render.clock)
            }
            .padding(.trailing, 14)
        }
        .font(.system(size: 13))
        .foregroundStyle(ink)
        .frame(width: width, height: height)
        .background(dark ? Color.black.opacity(0.18) : Color.white.opacity(0.18))
    }
}

Render.run()
