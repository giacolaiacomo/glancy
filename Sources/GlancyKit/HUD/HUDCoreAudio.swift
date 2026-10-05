import AppKit
import CoreAudio
import CoreMediaIO

/// The real `AudioSystem`: CoreAudio for devices, mute and "who is recording", CoreMediaIO for
/// the camera. Every change comes from property listeners, delivered on a private queue and
/// hopped to the main actor (removing a listener from its own delivery queue can deadlock).
@MainActor
final class CoreAudioSystem: AudioSystem {
    private let listenQueue = DispatchQueue(label: "ai.glancy.hud.devices.listen")
    private var onChange: (@MainActor (AudioChange) -> Void)?
    /// Every registered listener, to remove the very same blocks again.
    private var audioListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var perDevice: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var perInput: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var perProcess: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var cameraListeners: [(CMIOObjectID, CMIOObjectPropertyAddress, CMIOObjectPropertyListenerBlock)] = []
    private var perCamera: [(CMIOObjectID, CMIOObjectPropertyAddress, CMIOObjectPropertyListenerBlock)] = []

    private static let system = AudioObjectID(kAudioObjectSystemObject)

    // MARK: Reads and writes

    func devices() -> [AudioDevice] {
        Self.objectList(Self.system, kAudioHardwarePropertyDevices).compactMap { id in
            let hasIn = Self.hasStreams(id, kAudioDevicePropertyScopeInput)
            let hasOut = Self.hasStreams(id, kAudioDevicePropertyScopeOutput)
            guard hasIn || hasOut, let uid = Self.string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            // Hidden helper devices (CADefaultDeviceAggregate…) are not choices.
            if (Self.uint32(id, kAudioDevicePropertyIsHidden) ?? 0) != 0 { return nil }
            return AudioDevice(id: id, uid: uid, name: Self.string(id, kAudioObjectPropertyName) ?? uid,
                               hasInput: hasIn, hasOutput: hasOut,
                               transport: AudioTransport(code: Self.uint32(id, kAudioDevicePropertyTransportType) ?? 0))
        }
    }

