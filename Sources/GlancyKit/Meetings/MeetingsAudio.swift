import AppKit
import Accelerate
import AVFoundation
import CoreAudio
import Darwin
import ScreenCaptureKit

// The real audio pieces: who holds the microphone (CoreAudio property listeners), the two
// tracks (AVAudioEngine for the microphone; a Core Audio process tap for what the Mac plays on
// macOS 14.4+, ScreenCaptureKit audio before), the writer that turns either into a small mono AAC
// file, and the permissions. None of it is built by tests, renders or the lab.

// MARK: CoreAudio plumbing

enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func objectList(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var addr = address(selector, scope: scope)
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr,
              let s = value?.takeRetainedValue() as String?, !s.isEmpty else { return nil }
        return s
    }

    static func hasInput(_ id: AudioObjectID) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    /// Devices that can record (hidden helpers left out).
    static func inputDevices() -> [AudioObjectID] {
        objectList(system, kAudioHardwarePropertyDevices).filter { hasInput($0) && (uint32($0, kAudioDevicePropertyIsHidden) ?? 0) == 0 }
    }

    static func defaultOutputUID() -> String? {
        guard let id = uint32(system, kAudioHardwarePropertyDefaultOutputDevice), id != kAudioObjectUnknown else { return nil }
        return string(id, kAudioDevicePropertyDeviceUID)
    }

    /// This process's audio object (macOS 14.2+), to leave Glancy out of the tap.
    @available(macOS 14.2, *)
    static func ownProcessObject() -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var out = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &out)
        return status == noErr && out != kAudioObjectUnknown ? out : nil
    }

    /// A process's short name (daemons like avconferenced have no NSRunningApplication).
    static func processName(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        let n = proc_name(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

// MARK: Microphone watcher

/// At rest: one listener for the device list and one "running somewhere" listener per input
/// device — nothing runs until the system calls one. While an input runs, also the audio-process
/// list and each process's "running input" (macOS 14.2+), to name who holds the microphone and to
/// see it let go even while Glancy itself records from it.
@MainActor
final class CoreAudioMicWatcher: MicWatching {
    private typealias Listener = (AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)
    private let queue = DispatchQueue(label: "ai.glancy.meetings.mic.listen")
    private var onChange: (@MainActor () -> Void)?
    private var base: [Listener] = []
    private var processList: [Listener] = []
    private var perProcess: [Listener] = []

    var listenerCount: Int { base.count + processList.count + perProcess.count }

    func start(onChange: @escaping @MainActor () -> Void) {
        guard self.onChange == nil else { return }
        self.onChange = onChange
        attachBase()
        refreshDetail()
    }

    func stop() {
        for l in base + processList + perProcess { remove(l) }
        base = []; processList = []; perProcess = []
        onChange = nil
    }

    func snapshot() -> MicSnapshot {
        let running = HAL.inputDevices().contains { (HAL.uint32($0, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0) != 0 }
        guard #available(macOS 14.2, *) else { return MicSnapshot(running: running, clients: nil) }
        let me = getpid()
        var clients: [MicClient] = []
        for p in HAL.objectList(HAL.system, kAudioHardwarePropertyProcessObjectList)
        where (HAL.uint32(p, kAudioProcessPropertyIsRunningInput) ?? 0) != 0 {
            guard let raw = HAL.uint32(p, kAudioProcessPropertyPID) else { continue }
            let pid = Int32(bitPattern: raw)
            guard pid != me else { continue }
            let app = NSRunningApplication(processIdentifier: pid)
            clients.append(MicClient(pid: pid, bundleID: HAL.string(p, kAudioProcessPropertyBundleID) ?? app?.bundleIdentifier,
                                     name: app?.localizedName ?? HAL.processName(pid)))
        }
        return MicSnapshot(running: running || !clients.isEmpty, clients: clients)
    }

    private enum Event { case devices, processes, change }

    private func deliver(_ e: Event) {
        guard onChange != nil else { return }
        switch e {
        case .devices: attachBase()
        case .processes: attachProcesses()
        case .change: break
        }
        refreshDetail()
        onChange?()
    }

    private func attachBase() {
        for l in base { remove(l) }
        base = []
        listen(HAL.system, kAudioHardwarePropertyDevices, .devices, into: &base)
        for d in HAL.inputDevices() {
            listen(d, kAudioDevicePropertyDeviceIsRunningSomewhere, .change, into: &base)
        }
    }

    /// The process listeners only while some input runs (Glancy's own recording included).
    private func refreshDetail() {
        guard #available(macOS 14.2, *) else { return }
        let running = HAL.inputDevices().contains { (HAL.uint32($0, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0) != 0 }
        if running, processList.isEmpty {
            listen(HAL.system, kAudioHardwarePropertyProcessObjectList, .processes, into: &processList)
            attachProcesses()
        } else if !running, !processList.isEmpty {
            for l in processList + perProcess { remove(l) }
            processList = []; perProcess = []
        }
    }

    private func attachProcesses() {
        guard #available(macOS 14.2, *), !processList.isEmpty else { return }
        for l in perProcess { remove(l) }
        perProcess = []
        for p in HAL.objectList(HAL.system, kAudioHardwarePropertyProcessObjectList) {
            listen(p, kAudioProcessPropertyIsRunningInput, .change, into: &perProcess)
        }
    }

    private func listen(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ event: Event, into list: inout [Listener]) {
        var addr = HAL.address(selector)
        guard AudioObjectHasProperty(id, &addr) else { return }
        let block = Self.block { [weak self] in self?.deliver(event) }
        if AudioObjectAddPropertyListenerBlock(id, &addr, queue, block) == noErr { list.append((id, addr, block)) }
    }

    /// Delivered on the listener queue, hopped to main (removing a listener from its own queue can
    /// deadlock).
    private nonisolated static func block(_ deliver: @escaping @MainActor () -> Void) -> AudioObjectPropertyListenerBlock {
        { @Sendable _, _ in DispatchQueue.main.async { MainActor.assumeIsolated { deliver() } } }
    }

    private func remove(_ l: Listener) {
        var a = l.1
        AudioObjectRemovePropertyListenerBlock(l.0, &a, queue, l.2)
    }
}

// MARK: Track writer

/// One track: any PCM in, mono 24 kHz AAC (~32 kbit/s, ~15 MB an hour) out, and when it last heard
/// something. Called from one audio queue at a time; `close()` from main. Thread-safe by a lock.
final class TrackWriter: @unchecked Sendable {
    static let rate: Double = 24_000
    static var settings: [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]
    }

    let url: URL
    private let lock = NSLock()
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: TrackWriter.rate, channels: 1, interleaved: false)!
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var inFormat: AVAudioFormat?
    private var closed = false
    private var lastLoud: CFAbsoluteTime?
    private(set) var failed = false

    init(url: URL) { self.url = url }

    /// The newest sound heard on any of `writers`, as seconds ago.
    static func silence(_ writers: [TrackWriter]) -> TimeInterval? {
        let last = writers.compactMap { w in w.lock.withLock { w.lastLoud } }.max()
        return last.map { CFAbsoluteTimeGetCurrent() - $0 }
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !closed, !failed else { return }
        if rms(buffer) >= SpeechChunks.floor { lastLoud = CFAbsoluteTimeGetCurrent() }
        if inFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outFormat)
            converter?.downmix = true
            inFormat = buffer.format
        }
        guard let converter else { failed = true; return }
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * outFormat.sampleRate / buffer.format.sampleRate).rounded(.up)) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        let feed = OneShot(buffer)
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in feed.next(outStatus) }
        guard status != .error, out.frameLength > 0 else { return }
        do {
            if file == nil {
                file = try AVAudioFile(forWriting: url, settings: Self.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            }
            try file?.write(from: out)
        } catch {
            failed = true
        }
    }

    /// Finishes the file (the AAC header is written when the file object goes away).
    func close() {
        lock.withLock {
            closed = true
            file = nil
            converter = nil
        }
    }

    private func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 1 }   // not float: count it as sound
        var v: Float = 0
        vDSP_rmsqv(data[0], buffer.stride, &v, vDSP_Length(buffer.frameLength))
        return v
    }

    /// Hands the converter one buffer, then "no data for now" (it keeps state between calls).
    private final class OneShot: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(_ b: AVAudioPCMBuffer) { buffer = b }
        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            guard let b = buffer else { status.pointee = .noDataNow; return nil }
            buffer = nil
            status.pointee = .haveData
            return b
        }
    }
}

