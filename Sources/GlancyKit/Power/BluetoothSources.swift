import CoreBluetooth
import Foundation
import IOBluetooth
import IOKit

/// Connect / disconnect notifications from IOBluetooth. No polling: one connect registration plus
/// one disconnect registration per connected device. Callbacks arrive on the main run loop.
@MainActor
final class BluetoothWatcher: NSObject {
    struct Device: Equatable {
        var address: String       // normalised
        var name: String
        var isAudio: Bool
    }

    var onConnect: ((Device) -> Void)?
    var onDisconnect: ((Device) -> Void)?
    private(set) var connected: [String: Device] = [:]
    private var connectNote: IOBluetoothUserNotification?
    private var disconnectNotes: [String: IOBluetoothUserNotification] = [:]

    /// IOBluetooth needs `NSBluetoothAlwaysUsageDescription` in Info.plist: without it macOS kills
    /// the process on first use. So command-line hosts (tests, renders) never touch it.
    static var isUsable: Bool {
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
        // Devices already connected at launch are known silently (no peek), then watched.
        for case let d as IOBluetoothDevice in IOBluetoothDevice.pairedDevices() ?? [] where d.isConnected() {
            track(d)
        }
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(didConnect(_:device:)))
    }

    func stop() {
        central = nil
        connectNote?.unregister()
        connectNote = nil
        disconnectNotes.values.forEach { $0.unregister() }
        disconnectNotes = [:]
        connected = [:]
    }

    @objc private func didConnect(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        // Registration replays devices that are already connected: those are not news.
        guard let d = track(device) else { return }
        onConnect?(d)
    }

    @objc private func didDisconnect(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let address = BluetoothProfiler.normaliseAddress(device.addressString ?? "")
        disconnectNotes.removeValue(forKey: address)?.unregister()
        if let d = connected.removeValue(forKey: address) { onDisconnect?(d) }
    }

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

    /// Magic Keyboard / Mouse / Trackpad: IORegistry `AppleDeviceManagementHIDEventService`
    /// `BatteryPercent`, keyed by normalised address (sub-millisecond).
    static func magicBatteries() -> [String: (name: String, percent: Int)] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator) == KERN_SUCCESS
        else { return [:] }
        defer { IOObjectRelease(iterator) }
        var out: [String: (String, Int)] = [:]
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func prop(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let percent = prop("BatteryPercent") as? Int, let address = prop("DeviceAddress") as? String else { continue }
            out[BluetoothProfiler.normaliseAddress(address)] = ((prop("Product") as? String) ?? "", percent)
        }
        return out
    }
}
