import CoreBluetooth
import Foundation
import IOKit.ps
import SwiftUI

/// Power preferences (Settings → Power). Both on by default.
@MainActor @Observable
public final class PowerSettings {
    public static let batteryKey = "glancy.power.batteryActivities"
    public static let bluetoothKey = "glancy.power.bluetoothPeeks"
    /// Plug / unplug / low battery / Low Power Mode in the wings.
    public var batteryActivities: Bool { didSet { defaults.set(batteryActivities, forKey: Self.batteryKey) } }
    /// A peek when headphones connect.
    public var bluetoothPeeks: Bool { didSet { defaults.set(bluetoothPeeks, forKey: Self.bluetoothKey) } }
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        batteryActivities = defaults.object(forKey: Self.batteryKey) as? Bool ?? true
        bluetoothPeeks = defaults.object(forKey: Self.bluetoothKey) as? Bool ?? true
    }
}

/// A connected Bluetooth device worth showing.
public struct BluetoothDeviceInfo: Equatable, Identifiable, Sendable {
    public var id: String { address }
    public var address: String
    public var name: String
    public var symbol: String
    public var isAudio: Bool
    public var battery: BluetoothBattery
}

@MainActor @Observable
public final class PowerModel {
    public internal(set) var battery: PowerState = .noBattery
    /// Connected devices by normalised address.
    public internal(set) var devices: [String: BluetoothDeviceInfo] = [:]
    public init() {}

    /// The connected headphones with a known battery, if any (the Home card shows them).
    public var headphones: BluetoothDeviceInfo? {
        devices.values.filter { $0.isAudio && $0.battery.headline != nil }.min { $0.name < $1.name }
    }
    public var isNotable: Bool { PowerLogic.isNotable(battery, headphonesWithBattery: headphones != nil) }
}

/// Battery / charging / Low Power Mode and Bluetooth connections. Everything from OS callbacks:
/// the IOPS run-loop source, the power-state notification, IOBluetooth connect/disconnect.
@MainActor
public final class PowerModule: GlancyModule {
    public let id: ModuleID = .power
    public let settings: PowerSettings
    public let model = PowerModel()

    static let activityID = "power"
    static let profilerMaxAge: TimeInterval = 5 * 60
    static let peekDuration: TimeInterval = 3

    private var hub: ActivityHub?
    private var started = false
    private var powerSource: CFRunLoopSource?
    private var lpmObserver: NSObjectProtocol?
    private var previous: PowerState?
    private var lowWarned = false
    private let bluetooth = BluetoothWatcher()
    private var profilerCache: [String: BluetoothBattery] = [:]
    private var profiledAt: Date?
    private var profilerTask: Task<Void, Never>?
    private var profilerRun: BluetoothBatteryReader.ProfilerRun?

    /// Demo images and `--self-test`: a fixed battery and devices; no IOKit, Bluetooth or
    /// system_profiler, so no real device names can show.
    struct Fixed { var battery: PowerState; var devices: [BluetoothDeviceInfo] }
    var fixed: Fixed?

    public convenience init() { self.init(settings: PowerSettings()) }
    public init(settings: PowerSettings) { self.settings = settings }

    // MARK: Lifecycle

