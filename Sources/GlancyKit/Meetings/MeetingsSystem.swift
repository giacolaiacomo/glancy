import AppKit
import AVFoundation
import Foundation

// The system pieces the meeting recorder uses — who holds the microphone, the two-track capture,
// the permissions, on-device speech, playback — each behind a small protocol, so the module runs
// against fakes in tests, renders and the lab: an automated run never opens the microphone, never
// creates an audio tap and never shows a permission prompt. The real ones exist only while in use:
// at rest there are a few CoreAudio property listeners and nothing else.

// MARK: Who holds the microphone

@MainActor
public protocol MicWatching: AnyObject {
    /// Starts listening (CoreAudio property listeners; no polling). `onChange` runs on main after
    /// anything about the microphone changed. Idempotent.
    func start(onChange: @escaping @MainActor () -> Void)
    func stop()
    /// What the microphone is doing now (a few property reads).
    func snapshot() -> MicSnapshot
    /// Listeners registered right now (tests and the at-rest budget).
    var listenerCount: Int { get }
}

// MARK: Capture

/// The two tracks of a recording: `you.m4a` (the microphone) and `others.m4a` (what the Mac plays).
@MainActor
public protocol MeetingCapturing: AnyObject {
    /// Starts writing the tracks asked for into `folder`; returns the ones that started.
    func start(folder: URL, mic: Bool, system: Bool) async throws -> [MeetingSpeaker]
    /// Seconds since a sound above the noise floor on any track; nil = nothing heard yet.
    func silence() -> TimeInterval?
    /// Stops at once and finishes the files (synchronous: also used when quitting).
    func stop()
    /// A track stopped by itself (its device went away and could not be reopened).
    var onTrackLost: ((MeetingSpeaker) -> Void)? { get set }
}

// MARK: Permissions

/// Microphone, system audio ("System Audio Recording Only", or Screen Recording before 14.4) and
/// Speech Recognition. `request` shows the system prompt only when not answered yet.
@MainActor
public protocol MeetingPermissions: AnyObject {
    func mic() -> MicAccess
    func requestMic() async -> Bool
    func systemAudio() -> MicAccess
    func requestSystemAudio() async -> Bool
    func speech() -> SpeechAccess
    func requestSpeech() async -> Bool
}

// MARK: Speech

/// Which on-device recogniser writes the transcript.
public enum MeetingSpeechEngine: String, Sendable {
    /// SpeechAnalyzer + SpeechTranscriber (macOS 26): long-form, no Speech Recognition permission.
    case analyzer
    /// SFSpeechRecognizer with `requiresOnDeviceRecognition`, in pieces of at most 55 s.
    case recognizer
    /// No on-device recognition for this language here.
    case unavailable
}

public protocol MeetingTranscribing: Sendable {
    /// The recogniser here needs Speech Recognition (SFSpeechRecognizer; SpeechAnalyzer doesn't).
    var needsSpeechPermission: Bool { get }
    /// The recogniser this Mac has for `locale` (never one that sends audio to a server).
    func engine(for locale: Locale) async -> MeetingSpeechEngine
    /// Timed pieces of text (words or phrases) in one track, seconds from its start. Runs off the
    /// main thread; `progress` 0…1.
    func transcribe(_ url: URL, locale: Locale, engine: MeetingSpeechEngine,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> [SpokenWord]
}

// MARK: Playback

@MainActor
public protocol MeetingPlaying: AnyObject {
    var isPlaying: Bool { get }
    func play()
    func pause()
    /// Done with it: stops and lets go of its observer.
    func stop()
    /// Reached the end.
    var onFinish: (() -> Void)? { get set }
}

// MARK: The set

/// What a `MeetingsModule` is built from: the real pieces, or inert ones (tests, renders, the lab).
public struct MeetingsSystem {
    var watcher: @MainActor () -> MicWatching
    var capture: @MainActor () -> MeetingCapturing
    var permissions: MeetingPermissions
    var transcriber: MeetingTranscribing
    /// A player for both tracks of a recording, mixed (the files that exist).
    var player: @MainActor ([URL]) async -> MeetingPlaying?
    /// Shows a folder in the Finder.
    var reveal: @MainActor (URL) -> Void

    @MainActor public static var system: MeetingsSystem {
        MeetingsSystem(watcher: { CoreAudioMicWatcher() }, capture: { SystemMeetingCapture() },
                       permissions: SystemMeetingPermissions(), transcriber: SystemMeetingTranscriber(),
                       player: { await SystemMeetingPlayer.make($0) },
                       reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) })
    }

    /// The renderer's and the lab's: nothing real, the permissions as on a Mac set up halfway.
    @MainActor public static var sample: MeetingsSystem {
        MeetingsSystem(watcher: { InertMicWatcher() }, capture: { InertCapture() }, permissions: SampleMeetingPermissions(),
                       transcriber: InertMeetingTranscriber(), player: { _ in nil }, reveal: { _ in })
    }

    /// Nothing real: no listeners, no capture, every permission refused, no player.
    @MainActor public static var inert: MeetingsSystem {
        MeetingsSystem(watcher: { InertMicWatcher() }, capture: { InertCapture() }, permissions: InertMeetingPermissions(),
                       transcriber: InertMeetingTranscriber(), player: { _ in nil }, reveal: { _ in })
    }

    public init(watcher: @escaping @MainActor () -> MicWatching, capture: @escaping @MainActor () -> MeetingCapturing,
                permissions: MeetingPermissions, transcriber: MeetingTranscribing,
                player: @escaping @MainActor ([URL]) async -> MeetingPlaying?, reveal: @escaping @MainActor (URL) -> Void) {
        self.watcher = watcher; self.capture = capture; self.permissions = permissions; self.transcriber = transcriber
        self.player = player; self.reveal = reveal
    }
}