// MARK: Capture

struct MeetingCaptureError: Error {}

/// The real two-track capture.
///
/// System audio: a Core Audio process tap on macOS 14.4+ — a private, unmuted global tap of every
/// process's output but Glancy's, read through a private aggregate device. It asks for "System
/// Audio Recording Only" (not Screen Recording), captures no video, costs one HAL IO cycle and is
/// what the system's own recorders use. Before 14.4 (taps arrived in 14.2 and were unreliable
/// until 14.4): ScreenCaptureKit with `capturesAudio`, a 2×2 video stream at 1 fps, which needs
/// Screen Recording.
@MainActor
final class SystemMeetingCapture: MeetingCapturing {
    private var mic: MicTrack?
    /// A `ProcessTapTrack` (macOS 14.4+; typed loosely so the class can stay available everywhere).
    private var tap: AnyObject?
    private var screen: ScreenAudioTrack?
    private var systemWriter: TrackWriter?
    var onTrackLost: ((MeetingSpeaker) -> Void)?

    func start(folder: URL, mic wantsMic: Bool, system wantsSystem: Bool) async throws -> [MeetingSpeaker] {
        stop()
        var out: [MeetingSpeaker] = []
        if wantsMic {
            let track = MicTrack(writer: TrackWriter(url: folder.appendingPathComponent(MeetingRecord.file(.you))))
            track.onLost = { [weak self] in self?.onTrackLost?(.you) }
            if (try? track.start()) != nil { mic = track; out.append(.you) }
        }
        if wantsSystem {
            let writer = TrackWriter(url: folder.appendingPathComponent(MeetingRecord.file(.others)))
            if #available(macOS 14.4, *) {
                let t = ProcessTapTrack(writer: writer)
                if (try? t.start()) != nil { tap = t; systemWriter = writer; out.append(.others) }
            } else {
                let sck = ScreenAudioTrack(writer: writer)
                if (try? await sck.start()) != nil { screen = sck; systemWriter = writer; out.append(.others) }
            }
        }
        return out
    }

    func silence() -> TimeInterval? {
        TrackWriter.silence([mic?.writer, systemWriter].compactMap { $0 })
    }

    func stop() {
        mic?.stop(); mic = nil
        if #available(macOS 14.4, *), let t = tap as? ProcessTapTrack { t.stop() }
        tap = nil
        screen?.stop(); screen = nil
        systemWriter = nil
    }
}

