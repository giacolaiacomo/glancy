import AVFoundation
import Foundation
import Speech

// The system pieces voice notes use — microphone permission, the recorder, the player, on-device
// speech recognition — each behind a small protocol so the logic runs against fakes in tests and
// renders (an automated run never opens the microphone or asks for a permission). The real ones
// exist only while in use: a recorder while recording, a player while a note is loaded.

// MARK: Microphone permission

public enum MicAccess: Sendable, Equatable { case notDetermined, denied, granted }

@MainActor
public protocol MicAuthorizing: AnyObject {
    func status() -> MicAccess
    /// Shows the system prompt (only when not determined). True = granted.
    func request() async -> Bool
}

@MainActor
final class SystemMicAuthorization: MicAuthorizing {
    /// Without the usage string macOS kills the app on access (an unbundled debug run): treat as off.
    static var usable: Bool { Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil }

    func status() -> MicAccess {
        guard Self.usable else { return .denied }
        return switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    func request() async -> Bool {
        guard Self.usable else { return false }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }
}

// MARK: Recorder

@MainActor
public protocol VoiceRecording: AnyObject {
    /// Starts writing AAC (mono, 44.1 kHz, 64 kbps) to `url` from the default input, at once.
    /// The recorder itself stops at `maxDuration`.
    func start(url: URL, maxDuration: TimeInterval) throws
    /// Seconds recorded so far.
    var currentTime: TimeInterval { get }
    /// The input level right now, 0…1.
    func level() -> Float
    /// Finishes the file; its length in seconds.
    func stop() -> TimeInterval
    /// Stops and deletes the file.
    func cancel()
    /// The recording ended on its own (input gone, encoder error, the length limit).
    var onEnded: (() -> Void)? { get set }
}

struct VoiceRecorderError: Error {}

@MainActor
final class SystemVoiceRecorder: NSObject, VoiceRecording, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var lastTime: TimeInterval = 0
    var onEnded: (() -> Void)?

    static let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 44_100,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 64_000,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
    ]

    func start(url: URL, maxDuration: TimeInterval) throws {
        let r = try AVAudioRecorder(url: url, settings: Self.settings)
        r.isMeteringEnabled = true
        r.delegate = self
        guard r.record(forDuration: maxDuration) else { throw VoiceRecorderError() }
        recorder = r
    }

    var currentTime: TimeInterval {
        if let r = recorder, r.isRecording { lastTime = r.currentTime }
        return lastTime
    }

    func level() -> Float {
        guard let r = recorder, r.isRecording else { return 0 }
        r.updateMeters()
        // -50 dB (room tone) … 0 dB, eased so speech fills most of the meter.
        let db = r.averagePower(forChannel: 0)
        return Float(pow(Double(max(0, min(1, (db + 50) / 50))), 1.6))
    }

    func stop() -> TimeInterval {
        let t = currentTime
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        return t
    }

    func cancel() {
        recorder?.delegate = nil
        recorder?.stop()
        recorder?.deleteRecording()
        recorder = nil
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.ended() }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in self?.ended() }
    }

    private func ended() {
        guard recorder != nil else { return }
        onEnded?()
    }
}

// MARK: Player

@MainActor
public protocol VoicePlaying: AnyObject {
    var duration: TimeInterval { get }
    var currentTime: TimeInterval { get set }
    var rate: Float { get set }
    var isPlaying: Bool { get }
    @discardableResult func play() -> Bool
    func pause()
    /// Reached the end.
    var onFinish: (() -> Void)? { get set }
}

@MainActor
final class SystemVoicePlayer: NSObject, VoicePlaying, AVAudioPlayerDelegate {
    private let player: AVAudioPlayer
    var onFinish: (() -> Void)?

    init?(url: URL) {
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return nil }
        player = p
        super.init()
        p.enableRate = true
        p.delegate = self
        p.prepareToPlay()
    }

    var duration: TimeInterval { player.duration }
    var currentTime: TimeInterval {
        get { player.currentTime }
        set { player.currentTime = max(0, min(newValue, player.duration)) }
    }
    var rate: Float {
        get { player.rate }
        set { player.rate = newValue }
    }
    var isPlaying: Bool { player.isPlaying }
    func play() -> Bool { player.play() }
    func pause() { player.pause() }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.onFinish?() }
    }
}

