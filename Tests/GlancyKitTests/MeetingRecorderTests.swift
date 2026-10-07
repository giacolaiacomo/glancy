import AVFoundation
import Foundation
import Observation
import Testing
@testable import GlancyKit

// The meeting recorder (lot W10-MEET) against fakes: no microphone is opened, no audio tap is
// created, no permission is asked. The only real audio is the track writer encoding generated
// buffers into a temp folder.

private func tempDir(_ name: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("glancy-meetings-tests-\(name)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private let m0 = Date(timeIntervalSince1970: 1_791_360_000)   // a Wednesday morning

private func zoomLink() -> MeetingLink? { MeetingLink.extract(url: URL(string: "https://zoom.us/j/5550100123"), location: nil, notes: nil) }
private func meetLink() -> MeetingLink? { MeetingLink.extract(url: URL(string: "https://meet.google.com/abc-defg-hij"), location: nil, notes: nil) }

private func event(_ id: String, _ title: String, start: TimeInterval, length: TimeInterval = 1800, link: MeetingLink? = zoomLink(),
                   allDay: Bool = false, declined: Bool = false) -> CalendarEvent {
    CalendarEvent(id: id, title: title, start: m0.addingTimeInterval(start), end: m0.addingTimeInterval(start + length),
                  isAllDay: allDay, isDeclined: declined, link: link)
}

private let zoom = MicClient(pid: 501, bundleID: "us.zoom.xos", name: "zoom.us")
private let chrome = MicClient(pid: 502, bundleID: "com.google.Chrome.helper", name: "Google Chrome Helper")
private let facetime = MicClient(pid: 503, bundleID: nil, name: "avconferenced")
private let other = MicClient(pid: 504, bundleID: "com.example.recorder", name: "Recorder")

@MainActor
private func waitUntil(_ seconds: Double = 5, _ cond: () -> Bool) async -> Bool {
    let end = Date.now.addingTimeInterval(seconds)
    while !cond() {
        if Date.now > end { return false }
        try? await Delay.sleep(for: .milliseconds(10))
    }
    return true
}

// MARK: Fakes

@MainActor private final class FakeWatcher: MicWatching {
    var snap = MicSnapshot.idle
    var onChange: (@MainActor () -> Void)?
    var starts = 0, stops = 0
    func start(onChange: @escaping @MainActor () -> Void) { starts += 1; self.onChange = onChange }
    func stop() { stops += 1; onChange = nil }
    func snapshot() -> MicSnapshot { snap }
    var listenerCount: Int { onChange == nil ? 0 : 2 }
    func set(_ clients: [MicClient]) {
        snap = MicSnapshot(running: !clients.isEmpty, clients: clients)
        onChange?()
    }
}

@MainActor private final class FakeCapture: MeetingCapturing {
    var started: (folder: URL, mic: Bool, system: Bool)?
    var stops = 0
    var quiet: TimeInterval?
    var fails = false
    var onTrackLost: ((MeetingSpeaker) -> Void)?
    func start(folder: URL, mic: Bool, system: Bool) async throws -> [MeetingSpeaker] {
        started = (folder, mic, system)
        if fails { return [] }
        var out: [MeetingSpeaker] = []
        if mic { out.append(.you) }
        if system { out.append(.others) }
        for s in out { FileManager.default.createFile(atPath: folder.appendingPathComponent(MeetingRecord.file(s)).path, contents: Data()) }
        return out
    }
    func silence() -> TimeInterval? { quiet }
    func stop() { stops += 1 }
}

@MainActor private final class FakePermissions: MeetingPermissions {
    var micAccess: MicAccess
    var systemAccess: MicAccess
    var speechAccess: SpeechAccess
    var grant: Bool
    var micRequests = 0, systemRequests = 0, speechRequests = 0
    init(mic: MicAccess = .granted, system: MicAccess = .granted, speech: SpeechAccess = .granted, grant: Bool = true) {
        micAccess = mic; systemAccess = system; speechAccess = speech; self.grant = grant
    }
    func mic() -> MicAccess { micAccess }
    func requestMic() async -> Bool { micRequests += 1; micAccess = grant ? .granted : .denied; return grant }
    func systemAudio() -> MicAccess { systemAccess }
    func requestSystemAudio() async -> Bool { systemRequests += 1; systemAccess = grant ? .granted : .denied; return grant }
    func speech() -> SpeechAccess { speechAccess }
    func requestSpeech() async -> Bool { speechRequests += 1; speechAccess = grant ? .granted : .denied; return grant }
}

private struct FakeTranscriber: MeetingTranscribing {
    var engineValue: MeetingSpeechEngine = .analyzer
    var needsSpeechPermission: Bool { engineValue == .recognizer }
    var you: [SpokenWord] = [SpokenWord(text: "Hello everyone.", start: 1, duration: 1.2),
                             SpokenWord(text: "Shall we start?", start: 20, duration: 1)]
    var others: [SpokenWord] = [SpokenWord(text: "Hi!", start: 4, duration: 0.5),
                                SpokenWord(text: "Yes, the numbers are in.", start: 5.5, duration: 2)]
    func engine(for locale: Locale) async -> MeetingSpeechEngine { engineValue }
    func transcribe(_ url: URL, locale: Locale, engine: MeetingSpeechEngine,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> [SpokenWord] {
        progress(0.5)
        progress(1)
        return url.lastPathComponent == MeetingRecord.file(.you) ? you : others
    }
}

@MainActor private final class FakeNotes: MeetingNotesSink {
    var notes: [String] = []
    func addMeetingNote(_ text: String) -> Bool { notes.append(text); return true }
}

@MainActor @Observable private final class FakeCalendar: MeetingCalendarSource {
    var events: [CalendarEvent] = []
    var meetingEvents: [CalendarEvent] { events }
}

@MainActor private final class Clock {
    var now = m0
}

@MainActor
private struct Rig {
    let module: MeetingsModule
    let watcher = FakeWatcher()
    let capture = FakeCapture()
    let permissions: FakePermissions
    let notes = FakeNotes()
    let calendar = FakeCalendar()
    let clock = Clock()
    let hub = ActivityHub()
    let dir: URL

    init(permissions: FakePermissions = FakePermissions(), transcriber: FakeTranscriber = FakeTranscriber(),
         mode: MeetingsMode = .ask, events: [CalendarEvent] = []) {
        self.permissions = permissions
        dir = tempDir("rig")
        let w = watcher, c = capture
        let settings = MeetingsSettings(defaults: UserDefaults(suiteName: "glancy.test.meetings.\(UUID().uuidString)")!)
        settings.mode = mode
        settings.language = .en
        module = MeetingsModule(store: MeetingsStore(directory: dir, usesTrash: false), settings: settings,
                                system: MeetingsSystem(watcher: { w }, capture: { c }, permissions: permissions, transcriber: transcriber,
                                                       player: { _ in nil }, reveal: { _ in }))
        let clock = clock
        module.clock = { clock.now }
        calendar.events = events
        module.calendar = calendar
        module.notes = notes
        module.start(hub: hub)
    }

    func advance(_ s: TimeInterval) { clock.now = clock.now.addingTimeInterval(s) }

    var folders: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") } }
}

// MARK: Detection (pure)

@Suite("Meetings: detection")
struct MeetingDetectionTests {
    @Test func aMeetingAppOnTheMicrophoneIsAMeetingNamedAfterTheCalendar() {
        let alone = MeetingDetector.detect(mic: MicSnapshot(running: true, clients: [zoom]), events: [], now: m0)
        #expect(alone?.key == "app:zoom" && alone?.app == "Zoom" && alone?.event == nil)
        // With a calendar meeting on (its link Zoom), the call takes its name and its end.
        let e = event("e1", "Design review", start: -120)
        let named = MeetingDetector.detect(mic: MicSnapshot(running: true, clients: [zoom]), events: [e], now: m0)
        #expect(named?.key == "event:e1" && named?.event?.title == "Design review" && named?.holderBundles == ["us.zoom."])
        // FaceTime's calls run in a daemon without a bundle.
        #expect(MeetingDetector.detect(mic: MicSnapshot(running: true, clients: [facetime]), events: [], now: m0)?.app == "FaceTime")
    }

    @Test func aBrowserOrAnotherAppCountsOnlyDuringACalendarMeetingWithALink() {
        #expect(MeetingDetector.detect(mic: MicSnapshot(running: true, clients: [chrome]), events: [], now: m0) == nil)
        #expect(MeetingDetector.detect(mic: MicSnapshot(running: true, clients: [other]), events: [], now: m0) == nil)
        let e = event("e2", "Weekly sync", start: 60, link: meetLink())   // starts in a minute: inside the early window
        let d = MeetingDetector.detect(mic: MicSnapshot(running: true, clients: [chrome]), events: [e], now: m0)
        #expect(d?.key == "event:e2" && d?.app == "Chrome" && d?.holderBundles == ["com.google.Chrome"])
        // No link, declined, all-day, too early, over: none of them count.
        for bad in [event("x", "No link", start: -60, link: nil), event("y", "Declined", start: -60, declined: true),
                    event("z", "All day", start: -3600, length: 86_400, allDay: true), event("w", "Later", start: 6 * 60),
                    event("v", "Over", start: -3600, length: 1800)] {
            #expect(MeetingDetector.detect(mic: MicSnapshot(running: true, clients: [chrome]), events: [bad], now: m0) == nil, "\(bad.title)")
        }
    }

    @Test func withoutProcessInformationTheMicrophoneDuringALinkedMeetingCounts() {
        let e = event("e3", "Standup", start: -60)
        #expect(MeetingDetector.detect(mic: MicSnapshot(running: true, clients: nil), events: [e], now: m0)?.key == "event:e3")
        #expect(MeetingDetector.detect(mic: MicSnapshot(running: true, clients: nil), events: [], now: m0) == nil)
        #expect(MeetingDetector.detect(mic: MicSnapshot(running: false, clients: nil), events: [e], now: m0) == nil)
        // A calendar meeting with nobody on the microphone is not a call yet.
        #expect(MeetingDetector.detect(mic: .idle, events: [e], now: m0) == nil)
    }

    @Test func holdingAndLettingGo() {
        let d = MeetingDetector.detect(mic: MicSnapshot(running: true, clients: [zoom]), events: [], now: m0)!
        #expect(MeetingDetector.stillHeld(d, mic: MicSnapshot(running: true, clients: [zoom, chrome])) == true)
        #expect(MeetingDetector.stillHeld(d, mic: MicSnapshot(running: true, clients: [chrome])) == false)
        #expect(MeetingDetector.stillHeld(d, mic: MicSnapshot(running: true, clients: nil)) == nil)
        #expect(MeetingDetector.stillHeld(MeetingDetection(key: "manual:1"), mic: .idle) == nil)
    }

    @Test func calendarBoundaries() {
        let e = event("e4", "Retro", start: 600, length: 1800)
        #expect(MeetingDetector.nextBoundary([e], after: m0) == m0.addingTimeInterval(300))     // 5 min early
        #expect(MeetingDetector.nextBoundary([e], after: m0.addingTimeInterval(400)) == m0.addingTimeInterval(2400))
        #expect(MeetingDetector.nextBoundary([e], after: m0.addingTimeInterval(3000)) == nil)
    }

    @Test func minutesFoldersAndClocks() {
        #expect(MeetingClock.minutes(59) == 0 && MeetingClock.minutes(60) == 1 && MeetingClock.minutes(3599) == 59)
        #expect(MeetingClock.nextMinute(start: m0, now: m0.addingTimeInterval(130)) == m0.addingTimeInterval(180))
        #expect(MeetingClock.stamp(247) == "04:07" && MeetingClock.stamp(3847) == "1:04:07")
        #expect(MeetingClock.clock(247) == "4:07")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Rome")!
        let name = MeetingFolder.name(start: m0, title: "Q3 / budget: \"final\"", taken: [], calendar: cal)
        #expect(!name.contains("/") && !name.contains(":") && !name.contains("\""))
        #expect(name.hasPrefix("2026-10-07 ") && name.hasSuffix("Q3 budget final"), "\(name)")
        #expect(MeetingFolder.name(start: m0, title: "Q3 / budget: \"final\"", taken: [name], calendar: cal) == name + " 2")
        #expect(MeetingFolder.sanitize("...hidden") == "hidden")
        #expect(MeetingFolder.sanitize(String(repeating: "a", count: 200)).count == MeetingFolder.maxTitle)
    }
}

// MARK: Speech pieces and the transcript (pure)

@Suite("Meetings: transcript")
struct MeetingTranscriptTests {
    @Test func longAudioIsCutInPausesIntoPiecesOfAtMost55Seconds() {
        // 3 minutes of "speech" with a quiet frame every 7 s; the first minute silent.
        var energy = [Float](repeating: 0.05, count: 1800)
        for i in stride(from: 0, to: 1800, by: 70) { energy[i] = 0.004 }
        for i in 0..<600 { energy[i] = 0.0005 }
        let plan = SpeechChunks.plan(energy: energy)
        #expect(plan.first?.frames.lowerBound == 0 && plan.last?.frames.upperBound == 1800)
        for (a, b) in zip(plan, plan.dropFirst()) { #expect(a.frames.upperBound == b.frames.lowerBound) }
        for c in plan.dropLast() {
            #expect(c.frames.count <= 550 && c.frames.count >= 400, "\(c.frames)")
        }
        #expect(plan.first?.silent == true)
        #expect(plan.dropFirst().contains { !$0.silent })
        // A cut lands on the quietest frame of its window.
        let cut = plan[1].frames.upperBound - 1
        #expect(energy[cut] <= 0.004)
    }

    @Test func wordsBecomeLinesAtPausesAndSentenceEnds() {
        let words = [SpokenWord(text: "So", start: 0, duration: 0.2), SpokenWord(text: "the", start: 0.25, duration: 0.1),
                     SpokenWord(text: "plan.", start: 0.4, duration: 0.3), SpokenWord(text: "Next", start: 1.3, duration: 0.2),
                     SpokenWord(text: "item", start: 1.55, duration: 0.2), SpokenWord(text: "later", start: 5, duration: 0.3)]
        let lines = TranscriptBuilder.lines(from: words, speaker: .you)
        #expect(lines.map(\.text) == ["So the plan.", "Next item", "later"])
        #expect(lines[1].start == 1.3)
    }

    @Test func bothTracksMergeInTimeAndTheEchoOfTheOthersIsDropped() {
        let you = [SpokenLine(speaker: .you, start: 1, end: 2, text: "Good morning"),
                   // The others, heard by the microphone through the speakers.
                   SpokenLine(speaker: .you, start: 6.2, end: 8, text: "the numbers are in for March"),
                   SpokenLine(speaker: .you, start: 20, end: 21, text: "Great, thanks")]
        let others = [SpokenLine(speaker: .others, start: 4, end: 5, text: "Hi"),
                      SpokenLine(speaker: .others, start: 6, end: 8, text: "The numbers are in for March."),
                      SpokenLine(speaker: .others, start: 8.5, end: 10, text: "Up four percent.")]
        let merged = TranscriptBuilder.merge(you: you, others: others)
        #expect(merged.map(\.speaker) == [.you, .others, .you])
        #expect(merged[1].text == "Hi The numbers are in for March. Up four percent.")
        #expect(!merged.contains { $0.speaker == .you && $0.text.contains("numbers") })
        let md = TranscriptBuilder.markdown(title: "Review", about: "Wed · 30 min", lines: merged, you: "You", others: "Others", empty: "Nobody spoke.")
        #expect(md.hasPrefix("# Review\n\nWed · 30 min\n\n**00:01 You:** Good morning\n\n**00:04 Others:** Hi"))
        let note = TranscriptBuilder.note(title: "Review", about: "Wed", lines: merged, you: "Tu", others: "Altri", empty: "")
        #expect(note.hasPrefix("Review\nWed\n\n00:01 Tu: Good morning\n00:04 Altri: Hi"))
        #expect(TranscriptBuilder.markdown(title: "T", about: "a", lines: [], you: "", others: "", empty: "Nobody spoke.").hasSuffix("_Nobody spoke._\n"))
    }

    @Test func theWriterEncodesAnyInputToSmallMonoAACAndHearsSound() async throws {
        let dir = tempDir("writer")
        let url = dir.appendingPathComponent("others.m4a")
        let writer = TrackWriter(url: url)
        #expect(TrackWriter.silence([writer]) == nil)
        // Two seconds of stereo 48 kHz: one of silence, one of a tone, in 10 ms IO cycles.
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        for cycle in 0..<200 {
            let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
            b.frameLength = 480
            for c in 0..<2 {
                for i in 0..<480 {
                    let t = Double(cycle * 480 + i) / 48_000
                    b.floatChannelData![c][i] = cycle < 100 ? 0 : Float(0.3 * sin(2 * .pi * 300 * t))
                }
            }
            writer.write(b)
        }
        let heard = try #require(TrackWriter.silence([writer]))
        #expect(heard < 2)
        writer.close()
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.channelCount == 1 && file.fileFormat.sampleRate == TrackWriter.rate)
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        #expect(abs(seconds - 2) < 0.15, "\(seconds)")
        let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        // ~32 kbit/s plus the container's fixed ~25 KB (two minutes measured at 505 KB: 15 MB an hour).
        #expect(size < 40_000, "\(size) bytes for 2 s")
        writer.write(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!)   // after close: dropped, no crash
    }
}

// MARK: The module, on fakes

@MainActor
@Suite("Meetings: module", .serialized)
struct MeetingsModuleTests {
    @Test func atRestItOnlyListens() {
        let rig = Rig()
        #expect(rig.watcher.starts == 1 && rig.watcher.listenerCount == 2)
        let census = ResourceCensus.of(rig.module)
        #expect(census.tasks == 0, "\(census)")
        #expect(rig.hub.top == nil && rig.hub.peek == nil)
        #expect(!rig.module.model.loaded)   // the list is read when the panel opens, not at start
        rig.module.settings.mode = .off
        #expect(rig.watcher.stops == 1 && rig.watcher.listenerCount == 0)
        rig.module.settings.mode = .ask
        #expect(rig.watcher.starts == 2)
        rig.module.stop()
        #expect(rig.watcher.listenerCount == 0)
        #expect(ResourceCensus.of(rig.module).tasks == 0)
    }

    @Test func aCallIsOfferedOnceAndNotNowHoldsUntilItEnds() async {
        let rig = Rig()
        rig.watcher.set([zoom])
        #expect(rig.module.model.phase == .offering && rig.module.model.title == "Zoom meeting")
        #expect(rig.hub.peek?.module == .meetings)
        rig.module.decline()
        #expect(rig.module.model.phase == .idle && rig.module.model.declined)
        // Another change while the call goes on: never asked again, nothing recorded.
        rig.watcher.set([zoom, chrome])
        #expect(rig.module.model.phase == .idle && rig.capture.started == nil)
        // A short release (a mute in some apps) keeps the answer…
        rig.watcher.set([])
        rig.advance(20)
        rig.watcher.set([zoom])
        #expect(rig.module.model.phase == .idle)
        // …a real end clears it: the next call asks again.
        rig.watcher.set([])
        rig.advance(90)
        rig.watcher.set([zoom])
        #expect(rig.module.model.phase == .offering)
        rig.module.stop()
    }

    @Test func anIgnoredOfferStaysInThePanelAndGoesWithTheCall() {
        let rig = Rig()
        rig.watcher.set([zoom])
        #expect(rig.module.model.phase == .offering)
        #expect(rig.module.homeWidgets().first?.widget == .meetings)
        rig.watcher.set([])
        rig.advance(10)
        rig.module.evaluate()
        #expect(rig.module.model.phase == .offering)     // not yet: maybe a mute
        rig.advance(25)
        rig.module.evaluate()
        #expect(rig.module.model.phase == .idle && rig.module.homeWidgets().isEmpty)
        #expect(rig.capture.started == nil)
        rig.module.stop()
    }

    @Test func recordAsksForBothPermissionsThenRecordsTwoTracks() async {
        let perms = FakePermissions(mic: .notDetermined, system: .notDetermined)
        let rig = Rig(permissions: perms, events: [event("e1", "Design review", start: -60)])
        rig.watcher.set([zoom])
        #expect(rig.module.model.title == "Design review")
        rig.module.record()
        #expect(await waitUntil { rig.module.model.phase == .recording })
        #expect(perms.micRequests == 1 && perms.systemRequests == 1)
        #expect(rig.capture.started?.mic == true && rig.capture.started?.system == true)
        #expect(rig.module.model.tracks == [.you, .others] && rig.module.model.notice == nil)
        // The wing: a red dot and the minutes.
        #expect(rig.hub.top?.id == MeetingsModule.wingID && rig.hub.top?.priority == 70)
        #expect(rig.module.model.minutes == 0)
        #expect(rig.folders.count == 1 && rig.folders[0].hasSuffix("Design review"))
        let meta = rig.dir.appendingPathComponent(rig.folders[0]).appendingPathComponent("meeting.json")
        #expect(await waitUntil { FileManager.default.fileExists(atPath: meta.path) })
        // A minute later the wing says so (one wake-up armed, nothing else).
        rig.advance(61)
        rig.module.tick()
        #expect(rig.module.model.minutes == 1)
        rig.module.stop()
        #expect(rig.capture.stops == 1)
    }

    @Test func whenTheCallLetsGoItStopsAfterTheGraceAndWritesTheTranscriptAndANote() async throws {
        let rig = Rig()
        rig.watcher.set([zoom])
        rig.module.record()
        #expect(await waitUntil { rig.module.model.phase == .recording })
        rig.advance(30 * 60)
        rig.module.tick()
        rig.watcher.set([])                   // Zoom left the call
        rig.advance(20)
        rig.module.tick()
        #expect(rig.module.model.phase == .recording)
        rig.watcher.set([zoom])               // …came back within the grace
        rig.watcher.set([])                   // …and left again: the grace starts over
        rig.advance(20)
        rig.module.tick()
        #expect(rig.module.model.phase == .recording)
        rig.advance(10)
        rig.module.tick()
        #expect(rig.module.model.phase == .idle && rig.capture.stops == 1)
        #expect(rig.hub.top == nil)
        let r = try #require(rig.module.model.records.first)
        #expect(abs(r.duration - (30 * 60 + 20 + 30)) < 1)
        #expect(await waitUntil { rig.module.model.record(r.id)?.transcript == .done })
        let md = try String(contentsOf: rig.dir.appendingPathComponent(r.id).appendingPathComponent("transcript.md"), encoding: .utf8)
        #expect(md.contains("**00:01 You:** Hello everyone."))
        #expect(md.contains("**00:04 Others:** Hi! Yes, the numbers are in."))
        #expect(md.contains("**00:20 You:** Shall we start?"))
        #expect(rig.notes.notes.count == 1 && rig.notes.notes[0].hasPrefix("Zoom meeting\n"))
        #expect(rig.notes.notes[0].contains("00:04 Others: Hi! Yes, the numbers are in."))
        // The call goes on after Stop (or comes back at once): not asked again.
        rig.watcher.set([zoom])
        #expect(rig.module.model.phase == .idle)
        rig.module.stop()
    }

    @Test func alwaysRecordsCalendarMeetingsWithoutAskingAndSaysSo() async {
        let rig = Rig(mode: .always, events: [event("e1", "Board", start: -30)])
        rig.watcher.set([zoom])
        #expect(await waitUntil { rig.module.model.phase == .recording })
        #expect(rig.module.model.auto && rig.permissions.micRequests == 0)
        #expect(rig.hub.peek?.module == .meetings)   // never silent: the drop-down says so, with Stop
        rig.module.stop()
    }

    @Test func alwaysFallsBackToTheCardWithoutAMeetingOrPermissions() {
        let noEvent = Rig(mode: .always)
        noEvent.watcher.set([zoom])
        #expect(noEvent.module.model.phase == .offering)
        noEvent.module.stop()
        let noPermission = Rig(permissions: FakePermissions(system: .notDetermined), mode: .always,
                               events: [event("e1", "Board", start: -30)])
        noPermission.watcher.set([zoom])
        #expect(noPermission.module.model.phase == .offering && noPermission.permissions.systemRequests == 0)
        noPermission.module.stop()
    }

    @Test func aCalendarMeetingStopsTenMinutesAfterItsEndOnceQuiet() async {
        let rig = Rig(events: [event("e1", "Sync", start: -60, length: 1800)])
        rig.watcher.set([chrome])
        rig.module.record()
        #expect(await waitUntil { rig.module.model.phase == .recording })
        rig.capture.quiet = 5                 // still talking
        rig.advance(1740 + 600)               // end + 10 min
        rig.module.tick()
        #expect(rig.module.model.phase == .recording)
        rig.capture.quiet = 90                // quiet for a minute and a half
        rig.advance(60)
        rig.module.tick()
        #expect(rig.module.model.phase == .recording)   // next check two minutes after the first
        rig.advance(60)
        rig.module.tick()
        #expect(rig.module.model.phase == .idle)
        rig.module.stop()
    }

    @Test func discardTakesTwoClicksAndLeavesNothing() async {
        let rig = Rig()
        rig.module.record()
        #expect(await waitUntil { rig.module.model.phase == .recording })
        rig.advance(120)
        rig.module.discard()
        #expect(rig.module.model.phase == .recording && rig.module.model.confirmingDiscard)
        rig.module.discard()
        #expect(rig.module.model.phase == .idle && rig.capture.stops == 1)
        #expect(await waitUntil { rig.folders.isEmpty })
        #expect(rig.module.model.records.isEmpty && rig.hub.top == nil)
        rig.module.stop()
    }

    @Test func withoutMicrophoneAndSystemAudioNothingIsRecorded() async {
        let perms = FakePermissions(mic: .notDetermined, system: .denied, grant: false)
        let rig = Rig(permissions: perms)
        rig.module.record()
        #expect(await waitUntil { rig.module.model.notice == .cantHear })
        #expect(rig.module.model.phase == .idle && rig.capture.started == nil && rig.folders.isEmpty)
        #expect(perms.micRequests == 1 && perms.systemRequests == 0)   // denied: Settings, not a prompt
        rig.module.stop()
    }

    @Test func onlyTheMicrophoneStillRecordsAndSaysSo() async {
        let rig = Rig(permissions: FakePermissions(system: .denied))
        rig.module.record()
        #expect(await waitUntil { rig.module.model.phase == .recording })
        #expect(rig.capture.started?.system == false && rig.module.model.notice == .youOnly)
        rig.module.stop()
    }

    @Test func aRecordingPressedByMistakeIsThrownAway() async {
        let rig = Rig()
        rig.module.record()
        #expect(await waitUntil { rig.module.model.phase == .recording })
        rig.advance(1)
        rig.module.stopRecording()
        #expect(await waitUntil { rig.folders.isEmpty })
        #expect(rig.module.model.records.isEmpty)
        rig.module.stop()
    }

    @Test func turningTheModuleOffMidRecordingSavesItForLater() async throws {
        let rig = Rig()
        rig.module.record()
        #expect(await waitUntil { rig.module.model.phase == .recording })
        rig.advance(600)
        rig.module.stop()
        #expect(rig.capture.stops == 1 && rig.watcher.listenerCount == 0)
        let records = await rig.module.store.loadAll()
        let r = try #require(records.first)
        #expect(r.duration == 600 && r.transcript == .pending && r.tracks == [.you, .others])
        #expect(ResourceCensus.of(rig.module).tasks == 0)
    }

    @Test func speechRecognitionIsAskedOnlyAfterAStopYouPressed() async throws {
        let auto = Rig(permissions: FakePermissions(speech: .notDetermined), transcriber: FakeTranscriber(engineValue: .recognizer))
        auto.watcher.set([zoom])
        auto.module.record()
        #expect(await waitUntil { auto.module.model.phase == .recording })
        auto.advance(300)
        auto.watcher.set([])
        auto.advance(31)
        auto.module.tick()
        let id = try #require(auto.module.model.records.first?.id)
        #expect(await waitUntil { auto.module.model.record(id)?.transcript == .needsPermission })
        #expect(auto.permissions.speechRequests == 0)
        // The row's button is a user action: now it asks, then writes.
        auto.module.transcribe(id)
        #expect(await waitUntil { auto.module.model.record(id)?.transcript == .done })
        #expect(auto.permissions.speechRequests == 1)
        auto.module.stop()
    }

    @Test func theCalendarIsObservedNotPolled() async {
        let rig = Rig()
        rig.watcher.set([chrome])                      // a browser: nothing without a meeting
        #expect(rig.module.model.phase == .idle)
        rig.calendar.events = [event("e9", "Customer call", start: -10, link: meetLink())]
        #expect(await waitUntil { rig.module.model.phase == .offering })
        #expect(rig.module.model.title == "Customer call")
        rig.module.stop()
    }

    @Test func theListIsReadWhenThePanelOpensAndDeleteGoesToTheTrashOnTheSecondClick() async throws {
        let rig = Rig()
        rig.module.record()
        #expect(await waitUntil { rig.module.model.phase == .recording })
        rig.advance(300)
        rig.module.stop()
        // A fresh start: nothing in memory until the panel opens.
        rig.module.start(hub: rig.hub)
        #expect(rig.module.model.records.count == 1)   // kept from before (same object)
        let fresh = MeetingsModule(store: rig.module.store, settings: MeetingsSettings(defaults: UserDefaults(suiteName: "glancy.test.meetings.\(UUID().uuidString)")!),
                                   system: .inert)
        fresh.start(hub: ActivityHub())
        #expect(fresh.model.records.isEmpty)
        fresh.visibilityChanged(.expanded(.meetings))
        #expect(await waitUntil { fresh.model.loaded })
        let id = try #require(fresh.model.records.first?.id)
        fresh.delete(id)
        #expect(fresh.model.confirmingDelete == id && fresh.model.records.count == 1)
        fresh.delete(id)
        #expect(fresh.model.records.isEmpty)
        #expect(await waitUntil { rig.folders.isEmpty })
        fresh.stop()
        rig.module.stop()
    }

    @Test func notesTakeATranscriptOnlyWhileRunning() async {
        let notes = NotesModule(store: NotesStore(directory: tempDir("notes")),
                                settings: NotesSettings(defaults: UserDefaults(suiteName: "glancy.test.meetings.notes.\(UUID().uuidString)")!),
                                voiceSystem: .sample)
        notes.model.settings.hotkey = Hotkey(keyCode: 0, modifiers: 0)
        notes.model.settings.voiceHotkey = Hotkey(keyCode: 0, modifiers: 0)
        #expect(!notes.addMeetingNote("Design review\nline"))
        notes.start(hub: ActivityHub())
        let selected = notes.model.selectedID
        #expect(notes.addMeetingNote("Design review\n00:01 You: hello"))
        #expect(notes.model.notes.first?.title == "Design review")
        #expect(notes.model.selectedID == selected)    // the tab stays where it was
        #expect(await waitUntil { (try? FileManager.default.contentsOfDirectory(atPath: notes.model.store.directory.path))?.count == 1 })
        notes.stop()
    }

    @Test func theConsentDropDownFitsInBothLanguages() {
        let it = MeetingsText.italian
        let en = MeetingPeek.titleRoom("Record this meeting?", pills: ["Record", "Not now"])
        let itRoom = MeetingPeek.titleRoom(it["Record this meeting?"]!, pills: [it["Record"]!, it["Not now"]!])
        #expect(en >= 0 && itRoom >= 0, "\(en) \(itRoom)")   // the question and both buttons always fit
    }

    @Test func everyStringHasItsItalian() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/GlancyKit/Meetings")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        let pattern = try NSRegularExpression(pattern: #"L10n\.tr\("((?:[^"\\]|\\.)*)""#)
        var keys: Set<String> = []
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
            for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                keys.insert((text as NSString).substring(with: m.range(at: 1)).replacingOccurrences(of: "\\\"", with: "\""))
            }
        }
        #expect(keys.count > 60)
        for k in keys.sorted() { #expect(MeetingsText.italian[k] != nil, "no Italian for \(k.debugDescription)") }
        for w in [HomeWidget.meetings] {
            for s in [w.title, w.when, w.idle] { #expect(MeetingsText.italian[s] != nil, "\(s)") }
        }
    }
}

