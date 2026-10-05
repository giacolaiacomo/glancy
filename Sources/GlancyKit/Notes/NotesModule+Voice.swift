import AppKit
import SwiftUI

/// The system pieces a `VoiceNotes` is built from: the real ones, or inert samples (renders,
/// isolated runs) that never touch the microphone or ask for a permission.
public struct VoiceSystem {
    var mic: MicAuthorizing
    var transcriber: NoteTranscribing
    var recorder: @MainActor () -> VoiceRecording
    var player: @MainActor (URL) -> VoicePlaying?
    var analyze: @Sendable (URL) -> (duration: TimeInterval, waveform: [UInt8])?

    @MainActor public static var system: VoiceSystem {
        VoiceSystem(mic: SystemMicAuthorization(), transcriber: SystemTranscriber(),
                    recorder: { SystemVoiceRecorder() }, player: { SystemVoicePlayer(url: $0) },
                    analyze: { VoiceAnalysis.analyze($0) })
    }

    @MainActor static var sample: VoiceSystem {
        VoiceSystem(mic: InertMic(), transcriber: InertTranscriber(), recorder: { InertRecorder() }, player: { _ in nil },
                    analyze: { _ in nil })
    }

    init(mic: MicAuthorizing, transcriber: NoteTranscribing, recorder: @escaping @MainActor () -> VoiceRecording,
         player: @escaping @MainActor (URL) -> VoicePlaying?,
         analyze: @escaping @Sendable (URL) -> (duration: TimeInterval, waveform: [UInt8])?) {
        self.mic = mic; self.transcriber = transcriber; self.recorder = recorder; self.player = player; self.analyze = analyze
    }
}

@MainActor private final class InertMic: MicAuthorizing {
    func status() -> MicAccess { .denied }
    func request() async -> Bool { false }
}

private struct InertTranscriber: NoteTranscribing {
    @MainActor func status() -> SpeechAccess { .granted }
    @MainActor func request() async -> Bool { false }
    func availableOnDevice(_ locale: Locale) -> Bool { true }
    func transcribe(_ url: URL, locale: Locale) async throws -> String { "" }
}

@MainActor private final class InertRecorder: VoiceRecording {
    func start(url: URL, maxDuration: TimeInterval) throws { throw VoiceRecorderError() }
    var currentTime: TimeInterval { 0 }
    func level() -> Float { 0 }
    func stop() -> TimeInterval { 0 }
    func cancel() {}
    var onEnded: (() -> Void)?
}

// MARK: Recording from the module (hotkey, tab, command bar)

extension NotesModule {
    /// The hotkey: starts a recording, or stops and saves the one running. A muted mic or a
    /// refused permission opens the tab on the card that explains it.
    public func toggleRecording() {
        if voice.isRecording { stopRecording() } else { startRecording(openOnProblem: true) }
    }

    /// `then` runs with the result (the command bar closes the panel once recording).
    func startRecording(openOnProblem: Bool, then: ((VoiceNotes.StartResult) -> Void)? = nil) {
        Task { [weak self] in
            guard let self else { return }
            let result = await self.voice.record()
            if openOnProblem, result != .started, result != .busy { self.hub?.requestOpen(.notes) }
            then?(result)
        }
    }

    /// Stops and saves; a drop-down says so when the tab isn't on screen.
    func stopRecording() {
        Task { [weak self] in
            guard let self, let note = await self.voice.stop() else { return }
            if self.voice.display != .tab, let hub = self.hub {
                hub.show(PeekEvent(module: .notes, duration: 2,
                                   content: AnyView(VoiceSavedPeek(duration: note.audio?.duration ?? 0))))
            }
        }
    }

    /// Recording started / ended: the wing (red dot + time) while collapsed.
    func recordingChanged(_ on: Bool) {
        guard let hub else { return }
        if on {
            hub.post(LiveActivity(id: Self.voiceWingID, module: .notes, priority: Self.voiceWingPriority, updated: .now,
                                  left: AnyView(VoiceWingLeft()), right: AnyView(VoiceWingRight(voice: voice))))
        } else {
            hub.clear(Self.voiceWingID)
        }
    }

