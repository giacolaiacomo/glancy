import CoreBluetooth
import Foundation
import IOKit.ps
import SwiftUI

/// Power preferences (Settings → Power). Everything on by default; low warnings at 20 and 10 %.
@MainActor @Observable
public final class PowerSettings {
    public static let batteryKey = "glancy.power.batteryActivities"
    public static let bluetoothKey = "glancy.power.bluetoothPeeks"
    public static let lowAlertsKey = "glancy.power.lowAlerts"
    public static let lowFirstKey = "glancy.power.lowFirst"
    public static let lowSecondKey = "glancy.power.lowSecond"
    public static let fullAlertKey = "glancy.power.fullAlert"
    /// The levels offered for the two low warnings.
    public static let lowChoices = [5, 10, 15, 20, 25, 30]

    /// Plug / unplug / Low Power Mode in the wings.
    public var batteryActivities: Bool { didSet { defaults.set(batteryActivities, forKey: Self.batteryKey) } }
    /// A peek when headphones connect.
    public var bluetoothPeeks: Bool { didSet { defaults.set(bluetoothPeeks, forKey: Self.bluetoothKey) } }
    /// A peek when the battery reaches `lowFirst` and `lowSecond` on battery power.
    public var lowAlerts: Bool { didSet { defaults.set(lowAlerts, forKey: Self.lowAlertsKey); onChange?() } }
    public var lowFirst: Int { didSet { defaults.set(lowFirst, forKey: Self.lowFirstKey); onChange?() } }
    public var lowSecond: Int { didSet { defaults.set(lowSecond, forKey: Self.lowSecondKey); onChange?() } }
    /// A peek when charging completes (100 % or the charge limit).
    public var fullAlert: Bool { didSet { defaults.set(fullAlert, forKey: Self.fullAlertKey); onChange?() } }
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        batteryActivities = defaults.object(forKey: Self.batteryKey) as? Bool ?? true
        bluetoothPeeks = defaults.object(forKey: Self.bluetoothKey) as? Bool ?? true
        lowAlerts = defaults.object(forKey: Self.lowAlertsKey) as? Bool ?? true
        lowFirst = defaults.object(forKey: Self.lowFirstKey) as? Int ?? 20
        lowSecond = defaults.object(forKey: Self.lowSecondKey) as? Int ?? 10
        fullAlert = defaults.object(forKey: Self.fullAlertKey) as? Bool ?? true
    }

    /// The low thresholds in force, highest first, without duplicates.
    public var thresholds: [Int] { lowAlerts ? Array(Set([lowFirst, lowSecond])).sorted(by: >) : [] }
}

/// A connected Bluetooth device worth showing.
public struct BluetoothDeviceInfo: Equatable, Identifiable, Sendable {
    public var id: String { address }
    public var address: String
    public var name: String
    public var symbol: String
    public var isAudio: Bool
    public var battery: BluetoothBattery

    public init(address: String, name: String, symbol: String, isAudio: Bool, battery: BluetoothBattery) {
        self.address = address; self.name = name; self.symbol = symbol; self.isAudio = isAudio; self.battery = battery
    }
}

@MainActor @Observable
public final class PowerModel {
    public internal(set) var battery: PowerState = .noBattery
    /// Connected devices by normalised address.
    public internal(set) var devices: [String: BluetoothDeviceInfo] = [:]
    /// Paired headphones / speakers, connected or not (Connect offers the others).
    public internal(set) var pairedAudio: [BluetoothDeviceInfo] = []
    /// Addresses being connected right now.
    public internal(set) var connecting: Set<String> = []
    public init() {}

    /// The connected headphones with a known battery, if any (the Home card shows them).
    public var headphones: BluetoothDeviceInfo? {
        devices.values.filter { $0.isAudio && $0.battery.headline != nil }.min { $0.name < $1.name }
    }
    /// Every connected audio device, battery known or not.
    public var audioDevices: [BluetoothDeviceInfo] {
        devices.values.filter(\.isAudio).sorted { $0.name < $1.name }
    }
    /// Paired audio devices that are not connected.
    public var connectable: [BluetoothDeviceInfo] {
        pairedAudio.filter { devices[$0.address] == nil }
    }
    public var isNotable: Bool { PowerLogic.isNotable(battery, headphonesWithBattery: headphones != nil) }
}

