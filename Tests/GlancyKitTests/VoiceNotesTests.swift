import AVFoundation
import Carbon.HIToolbox
import Foundation
import Testing
@testable import GlancyKit

// Voice notes against fakes: no microphone is opened, no permission is asked, nothing is played
// out loud. Audio files are generated tones in temp folders.

private func tempDir(_ name: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("glancy-voice-tests-\(name)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func files(_ dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
}

/// A mono AAC .m4a: a 440 Hz tone, constant or fading in (`ramp`), or silence.
private func makeTone(_ url: URL, seconds: Double, ramp: Bool = false, silent: Bool = false) throws {
    let rate = 44_100.0
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                                   AVEncoderBitRateKey: 64_000]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let frames = AVAudioFrameCount(seconds * rate)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
    buffer.frameLength = frames
    let data = buffer.floatChannelData![0]
    for i in 0..<Int(frames) {
        let t = Double(i) / rate
        let amp = silent ? 0 : ramp ? 0.8 * t / seconds : 0.5
        data[i] = Float(amp * sin(2 * .pi * 440 * t))
    }
    try file.write(from: buffer)
}

@MainActor private func notesSettings() -> NotesSettings {
    let s = NotesSettings(defaults: UserDefaults(suiteName: "ai.glancy.tests.voice.\(UUID().uuidString)")!)
    s.hotkey = Hotkey(keyCode: 0, modifiers: 0)        // never grab a real global hotkey in tests
    s.voiceHotkey = Hotkey(keyCode: 0, modifiers: 0)
    return s
}

// MARK: Fakes

@MainActor private final class FakeMic: MicAuthorizing {
    var access: MicAccess
    var grant: Bool
    var requests = 0
    init(_ access: MicAccess, grant: Bool = true) { self.access = access; self.grant = grant }
    func status() -> MicAccess { access }
    func request() async -> Bool {
        requests += 1
        access = grant ? .granted : .denied
        return grant
    }
}

@MainActor private final class FakeRecorder: VoiceRecording {
    static var made = 0
    let source: URL?
    let fails: Bool
    var url: URL?
    var currentTime: TimeInterval = 0
    var onEnded: (() -> Void)?
    var maxDuration: TimeInterval = 0
    init(source: URL?, fails: Bool = false) { self.source = source; self.fails = fails; Self.made += 1 }
    func start(url: URL, maxDuration: TimeInterval) throws {
        if fails { throw VoiceRecorderError() }
        self.url = url
        self.maxDuration = maxDuration
        if let source { try FileManager.default.copyItem(at: source, to: url) } else { FileManager.default.createFile(atPath: url.path, contents: Data()) }
    }
    func level() -> Float { 0.5 }
    func stop() -> TimeInterval { currentTime }
    func cancel() { if let url { try? FileManager.default.removeItem(at: url) } }
}

@MainActor private final class FakePlayer: VoicePlaying {
    let url: URL
    var duration: TimeInterval = 40
    var currentTime: TimeInterval = 0
    var rate: Float = 1
    var isPlaying = false
    var onFinish: (() -> Void)?
    init(url: URL) { self.url = url }
    func play() -> Bool { isPlaying = true; return true }
    func pause() { isPlaying = false }
}

private final class FakeTranscriber: NoteTranscribing, @unchecked Sendable {
    var access: SpeechAccess
    var onDevice: Bool
    var text: String
    var requests = 0
    var calls = 0
    var locales: [String] = []
    init(_ access: SpeechAccess, onDevice: Bool = true, text: String = "call marta about the projector") {
        self.access = access; self.onDevice = onDevice; self.text = text
    }
    @MainActor func status() -> SpeechAccess { access }
    @MainActor func request() async -> Bool { requests += 1; access = .granted; return true }
    func availableOnDevice(_ locale: Locale) -> Bool { onDevice }
    func transcribe(_ url: URL, locale: Locale) async throws -> String {
        calls += 1
        locales.append(locale.identifier)
        return text
    }
}