/// The microphone, through AVAudioEngine's input tap. A device change (AirPods in, the default
/// input switched) restarts it on the new device, same file.
@MainActor
final class MicTrack {
    let writer: TrackWriter
    private let engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    var onLost: (() -> Void)?

    init(writer: TrackWriter) { self.writer = writer }

    func start() throws {
        try begin()
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart() }
        }
    }

    private func begin() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MeetingCaptureError() }
        input.installTap(onBus: 0, bufferSize: 4_096, format: format, block: Self.tap(writer))
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    private func restart() {
        guard observer != nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if (try? begin()) == nil { onLost?() }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        writer.close()
    }

    /// Called on the engine's own thread: built outside the main actor.
    private nonisolated static func tap(_ writer: TrackWriter) -> AVAudioNodeTapBlock {
        { @Sendable buffer, _ in writer.write(buffer) }
    }
}

/// What the Mac plays, through a Core Audio process tap (macOS 14.4+).
@available(macOS 14.4, *)
@MainActor
final class ProcessTapTrack {
    let writer: TrackWriter
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "ai.glancy.meetings.tap", qos: .userInitiated)

    init(writer: TrackWriter) { self.writer = writer }

    func start() throws {
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: HAL.ownProcessObject().map { [$0] } ?? [])
        description.uuid = UUID()
        description.name = "Glancy meeting"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr, tap != kAudioObjectUnknown else { throw MeetingCaptureError() }
        tapID = tap
        do {
            var addr = HAL.address(kAudioTapPropertyFormat)
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd) == noErr,
                  let format = AVAudioFormat(streamDescription: &asbd), let output = HAL.defaultOutputUID() else { throw MeetingCaptureError() }
            let config: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Glancy meeting",
                kAudioAggregateDeviceUIDKey: "ai.glancy.meetings.\(UUID().uuidString)",
                kAudioAggregateDeviceMainSubDeviceKey: output,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
            ]
            var aggregate = AudioObjectID(kAudioObjectUnknown)
            guard AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate) == noErr else { throw MeetingCaptureError() }
            aggregateID = aggregate
            var proc: AudioDeviceIOProcID?
            guard AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue, Self.io(writer, format)) == noErr, let proc else {
                throw MeetingCaptureError()
            }
            procID = proc
            guard AudioDeviceStart(aggregate, proc) == noErr else { throw MeetingCaptureError() }
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        queue.sync {}   // a cycle already queued lands before the file closes
        writer.close()
    }

    /// The IO cycle, on `queue`: the tap's samples, written without a copy.
    private nonisolated static func io(_ writer: TrackWriter, _ format: AVAudioFormat) -> AudioDeviceIOBlock {
        { @Sendable _, input, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            writer.write(buffer)
        }
    }
}