/// Battery / charging / Low Power Mode and Bluetooth connections. Everything from OS callbacks:
/// the IOPS run-loop source, the power-state notification, IOBluetooth connect/disconnect.
/// Headphone batteries are read in-process from IOBluetooth on connect (twice, as the buds report
/// a moment later) and each time the panel opens; `system_profiler` runs only when IOBluetooth
/// and IORegistry know nothing.
@MainActor
public final class PowerModule: GlancyModule {
    public let id: ModuleID = .power
    public let settings: PowerSettings
    public let model = PowerModel()
    /// The HUD module, for the microphone and output controls in the Devices tab (weak: turning
    /// the HUD off just hides them). Linked in `Modules.make()`.
    public weak var sound: HUDModule?

    static let activityID = "power"
    static let profilerMaxAge: TimeInterval = 5 * 60
    static let peekDuration: TimeInterval = 3
    static let alertDuration: TimeInterval = 4
    /// Battery reads after a connection: buds report their levels a moment after the link is up.
    static let connectReads: [TimeInterval] = [1, 4]

    private var hub: ActivityHub?
    private var started = false
    private var powerSource: CFRunLoopSource?
    private var lpmObserver: NSObjectProtocol?
    private var previous: PowerState?
    private(set) var alerts = BatteryAlerts()
    private let bluetooth = BluetoothWatcher()
    private var profilerCache: [String: BluetoothBattery] = [:]
    private var profiledAt: Date?
    private var profilerTask: Task<Void, Never>?
    private var profilerRun: BluetoothBatteryReader.ProfilerRun?
    private var readTasks: [String: Task<Void, Never>] = [:]

    /// Demo images, `--self-test` and tests: a fixed battery and devices; no IOKit, Bluetooth or
    /// system_profiler, so no real device names can show.
    struct Fixed {
        var battery: PowerState
        var devices: [BluetoothDeviceInfo]
        var paired: [BluetoothDeviceInfo] = []
    }
    var fixed: Fixed?
    /// Tests: replaces IOBluetooth's `openConnection`.
    var connector: ((String) -> Bool)?

    public convenience init() { self.init(settings: PowerSettings()) }
    public init(settings: PowerSettings) { self.settings = settings }

    // MARK: Lifecycle

    public func start(hub: ActivityHub) {
        guard !started else { return }
        started = true
        self.hub = hub
        L10n.addItalian(powerItalian)
        alerts = BatteryAlerts(thresholds: settings.thresholds, fullEnabled: settings.fullAlert)
        settings.onChange = { [weak self] in
            guard let self else { return }
            self.alerts.configure(thresholds: self.settings.thresholds, fullEnabled: self.settings.fullAlert)
        }
        if let fixed {
            model.battery = fixed.battery
            for d in fixed.devices { model.devices[d.address] = d }
            model.pairedAudio = fixed.paired
            return
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let module = Unmanaged<PowerModule>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { module.powerChanged() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            powerSource = source
        }
        lpmObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.powerChanged() }
        }
        powerChanged()

