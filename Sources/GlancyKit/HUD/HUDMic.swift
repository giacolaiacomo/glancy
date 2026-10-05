import CoreAudio
import Foundation

// Microphone mute, mic / camera in use and the output list, over a small `AudioSystem` seam so
// the logic runs against a fake in tests (the real one is `CoreAudioSystem`, HUDCoreAudio.swift).

/// An audio device as the Devices tab and the command bar need it.
public struct AudioDevice: Equatable, Identifiable, Sendable {
    public var id: AudioObjectID
    public var uid: String
    public var name: String
    public var hasInput: Bool
    public var hasOutput: Bool
    public var transport: AudioTransport

    public init(id: AudioObjectID, uid: String, name: String, hasInput: Bool, hasOutput: Bool, transport: AudioTransport = .other) {
        self.id = id; self.uid = uid; self.name = name; self.hasInput = hasInput; self.hasOutput = hasOutput; self.transport = transport
    }

    /// SF Symbol for an output device.
    public var symbol: String {
        let n = name.lowercased()
        if transport == .bluetooth || n.contains("airpods") || n.contains("beats") {
            return BluetoothIcon.symbol(name: name)
        }
        switch transport {
        case .builtIn: return n.contains("headphone") || n.contains("cuffie") ? "headphones" : "laptopcomputer"
        case .display: return "display"
        case .airPlay: return "airplayaudio"
        case .usb: return "cable.connector"
        case .virtual, .aggregate: return "waveform"
        default: return "hifispeaker"
        }
    }
}

public enum AudioTransport: String, Sendable {
    case builtIn, bluetooth, usb, airPlay, display, virtual, aggregate, other

    init(code: UInt32) {
        switch code {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeAirPlay: self = .airPlay
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: self = .display
        case kAudioDeviceTransportTypeVirtual: self = .virtual
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: self = .aggregate
        default: self = .other
        }
    }
}

/// What changed, as reported by the system's listeners.
public enum AudioChange: Sendable {
    case devices, defaultInput, defaultOutput, inputLevel, inputUse, camera
}

/// Who is using the microphone right now.
public struct InputUse: Equatable, Sendable {
    public var inUse: Bool
    /// Names of the apps recording, when the system can tell (macOS 14.2+).
    public var apps: [String]
    public init(inUse: Bool = false, apps: [String] = []) { self.inUse = inUse; self.apps = apps }
}

/// CoreAudio / CoreMediaIO as the Devices features need them. Main actor; every change arrives
/// through `observe` (property listeners — never polled).
@MainActor
public protocol AudioSystem: AnyObject {
    func devices() -> [AudioDevice]
    func defaultInput() -> AudioObjectID?
    func defaultOutput() -> AudioObjectID?
    func setDefaultOutput(_ id: AudioObjectID) -> Bool
    /// nil = the device has no mute control on its input.
    func inputMute(_ id: AudioObjectID) -> Bool?
    func canSetInputMute(_ id: AudioObjectID) -> Bool
    func setInputMute(_ id: AudioObjectID, _ on: Bool) -> Bool
    func inputVolume(_ id: AudioObjectID) -> Float?
    func canSetInputVolume(_ id: AudioObjectID) -> Bool
    func setInputVolume(_ id: AudioObjectID, _ value: Float) -> Bool
    func inputUse() -> InputUse
    /// nil = no camera, or not knowable.
    func cameraInUse() -> Bool?
    func observe(_ onChange: @escaping @MainActor (AudioChange) -> Void)
    func stopObserving()
}

/// A system with nothing in it: isolated runs (`--self-test`, `--demo`) never touch CoreAudio.
@MainActor
final class SilentAudioSystem: AudioSystem {
    func devices() -> [AudioDevice] { [] }
    func defaultInput() -> AudioObjectID? { nil }
    func defaultOutput() -> AudioObjectID? { nil }
    func setDefaultOutput(_ id: AudioObjectID) -> Bool { false }
    func inputMute(_ id: AudioObjectID) -> Bool? { nil }
    func canSetInputMute(_ id: AudioObjectID) -> Bool { false }
    func setInputMute(_ id: AudioObjectID, _ on: Bool) -> Bool { false }
    func inputVolume(_ id: AudioObjectID) -> Float? { nil }
    func canSetInputVolume(_ id: AudioObjectID) -> Bool { false }
    func setInputVolume(_ id: AudioObjectID, _ value: Float) -> Bool { false }
    func inputUse() -> InputUse { InputUse() }
    func cameraInUse() -> Bool? { nil }
    func observe(_ onChange: @escaping @MainActor (AudioChange) -> Void) {}
    func stopObserving() {}
}

