import CoreBluetooth
import Foundation
import IOBluetooth
import IOKit

/// Connect / disconnect notifications from IOBluetooth. No polling: one connect registration plus
/// one disconnect registration per connected device. IOBluetooth calls the selectors on its own
/// coordinator queue (CoreBluetooth's XPC replies), not on main: the `@objc` entry points are
/// `nonisolated`, copy what they need and hop to main (a main-actor `@objc` method trapped there —
/// four crash reports of 2026-10-05).
@MainActor
final class BluetoothWatcher: NSObject {
    struct Device: Equatable {
        var address: String       // normalised
        var name: String
        var isAudio: Bool
    }

    var onConnect: ((Device) -> Void)?
    var onDisconnect: ((Device) -> Void)?
    /// A paired-devices list changed (refreshed on connect / disconnect only).
    var onPairedChange: (() -> Void)?
    /// An `openConnection` finished: address, success.
    var onConnectResult: ((String, Bool) -> Void)?
    private(set) var connected: [String: Device] = [:]
    /// Paired audio devices (headphones, speakers), connected or not.
    private(set) var pairedAudio: [Device] = []
    private(set) var isWatching = false
    private var connectNote: IOBluetoothUserNotification?
    private var disconnectNotes: [String: IOBluetoothUserNotification] = [:]

    /// IOBluetooth needs `NSBluetoothAlwaysUsageDescription` in Info.plist: without it macOS kills
    /// the process on first use. So command-line hosts (tests, renders) never touch it.
    nonisolated static var isUsable: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil
    }

    /// Only reached once Bluetooth is authorized: before that, IOBluetooth calls block the calling
    /// thread until the user answers the system prompt — at launch that froze the whole app.
    private var central: CBCentralManager?

    func start() {
        guard connectNote == nil, Self.isUsable else { return }
        switch CBManager.authorization {
        case .allowedAlways:
            startWatching()
        case .notDetermined:
            // Ask without blocking: CoreBluetooth shows the prompt and reports back on main.
            if central == nil { central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false]) }
        default:
            return   // denied / restricted: headphones are simply not shown
        }
    }

    private func startWatching() {
        guard connectNote == nil else { return }
        central = nil
        isWatching = true
        // Devices already connected at launch are known silently (no peek), then watched.
        for case let d as IOBluetoothDevice in IOBluetoothDevice.pairedDevices() ?? [] where d.isConnected() {
            track(d)
        }
        refreshPaired()
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(didConnect(_:device:)))
    }

    private func refreshPaired() {
        let list = (IOBluetoothDevice.pairedDevices() ?? []).compactMap { $0 as? IOBluetoothDevice }
            .filter { $0.deviceClassMajor == UInt32(kBluetoothDeviceClassMajorAudio) }
            .compactMap { d -> Device? in
                guard let raw = d.addressString else { return nil }
                return Device(address: BluetoothProfiler.normaliseAddress(raw), name: d.name ?? raw, isAudio: true)
            }
        if list != pairedAudio { pairedAudio = list; onPairedChange?() }
    }

    /// The battery a connected device reports through IOBluetooth (AirPods, Beats: left / right /
    /// case; other headsets: single). In-process, no child process; empty when unknown.
    func battery(of address: String) -> BluetoothBattery {
        guard isWatching, let device = IOBluetoothDevice(addressString: address), device.isConnected() else { return BluetoothBattery() }
        var values: [String: Int] = [:]
        for key in ["batteryPercentLeft", "batteryPercentRight", "batteryPercentCase", "batteryPercentSingle", "batteryPercentCombined"]
        where device.responds(to: NSSelectorFromString(key)) {
            if let n = device.value(forKey: key) as? NSNumber { values[key] = n.intValue }
        }
        return BluetoothBattery.fromDevice(values)
    }

    /// Connects a paired device without blocking: the result comes to `onConnectResult`.
    @discardableResult
    func connect(_ address: String) -> Bool {
        guard isWatching, let device = IOBluetoothDevice(addressString: address), !device.isConnected() else { return false }
        return device.openConnection(self) == kIOReturnSuccess
    }

    /// `openConnection` delegate. Any thread.
    @objc nonisolated func connectionComplete(_ device: AnyObject, status: IOReturn) {
        guard Self.isUsable else { return }
        let address = BluetoothProfiler.normaliseAddress((device as? IOBluetoothDevice)?.addressString ?? "")
        let ok = status == kIOReturnSuccess
        Self.onMain(self) { $0.onConnectResult?(address, ok) }
    }

    func stop() {
        central = nil
        isWatching = false
        pairedAudio = []
        connectNote?.unregister()
        connectNote = nil
        disconnectNotes.values.forEach { $0.unregister() }
        disconnectNotes = [:]
        connected = [:]
    }

    /// IOBluetooth's connect notification. Any thread (the coordinator queue in practice). The
    /// parameters are `AnyObject` so a wrong object can never reach IOBluetooth API.
    @objc nonisolated func didConnect(_ note: AnyObject, device: AnyObject) {
        guard Self.isUsable, let device = device as? IOBluetoothDevice else { return }
        let ref = DeviceRef(device: device)
        Self.onMain(self) { me in
            guard me.isWatching else { return }
            // Registration replays devices that are already connected: those are not news.
            guard let d = me.track(ref.device) else { return }
            me.refreshPaired()
            me.onConnect?(d)
        }
    }

    /// IOBluetooth's disconnect notification. Any thread.
    @objc nonisolated func didDisconnect(_ note: AnyObject, device: AnyObject) {
        guard Self.isUsable, let device = device as? IOBluetoothDevice else { return }
        let address = BluetoothProfiler.normaliseAddress(device.addressString ?? "")
        Self.onMain(self) { me in
            me.disconnectNotes.removeValue(forKey: address)?.unregister()
            if let d = me.connected.removeValue(forKey: address) { me.onDisconnect?(d) }
            if me.isWatching { me.refreshPaired() }
        }
    }

    /// FIFO onto main, so connect and disconnect keep their order.
    private nonisolated static func onMain(_ watcher: BluetoothWatcher,
                                           _ body: @escaping @MainActor (BluetoothWatcher) -> Void) {
        DispatchQueue.main.async { [weak watcher] in
            MainActor.assumeIsolated {
                guard let watcher else { return }
                body(watcher)
            }
        }
    }

    /// An IOBluetooth device handed from the coordinator queue to main, where it is used.
    private struct DeviceRef: @unchecked Sendable { let device: IOBluetoothDevice }

    /// Starts watching a connected device; nil when it was already tracked.
    @discardableResult
    private func track(_ device: IOBluetoothDevice) -> Device? {
        guard let raw = device.addressString else { return nil }
        let address = BluetoothProfiler.normaliseAddress(raw)
        guard connected[address] == nil else { return nil }
        let d = Device(address: address, name: device.name ?? raw,
                       isAudio: device.deviceClassMajor == UInt32(kBluetoothDeviceClassMajorAudio))
        connected[address] = d
        disconnectNotes[address] = device.register(forDisconnectNotification: self, selector: #selector(didDisconnect(_:device:)))
        return d
    }
}

