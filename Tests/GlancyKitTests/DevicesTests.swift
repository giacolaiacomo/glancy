import CoreAudio
import Foundation
import SwiftUI
import Testing
@testable import GlancyKit

// Wave 4 · Devices: battery alerts, headphone batteries, microphone mute / in use, output switch,
// command bar. Every CoreAudio call goes to `FakeAudioSystem`: the real mic and output are never touched.

// MARK: Fakes

@MainActor
final class FakeAudioSystem: AudioSystem {
    struct Input { var mute: Bool?; var muteSettable: Bool; var volume: Float?; var volumeSettable: Bool }
    var list: [AudioDevice] = []
    var inputsState: [AudioObjectID: Input] = [:]
    var defaultIn: AudioObjectID?
    var defaultOut: AudioObjectID?
    var use = InputUse()
    var camera: Bool? = false
    var refuseOutput = false
    private(set) var observer: (@MainActor (AudioChange) -> Void)?
    private(set) var writes: [String] = []

    func devices() -> [AudioDevice] { list }
    func defaultInput() -> AudioObjectID? { defaultIn }
    func defaultOutput() -> AudioObjectID? { defaultOut }
    func setDefaultOutput(_ id: AudioObjectID) -> Bool {
        guard !refuseOutput else { return false }
        writes.append("output \(id)"); defaultOut = id; return true
    }
    func inputMute(_ id: AudioObjectID) -> Bool? { inputsState[id]?.mute }
    func canSetInputMute(_ id: AudioObjectID) -> Bool { inputsState[id]?.muteSettable ?? false }
    func setInputMute(_ id: AudioObjectID, _ on: Bool) -> Bool {
        guard inputsState[id]?.muteSettable == true else { return false }
        writes.append("mute \(id) \(on)"); inputsState[id]?.mute = on; return true
    }
    func inputVolume(_ id: AudioObjectID) -> Float? { inputsState[id]?.volume }
    func canSetInputVolume(_ id: AudioObjectID) -> Bool { inputsState[id]?.volumeSettable ?? false }
    func setInputVolume(_ id: AudioObjectID, _ value: Float) -> Bool {
        guard inputsState[id]?.volumeSettable == true else { return false }
        writes.append("volume \(id) \(value)"); inputsState[id]?.volume = value; return true
    }
    func inputUse() -> InputUse { use }
    func cameraInUse() -> Bool? { camera }
    func observe(_ onChange: @escaping @MainActor (AudioChange) -> Void) { observer = onChange }
    func stopObserving() { observer = nil }
    func fire(_ c: AudioChange) { observer?(c) }

    /// Built-in mic with a mute control (id 10), USB mic with volume only (id 11), speakers (20),
    /// AirPods with both directions (30, mute control).
    static func standard() -> FakeAudioSystem {
        let f = FakeAudioSystem()
        f.list = [
            AudioDevice(id: 10, uid: "builtin-mic", name: "MacBook Pro Microphone", hasInput: true, hasOutput: false, transport: .builtIn),
            AudioDevice(id: 11, uid: "usb-mic", name: "USB Mic", hasInput: true, hasOutput: false, transport: .usb),
            AudioDevice(id: 20, uid: "builtin-out", name: "MacBook Pro Speakers", hasInput: false, hasOutput: true, transport: .builtIn),
            AudioDevice(id: 30, uid: "airpods", name: "AirPods Pro", hasInput: true, hasOutput: true, transport: .bluetooth),
        ]
        f.inputsState = [
            10: Input(mute: false, muteSettable: true, volume: 0.6, volumeSettable: true),
            11: Input(mute: nil, muteSettable: false, volume: 0.8, volumeSettable: true),
            30: Input(mute: false, muteSettable: true, volume: 1, volumeSettable: false),
        ]
        f.defaultIn = 10
        f.defaultOut = 20
        return f
    }
}

@MainActor private func freshDefaults(_ name: String = #function) -> UserDefaults {
    let suite = "ai.glancy.tests.devices.\(name).\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    d.removePersistentDomain(forName: suite)
    return d
}