    func voiceCommands() -> [GlancyCommand] {
        if voice.isRecording {
            return [
                GlancyCommand(id: "notes.voice.stop", module: .notes, title: L10n.tr("Stop recording"), symbol: "stop.circle.fill",
                              keywords: ["stop", "recording", "voice", "ferma", "registrazione", "nota vocale"],
                              rank: 20, closesPanel: true) { [weak self] in self?.stopRecording() },
                GlancyCommand(id: "notes.voice.cancel", module: .notes, title: L10n.tr("Cancel recording"), symbol: "xmark.circle",
                              keywords: ["cancel", "discard", "recording", "annulla", "scarta", "registrazione"],
                              closesPanel: true) { [weak self] in self?.voice.cancel() },
            ]
        }
        return [
            GlancyCommand(id: "notes.voice.record", module: .notes, title: L10n.tr("Record voice note"), symbol: "mic.fill",
                          keywords: ["record", "voice", "voice note", "voice memo", "memo", "dictate", "audio", "mic",
                                     "registra", "nota vocale", "memo vocale", "voce", "detta", "microfono"],
                          closesPanel: false) { [weak self] in
                self?.startRecording(openOnProblem: true) { result in
                    if result == .started { self?.hub?.requestClose() }
                }
            },
        ]
    }
}

/// The HUD module's microphone mute, as the Notes tab needs it.
extension HUDModule: NotesMicControl {
    public var notesMicMuted: Bool { audio.running && audio.micMuted }
    public func notesUnmuteMic() -> Bool { audio.setMicMuted(false) }
}

// MARK: Renders

extension NotesSample {
    /// Two made-up voice notes (no audio file behind them: the waveform is in the metadata).
    static func voiceSamples(_ now: Date) -> [Note] {
        [
            Note(id: "sample-v1", text: """
            Voice note 09:12
            Call Marta about the venue on Thursday and ask whether the projector takes USB-C. Book the 8:40 train.
            """, modified: now.addingTimeInterval(-25 * 60),
                 audio: NoteAudio(file: "sample-v1.m4a", duration: 42, waveform: wave(seed: 7, count: VoiceAnalysis.bars), transcribed: true)),
            Note(id: "sample-v2", text: "Voice note 18:40", modified: now.addingTimeInterval(-27 * 3600),
                 audio: NoteAudio(file: "sample-v2.m4a", duration: 12, waveform: wave(seed: 3, count: VoiceAnalysis.bars), transcribed: true)),
        ]
    }

    /// A speech-like waveform: syllables with short pauses (deterministic).
    static func wave(seed: UInt64, count: Int) -> [UInt8] {
        var x = seed &* 6364136223846793005 &+ 1442695040888963407
        return (0..<count).map { i in
            x = x &* 6364136223846793005 &+ 1442695040888963407
            let noise = Double(x >> 33) / Double(UInt32.max >> 1)
            let syllable = 0.55 + 0.45 * sin(Double(i) * 0.9 + Double(seed))
            let pause = i % 13 == 12 || i % 13 == 0 ? 0.25 : 1
            return UInt8(max(18, min(255, 255 * syllable * pause * (0.55 + 0.45 * noise))))
        }
    }
}

extension NotesModule {
    /// Voice-note states for `glancy-render` (sample data only; nothing recorded or played).
    public enum VoiceRenderState: String, CaseIterable, Sendable {
        case list, recording, wing, playback, transcribe, denied, muted
    }

    public func prepareForRender(_ state: VoiceRenderState) {
        guard sample else { return }
        let levels: [Float] = (0..<VoiceNotes.meterBars).map { i in
            Float(0.18 + 0.7 * abs(sin(Double(i) * 0.55)) * (i % 7 == 0 ? 0.35 : 1))
        }
        voice.card = nil
        voice.setSample(phase: .idle)
        switch state {
        case .list:
            model.select("sample-1")
        case .recording, .wing:
            voice.setSample(phase: .recording, elapsed: 83, levels: levels)
            if state == .wing { recordingChanged(true) }
        case .playback:
            model.select("sample-v1")
            voice.setSample(phase: .idle, playing: "sample-v1", position: 15, rate: 1.5)
        case .transcribe:
            model.select("sample-v2")
            voice.setSample(phase: .idle, speechAsk: "sample-v2")
        case .denied:
            voice.setSample(phase: .idle, card: .micDenied)
        case .muted:
            voice.setSample(phase: .idle, card: .micMuted)
        }
    }
}