extension BluetoothWatcher: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            if CBManager.authorization == .allowedAlways, self.central != nil { startWatching() }
        }
    }
}

/// Bluetooth battery levels, cheapest source first, never on the main thread for the slow one.
enum BluetoothBatteryReader {
    /// One `system_profiler SPBluetoothDataType -json` run (~0.1–0.3 s), off the main thread.
    /// The child is short-lived; `cancel` terminates it.
    final class ProfilerRun: @unchecked Sendable {
        private let process = Process()
        func cancel() { if process.isRunning { process.terminate() } }

        func run() async -> [ProfiledBluetoothDevice] {
            await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .utility).async { [process] in
                    process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
                    process.arguments = ["SPBluetoothDataType", "-json"]
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = FileHandle.nullDevice
                    do { try process.run() } catch { cont.resume(returning: []); return }
                    let pid = process.processIdentifier
                    ChildProcesses.register(pid)
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    ChildProcesses.unregister(pid)
                    cont.resume(returning: BluetoothProfiler.parse(data))
                }
            }
        }
    }

    /// IORegistry `AppleDeviceManagementHIDEventService` entries (Magic Keyboard / Mouse /
    /// Trackpad, and any headset the system publishes there): `BatteryPercent` and, when present,
    /// `BatteryPercentLeft/Right/Case/Single`, keyed by normalised address. Sub-millisecond.
    static func registryBatteries() -> [String: BluetoothBattery] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator) == KERN_SUCCESS
        else { return [:] }
        defer { IOObjectRelease(iterator) }
        var out: [String: BluetoothBattery] = [:]
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var props: [String: Any] = [:]
            for key in ["DeviceAddress", "BatteryPercent", "BatteryPercentLeft", "BatteryPercentRight", "BatteryPercentCase", "BatteryPercentSingle"] {
                if let v = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() { props[key] = v }
            }
            guard let address = props["DeviceAddress"] as? String else { continue }
            let battery = BluetoothBattery.fromRegistry(props)
            if !battery.isEmpty { out[BluetoothProfiler.normaliseAddress(address)] = battery }
        }
        return out
    }
}