// MARK: Battery alerts

@Suite struct BatteryAlertTests {
    func onBattery(_ p: Int) -> PowerState { PowerState(hasBattery: true, percent: p, onAC: false) }

    /// Runs a sequence of levels on battery; returns the alerts in order.
    func run(_ levels: [Int], alerts a: inout BatteryAlerts, from start: PowerState? = nil) -> [BatteryAlert] {
        var prev = start
        var out: [BatteryAlert] = []
        for p in levels {
            let s = onBattery(p)
            if let alert = a.update(from: prev, to: s) { out.append(alert) }
            prev = s
        }
        return out
    }

    @Test func eachThresholdOncePerDischarge() {
        var a = BatteryAlerts(thresholds: [20, 10])
        let fired = run(Array(stride(from: 30, through: 3, by: -1)), alerts: &a, from: onBattery(31))
        #expect(fired == [.low(20), .low(10)])
    }

    @Test func noRepeatWhileHoveringAroundAThreshold() {
        var a = BatteryAlerts(thresholds: [20, 10], hysteresis: 3)
        // 21 → 20 fires; wobbling 20/21/22 never fires again; 23 re-arms, the next 20 fires again.
        let fired = run([21, 20, 21, 20, 22, 21, 20, 19], alerts: &a, from: onBattery(22))
        #expect(fired == [.low(20)])
        let again = run([23, 22, 20], alerts: &a, from: onBattery(19))
        #expect(again == [.low(20)])
    }

    @Test func aBigDropWarnsOnceForTheLowest() {
        var a = BatteryAlerts(thresholds: [20, 10])
        #expect(run([25, 9, 8, 11, 9], alerts: &a, from: onBattery(26)) == [.low(10)])
    }

    @Test func pluggingInReArms() {
        var a = BatteryAlerts(thresholds: [20, 10])
        #expect(run([20], alerts: &a, from: onBattery(21)) == [.low(20)])
        let ac = PowerState(hasBattery: true, percent: 20, onAC: true, isCharging: true)
        #expect(a.update(from: onBattery(20), to: ac) == nil)
        #expect(a.update(from: ac, to: onBattery(20)) == .low(20))
    }

    @Test func lowAtLaunchWarnsOnceAndNotOnAC() {
        var a = BatteryAlerts(thresholds: [20, 10])
        #expect(a.update(from: nil, to: onBattery(8)) == .low(10))
        #expect(a.update(from: onBattery(8), to: onBattery(7)) == nil)
        var b = BatteryAlerts(thresholds: [20, 10])
        #expect(b.update(from: nil, to: PowerState(hasBattery: true, percent: 8, onAC: true)) == nil)
    }

    @Test func noThresholdsNoLowAndNoBatteryNothing() {
        var a = BatteryAlerts(thresholds: [])
        #expect(run([20, 10, 5], alerts: &a, from: onBattery(30)).isEmpty)
        var b = BatteryAlerts()
        #expect(b.update(from: nil, to: .noBattery) == nil)
        #expect(b.update(from: .noBattery, to: .noBattery) == nil)
    }

    @Test func reconfiguringKeepsWhatFired() {
        var a = BatteryAlerts(thresholds: [20, 10])
        _ = run([20], alerts: &a, from: onBattery(21))
        a.configure(thresholds: [20, 5], fullEnabled: true)
        #expect(!a.armed.contains(20) && a.armed.contains(5))
        #expect(run([19, 5], alerts: &a, from: onBattery(20)) == [.low(5)])
    }

    // Full

    func charging(_ p: Int) -> PowerState { PowerState(hasBattery: true, percent: p, onAC: true, isCharging: true) }
    func held(_ p: Int, charged: Bool = false) -> PowerState { PowerState(hasBattery: true, percent: p, onAC: true, isCharging: false, isCharged: charged) }

    @Test func fullAt100Once() {
        var a = BatteryAlerts()
        #expect(a.update(from: charging(98), to: charging(99)) == nil)
        #expect(a.update(from: charging(99), to: held(100, charged: true)) == .full(limit: nil))
        #expect(a.update(from: held(100, charged: true), to: held(100, charged: true)) == nil)
    }

