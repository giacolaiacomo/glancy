import Foundation
import Observation

/// What the Notes tab needs to know about the microphone mute (the HUD module's). Optional and
/// weak: with the HUD off, recording just goes ahead.
@MainActor
public protocol NotesMicControl: AnyObject {
    /// The default input is muted, so a recording would be silent.
    var notesMicMuted: Bool { get }
    /// Unmutes it; false when that could not be done.
    func notesUnmuteMic() -> Bool
}

/// Recording, playing and transcribing voice notes.
///
/// Recording: idle → (permission) → recording → saving → idle, or cancelled. Only a click, the
/// hotkey or a command starts it. The recorder exists only while recording, the player only while
/// a note is loaded in it.
///
/// Ticking: the elapsed time, the meter and the play head are refreshed by one task that runs only
/// while something on screen shows them — 15×/s with the Notes tab open, once a second for the
/// collapsed wing while recording, never otherwise (no recording, nothing playing → no task).
@MainActor @Observable
public final class VoiceNotes {
    public enum Phase: Equatable, Sendable { case idle, asking, recording, saving }
    /// A card in place of the editor.
    public enum Card: Equatable, Sendable { case micDenied, micMuted, failed }
    public enum StartResult: Equatable, Sendable { case started, denied, muted, failed, busy }
    /// Where the recording / play head is on screen.
    public enum Display: Equatable, Sendable { case none, wing, tab }

    public private(set) var phase: Phase = .idle
    public var card: Card?
    /// Seconds recorded.
    public private(set) var elapsed: TimeInterval = 0
    /// The last input levels (0…1), newest last, for the meter.
    public private(set) var levels: [Float] = []
    static let meterBars = 56

    // Playback
    public private(set) var playingID: String?
    public private(set) var isPlaying = false
    public private(set) var position: TimeInterval = 0
    public private(set) var rate: Float = 1
    public static let rates: [Float] = [1, 1.5, 2]

    // Transcription
    public private(set) var transcribing: Set<String> = []
    /// The note waiting for a yes to Speech Recognition (the explanation card).
    public private(set) var speechAskID: String?

    @ObservationIgnored let notes: NotesModel
    @ObservationIgnored public weak var micControl: NotesMicControl?
    @ObservationIgnored private let mic: MicAuthorizing
    @ObservationIgnored private let makeRecorder: @MainActor () -> VoiceRecording
    @ObservationIgnored private let makePlayer: @MainActor (URL) -> VoicePlaying?
    @ObservationIgnored let transcriber: NoteTranscribing
    @ObservationIgnored private let analyze: @Sendable (URL) -> (duration: TimeInterval, waveform: [UInt8])?
    @ObservationIgnored private let scratch: URL
    /// Tests shorten the length limit; otherwise `settings.maxMinutes`.
    @ObservationIgnored var maxLengthOverride: TimeInterval?
    /// The app's language (it-IT / en-US); tests pin it.
    @ObservationIgnored var transcriptionLocale: () -> Locale = { VoiceLocale.current(italian: L10n.isItalian) }
    /// Recordings shorter than this are dropped (a double press).
    @ObservationIgnored var minimumLength: TimeInterval = 0.5

    @ObservationIgnored private var recorder: VoiceRecording?
    @ObservationIgnored private var recordingURL: URL?
    @ObservationIgnored private var startedAt = Date.distantPast
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var player: VoicePlaying?
    @ObservationIgnored private(set) var tickTask: Task<Void, Never>?
    @ObservationIgnored public var display: Display = .none { didSet { if display != oldValue { displayChanged(oldValue) } } }

    /// Recording started (true) or ended (false): the module posts / clears the wing.
    @ObservationIgnored var onRecordingChange: ((Bool) -> Void)?

    init(notes: NotesModel, mic: MicAuthorizing, transcriber: NoteTranscribing,
         makeRecorder: @escaping @MainActor () -> VoiceRecording,
         makePlayer: @escaping @MainActor (URL) -> VoicePlaying?,
         analyze: @escaping @Sendable (URL) -> (duration: TimeInterval, waveform: [UInt8])? = { VoiceAnalysis.analyze($0) },
         scratch: URL = FileManager.default.temporaryDirectory) {
        self.notes = notes
        self.mic = mic
        self.transcriber = transcriber
        self.makeRecorder = makeRecorder
        self.makePlayer = makePlayer
        self.analyze = analyze
        self.scratch = scratch
    }

    var settings: NotesSettings { notes.settings }
    public var isRecording: Bool { phase == .recording }
    var maxLength: TimeInterval { maxLengthOverride ?? TimeInterval(settings.maxMinutes * 60) }

