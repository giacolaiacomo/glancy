import Foundation
import Observation

/// What Glancy does when a meeting starts.
public enum MeetingsMode: String, CaseIterable, Codable, Sendable {
    /// A card asks "Record this meeting?" (the default).
    case ask
    /// Calendar meetings start recording by themselves (a drop-down says so, with Stop); anything
    /// else still asks.
    case always
    /// Never asks; Record in the tab still works. No listeners at all.
    case off
}

/// The language transcripts are written in.
public enum MeetingsLanguage: String, CaseIterable, Codable, Sendable {
    case app, en, it

    /// The locale to recognise in (`italian`: the app's language is Italian).
    public func locale(italian: Bool) -> Locale {
        switch self {
        case .app: Locale(identifier: italian ? "it-IT" : "en-US")
        case .en: Locale(identifier: "en-US")
        case .it: Locale(identifier: "it-IT")
        }
    }
}

/// Settings → Meetings, saved in UserDefaults.
@MainActor @Observable
public final class MeetingsSettings {
    @ObservationIgnored private let defaults: UserDefaults
    /// Told when the mode changes (the module starts or stops listening).
    @ObservationIgnored var onModeChange: (() -> Void)?

    public var mode: MeetingsMode {
        didSet {
            guard mode != oldValue else { return }
            defaults.set(mode.rawValue, forKey: Key.mode)
            onModeChange?()
        }
    }
    public var language: MeetingsLanguage {
        didSet { defaults.set(language.rawValue, forKey: Key.language) }
    }
    /// A note in Notes with each transcript (when the Notes module is on).
    public var saveToNotes: Bool {
        didSet { defaults.set(saveToNotes, forKey: Key.notes) }
    }

    enum Key {
        static let mode = "meetings.mode"
        static let language = "meetings.language"
        static let notes = "meetings.saveToNotes"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = defaults.string(forKey: Key.mode).flatMap(MeetingsMode.init) ?? .ask
        language = defaults.string(forKey: Key.language).flatMap(MeetingsLanguage.init) ?? .app
        saveToNotes = defaults.object(forKey: Key.notes) as? Bool ?? true
    }
}
