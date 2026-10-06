import AppKit
import Foundation
import Testing
@testable import GlancyKit

// MARK: - Fakes (no automated run touches appearance, Wi-Fi, Finder, sleep, lock, Trash or camera)

@MainActor
final class FakeSystemActions: SystemActions {
    var awakeHeld = false
    var awakeCalls: [Bool] = []
    var dark = false
    var darkOutcome: ScriptOutcome = .ok
    var wifi: Bool? = true
    var wifiSetWorks = true
    var flags: [FinderFlag: Bool] = [.desktopIcons: false, .hiddenFiles: false]
    var finderCalls: [(FinderFlag, Bool)] = []
    var trash: Result<TrashSummary, ScriptOutcome> = .success(TrashSummary(items: 3, bytes: 4096))
    var emptied = 0
    var volumes: [String] = []
    var ejectResult = (ejected: 0, failed: 0)
    var tools: [String] = []
    var copied: [String] = []
    var nextColor: RGB?
    var camera: CameraAccess = .unavailable

    func holdAwake(_ on: Bool) -> Bool { awakeCalls.append(on); awakeHeld = on; return true }
    func darkMode() -> Bool { dark }
    func wifiPower() -> Bool? { wifi }
    func finderFlag(_ flag: FinderFlag) -> Bool { flags[flag] ?? false }
    func setDarkMode(_ on: Bool) async -> ScriptOutcome {
        if darkOutcome == .ok { dark = on }
        return darkOutcome
    }
    func setWiFiPower(_ on: Bool) -> Bool {
        guard wifiSetWorks else { return false }
        wifi = on
        return true
    }
    func setFinderFlag(_ flag: FinderFlag, _ on: Bool) async -> Bool {
        finderCalls.append((flag, on)); flags[flag] = on; return true
    }
    func lockScreen() { tools.append("lock") }
    func sleepDisplay() { tools.append("displaySleep") }
    func startScreenSaver() { tools.append("screenSaver") }
    func screenshot(_ target: ScreenshotTarget) { tools.append("screenshot.\(target)") }
    func trashSummary() async -> Result<TrashSummary, ScriptOutcome> { trash }
    func emptyTrash() async -> ScriptOutcome { emptied += 1; return .ok }
    func ejectableVolumes() -> [String] { volumes }
    func ejectAll() async -> (ejected: Int, failed: Int) { volumes = []; return ejectResult }
    func sampleColor(_ done: @escaping @MainActor (RGB?) -> Void) { tools.append("sample"); done(nextColor) }
    func copy(_ text: String) { copied.append(text) }
    func cameraAccess() -> CameraAccess { camera }
    func requestCamera() async -> Bool { camera == .granted }
    func openAutomationSettings() { tools.append("automationSettings") }
    func openCameraSettings() { tools.append("cameraSettings") }
}

/// Records each requested wake-up; the test fires it.
@MainActor
final class FakeScheduler: WakeScheduling {
    var scheduled: [(Date, @MainActor () -> Void)] = []
    var cancelled = 0
    func schedule(at date: Date, _ fire: @escaping @MainActor () -> Void) -> WakeToken {
        scheduled.append((date, fire))
        return WakeToken { [weak self] in Task { @MainActor in self?.cancelled += 1 } }
    }
}

/// Counters that grow by a fixed step on every read.
final class FakeStatsSource: StatsSource, @unchecked Sendable {
    private let lock = NSLock()
    private var n: UInt64 = 0
    func cpu() -> CPUTicks? {
        lock.withLock { n += 1 }
        let k = lock.withLock { n }
        return CPUTicks(user: 30 * k, system: 10 * k, idle: 60 * k, nice: 0)
    }
    func memory() -> MemoryReading? { MemoryReading(used: 8 << 30, total: 16 << 30, pressure: 1) }
    func network() -> NetworkCounters? { nil }
    func disk() -> DiskReading? { DiskReading(free: 100, total: 400) }
    func battery() -> BatteryReading? { BatteryReading(cycles: 10, health: 0.95) }
    func bootTime() -> Date? { Date.now.addingTimeInterval(-3600) }
}