        bluetooth.onConnect = { [weak self] d in self?.connected(d) }
        bluetooth.onDisconnect = { [weak self] d in self?.disconnected(d) }
        bluetooth.onPairedChange = { [weak self] in self?.pairedChanged() }
        bluetooth.onConnectResult = { [weak self] address, _ in self?.model.connecting.remove(address) }
        bluetooth.start()
        for d in bluetooth.connected.values { add(d) }
        pairedChanged()
        refreshBatteries()
    }

    public func stop() {
        started = false
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        powerSource = nil
        if let lpmObserver { NotificationCenter.default.removeObserver(lpmObserver) }
        lpmObserver = nil
        settings.onChange = nil
        bluetooth.stop()
        bluetooth.onConnect = nil; bluetooth.onDisconnect = nil
        bluetooth.onPairedChange = nil; bluetooth.onConnectResult = nil
        profilerTask?.cancel(); profilerTask = nil
        profilerRun?.cancel(); profilerRun = nil
        readTasks.values.forEach { $0.cancel() }
        readTasks = [:]
        model.devices = [:]
        model.pairedAudio = []
        model.connecting = []
        previous = nil
        hub?.clear(Self.activityID)
        hub = nil
    }

    public func visibilityChanged(_ visibility: SurfaceVisibility) {
        guard started, fixed == nil, case .expanded = visibility else { return }
        // While the panel is open, batteries may refresh: in-process reads every open,
        // system_profiler (only when those know nothing) at most every 5 minutes.
        refreshBatteries()
        let unknown = model.devices.values.contains { $0.isAudio && $0.battery.isEmpty }
        if unknown, profiledAt.map({ Date.now.timeIntervalSince($0) > Self.profilerMaxAge }) ?? true {
            profile(after: 0)
        }
    }

    // MARK: Permissions

    /// A permission may have changed: start watching Bluetooth once it is allowed (no relaunch)
    /// and show the devices already connected.
    public func permissionsChanged() {
        // Only once allowed: never re-ask for Bluetooth because another permission changed.
        guard started, fixed == nil, BluetoothWatcher.isUsable, CBManager.authorization == .allowedAlways else { return }
        bluetooth.start()
        for d in bluetooth.connected.values where model.devices[d.address] == nil { add(d) }
        pairedChanged()
        refreshBatteries()
    }

    // MARK: Battery

    private func powerChanged() {
        guard started else { return }
        apply(Self.readPower())
    }

    /// One state from IOPS (or a test): wings for plug / unplug / Low Power Mode, peeks for low / full.
    func apply(_ state: PowerState) {
        let event = PowerLogic.transition(from: previous, to: state)
        let alert = alerts.update(from: previous, to: state)
        previous = state
        if model.battery != state { model.battery = state }
        if let event, settings.batteryActivities { post(event) }
        if let alert { show(alert) }
    }

    static func readPower() -> PowerState {
        let lpm = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return PowerState.parse([], lowPowerMode: lpm)
        }
        let sources = list.compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
        return PowerState.parse(sources, lowPowerMode: lpm)
    }

    private func post(_ event: PowerEvent) {
        guard let hub else { return }
        let now = Date.now
        hub.post(LiveActivity(
            id: Self.activityID, module: .power, priority: PowerLogic.activityPriority, updated: now,
            expires: now.addingTimeInterval(PowerLogic.activityDuration),
            left: AnyView(PowerWingLeft(event: event, model: model)),
            right: AnyView(PowerWingRight(event: event, model: model))))
    }

    private func show(_ alert: BatteryAlert) {
        hub?.show(PeekEvent(module: .power, duration: Self.alertDuration, content: AnyView(BatteryAlertPeek(alert: alert, model: model))))
    }

    // MARK: Bluetooth

    private func connected(_ d: BluetoothWatcher.Device) {
        add(d)
        model.connecting.remove(d.address)
        if d.isAudio {
            if settings.bluetoothPeeks, let hub {
                hub.show(PeekEvent(module: .power, duration: Self.peekDuration,
                                   content: AnyView(BluetoothPeek(model: model, address: d.address))))
            }
            scheduleReads(d.address)
        } else {
            refreshBatteries()
        }
    }

    private func disconnected(_ d: BluetoothWatcher.Device) {
        readTasks.removeValue(forKey: d.address)?.cancel()
        model.devices.removeValue(forKey: d.address)
    }

    /// Two one-shot reads after a connection; then system_profiler once if nothing in-process
    /// knows the battery.
    private func scheduleReads(_ address: String) {
        readTasks[address]?.cancel()
        readTasks[address] = Task { [weak self] in
            var elapsed: TimeInterval = 0
            for at in Self.connectReads {
                try? await Delay.sleep(for: .seconds(at - elapsed))
                elapsed = at
                guard !Task.isCancelled, let self else { return }
                self.refreshBatteries()
            }
            guard !Task.isCancelled, let self else { return }
            self.readTasks[address] = nil
            if self.model.devices[address]?.battery.isEmpty == true { self.profile(after: 0) }
        }
    }

    private func add(_ d: BluetoothWatcher.Device) {
        model.devices[d.address] = BluetoothDeviceInfo(
            address: d.address, name: d.name, symbol: BluetoothIcon.symbol(name: d.name, isAudio: d.isAudio),
            isAudio: d.isAudio, battery: profilerCache[d.address] ?? BluetoothBattery())
    }

    private func pairedChanged() {
        let list = bluetooth.pairedAudio.map {
            BluetoothDeviceInfo(address: $0.address, name: $0.name, symbol: BluetoothIcon.symbol(name: $0.name), isAudio: true, battery: BluetoothBattery())
        }
        if list != model.pairedAudio { model.pairedAudio = list }
    }

    /// In-process reads: IOBluetooth battery properties for audio, IORegistry for the rest.
    func refreshBatteries() {
        guard fixed == nil, !model.devices.isEmpty else { return }
        let registry = BluetoothBatteryReader.registryBatteries()
        for (address, var info) in model.devices {
            var fresh = registry[address] ?? BluetoothBattery()
            if info.isAudio { fresh = bluetooth.battery(of: address).merged(with: fresh) }
            guard !fresh.isEmpty else { continue }
            info.battery = fresh
            if model.devices[address] != info { model.devices[address] = info }
        }
    }

    private func profile(after delay: TimeInterval) {
        guard profilerTask == nil else { return }
        let run = BluetoothBatteryReader.ProfilerRun()
        profilerRun = run
        profilerTask = Task { [weak self] in
            if delay > 0 { try? await Delay.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            let devices = await run.run()
            guard !Task.isCancelled, let self else { return }
            self.profiled(devices)
        }
    }

    private func profiled(_ devices: [ProfiledBluetoothDevice]) {
        profilerTask = nil
        profilerRun = nil
        profiledAt = .now
        for p in devices where !p.battery.isEmpty { profilerCache[p.address] = p.battery }
        for p in devices where p.connected {
            guard var info = model.devices[p.address] else { continue }
            if !p.battery.isEmpty, info.battery.isEmpty { info.battery = p.battery }
            info.symbol = BluetoothIcon.symbol(name: info.name, minorType: p.minorType, isAudio: info.isAudio)
            if model.devices[p.address] != info { model.devices[p.address] = info }
        }
    }

    /// Connects a paired headset (asynchronous; the connect notification brings the peek).
    @discardableResult
    public func connect(_ address: String) -> Bool {
        guard model.devices[address] == nil, !model.connecting.contains(address) else { return false }
        let ok = connector?(address) ?? bluetooth.connect(address)
        if ok { model.connecting.insert(address) }
        return ok
    }

    // MARK: Surface

    public var tab: PanelTab? {
        PanelTab(module: .power, symbol: "headphones", title: LocalizedStringKey(L10n.tr("Devices"))) { [unowned self] in
            AnyView(DevicesTab(model: self.model, sound: self.sound, connect: { [weak self] in self?.connect($0) }))
        }
    }

    public func homeCard() -> AnyView? {
        guard model.isNotable else { return nil }
        return AnyView(PowerHomeCard(model: model))
    }

    /// At rest (Always): the battery level and what it is doing (time left, on the adapter,
    /// charged), from the IOKit power-source callbacks already running. A Mac without a battery
    /// has nothing to show.
    public func homeIdleCard(_ widget: HomeWidget) -> AnyView? {
        let b = model.battery
        guard widget == .power, b.hasBattery else { return nil }
        return AnyView(HomeIdleRow(symbol: PowerLogic.batterySymbol(b.percent, charging: b.isCharging),
                                   caption: L10n.tr("Battery"), title: "\(b.percent)%", detail: PowerText.status(b),
                                   open: { [weak self] in self?.hub?.requestOpen(.power) }))
    }

    /// For renders and previews: shows a sample activity / peek without touching any hardware.
    public func showSample(_ event: PowerEvent = .pluggedIn, state: PowerState? = nil) {
        model.battery = state ?? PowerState(hasBattery: true, percent: 80, onAC: true, isCharging: true, minutesToFull: 84)
        post(event)
    }

    public func showSamplePeek(name: String = "AirPods Pro", battery: BluetoothBattery = BluetoothBattery(left: 82, right: 90, case: 40)) {
        let address = "00:00:00:00:00:01"
        model.devices[address] = BluetoothDeviceInfo(address: address, name: name, symbol: BluetoothIcon.symbol(name: name),
                                                     isAudio: true, battery: battery)
        hub?.show(PeekEvent(module: .power, duration: Self.peekDuration, content: AnyView(BluetoothPeek(model: model, address: address))))
    }

    /// For renders: a low or full peek on a sample battery.
    public func showSampleAlert(_ alert: BatteryAlert) {
        switch alert {
        case .low(let t): model.battery = PowerState(hasBattery: true, percent: t, onAC: false, minutesToEmpty: t * 6)
        case .full(let limit): model.battery = PowerState(hasBattery: true, percent: limit ?? 100, onAC: true, isCharged: limit == nil)
        }
        show(alert)
    }

    /// For renders: fixed devices (battery, headphones, paired) without hardware.
    public func prepareForRender(battery: PowerState, devices: [BluetoothDeviceInfo], paired: [BluetoothDeviceInfo] = []) {
        model.battery = battery
        model.devices = Dictionary(devices.map { ($0.address, $0) }, uniquingKeysWith: { _, last in last })
        model.pairedAudio = paired
    }

    // MARK: Command bar

    public func commands() -> [GlancyCommand] {
        var out: [GlancyCommand] = []
        if let b = batteryCommand(rank: 0) { out.append(b) }
        out += model.audioDevices.map { headphonesCommand($0, rank: 0) }
        out += model.connectable.map { connectCommand($0, rank: 0) }
        return out
    }

    public func results(for query: String) -> [GlancyCommand] {
        let q = PowerCommands.normalise(query)
        guard q.count >= 2 else { return [] }
        var out: [GlancyCommand] = []
        if PowerCommands.matches(q, PowerCommands.batteryWords), let b = batteryCommand(rank: 80) { out.append(b) }
        let headphoneWord = PowerCommands.matches(q, PowerCommands.headphoneWords)
        let connectWord = PowerCommands.matches(q, PowerCommands.connectWords)
        for d in model.audioDevices where headphoneWord || PowerCommands.nameMatches(q, d.name) {
            out.append(headphonesCommand(d, rank: PowerCommands.nameMatches(q, d.name) ? 90 : 70))
        }
        for d in model.connectable where headphoneWord || connectWord || PowerCommands.nameMatches(q, d.name) {
            out.append(connectCommand(d, rank: PowerCommands.nameMatches(q, d.name) ? 85 : 60))
        }
        return out
    }

    private func batteryCommand(rank: Int) -> GlancyCommand? {
        let b = model.battery
        guard b.hasBattery else { return nil }
        return GlancyCommand(id: "power.battery", module: .power, title: L10n.tr("Battery %d%%", b.percent),
                             subtitle: PowerText.status(b), symbol: PowerLogic.batterySymbol(b.percent, charging: b.isCharging),
                             keywords: PowerCommands.batteryWords, rank: rank, closesPanel: false) { [weak self] in
            self?.hub?.requestOpen(.power)
        }
    }

    private func headphonesCommand(_ d: BluetoothDeviceInfo, rank: Int) -> GlancyCommand {
        GlancyCommand(id: "power.headphones.\(d.address)", module: .power, title: d.name,
                      subtitle: PowerText.budsLine(d.battery) ?? L10n.tr("Connected"), symbol: d.symbol,
                      keywords: PowerCommands.headphoneWords, rank: rank, closesPanel: false) { [weak self] in
            self?.hub?.requestOpen(.power)
        }
    }

    private func connectCommand(_ d: BluetoothDeviceInfo, rank: Int) -> GlancyCommand {
        GlancyCommand(id: "power.connect.\(d.address)", module: .power, title: L10n.tr("Connect %@", d.name),
                      subtitle: L10n.tr("Paired, not connected"), symbol: d.symbol,
                      keywords: PowerCommands.headphoneWords + PowerCommands.connectWords, rank: rank) { [weak self] in
            self?.connect(d.address)
        }
    }
}