@MainActor private final class FakeMute: NotesMicControl {
    var muted: Bool
    var unmutes = 0
    init(muted: Bool) { self.muted = muted }
    var notesMicMuted: Bool { muted }
    func notesUnmuteMic() -> Bool { unmutes += 1; muted = false; return true }
}

/// A Notes module wired to fakes, its folder and a scratch folder.
@MainActor private struct Rig {
    let module: NotesModule
    let dir: URL
    let mic: FakeMic
    let transcriber: FakeTranscriber
    var voice: VoiceNotes { module.voice }
    var players: [FakePlayer] { playerBox.list }
    let playerBox: PlayerBox
    let hub = ActivityHub()

    final class PlayerBox { var list: [FakePlayer] = [] }

    init(_ name: String, mic: MicAccess = .granted, grant: Bool = true, speech: SpeechAccess = .granted, onDevice: Bool = true,
         failRecorder: Bool = false, source: URL? = nil, transcribe: Bool = true) {
        dir = tempDir(name)
        let fakeMic = FakeMic(mic, grant: grant)
        let tr = FakeTranscriber(speech, onDevice: onDevice)
        let box = PlayerBox()
        let system = VoiceSystem(mic: fakeMic, transcriber: tr,
                                 recorder: { FakeRecorder(source: source, fails: failRecorder) },
                                 player: { url in let p = FakePlayer(url: url); box.list.append(p); return p },
                                 analyze: { VoiceAnalysis.analyze($0) })
        let settings = notesSettings()
        settings.transcribe = transcribe
        module = NotesModule(store: NotesStore(directory: dir.appendingPathComponent("notes")), settings: settings,
                             debounce: .milliseconds(10), voiceSystem: system)
        self.mic = fakeMic
        self.transcriber = tr
        self.playerBox = box
        module.start(hub: hub)
    }

    var recorder: FakeRecorder? { Mirror(reflecting: voice).descendant("recorder") as? FakeRecorder }
    var notesDir: URL { dir.appendingPathComponent("notes") }

    /// Records `seconds` of the fake input and stops.
    @discardableResult
    func recordAndStop(_ seconds: TimeInterval = 3) async -> Note? {
        #expect(await voice.record() == .started)
        recorder?.currentTime = seconds
        return await voice.stop()
    }
}

private let toneURL: URL = {
    let u = tempDir("tone").appendingPathComponent("tone.m4a")
    try? makeTone(u, seconds: 2)
    return u
}()

// MARK: - Model and file format

@Suite struct VoiceNoteFileTests {
    @Test func audioMetadataRoundTrips() {
        let audio = NoteAudio(file: "2026-10-05 143210.m4a", duration: 42.34, waveform: [0, 12, 255, 128], transcribed: true)
        let text = "Voice note 14:32\ncall marta\n- [ ] book train"
        let raw = NoteFile.encode(text, audio: audio)
        #expect(raw.hasPrefix("---\naudio: 2026-10-05 143210.m4a\nduration: 42.3\nwaveform: AAz/gA==\ntranscribed: true\n---\n"))
        let (back, decoded) = NoteFile.decode(raw)
        #expect(back == text)
        #expect(decoded?.file == audio.file)
        #expect(decoded?.waveform == audio.waveform)
        #expect(decoded?.transcribed == true)
        #expect(abs((decoded?.duration ?? 0) - 42.3) < 0.001)
        // Re-encoding gives the same bytes.
        #expect(NoteFile.encode(back, audio: decoded) == raw)
    }

    @Test func oldNotesLoadUnchanged() {
        let plain = ["Groceries\n- [ ] milk", "", "---\nrule at the top\n---\nmore", "---\ntitle: Obsidian page\n---\nbody",
                     "---\naudio: ../../etc/passwd\n---\nx", "---\nno close"]
        for raw in plain {
            let (text, audio) = NoteFile.decode(raw)
            #expect(text == raw)
            #expect(audio == nil)
            #expect(NoteFile.encode(text, audio: audio) == raw)
        }
    }