@MainActor
private func makeControl(_ actions: FakeSystemActions = FakeSystemActions(), scheduler: FakeScheduler = FakeScheduler(),
                         interval: Duration = .milliseconds(10)) -> (ControlModule, FakeSystemActions, FakeScheduler, ActivityHub) {
    let defaults = UserDefaults(suiteName: "glancy.test.control.\(UUID().uuidString)")!
    let m = ControlModule(actions: actions, settings: ControlSettings(defaults: defaults), scheduler: scheduler,
                          stats: StatsSampler(source: FakeStatsSource(), interval: interval))
    m.closeDelay = .milliseconds(1)
    let hub = ActivityHub()
    m.start(hub: hub)
    return (m, actions, scheduler, hub)
}

@MainActor
private func settle(_ cond: @MainActor () -> Bool, timeout: Double = 10) async -> Bool {
    let end = Date.now.addingTimeInterval(timeout)
    while Date.now < end {
        if cond() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return cond()
}

// MARK: - Keep awake

@MainActor
@Suite("Control: keep awake") struct ControlAwakeTests {
    @Test func startHoldsAssertionAndSchedulesOneWake() {
        let (m, fake, sched, hub) = makeControl()
        let now = Date.now
        m.startAwake(seconds: 3600, duration: .h1, now: now)
        #expect(fake.awakeHeld)
        #expect(m.model.awake.isOn)
        #expect(sched.scheduled.count == 1, "one wake-up at the deadline, no polling")
        #expect(sched.scheduled.first?.0 == now.addingTimeInterval(3600))
        #expect(hub.top?.id == "control.awake")
        m.stop()
    }

    @Test func expiryReleasesAssertionAndClearsWing() {
        let (m, fake, sched, hub) = makeControl()
        // Started an hour and a second ago: the deadline has passed when the wake-up fires.
        m.startAwake(seconds: 3600, duration: .h1, now: Date.now.addingTimeInterval(-3601))
        sched.scheduled[0].1()
        #expect(!m.model.awake.isOn)
        #expect(!fake.awakeHeld)
        #expect(fake.awakeCalls == [true, false])
        #expect(hub.top == nil)
        #expect(sched.scheduled.count == 1)
        m.stop()
    }

    @Test func earlyWakeRearmsOnce() {
        let (m, _, sched, _) = makeControl()
        m.startAwake(seconds: 3600, duration: .h1, now: .now)
        // A wake-up before the deadline (e.g. after system sleep) re-arms a single new one.
        m.checkAwakeExpiry(now: .now)
        #expect(m.model.awake.isOn)
        #expect(sched.scheduled.count == 2)
        m.stop()
    }

    @Test func foreverSchedulesNothing() {
        let (m, fake, sched, hub) = makeControl()
        m.startAwake(.forever)
        #expect(m.model.awake.isOn && m.model.awake.until == nil)
        #expect(sched.scheduled.isEmpty)
        #expect(hub.top?.id == "control.awake")
        m.stopAwake()
        #expect(!fake.awakeHeld && hub.top == nil)
        m.stop()
    }

    @Test func toggleUsesDefaultAndChipCycles() {
        let (m, _, _, _) = makeControl()
        m.settings.awakeDefault = .m30
        m.toggle(.keepAwake)
        #expect(m.model.awake.duration == .m30)
        m.cycleAwakeDuration()
        #expect(m.model.awake.duration == .h1)
        #expect(m.settings.awakeDefault == .h1)
        m.toggle(.keepAwake)
        #expect(!m.model.awake.isOn)
        m.cycleAwakeDuration()
        #expect(m.settings.awakeDefault == .h2 && !m.model.awake.isOn)
        m.stop()
    }

    @Test func stopReleasesAssertion() {
        let (m, fake, _, _) = makeControl()
        m.startAwake(.h2)
        m.stop()
        #expect(!fake.awakeHeld)
        #expect(ResourceCensus.of(m).total == 0)
    }

    @Test func wingHiddenWhenTurnedOffInSettings() {
        let (m, _, _, hub) = makeControl()
        m.settings.awakeInWings = false
        m.startAwake(.h1)
        #expect(hub.top == nil)
        m.settings.awakeInWings = true
        m.settingsChanged()
        #expect(hub.top?.id == "control.awake")
        m.stop()
    }
}

// MARK: - Toggles and tools

@MainActor
@Suite("Control: toggles and tools") struct ControlToggleTests {
    @Test func darkModeOnAndPermissionRefused() async {
        let (m, fake, _, _) = makeControl()
        m.toggle(.darkMode)
        #expect(await settle { !m.model.busy.contains(.darkMode) && m.model.darkMode })
        fake.darkOutcome = .needsPermission
        m.toggle(.darkMode)
        #expect(await settle { m.model.prompt == .needsAutomation("System Events") })
        #expect(m.model.darkMode, "unchanged when refused")
        m.confirm()
        #expect(fake.tools == ["automationSettings"])
        m.stop()
    }

    @Test func finderFlagsAskBeforeRestarting() async {
        let (m, fake, _, _) = makeControl()
        m.toggle(.desktopIcons)
        #expect(m.model.prompt == .confirmFinder(.desktopIcons, on: true))
        #expect(fake.finderCalls.isEmpty)
        m.dismissPrompt()
        #expect(fake.finderCalls.isEmpty)
        m.toggle(.hiddenFiles)
        m.confirm()
        #expect(await settle { m.model.hiddenFilesShown })
        #expect(fake.finderCalls.count == 1 && fake.finderCalls[0].0 == .hiddenFiles && fake.finderCalls[0].1)
        m.stop()
    }

    @Test func wifiToggleAndFailure() {
        let (m, fake, _, _) = makeControl()
        m.refreshStates()
        m.toggle(.wifi)
        #expect(m.model.wifi == false)
        fake.wifiSetWorks = false
        m.toggle(.wifi)
        #expect(m.model.wifi == false)
        fake.wifi = nil
        m.refreshStates()
        m.toggle(.wifi)
        #expect(m.model.wifi == nil)
        m.stop()
    }

    @Test func emptyTrashConfirmsWithSize() async {
        let (m, fake, _, _) = makeControl()
        m.visibilityChanged(.expanded(.control))
        m.run(.emptyTrash)
        #expect(await settle { m.model.prompt == .confirmTrash(TrashSummary(items: 3, bytes: 4096)) })
        #expect(fake.emptied == 0)
        m.confirm()
        #expect(await settle { fake.emptied == 1 })
        fake.trash = .success(TrashSummary(items: 0, bytes: 0))
        m.run(.emptyTrash)
        #expect(await settle { if case .note = m.model.prompt { true } else { false } })
        #expect(fake.emptied == 1)
        m.stop()
    }

    @Test func toolsCloseThePanelFirst() async {
        let (m, fake, _, hub) = makeControl()
        var closes = 0
        hub.onCloseRequest = { closes += 1 }
        m.visibilityChanged(.expanded(.control))
        m.run(.lock)
        m.run(.displaySleep)
        m.run(.screenSaver)
        m.run(.screenshot)
        #expect(await settle { fake.tools.count == 4 })
        #expect(closes == 4)
        #expect(Set(fake.tools) == ["lock", "displaySleep", "screenSaver", "screenshot.clipboard"])
        m.stop()
    }

    @Test func colorPickerCopiesHexAndRemembers() async {
        let (m, fake, _, hub) = makeControl()
        fake.nextColor = RGB(r: 255, g: 136, b: 0)
        m.pickColor()
        #expect(await settle { fake.copied == ["#FF8800"] })
        #expect(m.model.recent.colors.first == RGB(r: 255, g: 136, b: 0))
        #expect(m.model.picked == RGB(r: 255, g: 136, b: 0))
        #expect(hub.peek != nil, "collapsed: a peek shows the swatch")
        // Cancelled loupe: nothing copied.
        fake.nextColor = nil
        m.pickColor()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(fake.copied.count == 1)
        m.stop()
    }

    @Test func mirrorNeedsCameraAndStopsWhenLeaving() {
        let (m, fake, _, _) = makeControl()
        m.visibilityChanged(.expanded(.control))
        m.toggle(.mirror)
        #expect(m.model.mirror == .off)           // no usage string in tests: never opens the camera
        fake.camera = .denied
        m.toggle(.mirror)
        #expect(m.model.prompt == .needsCamera)
        fake.camera = .granted
        m.dismissPrompt()
        m.toggle(.mirror)
        #expect(m.model.mirror == .live)
        m.visibilityChanged(.expanded(.timer))
        #expect(m.model.mirror == .off)
        m.stop()
    }

    @Test func ejectReportsNothingOrCount() async {
        let (m, fake, _, _) = makeControl()
        m.visibilityChanged(.expanded(.control))
        m.run(.eject)
        #expect(await settle { m.model.prompt == .note(ControlText.t("Nothing to eject"), symbol: "eject") })
        fake.volumes = ["USB", "Backup"]
        fake.ejectResult = (2, 0)
        m.run(.eject)
        #expect(await settle { m.model.prompt == .note(L10n.tr("%d disks ejected", 2), symbol: "eject") })
        #expect(m.model.ejectable.isEmpty)
        m.stop()
    }
}

// MARK: - Stats

@MainActor
@Suite("Control: stats", .serialized) struct ControlStatsTests {
    @Test func samplesOnlyWhileTabVisible() async {
        let (m, _, _, _) = makeControl()
        #expect(!m.stats.isRunning)
        m.visibilityChanged(.collapsed)
        m.visibilityChanged(.expanded(nil))
        #expect(!m.stats.isRunning, "Home is not the Control tab")
        m.visibilityChanged(.expanded(.control))
        #expect(m.stats.isRunning)
        #expect(await settle { m.stats.samples >= 3 })
        #expect(m.stats.snapshot.cpu != nil)
        #expect(m.stats.snapshot.disk == DiskReading(free: 100, total: 400))
        m.visibilityChanged(.collapsed)
        #expect(!m.stats.isRunning)
        let frozen = m.stats.samples
        try? await Task.sleep(for: .milliseconds(80))
        #expect(m.stats.samples == frozen, "no sampling while collapsed")
        m.visibilityChanged(.expanded(.control))
        #expect(m.stats.isRunning)
        m.visibilityChanged(.hidden)
        #expect(!m.stats.isRunning)
        m.settings.showStats = false
        m.visibilityChanged(.expanded(.control))
        #expect(!m.stats.isRunning)
        m.stop()
        #expect(ResourceCensus.of(m).total == 0)
    }

    @Test func engineMaths() {
        #expect(StatsEngine.cpuLoad(from: CPUTicks(user: 0, system: 0, idle: 0, nice: 0),
                                    to: CPUTicks(user: 20, system: 5, idle: 75, nice: 0)) == 0.25)
        #expect(StatsEngine.cpuLoad(from: CPUTicks(user: 1, system: 1, idle: 1, nice: 0),
                                    to: CPUTicks(user: 1, system: 1, idle: 1, nice: 0)) == nil)
        #expect(StatsEngine.delta(100, 40) == 0, "counter reset is not a huge jump")

        struct Net: StatsSource {
            let rx: UInt64
            func cpu() -> CPUTicks? { nil }
            func memory() -> MemoryReading? { nil }
            func network() -> NetworkCounters? { NetworkCounters(received: rx, sent: rx / 2) }
            func disk() -> DiskReading? { nil }
            func battery() -> BatteryReading? { nil }
            func bootTime() -> Date? { Date(timeIntervalSinceReferenceDate: 0) }
        }
        var e = StatsEngine()
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        e.sample(Net(rx: 1000), now: t0, slow: true)
        #expect(e.snapshot.down == nil)
        e.sample(Net(rx: 3000), now: t0.addingTimeInterval(2), slow: false)
        #expect(e.snapshot.down == 1000)
        #expect(e.snapshot.up == 500)
        #expect(e.snapshot.uptime == 1002)
    }

    @Test func liveSourceReadsThisMac() {
        // Read-only system counters: no permission involved.
        let s = LiveStatsSource()
        #expect(s.cpu() != nil)
        let mem = s.memory()
        #expect(mem != nil && mem!.used > 0 && mem!.used <= mem!.total)
        #expect(s.network() != nil)
        #expect(s.bootTime() != nil)
        #expect((s.disk()?.total ?? 0) > 0)
    }

    @Test func formats() {
        #expect(ControlFormat.uptime(3 * 86400 + 4 * 3600 + 59) == "3d 4h")
        #expect(ControlFormat.uptime(5 * 3600 + 12 * 60) == "5h 12m")
        #expect(ControlFormat.rate(1_240_000) == "1.2 MB/s")
        #expect(ControlFormat.rate(86_000) == "86 KB/s")
        #expect(ControlFormat.length(5400) == "1h 30m")
        #expect(ControlFormat.length(1800) == "30m")
    }
}