    @Test func chargeLimitReached() {
        // macOS stops at the charge limit (80 %): AC, not charging, not "charged" — as captured live.
        var a = BatteryAlerts()
        #expect(a.update(from: charging(79), to: charging(80)) == nil)
        #expect(a.update(from: charging(80), to: held(80)) == .full(limit: 80))
        #expect(a.update(from: held(80), to: held(80)) == nil)
        // Optimised Charging finishing later to 100: reported again, as full.
        #expect(a.update(from: held(80), to: charging(81)) == nil)
        #expect(a.update(from: charging(99), to: held(100, charged: true)) == .full(limit: nil))
    }

    @Test func aPauseBelowTheLimitRangeIsNotFull() {
        var a = BatteryAlerts()
        #expect(a.update(from: charging(60), to: held(60)) == nil)   // heat / calibration pause
    }

    @Test func fullAtLaunchIsSilentUnplugReArms() {
        var a = BatteryAlerts()
        #expect(a.update(from: nil, to: held(100, charged: true)) == nil)
        #expect(a.update(from: held(100, charged: true), to: held(100, charged: true)) == nil)
        let unplugged = PowerState(hasBattery: true, percent: 99, onAC: false)
        #expect(a.update(from: held(100, charged: true), to: unplugged) == nil)
        #expect(a.update(from: unplugged, to: charging(99)) == nil)
        #expect(a.update(from: charging(99), to: held(100, charged: true)) == .full(limit: nil))
    }

    @Test func fullDisabledStaysQuiet() {
        var a = BatteryAlerts(fullEnabled: false)
        #expect(a.update(from: charging(99), to: held(100, charged: true)) == nil)
    }

    @Test func timeToEmptyFromIOPS() {
        let d: [String: Any] = ["Type": "InternalBattery", "Current Capacity": 55, "Max Capacity": 100,
                                "Power Source State": "Battery Power", "Is Charging": false, "Time to Empty": 190, "Time to Full Charge": 0]
        let s = PowerState.parse([d])
        #expect(s.minutesToEmpty == 190 && s.minutesRemaining == 190 && s.minutesToFull == nil)
        var estimating = d; estimating["Time to Empty"] = -1
        #expect(PowerState.parse([estimating]).minutesToEmpty == nil)
        var ac = d; ac["Power Source State"] = "AC Power"
        #expect(PowerState.parse([ac]).minutesToEmpty == nil)
    }
}

// MARK: Headphone batteries

@Suite struct HeadphoneBatteryTests {
    @Test func airPodsLeftRightCase() {
        let b = BluetoothBattery.fromDevice(["batteryPercentLeft": 82, "batteryPercentRight": 90, "batteryPercentCase": 40,
                                             "batteryPercentSingle": 0, "batteryPercentCombined": 86])
        #expect(b == BluetoothBattery(left: 82, right: 90, case: 40))
        #expect(b.headline == 82)
    }

    @Test func missingAndZeroKeysAreOmitted() {
        // Case out of range of the buds: 0 = unknown, never "0 %".
        let b = BluetoothBattery.fromDevice(["batteryPercentLeft": 70, "batteryPercentRight": 0, "batteryPercentCase": 0])
        #expect(b == BluetoothBattery(left: 70))
        #expect(BluetoothBattery.fromDevice([:]).isEmpty)
        #expect(BluetoothBattery.fromDevice(["batteryPercentLeft": 255]).isEmpty)
    }

    @Test func singleUnitHeadsets() {
        #expect(BluetoothBattery.fromDevice(["batteryPercentSingle": 64]) == BluetoothBattery(main: 64))   // AirPods Max, Beats Solo
        #expect(BluetoothBattery.fromDevice(["batteryPercentCombined": 50]) == BluetoothBattery(main: 50))
    }

