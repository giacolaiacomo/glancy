import AppKit
import Observation
import SwiftUI

/// Records meetings, with consent: when a call takes the microphone (Zoom, Teams, Webex, FaceTime,
/// Slack, or a browser during a calendar meeting with a link) a drop-down asks "Record this
/// meeting?". Recording writes two tracks — you (the microphone) and the others (what the Mac
/// plays) — and stops when the call lets go of the microphone, on Stop, or after the calendar
/// meeting has ended and gone quiet. Then the tracks are written out on this Mac, as "You" and
/// "Others" lines in transcript.md (and a note in Notes).
///
/// Opt-in, off by default. At rest: a few CoreAudio property listeners, nothing else — no polling,
/// no timer, no audio open. While recording: the wing (a red dot, the minutes, changed once a
/// minute) and one wake-up armed at the next thing due.
@MainActor
public final class MeetingsModule: GlancyModule {
    public let id: ModuleID = .meetings
    public let model = MeetingsModel()
    public let settings: MeetingsSettings
    public let store: MeetingsStore
    let system: MeetingsSystem
    /// Made-up recordings and fixed states (the renderer, the lab); nothing real is opened.
    let sample: Bool
    /// The clock (tests move it).
    var clock: () -> Date

    /// Calendar meetings (the Calendar module) and Notes, held weakly; nil = none.
    public weak var calendar: MeetingCalendarSource?
    public weak var notes: MeetingNotesSink?

    private(set) var hub: ActivityHub?
    private var started = false
    private var watcher: MicWatching?
    private var capture: MeetingCapturing?
    private var player: MeetingPlaying?
    /// The recording under way.
    private var current: MeetingRecord?
    /// Meetings already offered or answered while their microphone stays in use: never asked twice.
    private var handled: Set<String> = []
    /// Since when no meeting holds the microphone (a short release — a mute in some apps — keeps
    /// "Not now" and the offer).
    private var freeSince: Date?
    private var micBusy = false
    private var releaseAt: Date?
    private var endCheckAt: Date?
    private var capAt: Date?
    /// Bumped to drop a calendar observation armed before (no way to cancel one).
    private var calendarGeneration = 0

    private var wake: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?
    private var copyTask: Task<Void, Never>?
    private var transcribing: [String: Task<Void, Never>] = [:]

    static let wingID = "meetings.recording"
    /// Above charging (60), voice notes (57) and agents working (50); below the HUD (75), a timer
    /// finishing (80), a meeting starting (85) and agents waiting (90).
    static let wingPriority = 70
    /// How long the "Record this meeting?" drop-down stays; the offer stays in the tab and on Home.
    static let offerSeconds: TimeInterval = 10
    public static let symbol = "person.2.wave.2"

    public convenience init() {
        let env = ProcessInfo.processInfo
        if env.processName == "glancy-render" || env.environment["GLANCY_MEETINGS_SAMPLE"] == "1" {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glancy-meetings-sample", isDirectory: true)
            let suite = "ai.glancy.meetings.sample"
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            self.init(store: MeetingsStore(directory: dir), settings: MeetingsSettings(defaults: UserDefaults(suiteName: suite)!),
                      system: .sample, sample: true)
        } else {
            self.init(store: MeetingsStore(), settings: MeetingsSettings(), system: .system)
        }
    }

    public init(store: MeetingsStore, settings: MeetingsSettings, system: MeetingsSystem, sample: Bool = false,
                clock: @escaping () -> Date = { .now }) {
        self.store = store
        self.settings = settings
        self.system = system
        self.sample = sample
        self.clock = clock
        // Settings → Meetings is reachable while the module is off: its strings must be there too.
        L10n.addItalian(MeetingsText.italian)
    }

    var permissions: MeetingPermissions { system.permissions }

    // MARK: Lifecycle

    public func start(hub: ActivityHub) {
        guard !started else { return }
        started = true
        self.hub = hub
        L10n.addItalian(MeetingsText.italian)
        settings.onModeChange = { [weak self] in self?.modeChanged() }
        if sample {
            MeetingsSample.fill(model, now: clock())
            return
        }
        listen()
    }