    func defaultInput() -> AudioObjectID? { Self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice) }
    func defaultOutput() -> AudioObjectID? { Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) }

    func setDefaultOutput(_ id: AudioObjectID) -> Bool {
        var addr = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        var value = id
        let ok = AudioObjectSetPropertyData(Self.system, &addr, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &value) == noErr
        // System sounds follow the output, as choosing it in Control Centre does.
        var sys = Self.address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        if ok { _ = AudioObjectSetPropertyData(Self.system, &sys, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &value) }
        return ok
    }

    func inputMute(_ id: AudioObjectID) -> Bool? {
        Self.uint32(id, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput).map { $0 != 0 }
    }

    func canSetInputMute(_ id: AudioObjectID) -> Bool {
        Self.isSettable(id, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput)
    }

    func setInputMute(_ id: AudioObjectID, _ on: Bool) -> Bool {
        var addr = Self.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput)
        var value: UInt32 = on ? 1 : 0
        return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    /// The main element's input volume, else the average of channels 1–2.
    func inputVolume(_ id: AudioObjectID) -> Float? {
        let levels = inputVolumeElements(id).compactMap { Self.float(id, kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeInput, element: $0) }
        return levels.isEmpty ? nil : levels.reduce(0, +) / Float(levels.count)
    }

    func canSetInputVolume(_ id: AudioObjectID) -> Bool { !inputVolumeElements(id).isEmpty }

    func setInputVolume(_ id: AudioObjectID, _ value: Float) -> Bool {
        let elements = inputVolumeElements(id)
        guard !elements.isEmpty else { return false }
        var ok = true
        for e in elements {
            var addr = Self.address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeInput, element: e)
            var v = Float32(value)
            ok = AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr && ok
        }
        return ok
    }

    private func inputVolumeElements(_ id: AudioObjectID) -> [AudioObjectPropertyElement] {
        if Self.isSettable(id, kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeInput) { return [kAudioObjectPropertyElementMain] }
        return [1, 2].filter { Self.isSettable(id, kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeInput, element: $0) }
    }

    /// macOS 14.2+: the audio processes whose input is running (exact, names the app). Plus, on
    /// every version, input-only devices running somewhere (the built-in microphone). Devices
    /// with both directions are left to the process check: their "running" also means playback.
    func inputUse() -> InputUse {
        var apps: [String] = []
        var inUse = false
        if #available(macOS 14.2, *) {
            for p in Self.objectList(Self.system, kAudioHardwarePropertyProcessObjectList)
            where (Self.uint32(p, kAudioProcessPropertyIsRunningInput) ?? 0) != 0 {
                inUse = true
                if let pid = Self.int32(p, kAudioProcessPropertyPID), pid != getpid() {
                    if let name = NSRunningApplication(processIdentifier: pid)?.localizedName, !apps.contains(name) { apps.append(name) }
                }
            }
        }
        if !inUse {
            inUse = devices().contains { $0.hasInput && !$0.hasOutput && (Self.uint32($0.id, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0) != 0 }
        }
        return InputUse(inUse: inUse, apps: apps.sorted())
    }

    func cameraInUse() -> Bool? {
        let cams = Self.cameraList()
        guard !cams.isEmpty else { return nil }
        return cams.contains { Self.cameraRunning($0) }
    }

    // MARK: Listeners

    func observe(_ onChange: @escaping @MainActor (AudioChange) -> Void) {
        stopObserving()
        self.onChange = onChange
        listen(Self.system, kAudioHardwarePropertyDevices, .devices, into: &audioListeners)
        listen(Self.system, kAudioHardwarePropertyDefaultInputDevice, .defaultInput, into: &audioListeners)
        listen(Self.system, kAudioHardwarePropertyDefaultOutputDevice, .change(.defaultOutput), into: &audioListeners)
        if #available(macOS 14.2, *) {
            listen(Self.system, kAudioHardwarePropertyProcessObjectList, .processes, into: &audioListeners)
        }
        attachDevices()
        attachInput()
        attachProcesses()
        listenCameras()
    }

    func stopObserving() {
        for list in [audioListeners, perDevice, perInput, perProcess] {
            for (id, addr, block) in list {
                var a = addr
                AudioObjectRemovePropertyListenerBlock(id, &a, listenQueue, block)
            }
        }
        audioListeners = []; perDevice = []; perInput = []; perProcess = []
        for (id, addr, block) in cameraListeners + perCamera {
            var a = addr
            CMIOObjectRemovePropertyListenerBlock(id, &a, listenQueue, block)
        }
        cameraListeners = []; perCamera = []
        onChange = nil
    }

    /// What a listener reports: a change, or a list that changed (listeners re-attached first).
    private enum Event { case change(AudioChange), devices, defaultInput, processes, cameras }

    private func deliver(_ event: Event) {
        guard onChange != nil else { return }
        switch event {
        case .change(let c): onChange?(c)
        case .devices: attachDevices(); onChange?(.devices)
        case .defaultInput: attachInput(); onChange?(.defaultInput)
        case .processes: attachProcesses(); onChange?(.inputUse)
        case .cameras: attachCameras(); onChange?(.camera)
        }
    }

    private func listen(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ event: Event,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                        into list: inout [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)]) {
        var addr = Self.address(selector, scope: scope, element: element)
        guard AudioObjectHasProperty(id, &addr) else { return }
        let block: AudioObjectPropertyListenerBlock = { @Sendable [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.deliver(event) } }
        }
        if AudioObjectAddPropertyListenerBlock(id, &addr, listenQueue, block) == noErr { list.append((id, addr, block)) }
    }

    private func detach(_ list: inout [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)]) {
        for (id, addr, block) in list {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(id, &a, listenQueue, block)
        }
        list = []
    }

    /// Input-only devices: running somewhere (the mic dot on Macs before 14.2, and a second signal after).
    private func attachDevices() {
        detach(&perDevice)
        for d in devices() where d.hasInput && !d.hasOutput {
            listen(d.id, kAudioDevicePropertyDeviceIsRunningSomewhere, .change(.inputUse), into: &perDevice)
        }
    }

    /// The default input's mute and volume.
    private func attachInput() {
        detach(&perInput)
        guard let id = defaultInput() else { return }
        listen(id, kAudioDevicePropertyMute, .change(.inputLevel), scope: kAudioDevicePropertyScopeInput, into: &perInput)
        for e in [kAudioObjectPropertyElementMain, 1, 2] {
            listen(id, kAudioDevicePropertyVolumeScalar, .change(.inputLevel), scope: kAudioDevicePropertyScopeInput, element: e, into: &perInput)
        }
    }

    private func attachProcesses() {
        guard #available(macOS 14.2, *) else { return }
        detach(&perProcess)
        for p in Self.objectList(Self.system, kAudioHardwarePropertyProcessObjectList) {
            listen(p, kAudioProcessPropertyIsRunningInput, .change(.inputUse), into: &perProcess)
        }
    }

    private func listenCameras() {
        var addr = Self.cmioAddress(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        let block: CMIOObjectPropertyListenerBlock = { @Sendable [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.deliver(.cameras) } }
        }
        if CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &addr, listenQueue, block) == 0 {
            cameraListeners.append((CMIOObjectID(kCMIOObjectSystemObject), addr, block))
        }
        attachCameras()
    }

    private func attachCameras() {
        for (id, addr, block) in perCamera {
            var a = addr
            CMIOObjectRemovePropertyListenerBlock(id, &a, listenQueue, block)
        }
        perCamera = []
        for cam in Self.cameraList() {
            var addr = Self.cmioAddress(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere))
            let block: CMIOObjectPropertyListenerBlock = { @Sendable [weak self] _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.onChange?(.camera) } }
            }
            if CMIOObjectAddPropertyListenerBlock(cam, &addr, listenQueue, block) == 0 { perCamera.append((cam, addr, block)) }
        }
    }

    // MARK: CoreAudio plumbing

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        uint32(system, selector).flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    private static func objectList(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func hasStreams(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func isSettable(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
                                   element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Bool {
        var addr = address(selector, scope: scope, element: element)
        guard AudioObjectHasProperty(id, &addr) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(id, &addr, &settable) == noErr && settable.boolValue
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var addr = address(selector, scope: scope)
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func int32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Int32? {
        uint32(id, selector).map { Int32(bitPattern: $0) }
    }

    private static func float(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
                              element: AudioObjectPropertyElement) -> Float? {
        var addr = address(selector, scope: scope, element: element)
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr,
              let s = value?.takeRetainedValue() as String?, !s.isEmpty else { return nil }
        return s
    }

    // MARK: CoreMediaIO plumbing

    private static func cmioAddress(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: selector, mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func cameraList() -> [CMIOObjectID] {
        var addr = cmioAddress(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        var size: UInt32 = 0
        let sys = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == 0, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(sys, &addr, 0, nil, size, &used, &ids) == 0 else { return [] }
        return Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    private static func cameraRunning(_ id: CMIOObjectID) -> Bool {
        var addr = cmioAddress(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere))
        var value: UInt32 = 0
        var used: UInt32 = 0
        return CMIOObjectGetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value) == 0 && value != 0
    }
}