// MARK: - Colour, queries, commands

@Suite("Control: parsing") struct ControlParsingTests {
    @Test func hexVariants() {
        let orange = RGB(r: 255, g: 136, b: 0)
        #expect(RGB.parse("#ff8800") == orange)
        #expect(RGB.parse("FF8800") == orange)
        #expect(RGB.parse("#f80") == orange)
        #expect(RGB.parse("0xFF8800") == orange)
        #expect(RGB.parse("hex ff8800") == orange)
        #expect(RGB.parse("colore #FF8800") == orange)
        #expect(RGB.parse("rgb(255, 136, 0)") == orange)
        #expect(RGB.parse("rgb(255 136 0)") == orange)
        #expect(orange.hex == "#FF8800")
        #expect(orange.rgbString == "rgb(255, 136, 0)")
        #expect(RGB.parse("#ff88") == nil)
        #expect(RGB.parse("#gg8800") == nil)
        #expect(RGB.parse("rgb(256, 0, 0)") == nil)
        #expect(RGB.parse("ff8800", requirePrefix: true) == nil)
        #expect(RGB.parse("#ff8800", requirePrefix: true) == orange)
        #expect(RGB(red: 1, green: 0.5333, blue: 0) == orange)
    }

    @Test func recentColorsDedupeAndCap() {
        var r = RecentColors()
        for i in 0..<12 { r.add(RGB(r: i, g: 0, b: 0)) }
        #expect(r.colors.count == RecentColors.limit)
        #expect(r.colors.first == RGB(r: 11, g: 0, b: 0))
        r.add(RGB(r: 5, g: 0, b: 0))
        #expect(r.colors.first == RGB(r: 5, g: 0, b: 0))
        #expect(r.colors.filter { $0 == RGB(r: 5, g: 0, b: 0) }.count == 1)
    }