// MARK: Transcription

public enum SpeechAccess: Sendable, Equatable { case notDetermined, denied, granted }

/// Speech to text, on this Mac only.
public protocol NoteTranscribing: Sendable {
    @MainActor func status() -> SpeechAccess
    /// Shows the system prompt. True = granted.
    @MainActor func request() async -> Bool
    /// On-device recognition exists for this language here (never falls back to a server).
    func availableOnDevice(_ locale: Locale) -> Bool
    /// The words in the file; "" when nobody spoke. Runs off the main thread.
    func transcribe(_ url: URL, locale: Locale) async throws -> String
}

struct SystemTranscriber: NoteTranscribing {
    static var usable: Bool { Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil }

    @MainActor func status() -> SpeechAccess {
        guard Self.usable else { return .denied }
        return switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    @MainActor func request() async -> Bool {
        guard Self.usable else { return false }
        return await Self.askSpeech()
    }

    /// The answer arrives on a TCC/XPC queue, so the callback must not be main-actor isolated
    /// (a closure formed inside a @MainActor method is, and Swift traps when it runs elsewhere).
    nonisolated static func askSpeech() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in cont.resume(returning: status == .authorized) }
        }
    }

    func availableOnDevice(_ locale: Locale) -> Bool {
        guard let r = SFSpeechRecognizer(locale: locale) else { return false }
        return r.supportsOnDeviceRecognition
    }

    func transcribe(_ url: URL, locale: Locale) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
            throw VoiceRecorderError()
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        // Never send audio to a server: no on-device model, no transcript.
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        let once = Once()
        let box = TaskBox()
        box.recognizer = recognizer   // kept alive until the task ends
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                box.task = recognizer.recognitionTask(with: request) { @Sendable result, error in
                    if let result, result.isFinal {
                        if once.claim() { cont.resume(returning: result.bestTranscription.formattedString) }
                    } else if let error {
                        // "No speech detected" and friends: an empty transcript, not a failure.
                        let code = (error as NSError).code
                        if once.claim() {
                            if code == 1110 || code == 203 { cont.resume(returning: "") } else { cont.resume(throwing: error) }
                        }
                    }
                }
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
    }

    private final class TaskBox: @unchecked Sendable {
        var task: SFSpeechRecognitionTask?
        var recognizer: SFSpeechRecognizer?
    }
}

/// The language a voice note is transcribed in: the app's (it-IT / en-US).
enum VoiceLocale {
    static func current(italian: Bool) -> Locale { Locale(identifier: italian ? "it-IT" : "en-US") }
}

// MARK: Analysis

/// Length and waveform of a recording, read once after it is saved (off the main thread).
public enum VoiceAnalysis {
    public static let bars = 64

    /// nil when the file can't be read.
    public static func analyze(_ url: URL, bars: Int = bars) -> (duration: TimeInterval, waveform: [UInt8])? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let frames = file.length
        guard frames > 0, format.sampleRate > 0 else { return (0, []) }
        let duration = Double(frames) / format.sampleRate
        let perBar = max(1, Int((Double(frames) / Double(bars)).rounded(.up)))
        var sums = [Double](repeating: 0, count: bars)
        var counts = [Int](repeating: 0, count: bars)
        let chunk: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return nil }
        var index = 0
        while file.framePosition < frames {
            do { try file.read(into: buffer, frameCount: chunk) } catch { break }
            let n = Int(buffer.frameLength)
            guard n > 0, let data = buffer.floatChannelData?[0] else { break }
            for i in 0..<n {
                let bar = min(bars - 1, (index + i) / perBar)
                let v = Double(data[i])
                sums[bar] += v * v
                counts[bar] += 1
            }
            index += n
        }
        let rms = zip(sums, counts).map { $1 > 0 ? ($0 / Double($1)).squareRoot() : 0 }
        return (duration, waveform(rms))
    }

    /// RMS per bar → 0…255, the loudest bar full, quiet ones still visible (square-root curve).
    static func waveform(_ rms: [Double]) -> [UInt8] {
        let top = rms.max() ?? 0
        guard top > 0.0005 else { return rms.map { _ in 0 } }
        return rms.map { UInt8(max(0, min(255, (($0 / top).squareRoot() * 255).rounded()))) }
    }
}