/// Matching for the command bar (EN + IT).
enum PowerCommands {
    static let batteryWords = ["battery", "batteria", "charge", "charging", "carica", "power", "energia", "alimentazione"]
    static let headphoneWords = ["airpods", "headphones", "headset", "earbuds", "cuffie", "auricolari", "beats", "bluetooth"]
    static let connectWords = ["connect", "collega", "connetti"]

    static func normalise(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The query is the start of a word ("batt", "cuff"), or one of its words of 3+ letters is.
    static func matches(_ q: String, _ words: [String]) -> Bool {
        let parts = q.split(separator: " ").map(String.init).filter { $0.count >= 3 }
        return words.contains { w in w.hasPrefix(q) || parts.contains { w.hasPrefix($0) } }
    }

    static func nameMatches(_ q: String, _ name: String) -> Bool {
        normalise(name).contains(q)
    }
}

let powerItalian: [String: String] = [
    "Charging": "In carica",
    "Charged": "Carica completa",
    "Low battery": "Batteria scarica",
    "Low Power": "Risparmio energetico",
    "Low Power Mode": "Risparmio energetico",
    "Full in %@": "Piena tra %@",
    "%@ left": "%@ rimanenti",
    "Connected": "Collegato",
    "L %d%%  R %d%%": "S %d%%  D %d%%",
    "Case": "Custodia",
    "L": "S",
    "R": "D",
    "Devices": "Dispositivi",
    "Battery %d%%": "Batteria %d%%",
    "Connect %@": "Collega %@",
    "Connecting…": "Collegamento…",
    "Connect": "Collega",
    "Paired, not connected": "Abbinato, non collegato",
    "Fully charged": "Carica completa",
    "Charged to %d%%": "Carica al %d%%",
    "Charge limit reached": "Limite di carica raggiunto",
    "On battery": "A batteria",
    "Power adapter": "Alimentatore",
    "Not charging": "Non in carica",
    "No battery": "Nessuna batteria",
    "This Mac": "Questo Mac",
    "Headphones": "Cuffie",
    "No headphones connected": "Nessuna cuffia collegata",
    "Battery unknown": "Batteria non disponibile",
]