    @Test func awakeQueries() {
        #expect(ControlQuery.awake("awake 2h") == .some(7200))
        #expect(ControlQuery.awake("caffeinate 30m") == .some(1800))
        #expect(ControlQuery.awake("tieni sveglio 1 ora") == .some(3600))
        #expect(ControlQuery.awake("sveglio 90 min") == .some(5400))
        #expect(ControlQuery.awake("awake 1h30") == .some(5400))
        #expect(ControlQuery.awake("Awake 1h 15m") == .some(4500))
        #expect(ControlQuery.awake("tieni sveglio 2 ore") == .some(7200))
        #expect(ControlQuery.awake("awake forever") == .some(nil))
        #expect(ControlQuery.awake("tieni sveglio sempre") == .some(nil))
        #expect(ControlQuery.awake("awake") == nil)
        #expect(ControlQuery.awake("awake 2") == nil)
        #expect(ControlQuery.awake("awake soon") == nil)
        #expect(ControlQuery.awake("2h") == nil)
    }

    @Test func layoutMovesWithinGroup() {
        var l = ControlLayout()
        #expect(l.toggles.first == .keepAwake)
        #expect(!l.canMove(.keepAwake, by: -1))
        #expect(!l.canMove(.hiddenFiles, by: 1), "a toggle never crosses into the tools")
        l.move(.keepAwake, by: 1)
        #expect(l.toggles.prefix(2) == [.darkMode, .keepAwake])
        l.hidden.insert(.wifi)
        #expect(!l.toggles.contains(.wifi))
        var partial = ControlLayout(order: [.eject, .lock])
        partial.normalize()
        #expect(partial.order.count == ControlTile.allCases.count)
        #expect(partial.tools.first == .eject)
    }