// MARK: At rest on this Mac (opt-in, with the cost tests)

/// The real listeners (CoreAudio property listeners: no microphone opened, no tap, nothing asked):
/// what Meetings costs at rest. Run alone: `GLANCY_COST_TESTS=1 swift test --filter MeetingsAtRest`.
@MainActor
@Suite("Meetings: at rest on this Mac", .enabled(if: collapsedCostTestsEnabled))
struct MeetingsAtRestCostTests {
    private func footprintKB() -> Double {
        var usage = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &usage) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return ok == 0 ? Double(usage.ri_phys_footprint) / 1024 : 0
    }

    private func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }

    @Test func theRealListenersCostNothingAtRest() async throws {
        _ = HAL.inputDevices()                       // the HAL: HUD and Media load it in the app anyway
        try await Delay.sleep(for: .seconds(1))
        let before = footprintKB()
        let watcher = CoreAudioMicWatcher()
        var changes = 0
        watcher.start { changes += 1 }
        try await Delay.sleep(for: .seconds(1))
        let started = footprintKB()
        let c0 = cpuSeconds(), t0 = Date.now
        try await Delay.sleep(for: .seconds(5))
        let cpu = (cpuSeconds() - c0) / Date.now.timeIntervalSince(t0) * 100
        let listeners = watcher.listenerCount
        watcher.stop()
        print(String(format: "meetings at rest: %d listeners, footprint %+.0f KB, CPU %.2f%% over 5 s, %d changes",
                     listeners, started - before, cpu, changes))
        #expect(listeners >= 1)
        #expect(watcher.listenerCount == 0)
        #expect(started - before < 1024)             // ≤ +1 MB
        #expect(cpu < 0.5)                           // nothing runs between events (the test process idle)
    }
}