    @Test func registryKeys() {
        #expect(BluetoothBattery.fromRegistry(["BatteryPercent": 47, "DeviceAddress": "aa-bb"]) == BluetoothBattery(main: 47))
        #expect(BluetoothBattery.fromRegistry(["BatteryPercentLeft": 10, "BatteryPercentRight": 20, "BatteryPercentCase": 30])
                == BluetoothBattery(left: 10, right: 20, case: 30))
        #expect(BluetoothBattery.fromRegistry(["Product": "Magic Mouse"]).isEmpty)
        #expect(BluetoothBattery.fromRegistry(["BatteryPercent": "47"]).isEmpty)
    }

    @Test func beatsAndAirPodsSymbols() {
        #expect(BluetoothIcon.symbol(name: "Beats Studio Buds") == "beats.studiobuds")
        #expect(BluetoothIcon.symbol(name: "Powerbeats Pro") == "beats.powerbeatspro")
        #expect(BluetoothIcon.symbol(name: "Beats Fit Pro") == "beats.fitpro")
        #expect(BluetoothIcon.symbol(name: "Beats Solo 4") == "beats.headphones")
        #expect(BluetoothIcon.symbol(name: "AirPods Max di Gianluca") == "airpodsmax")
        #expect(AudioDevice(id: 1, uid: "u", name: "AirPods Pro", hasInput: true, hasOutput: true, transport: .bluetooth).symbol == "airpodspro")
        #expect(AudioDevice(id: 1, uid: "u", name: "LG HDR 4K", hasInput: false, hasOutput: true, transport: .display).symbol == "display")
    }

    @Test func mergeFillsGaps() {
        let device = BluetoothBattery(left: 80, right: 81)
        let registry = BluetoothBattery(left: 10, case: 33)
        #expect(device.merged(with: registry) == BluetoothBattery(left: 80, right: 81, case: 33))
    }

    @Test @MainActor func budsLines() {
        L10n.apply(.en)
        #expect(PowerText.budsLine(BluetoothBattery(left: 82, right: 90, case: 40)) == "L 82%  R 90%  Case 40%")
        #expect(PowerText.budsLine(BluetoothBattery(left: 82)) == "82%")
        #expect(PowerText.budsLine(BluetoothBattery(main: 64)) == "64%")
        #expect(PowerText.budsLine(BluetoothBattery()) == nil)
    }
}

// MARK: Microphone

@Suite @MainActor struct MicMuteTests {
    @Test func muteControlToggle() {
        let sys = FakeAudioSystem.standard()
        let audio = AudioCenter(system: sys, defaults: freshDefaults())
        var events: [(Bool, Bool)] = []
        audio.onMicChange = { events.append(($0, $1)) }
        audio.start()
        #expect(!audio.micMuted && audio.micMutable && audio.defaultInput?.name == "MacBook Pro Microphone")
        #expect(audio.toggleMic() == true)
        #expect(audio.micMuted && sys.inputsState[10]?.mute == true)
        #expect(sys.inputsState[10]?.volume == 0.6)   // volume untouched with a mute control
        #expect(audio.toggleMic() == false)
        #expect(!audio.micMuted && sys.inputsState[10]?.mute == false)
        #expect(events.map(\.0) == [true, false] && events.allSatisfy(\.1))
    }

    @Test func volumeFallbackSavesAndRestores() {
        let sys = FakeAudioSystem.standard()
        sys.defaultIn = 11
        let defaults = freshDefaults()
        let audio = AudioCenter(system: sys, defaults: defaults)
        audio.start()
        #expect(audio.setMicMuted(true))
        #expect(audio.micMuted && sys.inputsState[11]?.volume == 0)
        // Kept in defaults: a relaunch (or crash) still knows the level to restore.
        let relaunched = AudioCenter(system: sys, defaults: defaults)
        relaunched.start()
        #expect(relaunched.micMuted && relaunched.savedVolumes["usb-mic"] == 0.8)
        #expect(relaunched.setMicMuted(false))
        #expect(sys.inputsState[11]?.volume == 0.8 && !relaunched.micMuted)
        #expect(relaunched.savedVolumes.isEmpty)
    }

