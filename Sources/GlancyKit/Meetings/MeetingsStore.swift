import AVFoundation
import Foundation

/// Where a recording's transcript stands.
public enum TranscriptState: String, Codable, Sendable {
    /// Not written yet (just recorded, or interrupted: a quit, the module turned off).
    case pending
    case done
    /// Transcribed, nobody spoke.
    case empty
    case failed
    /// Speech Recognition has not been allowed (the SFSpeechRecognizer path only).
    case needsPermission
    /// No on-device recognition for the language on this Mac.
    case unavailable
}

/// One recorded meeting: `meeting.json` in its folder, next to `you.m4a`, `others.m4a` and
/// `transcript.md`.
public struct MeetingRecord: Codable, Identifiable, Equatable, Sendable {
    /// The folder's name ("2026-10-07 1000 Design review").
    public var id: String
    public var title: String
    public var start: Date
    /// Seconds recorded; 0 while recording (or after a crash mid-recording).
    public var duration: TimeInterval
    public var app: String?
    public var eventID: String?
    /// The transcript's language ("en-US", "it-IT").
    public var language: String
    public var tracks: [MeetingSpeaker]
    public var transcript: TranscriptState
    /// Lines in the transcript, once written.
    public var lines: Int?

    public init(id: String, title: String, start: Date, duration: TimeInterval = 0, app: String? = nil, eventID: String? = nil,
                language: String, tracks: [MeetingSpeaker], transcript: TranscriptState = .pending, lines: Int? = nil) {
        self.id = id; self.title = title; self.start = start; self.duration = duration; self.app = app; self.eventID = eventID
        self.language = language; self.tracks = tracks; self.transcript = transcript; self.lines = lines
    }

    public static func file(_ speaker: MeetingSpeaker) -> String { speaker == .you ? "you.m4a" : "others.m4a" }
    public static let transcriptFile = "transcript.md"
    public static let metadataFile = "meeting.json"
}

/// Recordings on disk, one folder each in `Application Support/Glancy/Meetings/`. All I/O on this
/// actor (never on main), except the synchronous save a quit needs.
public actor MeetingsStore {
    public nonisolated let directory: URL
    /// Delete moves to the Trash (false: removes, for tests: never the user's Trash).
    private let usesTrash: Bool

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Glancy/Meetings", isDirectory: true)
    }

    public init(directory: URL = MeetingsStore.defaultDirectory, usesTrash: Bool = true) {
        self.directory = directory
        self.usesTrash = usesTrash
    }

    public nonisolated func folder(_ id: String) -> URL { directory.appendingPathComponent(id, isDirectory: true) }
    public nonisolated func audio(_ id: String, _ speaker: MeetingSpeaker) -> URL {
        folder(id).appendingPathComponent(MeetingRecord.file(speaker))
    }
    public nonisolated func transcript(_ id: String) -> URL { folder(id).appendingPathComponent(MeetingRecord.transcriptFile) }

    /// A new, empty folder for a recording starting at `start`; nil when it can't be made.
    public func makeFolder(start: Date, title: String) -> String? {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let taken = Set((try? fm.contentsOfDirectory(atPath: directory.path)) ?? [])
        let name = MeetingFolder.name(start: start, title: title, taken: taken)
        do {
            try fm.createDirectory(at: folder(name), withIntermediateDirectories: false)
            return name
        } catch {
            return nil
        }
    }

    public func save(_ r: MeetingRecord) { _ = Self.write(r, in: directory) }

    /// The same, synchronously (quitting: no later turn of the run loop).
    @discardableResult
    nonisolated static func write(_ r: MeetingRecord, in directory: URL) -> Bool {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(r) else { return false }
        let url = directory.appendingPathComponent(r.id, isDirectory: true).appendingPathComponent(MeetingRecord.metadataFile)
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// Every recording, newest first. A folder whose recording never finished (a crash) gets its
    /// length from its audio.
    public func loadAll() -> [MeetingRecord] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var out: [MeetingRecord] = []
        for name in names where !name.hasPrefix(".") {
            let meta = folder(name).appendingPathComponent(MeetingRecord.metadataFile)
            guard let data = try? Data(contentsOf: meta), var r = try? dec.decode(MeetingRecord.self, from: data) else { continue }
            r.id = name
            if r.duration <= 0 {
                r.duration = r.tracks.compactMap { Self.length(audio(name, $0)) }.max() ?? 0
                if r.duration > 0 { _ = Self.write(r, in: directory) }
            }
            out.append(r)
        }
        return out.sorted { ($0.start, $0.id) > ($1.start, $1.id) }
    }

    public func writeTranscript(_ id: String, _ text: String) -> Bool {
        (try? Data(text.utf8).write(to: transcript(id), options: .atomic)) != nil
    }

    public func readTranscript(_ id: String) -> String? {
        (try? Data(contentsOf: transcript(id))).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Delete from the list: to the Trash (recoverable), removed only if there is no Trash.
    public func trash(_ id: String) -> Bool {
        let url = folder(id)
        if usesTrash, (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil { return true }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }

    /// Discarded or too short: gone for good.
    public func remove(_ id: String) {
        try? FileManager.default.removeItem(at: folder(id))
    }

    /// An audio file's length in seconds; nil when unreadable.
    nonisolated static func length(_ url: URL) -> TimeInterval? {
        guard let f = try? AVAudioFile(forReading: url), f.processingFormat.sampleRate > 0 else { return nil }
        return Double(f.length) / f.processingFormat.sampleRate
    }
}
