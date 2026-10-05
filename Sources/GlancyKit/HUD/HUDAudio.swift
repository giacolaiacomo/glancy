import CoreAudio
import Foundation
import os

/// The default output device's volume and mute, through CoreAudio. Thread-safe: the event-tap
/// thread writes, the listener queue reads. Volume uses the main element when it is settable,
/// otherwise every channel of the preferred stereo pair.
final class AudioOutput: @unchecked Sendable {
    struct Snapshot {
        var device: AudioObjectID
        var volumeElements: [AudioObjectPropertyElement]   // [] = no software volume
        var canMute: Bool
    }

    /// Registration and reads happen on `queue`; CoreAudio delivers to `listenQueue`, which only
    /// hops to `queue` (removing a listener from its own delivery queue can deadlock).
    private let queue = DispatchQueue(label: "ai.glancy.hud.audio")
    private let listenQueue = DispatchQueue(label: "ai.glancy.hud.audio.listen")
    private let lock = OSAllocatedUnfairLock<State>(initialState: State())
    private struct State: Sendable {
        var snapshot: Snapshot?
        var known: VolumeState?
        var listening = false
        var listenedDevice: AudioObjectID = 0
        var generation = 0
    }

    // Blocks kept so the very same objects can be removed again.
    private var systemListener: AudioObjectPropertyListenerBlock?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    /// Called on the listener queue with a state that changed because of someone else.
    private var onExternal: (@Sendable (VolumeState) -> Void)?

    // MARK: Reads and writes (any thread)

    /// The current default output device, its volume elements and mute support (cached until the
    /// default device changes).
    func snapshot() -> Snapshot? {
        if let s = lock.withLock({ $0.snapshot }) { return s }
        guard let device = Self.defaultOutputDevice() else { return nil }
        let s = Snapshot(device: device, volumeElements: Self.volumeElements(device), canMute: Self.isSettable(device, kAudioDevicePropertyMute, kAudioObjectPropertyElementMain))
        lock.withLock { $0.snapshot = s }
        return s
    }

    func read() -> VolumeState? {
        guard let s = snapshot(), !s.volumeElements.isEmpty else { return nil }
        return Self.read(s)
    }

    /// Applies a key: a step (direction ±1) or a mute toggle (0). Returns the new state, or nil
    /// when the device can't do it or a call fails (the caller then passes the key through).
    func apply(direction: Int, fine: Bool) -> VolumeState? {
        guard let s = snapshot(), !s.volumeElements.isEmpty, let current = Self.read(s) else { return nil }
        var target = current
        if direction == 0 {
            guard s.canMute else { return nil }
            target.muted.toggle()
        } else {
            target.volume = HUDStep.next(current.volume, up: direction > 0, fine: fine)
            if direction > 0 && current.muted {
                guard s.canMute else { return nil }
                target.muted = false
            }
        }
        // Record the intent first so the listener never mistakes our own write for someone else's.
        let intent = target
        lock.withLock { $0.known = intent }
        var ok = true
        if target.volume != current.volume {
            for e in s.volumeElements { ok = Self.setFloat(s.device, kAudioDevicePropertyVolumeScalar, e, target.volume) && ok }
        }
        if target.muted != current.muted {
            ok = Self.setUInt32(s.device, kAudioDevicePropertyMute, kAudioObjectPropertyElementMain, target.muted ? 1 : 0) && ok
        }
        let after = Self.read(s) ?? target
        lock.withLock { $0.known = after }
        return ok ? after : nil
    }

    // MARK: Listeners