    @Test func unmutedElsewhereIsFollowed() {
        let sys = FakeAudioSystem.standard()
        let audio = AudioCenter(system: sys, defaults: freshDefaults())
        var external: [Bool] = []
        audio.onMicChange = { muted, byUser in if !byUser { external.append(muted) } }
        audio.start()
        audio.setMicMuted(true)
        sys.inputsState[10]?.mute = false          // System Settings unmutes
        sys.fire(.inputLevel)
        #expect(!audio.micMuted && external == [false])
        // Muted elsewhere shows too.
        sys.inputsState[10]?.mute = true
        sys.fire(.inputLevel)
        #expect(audio.micMuted && external == [false, true])
    }

    @Test func aNewMicrophoneWhileMutedStaysMutedAndUnmuteRestoresAll() {
        let sys = FakeAudioSystem.standard()
        let audio = AudioCenter(system: sys, defaults: freshDefaults())
        audio.start()
        audio.setMicMuted(true)
        sys.defaultIn = 30                           // AirPods connect and become the input
        sys.fire(.defaultInput)
        #expect(audio.micMuted && sys.inputsState[30]?.mute == true)
        audio.setMicMuted(false)
        #expect(sys.inputsState[30]?.mute == false && sys.inputsState[10]?.mute == false)
    }

    @Test func stoppingRestoresWhatGlancyMuted() {
        let sys = FakeAudioSystem.standard()
        sys.defaultIn = 11
        let audio = AudioCenter(system: sys, defaults: freshDefaults())
        audio.start()
        audio.setMicMuted(true)
        audio.stop()
        #expect(sys.inputsState[11]?.volume == 0.8 && sys.observer == nil)
    }

    @Test func stoppingLeavesAMuteMadeElsewhere() {
        let sys = FakeAudioSystem.standard()
        sys.inputsState[10]?.mute = true
        let audio = AudioCenter(system: sys, defaults: freshDefaults())
        audio.start()
        #expect(audio.micMuted)
        audio.stop()
        #expect(sys.inputsState[10]?.mute == true && sys.writes.isEmpty)
    }

    @Test func noControlsNoMute() {
        let sys = FakeAudioSystem.standard()
        sys.inputsState[10] = .init(mute: nil, muteSettable: false, volume: nil, volumeSettable: false)
        let audio = AudioCenter(system: sys, defaults: freshDefaults())
        audio.start()
        #expect(!audio.micMutable && audio.toggleMic() == nil && sys.writes.isEmpty)
        sys.defaultIn = nil
        sys.fire(.defaultInput)
        #expect(audio.defaultInput == nil && audio.toggleMic() == nil)
    }

    @Test func outputSwitch() {
        let sys = FakeAudioSystem.standard()
        let audio = AudioCenter(system: sys, defaults: freshDefaults())
        audio.start()
        #expect(audio.outputs.map(\.name) == ["MacBook Pro Speakers", "AirPods Pro"])
        #expect(audio.inputs.map(\.id) == [10, 11, 30])
        #expect(audio.selectOutput(30) && audio.defaultOutput?.name == "AirPods Pro" && sys.writes == ["output 30"])
        #expect(!audio.selectOutput(10))           // an input, not an output
        sys.refuseOutput = true
        #expect(!audio.selectOutput(20) && audio.defaultOutputID == 30)
        sys.defaultOut = 20                         // changed in Control Centre
        sys.fire(.defaultOutput)
        #expect(audio.defaultOutputID == 20)
    }

    @Test func samplesNeverWrite() {
        let sys = FakeAudioSystem.standard()
        let audio = AudioCenter(system: sys, defaults: freshDefaults())
        audio.start()
        audio.setSample(muted: true)
        #expect(!audio.setMicMuted(false) && !audio.selectOutput(30))
        audio.stop()
        #expect(sys.writes.isEmpty)
    }
}

// MARK: In use