    @MainActor @Test func settingsPersist() {
        let d = UserDefaults(suiteName: "glancy.test.control.settings.\(UUID().uuidString)")!
        do {
            let s = ControlSettings(defaults: d)
            s.awakeDefault = .h2
            var l = s.layout
            l.hidden = [.mirror]
            s.layout = l
            s.showStats = false
            let again = ControlSettings(defaults: d)
            #expect(again.awakeDefault == .h2)
            #expect(again.layout.hidden == [.mirror])
            #expect(!again.showStats)
        }
    }
}

@MainActor
@Suite("Control: command bar", .serialized) struct ControlCommandTests {
    private func matches(_ cmds: [GlancyCommand], _ term: String) -> [GlancyCommand] {
        cmds.filter { c in ([c.title] + c.keywords).contains { $0.lowercased().contains(term) } }
    }

    @Test func everyTileHasACommandFoundInEnglishAndItalian() {
        let (m, _, _, _) = makeControl()
        let cmds = m.commands()
        #expect(Set(cmds.map(\.id)).count == cmds.count, "ids are unique")
        for tile in ControlTile.allCases {
            #expect(cmds.contains { $0.id == "control.\(tile.rawValue)" }, "\(tile)")
        }
        for term in ["caffeinate", "tieni sveglio", "dark mode", "modalità scura", "lock", "blocca", "empty trash",
                     "svuota cestino", "color picker", "contagocce", "mirror", "specchio", "wifi", "espelli", "salvaschermo"] {
            #expect(!matches(cmds, term).isEmpty, "\(term)")
        }
        #expect(cmds.allSatisfy { $0.module == .control })
        m.stop()
    }