    @Test func storeRoundTripAndOldFilesByteForByte() async throws {
        let dir = tempDir("store")
        let store = NotesStore(directory: dir)
        // A note written before voice notes existed.
        let old = "---\nnot front matter\n---\nOld note"
        try Data(old.utf8).write(to: dir.appendingPathComponent("old.md"))
        let audio = NoteAudio(file: "v.m4a", duration: 3, waveform: [1, 2, 3])
        await store.write(Note(id: "v", text: "Voice note 10:00", modified: .now, audio: audio))
        let all = await store.loadAll()
        let v = try #require(all.first { $0.id == "v" })
        #expect(v.audio == audio && v.text == "Voice note 10:00")
        let o = try #require(all.first { $0.id == "old" })
        #expect(o.audio == nil && o.text == old)
        await store.write(o)
        #expect(try String(contentsOf: dir.appendingPathComponent("old.md"), encoding: .utf8) == old)
    }

    @Test func voiceNoteIsNeverBlankAndTimesFormat() {
        #expect(Note(id: "a", text: "", modified: .now).isBlank)
        #expect(!Note(id: "a", text: " ", modified: .now, audio: NoteAudio(file: "a.m4a", duration: 1)).isBlank)
        #expect(VoiceTime.format(0) == "0:00")
        #expect(VoiceTime.format(42.9) == "0:42")
        #expect(VoiceTime.format(605) == "10:05")
        #expect(VoiceTime.format(3723) == "1:02:03")
    }

    @Test func transcriptGoesUnderTheTitleAboveTypedText() {
        #expect(NotesModel.inserting("words", into: "Voice note 9:12") == "Voice note 9:12\nwords")
        #expect(NotesModel.inserting("words", into: "Voice note 9:12\nmine") == "Voice note 9:12\nwords\nmine")
        #expect(NotesModel.inserting("words", into: "  ") == "words")
    }
}

// MARK: - Waveform

@Suite struct VoiceAnalysisTests {
    @Test func sineGivesDurationAndAFlatWaveform() throws {
        let url = tempDir("sine").appendingPathComponent("s.m4a")
        try makeTone(url, seconds: 2)
        let r = try #require(VoiceAnalysis.analyze(url))
        #expect(abs(r.duration - 2) < 0.1)
        #expect(r.waveform.count == VoiceAnalysis.bars)
        #expect(r.waveform.max() == 255)
        // Constant tone: every bar but the encoder's first/last frames is near full.
        #expect(r.waveform.dropFirst(2).dropLast(2).allSatisfy { $0 > 200 })
    }

    @Test func rampRisesAndSilenceIsFlat() throws {
        let dir = tempDir("ramp")
        let ramp = dir.appendingPathComponent("r.m4a")
        try makeTone(ramp, seconds: 2, ramp: true)
        let w = try #require(VoiceAnalysis.analyze(ramp)).waveform
        let q = w.count / 4
        let first = w.prefix(q).map(Int.init).reduce(0, +), last = w.suffix(q).map(Int.init).reduce(0, +)
        #expect(first < last)
        #expect(w[w.count / 2] < w[w.count - 3])
        let silent = dir.appendingPathComponent("z.m4a")
        try makeTone(silent, seconds: 1, silent: true)
        #expect(try #require(VoiceAnalysis.analyze(silent)).waveform.allSatisfy { $0 == 0 })
        #expect(VoiceAnalysis.analyze(dir.appendingPathComponent("missing.m4a")) == nil)
    }
}

// MARK: - Recording