/// What the Mac plays, through ScreenCaptureKit's audio (macOS 14.0–14.3).
final class ScreenAudioTrack: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let writer: TrackWriter
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "ai.glancy.meetings.screen", qos: .userInitiated)

    init(writer: TrackWriter) { self.writer = writer }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw MeetingCaptureError() }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stop() {
        stream?.stopCapture { @Sendable _ in }
        stream = nil
        queue.sync {}
        writer.close()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let buffer = Self.pcm(sampleBuffer) else { return }
        writer.write(buffer)
    }

    static func pcm(_ sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(sb) else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: desc)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr else {
            return nil
        }
        return buffer
    }
}

// MARK: Permissions

@MainActor
final class SystemMeetingPermissions: MeetingPermissions {
    private let microphone = SystemMicAuthorization()
    private let speechAuth = SystemTranscriber()

    func mic() -> MicAccess { microphone.status() }
    func requestMic() async -> Bool { await microphone.request() }
    func systemAudio() -> MicAccess { SystemAudioPermission.status() }
    func requestSystemAudio() async -> Bool { await SystemAudioPermission.request() }
    func speech() -> SpeechAccess { speechAuth.status() }
    func requestSpeech() async -> Bool { await speechAuth.request() }
}

/// "System Audio Recording Only" (the process tap, macOS 14.4+) or Screen Recording (before).
/// macOS has no public call to read or ask for the first: TCC's own preflight / request are used
/// when present (no prompt on preflight); without them the tap's first start asks.
enum SystemAudioPermission {
    /// Without the usage string the tap records silence (and asking may end the process).
    static var usable: Bool {
        if #available(macOS 14.4, *) { return Bundle.main.object(forInfoDictionaryKey: "NSAudioCaptureUsageDescription") != nil }
        return SystemPermissions.inBundle
    }

    static func status() -> MicAccess {
        guard usable else { return .denied }
        guard #available(macOS 14.4, *) else { return CGPreflightScreenCaptureAccess() ? .granted : .notDetermined }
        guard let preflight = TCC.preflight else { return .notDetermined }
        return switch preflight(TCC.service, nil) {
        case 0: .granted
        case 1: .denied
        default: .notDetermined
        }
    }

    static func request() async -> Bool {
        guard usable else { return false }
        guard #available(macOS 14.4, *) else { return CGRequestScreenCaptureAccess() }
        guard let request = TCC.request else { return true }   // the tap's first start asks
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            request(TCC.service, nil) { @Sendable granted in cont.resume(returning: granted) }
        }
    }

    /// For Settings → Permissions (never prompts).
    static func permissionStatus() -> PermissionStatus {
        guard SystemPermissions.inBundle, usable else { return .unavailable }
        return switch status() {
        case .granted: .granted
        case .denied: .denied
        case .notDetermined: .notDetermined
        }
    }

    /// System Settings → Privacy → Screen & System Audio Recording.
    static let settingsPane = "com.apple.preference.security?Privacy_ScreenCapture"

    private enum TCC {
        typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
        typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) @Sendable (Bool) -> Void) -> Void
        static var service: CFString { "kTCCServiceAudioCapture" as CFString }
        nonisolated(unsafe) static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
        static let preflight: Preflight? = handle.flatMap { dlsym($0, "TCCAccessPreflight") }.map { unsafeBitCast($0, to: Preflight.self) }
        static let request: Request? = handle.flatMap { dlsym($0, "TCCAccessRequest") }.map { unsafeBitCast($0, to: Request.self) }
    }
}

// MARK: Playback

/// Both tracks mixed (an AVMutableComposition with each file at time zero), played by AVPlayer.
@MainActor
final class SystemMeetingPlayer: MeetingPlaying {
    private let player: AVPlayer
    private var observer: NSObjectProtocol?
    var onFinish: (() -> Void)?

    private init(item: AVPlayerItem) {
        player = AVPlayer(playerItem: item)
        observer = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onFinish?() }
        }
    }

    static func make(_ files: [URL]) async -> MeetingPlaying? {
        let composition = AVMutableComposition()
        for url in files where FileManager.default.fileExists(atPath: url.path) {
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let duration = try? await asset.load(.duration),
                  let into = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try? into.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
        }
        guard !composition.tracks.isEmpty else { return nil }
        return SystemMeetingPlayer(item: AVPlayerItem(asset: composition))
    }

    var isPlaying: Bool { player.rate != 0 }
    func play() { player.play() }
    func pause() { player.pause() }

    func stop() {
        player.pause()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        onFinish = nil
    }
}