    public func stop() {
        guard started else { return }
        started = false
        finishNow()
        startTask?.cancel(); startTask = nil
        loadTask?.cancel(); loadTask = nil
        playTask?.cancel(); playTask = nil
        copyTask?.cancel(); copyTask = nil
        for t in transcribing.values { t.cancel() }
        transcribing = [:]
        wake?.cancel(); wake = nil
        player?.stop(); player = nil
        unlisten()
        settings.onModeChange = nil
        hub?.clearAll(from: .meetings)
        hub = nil
        model.phase = .idle
        model.detection = nil
        model.playing = nil
        model.progress = [:]
        model.confirmingDiscard = false
        model.confirmingDelete = nil
        handled = []
        freeSince = nil
        micBusy = false
    }

    public func visibilityChanged(_ visibility: SurfaceVisibility) {
        guard started else { return }
        if case .expanded = visibility { loadIfNeeded() }
        if visibility == .collapsed || visibility == .hidden {
            model.confirmingDelete = nil
            model.confirmingDiscard = false
        }
    }

    /// The microphone listeners and the calendar, unless the mode is Off.
    private func listen() {
        guard started, !sample, settings.mode != .off, watcher == nil else { return }
        let w = system.watcher()
        watcher = w
        w.start { [weak self] in self?.evaluate() }
        observeCalendar()
        evaluate()
    }

    private func unlisten() {
        watcher?.stop()
        watcher = nil
        calendarGeneration &+= 1
    }

    private func modeChanged() {
        guard started, !sample else { return }
        if settings.mode == .off {
            unlisten()
            if model.phase == .offering { withdrawOffer() }
            armWake()
        } else {
            listen()
        }
    }