@MainActor
@Suite(.serialized) struct VoiceRecordingTests {
    @Test func recordStopSavesAVoiceNoteBesideTheNotes() async throws {
        let rig = Rig("rec", speech: .denied, source: toneURL)
        #expect(rig.voice.phase == .idle)
        #expect(await rig.voice.record() == .started)
        #expect(rig.voice.isRecording)
        #expect(rig.hub.top?.id == NotesModule.voiceWingID)
        let maxDuration = rig.recorder?.maxDuration
        #expect(maxDuration == 1800)
        let temp = try #require(rig.recorder?.url)
        rig.recorder?.currentTime = 2
        let note = try #require(await rig.voice.stop())
        #expect(rig.voice.phase == .idle)
        #expect(rig.hub.top == nil)
        #expect(!FileManager.default.fileExists(atPath: temp.path))
        #expect(note.audio?.file == "\(note.id).m4a")
        #expect(abs((note.audio?.duration ?? 0) - 2) < 0.1)
        #expect(note.audio?.waveform.count == VoiceAnalysis.bars)
        #expect(note.text.hasPrefix("Voice note ") || note.text.hasPrefix("Nota vocale "))   // suites switch the language
        #expect(rig.module.model.selectedID == note.id)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(files(rig.notesDir) == ["\(note.id).m4a", "\(note.id).md"])
        let md = try String(contentsOf: rig.notesDir.appendingPathComponent("\(note.id).md"), encoding: .utf8)
        #expect(md.hasPrefix("---\naudio: \(note.id).m4a\n"))
        // Reloads as the same note.
        let loaded = await NotesStore(directory: rig.notesDir).loadAll()
        #expect(loaded.first?.audio == note.audio)
        rig.module.stop()
    }

    @Test func cancelLeavesNothing() async {
        let rig = Rig("cancel")
        #expect(await rig.voice.record() == .started)
        let temp = rig.recorder?.url
        rig.voice.cancel()
        #expect(rig.voice.phase == .idle)
        #expect(rig.hub.top == nil)
        #expect(temp.map { FileManager.default.fileExists(atPath: $0.path) } == false)
        #expect(rig.module.model.notes.isEmpty)
        #expect(files(rig.notesDir).isEmpty)
        rig.module.stop()
    }

    @Test func tooShortIsDropped() async {
        let rig = Rig("short")
        #expect(await rig.recordAndStop(0.2) == nil)
        #expect(rig.module.model.notes.isEmpty)
        #expect(rig.voice.phase == .idle)
        rig.module.stop()
    }