/// Microphone mute, in-use state and the output list. Mute uses the input's mute control; a
/// device without one is muted by setting its input volume to 0 (the previous level is kept in
/// defaults, so it comes back even after a crash). Unmuting — or Glancy stopping — restores every
/// device Glancy muted, so the mic is never left silent without the wing that says so.
@MainActor @Observable
public final class AudioCenter {
    public private(set) var outputs: [AudioDevice] = []
    public private(set) var inputs: [AudioDevice] = []
    public private(set) var defaultOutputID: AudioObjectID?
    public private(set) var defaultInputID: AudioObjectID?
    /// The default input is muted (by Glancy or anyone else).
    public private(set) var micMuted = false
    /// The default input can be muted at all (mute control or settable volume).
    public private(set) var micMutable = false
    public private(set) var micUse = InputUse()
    public private(set) var cameraInUse = false
    public private(set) var running = false

    /// Called when `micMuted` changes (`byUser` = through Glancy) or the in-use state changes.
    @ObservationIgnored var onMicChange: ((_ muted: Bool, _ byUser: Bool) -> Void)?
    @ObservationIgnored var onUseChange: ((_ mic: Bool, _ camera: Bool) -> Void)?

    @ObservationIgnored let system: AudioSystem
    @ObservationIgnored private let defaults: UserDefaults
    /// Devices Glancy muted with their mute control (uids).
    @ObservationIgnored private var mutedByUs: Set<String> = []
    /// A render sample is on screen: nothing is ever written to the system.
    @ObservationIgnored private var isSample = false

    static let savedVolumesKey = "glancy.hud.micSavedVolumes"
    /// Level restored on a volume-muted device whose previous level is unknown.
    static let fallbackRestoreVolume: Float = 0.75

    public init(system: AudioSystem, defaults: UserDefaults = .standard) {
        self.system = system
        self.defaults = defaults
    }

    public var defaultOutput: AudioDevice? { outputs.first { $0.id == defaultOutputID } }
    public var defaultInput: AudioDevice? { inputs.first { $0.id == defaultInputID } }

    // MARK: Lifecycle

    public func start() {
        guard !running else { return }
        running = true
        system.observe { [weak self] change in self?.changed(change) }
        reloadDevices()
        readMic(notify: false)
        readUse(notify: false)
    }

    /// Stops listening; `restore` unmutes whatever Glancy muted.
    public func stop(restore: Bool = true) {
        guard running else { return }
        if restore, !isSample, micMuted, !mutedByUs.isEmpty || !savedVolumes.isEmpty { _ = setMicMuted(false) }
        system.stopObserving()
        running = false
    }

    // MARK: Mic

    /// Mutes or unmutes the default input; the new state, or nil when it can't be done.
    @discardableResult
    public func toggleMic() -> Bool? {
        setMicMuted(!micMuted) ? micMuted : nil
    }

    @discardableResult
    public func setMicMuted(_ on: Bool) -> Bool {
        guard !isSample, let device = defaultInput else { return false }
        var ok: Bool
        if on {
            ok = mute(device)
        } else {
            ok = unmute(device)
            // Every other device Glancy silenced comes back too.
            for other in inputs where other.id != device.id && (mutedByUs.contains(other.uid) || savedVolumes[other.uid] != nil) {
                _ = unmute(other)
            }
        }
        let before = micMuted
        readMic(notify: false)
        ok = ok && micMuted == on
        if micMuted != before { onMicChange?(micMuted, true) }
        return ok
    }

    private func mute(_ d: AudioDevice) -> Bool {
        if system.canSetInputMute(d.id) {
            guard system.setInputMute(d.id, true) else { return false }
            mutedByUs.insert(d.uid)
            return true
        }
        guard system.canSetInputVolume(d.id), let level = system.inputVolume(d.id) else { return false }
        if level > 0 { var saved = savedVolumes; saved[d.uid] = level; savedVolumes = saved }
        return system.setInputVolume(d.id, 0)
    }

    private func unmute(_ d: AudioDevice) -> Bool {
        var ok = true
        if system.inputMute(d.id) == true {
            ok = system.setInputMute(d.id, false)
        }
        mutedByUs.remove(d.uid)
        if system.inputMute(d.id) == nil || savedVolumes[d.uid] != nil,
           system.canSetInputVolume(d.id), (system.inputVolume(d.id) ?? 1) == 0 {
            ok = system.setInputVolume(d.id, savedVolumes[d.uid] ?? Self.fallbackRestoreVolume) && ok
        }
        var saved = savedVolumes; saved[d.uid] = nil; savedVolumes = saved
        return ok
    }

