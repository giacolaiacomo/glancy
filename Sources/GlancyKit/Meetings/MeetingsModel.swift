import Foundation
import Observation

/// What the meeting views draw from. Written by `MeetingsModule` only.
@MainActor @Observable
public final class MeetingsModel {
    public enum Phase: Equatable, Sendable {
        case idle
        /// "Record this meeting?" (the drop-down, the tab, Home) until answered or the meeting ends.
        case offering
        /// Asking for permissions, opening the devices.
        case starting
        case recording
    }

    /// Something the user should know, shown until the next recording or until dismissed.
    public enum Notice: Equatable, Sendable {
        /// Neither the microphone nor system audio is allowed: nothing to record.
        case cantHear
        /// Recording your microphone only (system audio refused or unavailable).
        case youOnly
        /// Recording the others only (the microphone refused or unavailable).
        case othersOnly
        /// The devices would not open.
        case failed
    }

    public internal(set) var phase: Phase = .idle
    /// The meeting offered or recorded.
    public internal(set) var detection: MeetingDetection?
    public internal(set) var title = ""
    /// When the recording started.
    public internal(set) var started: Date?
    /// Whole minutes recorded (the wing; changed once a minute).
    public internal(set) var minutes = 0
    public internal(set) var tracks: [MeetingSpeaker] = []
    /// The recording began by itself (Always for calendar meetings).
    public internal(set) var auto = false
    /// "Not now" was pressed for the meeting on (the drop-down says so while it stays).
    public internal(set) var declined = false
    /// Discard asks once: the first click arms it.
    public var confirmingDiscard = false
    public internal(set) var notice: Notice?

    /// Past recordings, newest first (read on the first open of the panel).
    public internal(set) var records: [MeetingRecord] = []
    public internal(set) var loaded = false
    /// Transcripts being written: 0…1 by recording.
    public internal(set) var progress: [String: Double] = [:]
    public internal(set) var playing: String?
    /// Delete asks once: the recording whose first click armed it.
    public var confirmingDelete: String?
    /// The recording whose transcript was just copied ("Copied").
    public internal(set) var copied: String?

    public init() {}

    public var isRecording: Bool { phase == .recording }

    func record(_ id: String) -> MeetingRecord? { records.first { $0.id == id } }

    func update(_ r: MeetingRecord) {
        if let i = records.firstIndex(where: { $0.id == r.id }) { records[i] = r } else { records.insert(r, at: 0) }
    }
}

/// The calendar meetings, for naming a call and knowing when it should end (the Calendar module).
@MainActor
public protocol MeetingCalendarSource: AnyObject {
    /// Read inside `withObservationTracking`: a change of the events is observed.
    var meetingEvents: [CalendarEvent] { get }
}

/// Where a transcript goes as a note (the Notes module).
@MainActor
public protocol MeetingNotesSink: AnyObject {
    /// A new note whose first line is the title. False when Notes is not running.
    func addMeetingNote(_ text: String) -> Bool
}

extension CalendarModule: MeetingCalendarSource {
    public var meetingEvents: [CalendarEvent] { model.events }
}

extension NotesModule: MeetingNotesSink {
    public func addMeetingNote(_ text: String) -> Bool { addNote(text) }
}