@MainActor final class InertMicWatcher: MicWatching {
    func start(onChange: @escaping @MainActor () -> Void) {}
    func stop() {}
    func snapshot() -> MicSnapshot { .idle }
    var listenerCount: Int { 0 }
}

@MainActor final class InertCapture: MeetingCapturing {
    func start(folder: URL, mic: Bool, system: Bool) async throws -> [MeetingSpeaker] { [] }
    func silence() -> TimeInterval? { nil }
    func stop() {}
    var onTrackLost: ((MeetingSpeaker) -> Void)?
}

@MainActor final class InertMeetingPermissions: MeetingPermissions {
    func mic() -> MicAccess { .denied }
    func requestMic() async -> Bool { false }
    func systemAudio() -> MicAccess { .denied }
    func requestSystemAudio() async -> Bool { false }
    func speech() -> SpeechAccess { .denied }
    func requestSpeech() async -> Bool { false }
}

@MainActor final class SampleMeetingPermissions: MeetingPermissions {
    func mic() -> MicAccess { .granted }
    func requestMic() async -> Bool { false }
    func systemAudio() -> MicAccess { .notDetermined }
    func requestSystemAudio() async -> Bool { false }
    func speech() -> SpeechAccess { .granted }
    func requestSpeech() async -> Bool { false }
}

struct InertMeetingTranscriber: MeetingTranscribing {
    var needsSpeechPermission: Bool { false }
    func engine(for locale: Locale) async -> MeetingSpeechEngine { .unavailable }
    func transcribe(_ url: URL, locale: Locale, engine: MeetingSpeechEngine,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> [SpokenWord] { [] }
}

// MARK: The lab's recording

/// The lab's stand-in for the microphone and the system tap: speech-like synthetic audio, fed at
/// real time (the microphone in 100 ms buffers like AVAudioEngine's tap, the system track in 10 ms
/// ones like a HAL IO cycle) through the real `TrackWriter`s, so `scripts/cpu-lab.sh` measures what
/// converting and AAC-encoding two tracks costs. Never built by the app outside `--lab`.
@MainActor final class SyntheticCapture: MeetingCapturing {
    private var feeds: [SyntheticFeed] = []
    var onTrackLost: ((MeetingSpeaker) -> Void)?

    func start(folder: URL, mic: Bool, system: Bool) async throws -> [MeetingSpeaker] {
        stop()
        var out: [MeetingSpeaker] = []
        if mic {
            feeds.append(SyntheticFeed(writer: TrackWriter(url: folder.appendingPathComponent(MeetingRecord.file(.you))),
                                       rate: 48_000, channels: 1, block: 4_800, seed: 1))
            out.append(.you)
        }
        if system {
            feeds.append(SyntheticFeed(writer: TrackWriter(url: folder.appendingPathComponent(MeetingRecord.file(.others))),
                                       rate: 48_000, channels: 2, block: 480, seed: 2))
            out.append(.others)
        }
        return out
    }

    func silence() -> TimeInterval? { TrackWriter.silence(feeds.map(\.writer)) }

    func stop() {
        for f in feeds { f.stop() }
        feeds = []
    }
}

/// One synthetic track on its own queue. The timer is the stand-in for a device's IO cycle.
final class SyntheticFeed: @unchecked Sendable {
    let writer: TrackWriter
    private let source: DispatchSourceTimer
    private let queue = DispatchQueue(label: "ai.glancy.meetings.synthetic", qos: .userInitiated)

    init(writer: TrackWriter, rate: Double, channels: AVAudioChannelCount, block: AVAudioFrameCount, seed: Int) {
        self.writer = writer
        source = DispatchSource.makeTimerSource(queue: queue)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let period = Double(block) / rate
        source.schedule(deadline: .now() + period, repeating: period, leeway: .milliseconds(2))
        source.setEventHandler(handler: Self.handler(writer: writer, format: format, block: block, seed: seed))
        source.resume()
    }

    func stop() {
        source.cancel()
        queue.sync {}
        writer.close()
    }

    /// Built outside any actor: the timer calls it on its own queue.
    private static func handler(writer: TrackWriter, format: AVAudioFormat, block: AVAudioFrameCount, seed: Int) -> @Sendable () -> Void {
        let state = SyntheticVoice(seed: seed)
        return { @Sendable in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: block) else { return }
            buffer.frameLength = block
            state.fill(buffer)
            writer.write(buffer)
        }
    }
}

/// A voice-ish signal: a few harmonics of a gliding pitch, syllables, pauses.
private final class SyntheticVoice: @unchecked Sendable {
    private var t: Double = 0
    private let seed: Double
    init(seed: Int) { self.seed = Double(seed) }

    func fill(_ buffer: AVAudioPCMBuffer) {
        let rate = buffer.format.sampleRate
        let n = Int(buffer.frameLength)
        guard let data = buffer.floatChannelData else { return }
        for i in 0..<n {
            let time = t + Double(i) / rate
            let pitch = 140 + 30 * sin(time * 0.7 + seed)
            let syllable = max(0, sin(time * 2 * .pi * 3.1 + seed))
            let talking = sin(time * 0.35 + seed) > -0.2 ? 1.0 : 0.0
            var v = 0.0
            for h in 1...4 { v += sin(2 * .pi * pitch * Double(h) * time) / Double(h) }
            let sample = Float(0.12 * v * syllable * talking)
            for c in 0..<Int(buffer.format.channelCount) { data[c][i] = sample }
        }
        t += Double(n) / rate
    }
}
