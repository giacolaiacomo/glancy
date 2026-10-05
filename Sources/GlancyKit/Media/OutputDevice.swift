import CoreAudio
import Foundation

/// The default output device's name ("MacBook Pro Speakers", "AirPods Pro"). Read when the panel
/// opens; a CoreAudio listener follows changes only while the panel is open.
@MainActor
final class OutputDeviceWatcher {
    private var block: AudioObjectPropertyListenerBlock?
    private var onChange: ((String?) -> Void)?

    private nonisolated static let defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    nonisolated static func currentName() -> String? {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = defaultOutputAddress
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &name) == noErr,
              let cf = name?.takeRetainedValue() else { return nil }
        let s = cf as String
        return s.isEmpty ? nil : s
    }

    var isIdle: Bool { onChange == nil }

    func start(_ onChange: @escaping (String?) -> Void) {
        stop()
        self.onChange = onChange
        onChange(Self.currentName())
        let b: AudioObjectPropertyListenerBlock = { @Sendable [weak self] _, _ in
            let name = OutputDeviceWatcher.currentName()
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onChange?(name) } }
        }
        var addr = Self.defaultOutputAddress
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.global(qos: .utility), b) == noErr {
            block = b
        }
    }

    func stop() {
        if let block {
            var addr = Self.defaultOutputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.global(qos: .utility), block)
        }
        block = nil
        onChange = nil
    }
}