    /// Muted = the mute control is on, or (no mute control) the input volume is 0.
    static func isMuted(_ d: AudioDevice, _ system: AudioSystem) -> Bool {
        if let m = system.inputMute(d.id) {
            if m { return true }
            if system.canSetInputMute(d.id) { return false }
        }
        return system.inputVolume(d.id) == 0
    }

    private func readMic(notify: Bool) {
        let before = micMuted
        if let d = defaultInput {
            micMutable = system.canSetInputMute(d.id) || system.canSetInputVolume(d.id)
            micMuted = Self.isMuted(d, system)
        } else {
            micMutable = false
            micMuted = false
        }
        if notify, micMuted != before { onMicChange?(micMuted, false) }
    }

    /// Previous levels of devices muted through their volume, by uid.
    var savedVolumes: [String: Float] {
        get { (defaults.dictionary(forKey: Self.savedVolumesKey) as? [String: Double])?.mapValues { Float($0) } ?? [:] }
        set {
            if newValue.isEmpty { defaults.removeObject(forKey: Self.savedVolumesKey) }
            else { defaults.set(newValue.mapValues { Double($0) }, forKey: Self.savedVolumesKey) }
        }
    }

    // MARK: Output

    /// Makes `id` the default output; false when the system refused.
    @discardableResult
    public func selectOutput(_ id: AudioObjectID) -> Bool {
        guard !isSample, outputs.contains(where: { $0.id == id }) else { return false }
        guard id != defaultOutputID else { return true }
        guard system.setDefaultOutput(id) else { return false }
        defaultOutputID = system.defaultOutput() ?? id
        return true
    }

    /// Renders only: a state shown without asking CoreAudio.
    public func setSample(muted: Bool, micInUse: Bool = false, camera: Bool = false, apps: [String] = []) {
        isSample = true
        micMuted = muted
        micMutable = true
        micUse = InputUse(inUse: micInUse, apps: micInUse ? apps : [])
        cameraInUse = camera
    }

    /// Renders only: a fixed device list.
    public func setSampleDevices(_ devices: [AudioDevice], output: AudioObjectID?, input: AudioObjectID?) {
        isSample = true
        if !running { running = true }
        outputs = devices.filter(\.hasOutput)
        inputs = devices.filter(\.hasInput)
        defaultOutputID = output
        defaultInputID = input
    }

    // MARK: Changes

    private func changed(_ change: AudioChange) {
        guard running, !isSample else { return }
        switch change {
        case .devices:
            reloadDevices()
            readMic(notify: true)
        case .defaultOutput:
            let id = system.defaultOutput()
            if id != defaultOutputID { defaultOutputID = id }
        case .defaultInput:
            let wasMuted = micMuted
            let byUs = !mutedByUs.isEmpty || !savedVolumes.isEmpty
            defaultInputID = system.defaultInput()
            // A new microphone (AirPods connecting) while muted by Glancy stays muted: the toggle
            // is "the mic", not one device.
            if wasMuted, byUs, let d = defaultInput, !Self.isMuted(d, system) { _ = mute(d) }
            readMic(notify: true)
        case .inputLevel:
            readMic(notify: true)
            // Unmuted elsewhere (System Settings, the device): nothing left for Glancy to restore.
            if !micMuted, let d = defaultInput {
                mutedByUs.remove(d.uid)
                if savedVolumes[d.uid] != nil { var s = savedVolumes; s[d.uid] = nil; savedVolumes = s }
            }
        case .inputUse, .camera:
            readUse(notify: true)
        }
    }

    private func reloadDevices() {
        let all = system.devices()
        let outs = all.filter(\.hasOutput)
        let ins = all.filter(\.hasInput)
        if outs != outputs { outputs = outs }
        if ins != inputs { inputs = ins }
        let o = system.defaultOutput(), i = system.defaultInput()
        if o != defaultOutputID { defaultOutputID = o }
        if i != defaultInputID { defaultInputID = i }
    }

    private func readUse(notify: Bool) {
        let use = system.inputUse()
        let camera = system.cameraInUse() ?? false
        let changed = use.inUse != micUse.inUse || camera != cameraInUse
        if use != micUse { micUse = use }
        if camera != cameraInUse { cameraInUse = camera }
        if notify, changed { onUseChange?(micUse.inUse, cameraInUse) }
    }
}