    // MARK: Recording

    /// Starts recording now, asking for the microphone the first time. A muted mic or a refused
    /// permission puts up a card instead (the caller opens the tab to show it).
    @discardableResult
    public func record() async -> StartResult {
        guard phase == .idle else { return .busy }
        if micControl?.notesMicMuted == true { card = .micMuted; return .muted }
        switch mic.status() {
        case .denied:
            card = .micDenied
            return .denied
        case .notDetermined:
            phase = .asking
            let ok = await mic.request()
            phase = .idle
            guard ok else { card = .micDenied; return .denied }
        case .granted:
            break
        }
        return begin()
    }

    /// "Unmute and record" on the muted card.
    @discardableResult
    public func unmuteAndRecord() async -> StartResult {
        guard let micControl, micControl.notesUnmuteMic() else { return .muted }
        card = nil
        return await record()
    }

    private func begin() -> StartResult {
        stopPlayback()
        let url = scratch.appendingPathComponent("glancy-voice-\(UUID().uuidString).m4a")
        let r = makeRecorder()
        do { try r.start(url: url, maxDuration: maxLength) } catch {
            card = .failed
            return .failed
        }
        r.onEnded = { [weak self] in Task { await self?.stop() } }
        recorder = r
        recordingURL = url
        startedAt = notes.now()
        elapsed = 0
        levels = []
        card = nil
        phase = .recording
        let limit = maxLength
        deadline = Task { [weak self] in
            // One wake-up at the limit (the recorder also stops itself there).
            try? await Delay.sleep(for: .seconds(limit))
            guard !Task.isCancelled else { return }
            await self?.stop()
        }
        onRecordingChange?(true)
        retick()
        return .started
    }

    /// Stops and saves the recording as a new note (selected); transcribes it when allowed.
    @discardableResult
    public func stop() async -> Note? {
        guard phase == .recording, let r = recorder, let temp = recordingURL else { return nil }
        let length = r.stop()
        endRecording()
        guard length >= minimumLength else {
            try? FileManager.default.removeItem(at: temp)
            phase = .idle
            return nil
        }
        phase = .saving
        let fm = FileManager.default
        let dir = notes.store.directory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let id = Note.newID(at: startedAt, taken: Set(notes.notes.map(\.id)).union(Self.taken(in: dir)))
        let file = "\(id).m4a"
        let dest = dir.appendingPathComponent(file)
        do { try fm.moveItem(at: temp, to: dest) } catch {
            try? fm.removeItem(at: temp)
            phase = .idle
            card = .failed
            return nil
        }
        let analyze = analyze
        let info = await Task.detached(priority: .userInitiated) { analyze(dest) }.value
        let audio = NoteAudio(file: file, duration: info?.duration ?? length, waveform: info?.waveform ?? [])
        let note = notes.addVoiceNote(id: id, title: Self.title(at: startedAt), audio: audio)
        phase = .idle
        if settings.transcribe { await transcribe(note.id, ask: false) }
        return notes.notes.first { $0.id == note.id } ?? note
    }

    /// Saves a recording in progress at once, without waiting (quitting, the module turned off):
    /// no waveform or transcript yet — the note still plays.
    func finishNow() {
        guard phase == .recording, let r = recorder, let temp = recordingURL else { return }
        let length = r.stop()
        endRecording()
        phase = .idle
        let dir = notes.store.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let id = Note.newID(at: startedAt, taken: Set(notes.notes.map(\.id)).union(Self.taken(in: dir)))
        guard length >= minimumLength, (try? FileManager.default.moveItem(at: temp, to: dir.appendingPathComponent("\(id).m4a"))) != nil else {
            try? FileManager.default.removeItem(at: temp)
            return
        }
        notes.addVoiceNote(id: id, title: Self.title(at: startedAt), audio: NoteAudio(file: "\(id).m4a", duration: length))
    }

    /// Throws the recording away.
    public func cancel() {
        guard phase == .recording, let r = recorder else { return }
        r.cancel()
        if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
        endRecording()
        phase = .idle
    }

    private func endRecording() {
        recorder?.onEnded = nil
        recorder = nil
        recordingURL = nil
        deadline?.cancel()
        deadline = nil
        onRecordingChange?(false)
        retick()
    }

    /// Ids already used by a file in the folder (an `.m4a` must never be overwritten).
    private static func taken(in dir: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return Set(names.map { ($0 as NSString).deletingPathExtension })
    }

    /// "Voice note 14:32".
    static func title(at date: Date) -> String {
        let f = DateFormatter()
        f.locale = L10n.locale
        f.timeStyle = .short
        f.dateStyle = .none
        return L10n.tr("Voice note %@", f.string(from: date))
    }