@Suite @MainActor struct InUseTests {
    @Test func inUseFollowsTheSystem() {
        let sys = FakeAudioSystem.standard()
        let audio = AudioCenter(system: sys, defaults: freshDefaults())
        var changes: [(Bool, Bool)] = []
        audio.onUseChange = { changes.append(($0, $1)) }
        audio.start()
        #expect(!audio.micUse.inUse && !audio.cameraInUse)
        sys.use = InputUse(inUse: true, apps: ["Zoom"])
        sys.fire(.inputUse)
        #expect(audio.micUse == InputUse(inUse: true, apps: ["Zoom"]))
        sys.fire(.inputUse)                          // same state: no second change
        sys.camera = true
        sys.fire(.camera)
        sys.use = InputUse()
        sys.camera = nil                             // camera unplugged: unknown = not in use
        sys.fire(.inputUse)
        #expect(changes.map(\.0) == [true, true, false] && changes.map(\.1) == [false, true, false])
    }

    func module(_ sys: FakeAudioSystem) -> (HUDModule, ActivityHub) {
        let settings = HUDSettings(defaults: freshDefaults("hud"))
        let m = HUDModule(settings: settings, usesHardware: false, audioSystem: sys)
        let hub = ActivityHub()
        m.start(hub: hub)
        return (m, hub)
    }

    @Test func dotWingWhileRecordingHiddenWhenOff() {
        let sys = FakeAudioSystem.standard()
        let (m, hub) = module(sys)
        defer { m.stop() }
        #expect(hub.top == nil)
        sys.use = InputUse(inUse: true)
        sys.fire(.inputUse)
        #expect(hub.top?.id == "hud.inuse" && hub.top?.priority == 35 && hub.top?.expires == nil)
        m.settings.showInUse = false
        #expect(hub.top == nil)
        m.settings.showInUse = true
        sys.use = InputUse()
        sys.fire(.inputUse)
        #expect(hub.top == nil)
    }

    @Test func mutedWingReplacesTheDotAndFlashes() throws {
        let sys = FakeAudioSystem.standard()
        sys.use = InputUse(inUse: true)
        let (m, hub) = module(sys)
        defer { m.stop() }
        #expect(hub.top?.id == "hud.inuse")
        m.toggleMic()
        // The 1.5 s confirmation on top (HUD priority), the muted wing beneath it, no dot activity.
        let top = try #require(hub.top)
        #expect(top.id == "hud.mic.flash" && top.priority == 75)
        #expect(hub.priority(of: .hud) == 75)
        hub.clear("hud.mic.flash")
        #expect(hub.top?.id == "hud.mic" && hub.top?.priority == 55 && hub.top?.expires == nil)
        m.toggleMic()
        hub.clear("hud.mic.flash")
        #expect(hub.top?.id == "hud.inuse")
        #expect(sys.inputsState[10]?.mute == false)
    }

    @Test func stopRestoresAndClears() {
        let sys = FakeAudioSystem.standard()
        let (m, hub) = module(sys)
        m.toggleMic()
        #expect(sys.inputsState[10]?.mute == true)
        m.stop()
        #expect(sys.inputsState[10]?.mute == false && hub.top == nil)
    }

    @Test func micHotkeyDefaultAndPersistence() {
        let d = freshDefaults()
        let s = HUDSettings(defaults: d)
        #expect(s.micHotkey == HUDSettings.defaultMicHotkey && s.micHotkey.description == "⌃⌥0" && s.showInUse)
        s.micHotkey = Hotkey(keyCode: 46, modifiers: s.micHotkey.modifiers | 256)
        s.showInUse = false
        let again = HUDSettings(defaults: d)
        #expect(again.micHotkey.description == "⌃⌥⌘M" && !again.showInUse)
    }

    @Test func defaultMicHotkeyIsFreeAmongGlancyDefaults() {
        let windows = WindowsHotkeys()
        let taken: [Hotkey] = [windows.autoArrange, windows.open, windows.leftHalf, windows.rightHalf, windows.maximize, windows.restore,
                               windows.fit, windows.undo, windows.arrangeBalanced, windows.arrangeColumns, windows.arrangeRows,
                               windows.arrangeMaster, windows.arrangeCells, ClipboardSettings.defaultHotkey]
        #expect(!taken.contains(HUDSettings.defaultMicHotkey))
        // ⌃⌥J / ⌃⌥K (other wave-4 lots) are different keys too.
        #expect(![38, 40].contains(HUDSettings.defaultMicHotkey.keyCode))
    }
}