    /// Starts the property listeners; the current state is read silently (no HUD at launch).
    func startListening(onExternal: @escaping @Sendable (VolumeState) -> Void) {
        queue.sync {
            guard !lock.withLock({ $0.listening }) else { return }
            lock.withLock { $0.listening = true }
            self.onExternal = onExternal
            let system: AudioObjectPropertyListenerBlock = { [weak self, queue] _, _ in
                guard let self else { return }
                queue.async { self.defaultDeviceChanged() }
            }
            systemListener = system
            var addr = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, listenQueue, system)
            deviceListener = { [weak self, queue] _, _ in
                guard let self else { return }
                queue.async { self.deviceChanged() }
            }
            attachDevice()
        }
    }

    func stopListening() {
        queue.sync {
            guard lock.withLock({ $0.listening }) else { return }
            detachDevice()
            if let system = systemListener {
                var addr = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, listenQueue, system)
            }
            systemListener = nil
            deviceListener = nil
            onExternal = nil
            lock.withLock { s in
                s.generation += 1
                s.listening = false; s.known = nil; s.snapshot = nil
            }
        }
    }

    /// On the queue.
    private func attachDevice() {
        lock.withLock { $0.snapshot = nil }
        guard let s = snapshot() else { return }
        if let block = deviceListener {
            for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
                var addr = Self.address(selector, element: kAudioObjectPropertyElementWildcard)
                AudioObjectAddPropertyListenerBlock(s.device, &addr, listenQueue, block)
            }
        }
        let state = s.volumeElements.isEmpty ? nil : Self.read(s)
        lock.withLock { $0.listenedDevice = s.device; $0.known = state }
    }

    private func detachDevice() {
        let device = lock.withLock { $0.listenedDevice }
        guard device != 0, let block = deviceListener else { return }
        for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
            var addr = Self.address(selector, element: kAudioObjectPropertyElementWildcard)
            AudioObjectRemovePropertyListenerBlock(device, &addr, listenQueue, block)
        }
        lock.withLock { $0.listenedDevice = 0 }
    }

    /// A switch of output device (AirPods connecting, HDMI) is not a volume change: silent.
    private func defaultDeviceChanged() {
        detachDevice()
        attachDevice()
    }

    /// Several notifications arrive per change (one per channel): settle for 50 ms, then read once.
    private func deviceChanged() {
        let mine = lock.withLock { s -> Int in s.generation += 1; return s.generation }
        queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            guard let self, self.lock.withLock({ $0.generation == mine }) else { return }
            self.settle()
        }
    }

    private func settle() {
        guard let s = snapshot(), !s.volumeElements.isEmpty, let now = Self.read(s) else { return }
        let external = lock.withLock { st -> Bool in
            defer { st.known = now }
            return VolumeState.isExternalChange(known: st.known, now: now)
        }
        if external { onExternal?(now) }
    }

    // MARK: CoreAudio plumbing

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput,
                                element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return err == noErr && id != kAudioObjectUnknown ? id : nil
    }

    private static func isSettable(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement) -> Bool {
        var addr = address(selector, element: element)
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &addr, &settable) == noErr && settable.boolValue
    }

    /// The main element when settable, else the preferred stereo channels that are settable.
    private static func volumeElements(_ device: AudioObjectID) -> [AudioObjectPropertyElement] {
        if isSettable(device, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain) {
            return [kAudioObjectPropertyElementMain]
        }
        var addr = address(kAudioDevicePropertyPreferredChannelsForStereo)
        var channels: [UInt32] = [1, 2]
        var size = UInt32(MemoryLayout<UInt32>.size * 2)
        if AudioObjectHasProperty(device, &addr) {
            _ = channels.withUnsafeMutableBytes { AudioObjectGetPropertyData(device, &addr, 0, nil, &size, $0.baseAddress!) }
        }
        return channels.filter { isSettable(device, kAudioDevicePropertyVolumeScalar, $0) }
    }

    private static func read(_ s: Snapshot) -> VolumeState? {
        let levels = s.volumeElements.compactMap { getFloat(s.device, kAudioDevicePropertyVolumeScalar, $0) }
        guard !levels.isEmpty else { return nil }
        let muted = s.canMute ? (getUInt32(s.device, kAudioDevicePropertyMute, kAudioObjectPropertyElementMain) ?? 0) != 0 : false
        return VolumeState(volume: levels.reduce(0, +) / Float(levels.count), muted: muted)
    }

    private static func getFloat(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement) -> Float? {
        var addr = address(selector, element: element)
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func getUInt32(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement) -> UInt32? {
        var addr = address(selector, element: element)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func setFloat(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement, _ v: Float) -> Bool {
        var addr = address(selector, element: element)
        var value = Float32(v)
        return AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    private static func setUInt32(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement, _ v: UInt32) -> Bool {
        var addr = address(selector, element: element)
        var value = v
        return AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }
}