    /// The calendar's events, observed (no polling): a meeting starting or ending re-checks.
    private func observeCalendar() {
        guard let calendar else { return }
        calendarGeneration &+= 1
        let generation = calendarGeneration
        withObservationTracking {
            _ = calendar.meetingEvents
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.started, self.calendarGeneration == generation else { return }
                self.observeCalendar()
                self.evaluate()
            }
        }
    }

    // MARK: Detection

    /// Looks at the microphone and the calendar: offers, starts, keeps or ends what is due.
    func evaluate() {
        guard started, !sample else { return }
        let now = clock()
        let snapshot = watcher?.snapshot() ?? MicSnapshot(running: false, clients: nil)
        let events = calendar?.meetingEvents ?? []
        let found = watcher == nil ? nil : MeetingDetector.detect(mic: snapshot, events: events, now: now)
        micBusy = snapshot.running || !(snapshot.clients ?? []).isEmpty
        if found != nil {
            if let f = freeSince, now.timeIntervalSince(f) >= 60 { handled = [] }
            freeSince = nil
        } else if freeSince == nil {
            freeSince = now
        }

        switch model.phase {
        case .recording:
            if current != nil, let d = model.detection, watcher != nil {
                switch MeetingDetector.stillHeld(d, mic: snapshot) {
                case .some(false): if releaseAt == nil { releaseAt = now.addingTimeInterval(MeetingStopRules.releaseGrace) }
                case .some(true): releaseAt = nil
                case nil: break
                }
            }
        case .starting:
            break
        case .offering:
            if let found {
                handled.insert(found.key)
                model.detection = found
                model.title = title(for: found)
            } else if let f = freeSince, now.timeIntervalSince(f) >= MeetingStopRules.releaseGrace {
                withdrawOffer()
            }
        case .idle:
            if found == nil, let f = freeSince, now.timeIntervalSince(f) >= MeetingStopRules.releaseGrace { model.declined = false }
            guard let found, !handled.contains(found.key) else { break }
            handled.insert(found.key)
            if settings.mode == .always, found.event != nil, permissions.mic() == .granted, permissions.systemAudio() == .granted {
                record(found, auto: true)
            } else if settings.mode != .off {
                offer(found)
            }
        }
        armWake()
    }

    private func offer(_ d: MeetingDetection) {
        model.phase = .offering
        model.detection = d
        model.title = title(for: d)
        model.declined = false
        model.notice = nil
        showPeek()
    }

    private func withdrawOffer() {
        model.phase = .idle
        model.detection = nil
        model.title = ""
    }

    private func showPeek() {
        hub?.show(PeekEvent(module: .meetings, duration: Self.offerSeconds,
                            content: AnyView(MeetingPeek(model: model, actions: actions).environment(\.locale, L10n.locale))))
    }

    /// "Not now": no recording, and no asking again while this meeting holds the microphone.
    public func decline() {
        guard model.phase == .offering else { return }
        if let d = model.detection { handled.insert(d.key) }
        model.phase = .idle
        model.declined = true
        model.detection = nil
    }

    func title(for d: MeetingDetection) -> String {
        if let e = d.event, !e.title.trimmingCharacters(in: .whitespaces).isEmpty { return e.title }
        if let app = d.app { return L10n.tr("%@ meeting", app) }
        return L10n.tr("Meeting")
    }

    // MARK: Recording

    /// Record now: the meeting offered, the one on the microphone, or a meeting of its own.
    public func record() {
        let d = model.detection ?? manualDetection()
        record(d, auto: false)
    }

    private func manualDetection() -> MeetingDetection {
        let now = clock()
        if let e = MeetingDetector.inProgress(calendar?.meetingEvents ?? [], now: now).first {
            return MeetingDetection(key: "event:\(e.id)", event: e)
        }
        return MeetingDetection(key: "manual:\(Int(now.timeIntervalSince1970))")
    }

    func record(_ d: MeetingDetection, auto: Bool) {
        guard started, !sample, startTask == nil, model.phase == .idle || model.phase == .offering else { return }
        handled.insert(d.key)
        model.phase = .starting
        model.detection = d
        model.title = title(for: d)
        model.notice = nil
        model.declined = false
        startTask = Task { [weak self] in
            await self?.begin(d, auto: auto)
            self?.startTask = nil
        }
    }

    private func begin(_ d: MeetingDetection, auto: Bool) async {
        var mic = permissions.mic()
        if mic == .notDetermined, !auto { mic = await permissions.requestMic() ? .granted : .denied }
        guard started, model.phase == .starting else { return }
        var others = permissions.systemAudio()
        if others == .notDetermined, !auto { others = await permissions.requestSystemAudio() ? .granted : .denied }
        guard started, model.phase == .starting else { return }
        guard mic == .granted || others == .granted else {
            model.phase = .idle
            model.notice = .cantHear
            return
        }
        let start = clock()
        guard let id = await store.makeFolder(start: start, title: model.title) else { return fail() }
        guard started, model.phase == .starting else { await store.remove(id); return }
        let capture = system.capture()
        capture.onTrackLost = { [weak self] speaker in self?.trackLost(speaker) }
        let tracks = (try? await capture.start(folder: store.folder(id), mic: mic == .granted, system: others == .granted)) ?? []
        guard started, model.phase == .starting else {
            capture.stop()
            await store.remove(id)
            return
        }
        guard !tracks.isEmpty else {
            capture.stop()
            await store.remove(id)
            return fail()
        }
        self.capture = capture
        let r = MeetingRecord(id: id, title: model.title, start: start, app: d.app, eventID: d.event?.id,
                              language: transcriptLocale.identifier, tracks: tracks)
        current = r
        model.phase = .recording
        model.started = start
        model.minutes = 0
        model.tracks = tracks
        model.auto = auto
        model.confirmingDiscard = false
        model.notice = tracks.count == 2 ? nil : tracks == [.you] ? .youOnly : .othersOnly
        releaseAt = nil
        endCheckAt = d.event.map { MeetingStopRules.endCheck(eventEnd: $0.end) }
        capAt = start.addingTimeInterval(MeetingStopRules.maxLength)
        postWing()
        // Never silent: a recording that began by itself says so, with Stop.
        if auto { showPeek() }
        let store = store
        Task { await store.save(r) }   // length 0 until the end: a crash still leaves a listed folder
        evaluate()
    }

    private func fail() {
        model.phase = .idle
        model.notice = .failed
    }

    /// A device went away for good: the other track goes on; with none left, the recording ends.
    private func trackLost(_ speaker: MeetingSpeaker) {
        guard model.phase == .recording else { return }
        model.tracks.removeAll { $0 == speaker }
        if model.tracks.isEmpty { return stopRecording(user: false) }
        model.notice = speaker == .you ? .othersOnly : .youOnly
    }

    /// Stop: the files are finished, the transcript is written next.
    public func stopRecording() { stopRecording(user: true) }

    func stopRecording(user: Bool) {
        if model.phase == .starting {
            startTask?.cancel(); startTask = nil
            model.phase = .idle
            return
        }
        guard model.phase == .recording, var r = current else { return }
        capture?.stop()
        capture = nil
        r.duration = max(0, clock().timeIntervalSince(r.start))
        endRecordingState()
        if let key = model.detection?.key { handled.insert(key) }
        model.detection = nil
        let store = store
        guard r.duration >= MeetingStopRules.minLength else {
            Task { await store.remove(r.id) }
            return
        }
        model.update(r)
        transcribe(r.id, userAction: user)
    }

    /// Discard: two clicks; the folder goes for good.
    public func discard() {
        guard model.phase == .recording || model.phase == .starting else { return }
        guard model.confirmingDiscard else { model.confirmingDiscard = true; return }
        if model.phase == .starting { stopRecording(user: true); model.confirmingDiscard = false; return }
        capture?.stop()
        capture = nil
        let id = current?.id
        endRecordingState()
        model.detection = nil
        let store = store
        if let id { Task { await store.remove(id) } }
    }

    private func endRecordingState() {
        current = nil
        model.phase = .idle
        model.started = nil
        model.minutes = 0
        model.tracks = []
        model.auto = false
        model.confirmingDiscard = false
        releaseAt = nil
        endCheckAt = nil
        capAt = nil
        hub?.clear(Self.wingID)
        armWake()
    }

    /// The module stops (turned off, Glancy quitting) mid-recording: the files are finished and
    /// listed; the transcript waits for a Transcribe click.
    private func finishNow() {
        guard model.phase == .recording, var r = current else { return }
        capture?.stop()
        capture = nil
        r.duration = max(0, clock().timeIntervalSince(r.start))
        if r.duration < MeetingStopRules.minLength {
            try? FileManager.default.removeItem(at: store.folder(r.id))
        } else {
            MeetingsStore.write(r, in: store.directory)
            model.update(r)
        }
        endRecordingState()
    }

    // MARK: The one wake-up

    /// Sleeps until the next thing due: the wing's next minute, the release grace ending, the
    /// calendar meeting's end check, the length cap, an offer to withdraw, or — while the
    /// microphone is in use — a calendar meeting coming into or out of its window. Nothing at rest.
    private func armWake() {
        wake?.cancel()
        wake = nil
        guard started else { return }
        let now = clock()
        var due: [Date] = []
        if model.phase == .recording, let start = model.started {
            due.append(MeetingClock.nextMinute(start: start, now: now))
            if let releaseAt { due.append(releaseAt) }
            if let endCheckAt { due.append(endCheckAt) }
            if let capAt { due.append(capAt) }
        } else if micBusy, watcher != nil, let b = MeetingDetector.nextBoundary(calendar?.meetingEvents ?? [], after: now) {
            due.append(b)
        }
        if model.phase == .offering, let f = freeSince { due.append(f.addingTimeInterval(MeetingStopRules.releaseGrace)) }
        if model.declined, let f = freeSince { due.append(f.addingTimeInterval(MeetingStopRules.releaseGrace)) }
        guard let next = due.min() else { return }
        let wait = max(0.05, next.timeIntervalSince(now))
        wake = Task { [weak self] in
            try? await Delay.sleep(for: .milliseconds(Int(wait * 1000)))
            guard !Task.isCancelled else { return }
            self?.tick()
        }
    }

    func tick() {
        wake = nil
        guard started else { return }
        let now = clock()
        if model.phase == .recording, let start = model.started {
            model.minutes = MeetingClock.minutes(now.timeIntervalSince(start))
            if let releaseAt, now >= releaseAt { return stopRecording(user: false) }
            if let capAt, now >= capAt { return stopRecording(user: false) }
            if let e = endCheckAt, now >= e {
                if MeetingStopRules.quietEnough(capture?.silence()) { return stopRecording(user: false) }
                endCheckAt = now.addingTimeInterval(MeetingStopRules.recheck)
            }
        }
        if watcher != nil { evaluate() } else { armWake() }
    }

    // MARK: Wing

    private func postWing() {
        hub?.post(LiveActivity(id: Self.wingID, module: .meetings, priority: Self.wingPriority,
                               left: AnyView(MeetingWingLeft()), right: AnyView(MeetingWingRight(model: model))))
    }

    // MARK: Transcripts

    var transcriptLocale: Locale { settings.language.locale(italian: L10n.isItalian) }

    /// Writes the transcript of a recording (after Stop, or the Transcribe button), off the main thread.
    public func transcribe(_ id: String) { transcribe(id, userAction: true) }

    func transcribe(_ id: String, userAction: Bool) {
        guard started, transcribing[id] == nil, model.record(id) != nil else { return }
        model.progress[id] = 0
        transcribing[id] = Task { [weak self] in
            await self?.runTranscript(id, userAction: userAction)
            self?.transcribing[id] = nil
            self?.model.progress[id] = nil
        }
    }

    private func runTranscript(_ id: String, userAction: Bool) async {
        guard var r = model.record(id) else { return }
        let store = store
        await store.save(r)
        let locale = Locale(identifier: r.language)
        let engine = await system.transcriber.engine(for: locale)
        guard !Task.isCancelled else { return }
        if engine == .unavailable { return await finish(&r, .unavailable) }
        if engine == .recognizer {
            var speech = permissions.speech()
            if speech == .notDetermined, userAction { speech = await permissions.requestSpeech() ? .granted : .denied }
            guard speech == .granted else { return await finish(&r, .needsPermission) }
        }
        var lines: [MeetingSpeaker: [SpokenLine]] = [:]
        let tracks = r.tracks
        do {
            for (i, speaker) in tracks.enumerated() {
                let url = store.audio(id, speaker)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let share = 1 / Double(max(1, tracks.count)), base = Double(i) * share
                let words = try await system.transcriber.transcribe(url, locale: locale, engine: engine) { [weak self] p in
                    Task { @MainActor [weak self] in self?.setProgress(id, base + share * p) }
                }
                lines[speaker] = TranscriptBuilder.lines(from: words, speaker: speaker)
            }
        } catch {
            if Task.isCancelled { return }   // turned off or quitting: stays pending
            return await finish(&r, .failed)
        }
        guard !Task.isCancelled else { return }
        let merged = TranscriptBuilder.merge(you: lines[.you] ?? [], others: lines[.others] ?? [])
        let it = locale.language.languageCode?.identifier == "it"
        let names = MeetingsText.speakers(italian: it)
        let about = MeetingsText.about(r, italian: it)
        let empty = MeetingsText.nobodySpoke(italian: it)
        let markdown = TranscriptBuilder.markdown(title: r.title, about: about, lines: merged, you: names.you, others: names.others, empty: empty)
        guard await store.writeTranscript(id, markdown) else { return await finish(&r, .failed) }
        r.lines = merged.count
        await finish(&r, merged.isEmpty ? .empty : .done)
        if settings.saveToNotes, !merged.isEmpty {
            _ = notes?.addMeetingNote(TranscriptBuilder.note(title: r.title, about: about, lines: merged,
                                                             you: names.you, others: names.others, empty: empty))
        }
    }

    private func finish(_ r: inout MeetingRecord, _ state: TranscriptState) async {
        r.transcript = state
        if let latest = model.record(r.id) { r.title = latest.title }
        model.update(r)
        await store.save(r)
    }

    private func setProgress(_ id: String, _ p: Double) {
        guard transcribing[id] != nil else { return }
        let old = model.progress[id] ?? 0
        // Whole per cents only: the row redraws at most a hundred times.
        if (p * 100).rounded(.down) > (old * 100).rounded(.down) { model.progress[id] = min(1, p) }
    }

    // MARK: Recordings

    func loadIfNeeded() {
        guard !model.loaded, loadTask == nil, !sample else { return }
        let store = store
        loadTask = Task { [weak self] in
            let all = await store.loadAll()
            guard let self, !Task.isCancelled else { return }
            let mine = Set(self.model.records.map(\.id))
            self.model.records = (self.model.records + all.filter { !mine.contains($0.id) }).sorted { $0.start > $1.start }
            self.model.loaded = true
            self.loadTask = nil
        }
    }

    public func togglePlay(_ id: String) {
        if model.playing == id {
            player?.stop(); player = nil
            model.playing = nil
            return
        }
        player?.stop(); player = nil
        playTask?.cancel()
        guard let r = model.record(id) else { return }
        model.playing = id
        guard !sample else { return }
        let files = r.tracks.map { store.audio(id, $0) }
        playTask = Task { [weak self] in
            guard let self else { return }
            let p = await self.system.player(files)
            self.playTask = nil
            guard !Task.isCancelled, self.model.playing == id, let p else {
                if self.model.playing == id { self.model.playing = nil }
                return
            }
            p.onFinish = { [weak self] in
                self?.player?.stop(); self?.player = nil
                self?.model.playing = nil
            }
            self.player = p
            p.play()
        }
    }

    public func reveal(_ id: String? = nil) {
        let url = id.map { store.folder($0) } ?? store.directory
        try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        system.reveal(url)
    }

    public func copyTranscript(_ id: String, to pasteboard: NSPasteboard = .general) {
        let store = store
        copyTask?.cancel()
        copyTask = Task { [weak self] in
            guard let text = await store.readTranscript(id), let self, !Task.isCancelled else { return }
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            self.model.copied = id
            self.copyTask = nil
        }
    }

    /// Delete: two clicks; the folder goes to the Trash.
    public func delete(_ id: String) {
        guard model.confirmingDelete == id else { model.confirmingDelete = id; return }
        model.confirmingDelete = nil
        if model.playing == id { togglePlay(id) }
        transcribing.removeValue(forKey: id)?.cancel()
        model.progress[id] = nil
        model.records.removeAll { $0.id == id }
        guard !sample else { return }
        let store = store
        Task { _ = await store.trash(id) }
    }

    public func dismissNotice() { model.notice = nil }

    var actions: MeetingActions {
        MeetingActions(record: { [weak self] in self?.record() }, notNow: { [weak self] in self?.decline() },
                       stop: { [weak self] in self?.stopRecording() }, discard: { [weak self] in self?.discard() },
                       openTab: { [weak self] in self?.hub?.requestOpen(.meetings) })
    }

    // MARK: Panel

    public var tab: PanelTab? {
        PanelTab(module: .meetings, symbol: Self.symbol, title: "Meetings") { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(MeetingsTabView(module: self, model: self.model).environment(\.locale, L10n.locale))
        }
    }

    public func homeWidgets() -> [HomeWidgetCard] {
        let busy = model.phase != .idle || !model.progress.isEmpty || model.notice == .cantHear || model.notice == .failed
        guard busy else { return [] }
        let view = AnyView(MeetingsHomeCard(module: self, model: model).environment(\.locale, L10n.locale))
        // An offer is a question with a short life: first on Home.
        return [HomeWidgetCard(.meetings, view, priority: model.phase == .offering ? 80 : nil)]
    }

    public func homeIdleCard(_ widget: HomeWidget) -> AnyView? {
        guard widget == .meetings else { return nil }
        loadIfNeeded()
        guard let last = model.records.first else { return nil }
        return AnyView(MeetingsIdleCard(module: self, model: model, record: last).environment(\.locale, L10n.locale))
    }

    public func commands() -> [GlancyCommand] {
        var out: [GlancyCommand] = []
        if model.phase == .recording {
            out.append(GlancyCommand(id: "meetings.stop", module: .meetings, title: L10n.tr("Stop recording the meeting"),
                                     subtitle: model.title, symbol: "stop.circle.fill",
                                     keywords: ["stop", "meeting", "recording", "ferma", "riunione", "registrazione"], rank: 20) { [weak self] in
                self?.stopRecording()
            })
        } else if model.phase == .idle || model.phase == .offering {
            out.append(GlancyCommand(id: "meetings.record", module: .meetings, title: L10n.tr("Record the meeting"),
                                     subtitle: model.phase == .offering ? model.title : nil, symbol: "record.circle",
                                     keywords: ["record", "meeting", "call", "transcript", "registra", "riunione", "chiamata", "trascrizione"],
                                     closesPanel: true) { [weak self] in self?.record() })
        }
        out.append(GlancyCommand(id: "meetings.open", module: .meetings, title: L10n.tr("Meeting recordings"), symbol: Self.symbol,
                                 keywords: ["meetings", "recordings", "transcripts", "riunioni", "registrazioni", "trascrizioni"],
                                 closesPanel: false) { [weak self] in self?.hub?.requestOpen(.meetings) })
        return out
    }

    /// Settings → Modules: one line.
    var settingsSummary: String {
        switch settings.mode {
        case .ask: L10n.tr("Asks when a call starts")
        case .always: L10n.tr("Records calendar meetings")
        case .off: L10n.tr("Only when you press Record")
        }
    }

    // MARK: Renders and the lab

    public enum RenderState: String, CaseIterable, Sendable {
        case list, playing, offer, recording, transcribing, cantHear, empty
    }

    /// Fixed states on made-up recordings (`glancy-render`, the lab); nothing is opened.
    public func prepareForRender(_ state: RenderState) {
        guard sample else { return }
        let now = clock()
        hub?.clear(Self.wingID)
        model.phase = .idle
        model.detection = nil
        model.notice = nil
        model.declined = false
        model.progress = [:]
        model.playing = nil
        model.confirmingDelete = nil
        MeetingsSample.fill(model, now: now)
        switch state {
        case .list:
            break
        case .playing:
            model.playing = MeetingsSample.records(now)[0].id
        case .offer:
            let d = MeetingsSample.detection(now)
            model.phase = .offering
            model.detection = d
            model.title = title(for: d)
        case .recording:
            let d = MeetingsSample.detection(now)
            model.phase = .recording
            model.detection = d
            model.title = title(for: d)
            // Seven minutes in: the next minute is exactly a minute away.
            model.started = now.addingTimeInterval(-7 * 60)
            model.minutes = 7
            model.tracks = [.you, .others]
            postWing()
        case .transcribing:
            model.progress[MeetingsSample.records(now)[0].id] = 0.42
        case .cantHear:
            model.notice = .cantHear
        case .empty:
            model.records = []
        }
    }

    /// The consent drop-down, as a call starts (sample).
    public func showSampleOffer() {
        prepareForRender(.offer)
        showPeek()
    }

    /// A recording that began by itself: the drop-down with Stop (sample).
    public func showSampleAutoPeek() {
        prepareForRender(.recording)
        model.auto = true
        showPeek()
    }

    /// The lab's `meetings.encode` state: a real recording flow on synthetic audio, the real
    /// writers encoding two tracks at real time into the lab's scratch folder.
    func startSyntheticRecording() {
        guard started else { return }
        let synthetic = SyntheticCapture()
        let d = MeetingsSample.detection(clock())
        model.phase = .starting
        model.detection = d
        model.title = title(for: d)
        startTask = Task { [weak self] in
            guard let self else { return }
            let start = self.clock()
            guard let id = await self.store.makeFolder(start: start, title: self.model.title) else { return }
            let tracks = (try? await synthetic.start(folder: self.store.folder(id), mic: true, system: true)) ?? []
            self.capture = synthetic
            self.current = MeetingRecord(id: id, title: self.model.title, start: start, language: "en-US", tracks: tracks)
            self.model.phase = .recording
            self.model.started = start
            self.model.tracks = tracks
            self.postWing()
            self.startTask = nil
        }
    }
}

/// What the meeting views can do (closures into the module, held weakly there).
struct MeetingActions {
    let record: @MainActor () -> Void
    let notNow: @MainActor () -> Void
    let stop: @MainActor () -> Void
    let discard: @MainActor () -> Void
    let openTab: @MainActor () -> Void
}