// MARK: Command bar

@Suite @MainActor struct DevicesCommandTests {
    func hud(_ sys: FakeAudioSystem) -> HUDModule {
        let m = HUDModule(settings: HUDSettings(defaults: freshDefaults("cmd")), usesHardware: false, audioSystem: sys)
        m.start(hub: ActivityHub())
        return m
    }

    @Test func micAndOutputCommands() throws {
        L10n.apply(.en)
        let sys = FakeAudioSystem.standard()
        let m = hud(sys)
        defer { m.stop() }
        let cmds = m.commands()
        #expect(cmds.map(\.id) == ["hud.mic.toggle", "hud.output.airpods"])
        let mic = try #require(cmds.first)
        #expect(mic.title == "Mute microphone" && mic.subtitle == "MacBook Pro Microphone · ⌃⌥0" && !mic.closesPanel)
        mic.run()
        #expect(sys.inputsState[10]?.mute == true)
        #expect(m.commands().first?.title == "Unmute microphone")
        let out = try #require(cmds.last)
        #expect(out.title == "Play sound on AirPods Pro" && out.subtitle == "Now: MacBook Pro Speakers")
        out.run()
        #expect(sys.defaultOut == 30)
        // The current output is never offered.
        #expect(m.commands().map(\.id) == ["hud.mic.toggle", "hud.output.builtin-out"])
    }

    @Test func micAndOutputResultsEnglishAndItalian() {
        let sys = FakeAudioSystem.standard()
        let m = hud(sys)
        defer { m.stop() }
        #expect(m.results(for: "mic").map(\.id) == ["hud.mic.toggle"])
        #expect(m.results(for: "Microfono").map(\.id) == ["hud.mic.toggle"])
        #expect(m.results(for: "muto").map(\.id) == ["hud.mic.toggle"])
        #expect(m.results(for: "airp").map(\.id) == ["hud.output.airpods"])
        #expect(m.results(for: "uscita").map(\.id) == ["hud.output.airpods"])
        #expect(m.results(for: "airpods").first?.rank == 85)
        #expect(m.results(for: "x").isEmpty && m.results(for: "calendar").isEmpty)
    }

    @Test func italianTitles() {
        let sys = FakeAudioSystem.standard()
        let m = hud(sys)
        defer { m.stop(); L10n.apply(.en) }
        L10n.apply(.it)
        #expect(m.commands().map(\.title) == ["Silenzia microfono", "Riproduci audio su AirPods Pro"])
    }

    @Test func nothingWithoutAudio() {
        let m = HUDModule(settings: HUDSettings(defaults: freshDefaults("none")), usesHardware: false)
        #expect(m.commands().isEmpty && m.results(for: "mic").isEmpty)
    }

    func power(connected: [BluetoothDeviceInfo] = [], paired: [BluetoothDeviceInfo] = [], battery: PowerState) -> (PowerModule, ActivityHub) {
        let m = PowerModule(settings: PowerSettings(defaults: freshDefaults("power")))
        m.fixed = .init(battery: battery, devices: connected, paired: paired)
        let hub = ActivityHub()
        m.start(hub: hub)
        return (m, hub)
    }

    let pro = BluetoothDeviceInfo(address: "00:00:00:00:00:01", name: "AirPods Pro", symbol: "airpodspro", isAudio: true,
                                  battery: BluetoothBattery(left: 82, right: 90, case: 40))
    let max = BluetoothDeviceInfo(address: "00:00:00:00:00:02", name: "AirPods Max", symbol: "airpodsmax", isAudio: true, battery: BluetoothBattery())