    @Test func titlesFollowStateAndLanguage() {
        let (m, fake, _, _) = makeControl()
        fake.dark = true
        #expect(m.commands().first { $0.id == "control.darkMode" }?.title == "Turn Dark mode off")
        L10n.apply(.it)
        defer { L10n.apply(.en) }
        let it = m.commands()
        #expect(it.first { $0.id == "control.darkMode" }?.title == "Disattiva la modalità scura")
        #expect(it.first { $0.id == "control.keepAwake" }?.title == "Tieni sveglio")
        #expect(it.first { $0.id == "control.emptyTrash" }?.title == "Svuota cestino")
        m.stop()
    }

    @Test func runningCommands() async {
        let (m, fake, _, _) = makeControl()
        m.commands().first { $0.id == "control.keepAwake.h2" }?.run()
        #expect(m.model.awake.duration == .h2 && fake.awakeHeld)
        m.commands().first { $0.id == "control.keepAwake" }?.run()
        #expect(!m.model.awake.isOn)
        m.commands().first { $0.id == "control.lock" }?.run()
        #expect(await settle { fake.tools.contains("lock") })
        m.stop()
    }

    @Test func resultsForTypedQueries() {
        let (m, fake, _, _) = makeControl()
        let awake = m.results(for: "awake 2h")
        #expect(awake.count == 1)
        #expect(awake[0].title == "Keep awake for 2h" && awake[0].rank >= 50)
        awake[0].run()
        #expect(m.model.awake.isOn && m.model.awake.duration == .h2)

        let custom = m.results(for: "tieni sveglio 45 minuti")
        #expect(custom.first?.title == "Keep awake for 45m")

        let hex = m.results(for: "hex #ff8800")
        #expect(hex.first?.title == "#FF8800")
        #expect(hex.first?.subtitle?.contains("rgb(255, 136, 0)") == true)
        hex.first?.run()
        #expect(fake.copied == ["#FF8800"])
        #expect(m.model.recent.colors.first == RGB(r: 255, g: 136, b: 0))
        #expect(m.results(for: "#f80").first?.title == "#FF8800")

        #expect(m.results(for: "ff8800").isEmpty, "a bare word is not a colour")
        #expect(m.results(for: "hello").isEmpty)
        #expect(m.results(for: "aw").isEmpty)

        L10n.apply(.it)
        defer { L10n.apply(.en) }
        #expect(m.results(for: "sveglio 1h").first?.title == "Tieni sveglio per 1h")
        m.stop()
    }