    public func start(hub: ActivityHub) {
        guard !started else { return }
        started = true
        self.hub = hub
        L10n.addItalian(powerItalian)
        if let fixed {
            model.battery = fixed.battery
            for d in fixed.devices { model.devices[d.address] = d }
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
        bluetooth.onDisconnect = { [weak self] d in self?.model.devices.removeValue(forKey: d.address) }
        bluetooth.start()
        for d in bluetooth.connected.values { add(d) }
        refreshMagic()
    }

    public func stop() {
        started = false
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        powerSource = nil
        if let lpmObserver { NotificationCenter.default.removeObserver(lpmObserver) }
        lpmObserver = nil
        bluetooth.stop()
        bluetooth.onConnect = nil; bluetooth.onDisconnect = nil
        profilerTask?.cancel(); profilerTask = nil
        profilerRun?.cancel(); profilerRun = nil
        model.devices = [:]
        previous = nil
        hub?.clear(Self.activityID)
        hub = nil
    }

    public func visibilityChanged(_ visibility: SurfaceVisibility) {
        guard started, case .expanded = visibility else { return }
        // While the panel is open, batteries may refresh: AirPods at most every 5 minutes.
        if model.devices.values.contains(where: \.isAudio),
           profiledAt.map({ Date.now.timeIntervalSince($0) > Self.profilerMaxAge }) ?? true {
            profile(after: 0)
        }
        refreshMagic()
    }

    // MARK: Permissions

    /// A permission may have changed: start watching Bluetooth once it is allowed (no relaunch)
    /// and show the devices already connected.
    public func permissionsChanged() {
        // Only once allowed: never re-ask for Bluetooth because another permission changed.
        guard started, BluetoothWatcher.isUsable, CBManager.authorization == .allowedAlways else { return }
        bluetooth.start()
        for d in bluetooth.connected.values where model.devices[d.address] == nil { add(d) }
    }

    // MARK: Battery

    private func powerChanged() {
        guard started else { return }
        let state = Self.readPower()
        let (event, warned) = PowerLogic.transition(from: previous, to: state, lowWarned: lowWarned)
        previous = state
        lowWarned = warned
        if model.battery != state { model.battery = state }
        if let event, settings.batteryActivities { post(event, state) }
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

    private func post(_ event: PowerEvent, _ state: PowerState) {
        guard let hub else { return }
        let now = Date.now
        hub.post(LiveActivity(
            id: Self.activityID, module: .power, priority: PowerLogic.activityPriority, updated: now,
            expires: now.addingTimeInterval(PowerLogic.activityDuration),
            left: AnyView(PowerWingLeft(event: event, state: state)),
            right: AnyView(PowerWingRight(event: event, state: state))))
    }

    // MARK: Bluetooth

    private func connected(_ d: BluetoothWatcher.Device) {
        add(d)
        if d.isAudio {
            if settings.bluetoothPeeks, let hub {
                hub.show(PeekEvent(module: .power, duration: Self.peekDuration,
                                   content: AnyView(BluetoothPeek(model: model, address: d.address))))
            }
            // Give the buds a moment to report, then one system_profiler run.
            profile(after: 1)
        } else {
            refreshMagic()
        }
    }

    private func add(_ d: BluetoothWatcher.Device) {
        model.devices[d.address] = BluetoothDeviceInfo(
            address: d.address, name: d.name, symbol: BluetoothIcon.symbol(name: d.name, isAudio: d.isAudio),
            isAudio: d.isAudio, battery: profilerCache[d.address] ?? BluetoothBattery())
    }

    private func profile(after delay: TimeInterval) {
        guard profilerTask == nil else { return }
        let run = BluetoothBatteryReader.ProfilerRun()
        profilerRun = run
        profilerTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
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
            if !p.battery.isEmpty, info.battery != p.battery { info.battery = p.battery }
            info.symbol = BluetoothIcon.symbol(name: info.name, minorType: p.minorType, isAudio: info.isAudio)
            if model.devices[p.address] != info { model.devices[p.address] = info }
        }
    }

    private func refreshMagic() {
        guard model.devices.values.contains(where: { !$0.isAudio }) else { return }
        for (address, magic) in BluetoothBatteryReader.magicBatteries() {
            guard var info = model.devices[address] else { continue }
            info.battery.main = magic.percent
            if model.devices[address] != info { model.devices[address] = info }
        }
    }

    // MARK: Surface

    public func homeCard() -> AnyView? {
        guard model.isNotable else { return nil }
        return AnyView(PowerHomeCard(model: model))
    }

    /// For renders and previews: shows a sample activity / peek without touching any hardware.
    public func showSample(_ event: PowerEvent = .pluggedIn, state: PowerState? = nil) {
        post(event, state ?? PowerState(hasBattery: true, percent: 80, onAC: true, isCharging: true))
    }

    public func showSamplePeek(name: String = "AirPods Pro", battery: BluetoothBattery = BluetoothBattery(left: 82, right: 90, case: 40)) {
        let address = "00:00:00:00:00:01"
        model.devices[address] = BluetoothDeviceInfo(address: address, name: name, symbol: BluetoothIcon.symbol(name: name),
                                                     isAudio: true, battery: battery)
        hub?.show(PeekEvent(module: .power, duration: Self.peekDuration, content: AnyView(BluetoothPeek(model: model, address: address))))
    }
}

let powerItalian: [String: String] = [
    "Charging": "In carica",
    "Charged": "Carica completa",
    "Low battery": "Batteria scarica",
    "Low Power": "Risparmio energetico",
    "Full in %@": "Piena tra %@",
    "Connected": "Collegato",
    "L %d%%  R %d%%": "S %d%%  D %d%%",
    "Case": "Custodia",
]