    // MARK: Transcription

    /// Transcribes a voice note on this Mac. `ask` = the user said yes on the explanation card
    /// (the system prompt may follow); without it a first use only puts that card up.
    public func transcribe(_ id: String, ask: Bool) async {
        guard let note = notes.notes.first(where: { $0.id == id }), note.audio != nil,
              let url = notes.audioURL(note), !transcribing.contains(id) else { return }
        switch transcriber.status() {
        case .denied:
            return
        case .notDetermined:
            guard ask else { speechAskID = id; return }
            speechAskID = nil
            guard await transcriber.request() else { return }
        case .granted:
            break
        }
        speechAskID = nil
        let locale = transcriptionLocale()
        let transcriber = transcriber
        guard transcriber.availableOnDevice(locale) else { return }
        transcribing.insert(id)
        let text = try? await Task.detached(priority: .utility) { try await transcriber.transcribe(url, locale: locale) }.value
        transcribing.remove(id)
        guard let text else { return }
        notes.fillTranscript(id, text)
    }

    /// "Not now" on the explanation card: transcription off (Settings → Notes turns it back on).
    public func declineTranscription() {
        speechAskID = nil
        settings.transcribe = false
    }

    // MARK: Playback

    /// Play / pause a note's recording.
    public func togglePlay(_ note: Note) {
        if playingID == note.id, let player {
            if player.isPlaying { player.pause(); isPlaying = false } else { isPlaying = player.play() }
            position = player.currentTime
            retick()
            return
        }
        guard load(note) else { return }
        isPlaying = player?.play() ?? false
        retick()
    }

    /// Moves the play head of a note (0…1 of its length), loading it if needed.
    public func seek(_ note: Note, to fraction: Double) {
        if playingID != note.id { guard load(note) else { return } }
        guard let player else { return }
        player.currentTime = max(0, min(1, fraction)) * player.duration
        position = player.currentTime
    }

    /// 1× → 1.5× → 2× → 1×.
    public func cycleRate() {
        let i = Self.rates.firstIndex(of: rate) ?? 0
        rate = Self.rates[(i + 1) % Self.rates.count]
        player?.rate = rate
    }

    /// The play head of `note` (0 when another note is loaded).
    public func position(of note: Note) -> TimeInterval { playingID == note.id ? position : 0 }

    private func load(_ note: Note) -> Bool {
        stopPlayback()
        guard phase == .idle, let url = notes.audioURL(note), let p = makePlayer(url) else { return false }
        p.rate = rate
        p.onFinish = { [weak self] in self?.finished() }
        player = p
        playingID = note.id
        position = 0
        return true
    }

    private func finished() {
        isPlaying = false
        position = 0
        player?.currentTime = 0
        retick()
    }

    /// Unloads the player.
    public func stopPlayback() {
        player?.pause()
        player?.onFinish = nil
        player = nil
        playingID = nil
        isPlaying = false
        position = 0
        retick()
    }

    // MARK: Ticking

    private func displayChanged(_ old: Display) {
        // Leaving the tab ends playback (nothing would show it; no player kept around).
        if old == .tab, player != nil { stopPlayback() }
        retick()
    }

    /// The refresh interval right now, or nil when nothing on screen needs one.
    var tickInterval: Duration? {
        switch display {
        case .tab: return phase == .recording || isPlaying ? .milliseconds(66) : nil
        case .wing: return phase == .recording ? .seconds(1) : nil
        case .none: return nil
        }
    }

    private func retick() {
        tickTask?.cancel()
        tickTask = nil
        guard let interval = tickInterval else { return }
        tick()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Delay.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    func tick() {
        if phase == .recording, let recorder {
            elapsed = recorder.currentTime
            if display == .tab {
                levels.append(recorder.level())
                if levels.count > Self.meterBars { levels.removeFirst(levels.count - Self.meterBars) }
            }
        }
        if isPlaying, let player { position = player.currentTime }
    }

    // MARK: Renders

    /// A fixed state for `glancy-render`: nothing is recorded or played.
    func setSample(phase: Phase, elapsed: TimeInterval = 0, levels: [Float] = [], card: Card? = nil,
                   playing: String? = nil, position: TimeInterval = 0, rate: Float = 1, transcribing: Set<String> = [],
                   speechAsk: String? = nil) {
        self.phase = phase
        self.elapsed = elapsed
        self.levels = levels
        self.card = card
        self.playingID = playing
        self.isPlaying = playing != nil
        self.position = position
        self.rate = rate
        self.transcribing = transcribing
        self.speechAskID = speechAsk
    }
}