    @Test func resultsAreFast() {
        let (m, _, _, _) = makeControl()
        let start = Date.now
        for _ in 0..<100 { _ = m.results(for: "awake 1h30"); _ = m.results(for: "#ff8800"); _ = m.results(for: "spotify") }
        #expect(Date.now.timeIntervalSince(start) / 300 < 0.005)
        m.stop()
    }
}

@MainActor
@Suite("Control: Italian", .serialized) struct ControlItalianTests {
    @Test func everyControlStringHasItalian() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("Sources/GlancyKit/Control")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "ControlText.swift" }
        let pattern = try NSRegularExpression(pattern: #"(?:ControlText\.t|L10n\.tr|\btr)\("((?:[^"\\]|\\.)*)""#)
        var keys = Set<String>()
        for f in files {
            let s = try String(contentsOf: f, encoding: .utf8)
            for m in pattern.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                keys.insert(String(s[Range(m.range(at: 1), in: s)!]))
            }
        }
        // Tile titles go through ControlText.t(tile.title) / shortTitle.
        keys.formUnion(ControlTile.allCases.flatMap { [$0.title, $0.shortTitle] })
        L10n.addItalian(controlItalian)
        L10n.apply(.it)
        defer { L10n.apply(.en) }
        let same: Set<String> = ["Wi-Fi", "CPU"]
        let missing = keys.filter { L10n.tr($0) == $0 && !same.contains($0) }.sorted()
        #expect(missing.isEmpty, "untranslated: \(missing)")
    }
}

@MainActor
@Suite("Control: live reads") struct ControlLiveReadTests {
    /// Read-only: the same preferences `defaults` shows, nothing written.
    @Test func darkModeAndFinderFlagsMatchDefaults() {
        let live = LiveSystemActions()
        let style = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleInterfaceStyle"] as? String
        #expect(live.darkMode() == (style == "Dark"))
        let finder = UserDefaults.standard.persistentDomain(forName: "com.apple.finder")
        let create = (finder?["CreateDesktop"] as? NSNumber)?.boolValue ?? (finder?["CreateDesktop"] as? String).map { $0 == "1" || $0.lowercased() == "true" }
        #expect(live.finderFlag(.desktopIcons) == !(create ?? true))
    }
}