    @Test func batteryHeadphonesAndConnect() throws {
        L10n.apply(.en)
        let (m, hub) = power(connected: [pro], paired: [pro, max],
                             battery: PowerState(hasBattery: true, percent: 64, onAC: false, minutesToEmpty: 200))
        defer { m.stop() }
        var opened: [ModuleID?] = []
        hub.onOpenRequest = { opened.append($0) }
        var connects: [String] = []
        m.connector = { connects.append($0); return true }

        let cmds = m.commands()
        #expect(cmds.map(\.id) == ["power.battery", "power.headphones.00:00:00:00:00:01", "power.connect.00:00:00:00:00:02"])
        #expect(cmds[0].title == "Battery 64%" && cmds[0].subtitle == "On battery · 3h 20m left")
        #expect(cmds[1].subtitle == "L 82%  R 90%  Case 40%")
        #expect(cmds[2].title == "Connect AirPods Max")
        cmds[0].run()
        #expect(opened == [.power])
        cmds[2].run()
        #expect(connects == ["00:00:00:00:00:02"] && m.model.connecting.contains("00:00:00:00:00:02"))
        // Not twice while connecting; never for a connected device.
        #expect(!m.connect("00:00:00:00:00:02") && !m.connect("00:00:00:00:00:01"))
    }

    @Test func resultsEnglishAndItalian() {
        let (m, _) = power(connected: [pro], paired: [pro, max], battery: PowerState(hasBattery: true, percent: 64, onAC: false))
        defer { m.stop() }
        #expect(m.results(for: "battery").map(\.id) == ["power.battery"])
        #expect(m.results(for: "batteria").map(\.id) == ["power.battery"])
        #expect(m.results(for: "batt").first?.rank == 80)
        let airpods = m.results(for: "airpods").map(\.id)
        #expect(airpods == ["power.headphones.00:00:00:00:00:01", "power.connect.00:00:00:00:00:02"])
        #expect(m.results(for: "cuffie").map(\.id) == airpods)
        // A name beats the generic word: the Max (by name) first, by rank.
        let max = m.results(for: "airpods max").sorted { $0.rank > $1.rank }.map(\.id)
        #expect(max.first == "power.connect.00:00:00:00:00:02")
        #expect(m.results(for: "collega").map(\.id) == ["power.connect.00:00:00:00:00:02"])
        #expect(m.results(for: "pro").map(\.id) == ["power.headphones.00:00:00:00:00:01"])
        #expect(m.results(for: "a").isEmpty && m.results(for: "calendar").isEmpty)
    }

    @Test func noBatteryNoBatteryCommand() {
        let (m, _) = power(battery: .noBattery)
        defer { m.stop() }
        #expect(m.commands().isEmpty && m.results(for: "battery").isEmpty)
    }
}

// MARK: Power module peeks

@Suite @MainActor struct PowerAlertPeekTests {
    @Test func lowAndFullArePeeksPlugIsAWing() throws {
        let m = PowerModule(settings: PowerSettings(defaults: freshDefaults()))
        m.fixed = .init(battery: .noBattery, devices: [])
        let hub = ActivityHub()
        m.start(hub: hub)
        defer { m.stop() }
        m.apply(PowerState(hasBattery: true, percent: 21, onAC: false))
        #expect(hub.peek == nil && hub.top == nil)
        m.apply(PowerState(hasBattery: true, percent: 20, onAC: false, minutesToEmpty: 95))
        #expect(hub.peek?.module == .power && hub.top == nil)
        m.apply(PowerState(hasBattery: true, percent: 20, onAC: true, isCharging: true, minutesToFull: 70))
        #expect(hub.top?.id == "power" && hub.top?.priority == 60)
        #expect(m.model.battery.minutesToFull == 70)
    }

    @Test func settingsThresholds() {
        let d = freshDefaults()
        let s = PowerSettings(defaults: d)
        #expect(s.thresholds == [20, 10] && s.fullAlert)
        s.lowFirst = 25; s.lowSecond = 25
        #expect(s.thresholds == [25])
        s.lowAlerts = false
        #expect(s.thresholds.isEmpty)
        #expect(PowerSettings(defaults: d).lowFirst == 25)
    }
}