    @Test func maxLengthStopsAndSaves() async {
        let rig = Rig("max", source: toneURL)
        rig.voice.maxLengthOverride = 0.05
        #expect(await rig.voice.record() == .started)
        rig.recorder?.currentTime = 2
        #expect(rig.recorder?.maxDuration == 0.05)
        for _ in 0..<40 where rig.voice.phase != .idle { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(rig.voice.phase == .idle)
        #expect(rig.module.model.notes.count == 1)
        // The recorder ending on its own (input gone) saves too.
        let rig2 = Rig("ended", source: toneURL)
        #expect(await rig2.voice.record() == .started)
        rig2.recorder?.currentTime = 1
        rig2.recorder?.onEnded?()
        for _ in 0..<40 where rig2.voice.phase != .idle { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(rig2.module.model.notes.count == 1)
        rig.module.stop(); rig2.module.stop()
    }

    @Test func permissionAskedOnceThenDeniedCard() async {
        // First use: the prompt, granted → recording.
        let rig = Rig("perm", mic: .notDetermined, grant: true)
        #expect(await rig.voice.record() == .started)
        #expect(rig.mic.requests == 1)
        rig.voice.cancel()
        // Refused at the prompt: the card, nothing recording.
        let made = FakeRecorder.made
        let no = Rig("perm-no", mic: .notDetermined, grant: false)
        #expect(await no.voice.record() == .denied)
        #expect(no.voice.card == .micDenied)
        #expect(no.voice.phase == .idle)
        // Already denied: no prompt, the card again.
        let denied = Rig("perm-denied", mic: .denied)
        #expect(await denied.voice.record() == .denied)
        #expect(denied.mic.requests == 0)
        #expect(denied.voice.card == .micDenied)
        #expect(FakeRecorder.made == made)
        // The hotkey opens the tab on the card.
        var opened: [ModuleID?] = []
        denied.hub.onOpenRequest = { opened.append($0) }
        denied.voice.card = nil
        denied.module.toggleRecording()
        for _ in 0..<20 where opened.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(opened == [.notes])
        rig.module.stop(); no.module.stop(); denied.module.stop()
    }

    @Test func mutedMicShowsCardAndOneClickUnmuteRecords() async {
        let rig = Rig("muted")
        let mute = FakeMute(muted: true)
        rig.module.micControl = mute
        let made = FakeRecorder.made
        #expect(await rig.voice.record() == .muted)
        #expect(rig.voice.card == .micMuted)
        #expect(FakeRecorder.made == made)
        #expect(await rig.voice.unmuteAndRecord() == .started)
        #expect(mute.unmutes == 1)
        #expect(rig.voice.card == nil)
        #expect(rig.voice.isRecording)
        rig.voice.cancel()
        rig.module.stop()
    }

    @Test func recorderFailureShowsCard() async {
        let rig = Rig("fail", failRecorder: true)
        #expect(await rig.voice.record() == .failed)
        #expect(rig.voice.card == .failed)
        #expect(rig.voice.phase == .idle)
        #expect(rig.hub.top == nil)
        rig.module.stop()
    }

    @Test func ticksOnlyWhileSomethingShowsIt() async {
        let rig = Rig("tick")
        rig.voice.display = .wing
        #expect(rig.voice.tickInterval == nil)
        #expect(rig.voice.tickTask == nil)
        #expect(await rig.voice.record() == .started)
        #expect(rig.voice.tickInterval == .seconds(1))
        #expect(rig.voice.tickTask != nil)
        rig.voice.display = .tab
        #expect(rig.voice.tickInterval == .milliseconds(66))
        rig.recorder?.currentTime = 4
        try? await Task.sleep(for: .milliseconds(200))
        #expect(rig.voice.elapsed == 4)
        #expect(!rig.voice.levels.isEmpty && rig.voice.levels.count <= VoiceNotes.meterBars)
        rig.voice.display = .none
        #expect(rig.voice.tickTask == nil)
        rig.voice.cancel()
        rig.voice.display = .wing
        #expect(rig.voice.tickTask == nil)
        rig.module.stop()
    }

    @Test func moduleStopSavesARecordingInProgress() async {
        let rig = Rig("quit", source: toneURL)
        #expect(await rig.voice.record() == .started)
        rig.recorder?.currentTime = 2
        rig.module.stop()
        let ids = files(rig.notesDir)
        #expect(ids.count == 2)
        #expect(ids.contains { $0.hasSuffix(".m4a") } && ids.contains { $0.hasSuffix(".md") })
    }
}

// MARK: - Playback

@MainActor
@Suite(.serialized) struct VoicePlaybackTests {
    @Test func playPauseSeekSpeedAndFinish() async throws {
        let rig = Rig("play", source: toneURL, transcribe: false)
        rig.voice.display = .tab
        let note = try #require(await rig.recordAndStop(2))
        rig.voice.togglePlay(note)
        let p = try #require(rig.players.last)
        #expect(p.url.lastPathComponent == "\(note.id).m4a")
        #expect(rig.voice.playingID == note.id && rig.voice.isPlaying && p.isPlaying)
        #expect(rig.voice.tickTask != nil)
        rig.voice.togglePlay(note)
        #expect(!rig.voice.isPlaying && !p.isPlaying)
        #expect(rig.voice.tickTask == nil)
        rig.voice.seek(note, to: 0.5)
        #expect(p.currentTime == 20 && rig.voice.position(of: note) == 20)
        #expect(rig.players.count == 1)
        rig.voice.cycleRate(); #expect(rig.voice.rate == 1.5 && p.rate == 1.5)
        rig.voice.cycleRate(); #expect(rig.voice.rate == 2 && p.rate == 2)
        rig.voice.cycleRate(); #expect(rig.voice.rate == 1 && p.rate == 1)
        rig.voice.togglePlay(note)
        p.isPlaying = false
        p.onFinish?()
        #expect(!rig.voice.isPlaying && rig.voice.position == 0)
        // Leaving the tab unloads the player.
        rig.voice.togglePlay(note)
        rig.voice.display = .wing
        #expect(rig.voice.playingID == nil && !p.isPlaying)
        rig.module.stop()
    }

    @Test func deleteStopsPlaybackAndRemovesTheAudio() async throws {
        let rig = Rig("delete", source: toneURL, transcribe: false)
        rig.voice.display = .tab
        let note = try #require(await rig.recordAndStop(2))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(files(rig.notesDir).count == 2)
        rig.voice.togglePlay(note)
        rig.module.model.delete(note.id)
        #expect(rig.voice.playingID == nil)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(files(rig.notesDir).isEmpty)
        // The store alone, too.
        let store = NotesStore(directory: tempDir("del"))
        await store.write(Note(id: "x", text: "t", modified: .now, audio: NoteAudio(file: "x.m4a", duration: 1)))
        try Data([1]).write(to: store.directory.appendingPathComponent("x.m4a"))
        await store.delete("x")
        #expect(files(store.directory).isEmpty)
        rig.module.stop()
    }
}

// MARK: - Transcription

@MainActor
@Suite(.serialized) struct VoiceTranscriptionTests {
    @Test func transcriptFillsTheBodyAndIsSearchable() async throws {
        let rig = Rig("tr", speech: .granted, source: toneURL)
        rig.voice.transcriptionLocale = { VoiceLocale.current(italian: false) }
        let note = try #require(await rig.recordAndStop(2))
        #expect(rig.transcriber.calls == 1)
        #expect(rig.transcriber.locales == ["en-US"])
        #expect(note.text.hasSuffix("\ncall marta about the projector"))
        #expect(note.audio?.transcribed == true)
        #expect(rig.module.model.search("projector").map(\.id) == [note.id])
        let hits = rig.module.results(for: "projector")
        #expect(hits.first?.symbol == "waveform")
        #expect(hits.first?.subtitle == "call marta about the projector")
        rig.voice.transcriptionLocale = { VoiceLocale.current(italian: true) }
        _ = await rig.recordAndStop(2)
        #expect(rig.transcriber.locales.last == "it-IT")
        rig.module.stop()
    }

    @Test func firstUseAsksWithACardThenTranscribes() async throws {
        let rig = Rig("ask", speech: .notDetermined, source: toneURL)
        let note = try #require(await rig.recordAndStop(2))
        #expect(rig.voice.speechAskID == note.id)
        #expect(rig.transcriber.requests == 0 && rig.transcriber.calls == 0)
        await rig.voice.transcribe(note.id, ask: true)
        #expect(rig.transcriber.requests == 1 && rig.transcriber.calls == 1)
        #expect(rig.voice.speechAskID == nil)
        #expect(rig.module.model.notes.first?.audio?.transcribed == true)
        // "Not now" turns it off.
        let rig2 = Rig("decline", speech: .notDetermined, source: toneURL)
        _ = await rig2.recordAndStop(2)
        rig2.voice.declineTranscription()
        #expect(!rig2.module.model.settings.transcribe)
        _ = await rig2.recordAndStop(2)
        #expect(rig2.voice.speechAskID == nil && rig2.transcriber.calls == 0)
        rig.module.stop(); rig2.module.stop()
    }

    @Test func noOnDeviceModelOrDeniedMeansNoTranscript() async throws {
        let rig = Rig("nodev", speech: .granted, onDevice: false, source: toneURL)
        let note = try #require(await rig.recordAndStop(2))
        #expect(rig.transcriber.calls == 0)
        #expect(note.audio?.transcribed == false)
        let denied = Rig("nospeech", speech: .denied, source: toneURL)
        _ = await denied.recordAndStop(2)
        #expect(denied.transcriber.calls == 0 && denied.transcriber.requests == 0)
        let off = Rig("off", speech: .granted, source: toneURL, transcribe: false)
        _ = await off.recordAndStop(2)
        #expect(off.transcriber.calls == 0)
        rig.module.stop(); denied.module.stop(); off.module.stop()
    }
}

// MARK: - Hotkey and command bar

@MainActor
@Suite(.serialized) struct VoiceCommandTests {
    @Test func defaultHotkeyIsFreeAmongGlancysAndPersisted() {
        #expect(NotesSettings.defaultVoiceHotkey.description == "⌃⌥V")
        let ctrlOpt = UInt32(controlKey | optionKey)
        let windows = WindowsHotkeys()
        var others: [Hotkey] = Array(windows.allCombos)
        others += windows.arrangeBindings.compactMap { WindowsHotkeys.appVariant($0.1) }
        others += windows.allCombos.compactMap { WindowsHotkeys.appVariant($0) }
        others += [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
            .map { Hotkey(keyCode: UInt32($0), modifiers: ctrlOpt) }
        others += [NotesSettings.defaultHotkey, HUDSettings.defaultMicHotkey, CalendarSettings.defaultJoinHotkey,
                   CommandSettings.defaultHotkey, ClipboardSettings.defaultHotkey]
        let bindings = others.enumerated().map { HotkeyBinding(id: "other.\($0.offset)", title: "other", hotkey: $0.element) }
        let mine = HotkeyBinding(id: "notes.voice", title: "Voice note", hotkey: NotesSettings.defaultVoiceHotkey)
        #expect(HotkeyConflict.find(mine, among: bindings, system: [], failed: []) == nil)
        // A clash is reported.
        let clash = HotkeyBinding(id: "notes.voice", title: "Voice note", hotkey: NotesSettings.defaultHotkey)
        #expect(HotkeyConflict.find(clash, among: bindings, system: [], failed: []) != nil)
        // Settings keep a changed shortcut and the other voice options.
        let d = UserDefaults(suiteName: "ai.glancy.tests.voice.\(UUID().uuidString)")!
        let s = NotesSettings(defaults: d)
        #expect(s.voiceHotkey == NotesSettings.defaultVoiceHotkey && s.transcribe && s.maxMinutes == 30)
        s.voiceHotkey = Hotkey(keyCode: UInt32(kVK_ANSI_N), modifiers: ctrlOpt | UInt32(shiftKey))
        s.transcribe = false
        s.maxMinutes = 5
        let back = NotesSettings(defaults: d)
        #expect(back.voiceHotkey.description == "⌃⌥⇧N" && !back.transcribe && back.maxMinutes == 5)
    }

    @Test func commandsInEnglishAndItalian() async {
        let rig = Rig("cmds")
        L10n.apply(.en)
        #expect(rig.module.commands().map(\.title).contains("Record voice note"))
        #expect(rig.module.commands().first { $0.id == "notes.voice.record" }?.keywords.contains("registra") == true)
        // Italian only between awaits: other suites run meanwhile.
        L10n.apply(.it)
        let italian = rig.module.commands().map(\.title)
        L10n.apply(.en)
        #expect(italian.contains("Registra nota vocale"))
        // Running it records and closes the panel.
        var closed = 0
        rig.hub.onCloseRequest = { closed += 1 }
        rig.module.commands().first { $0.id == "notes.voice.record" }?.run()
        for _ in 0..<20 where !rig.voice.isRecording { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(rig.voice.isRecording)
        for _ in 0..<20 where closed == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(closed == 1)
        L10n.apply(.it)
        let italianStop = rig.module.commands().map(\.title)
        L10n.apply(.en)
        #expect(italianStop.contains("Ferma la registrazione"))
        #expect(rig.module.commands().map(\.id).suffix(2) == ["notes.voice.stop", "notes.voice.cancel"])
        #expect(rig.module.commands().map(\.title).contains("Stop recording"))
        rig.module.commands().first { $0.id == "notes.voice.cancel" }?.run()
        #expect(!rig.voice.isRecording)
        rig.module.stop()
    }

    @Test func hotkeyTogglesRecordingAndShowsSavedPeek() async {
        let rig = Rig("hotkey", source: toneURL, transcribe: false)
        rig.module.visibilityChanged(.collapsed)
        rig.module.toggleRecording()
        for _ in 0..<20 where !rig.voice.isRecording { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(rig.voice.isRecording)
        #expect(rig.voice.display == .wing)
        rig.recorder?.currentTime = 2
        rig.module.toggleRecording()
        for _ in 0..<40 where rig.hub.peek == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(rig.hub.peek?.module == .notes)
        #expect(rig.module.model.notes.count == 1)
        rig.module.stop()
    }
}
