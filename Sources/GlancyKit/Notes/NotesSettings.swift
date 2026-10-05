import Carbon.HIToolbox
import Foundation
import Observation

/// Notes preferences and the little state worth keeping across launches.
@MainActor @Observable
public final class NotesSettings {
    static let hotkeyKey = "glancy.notes.hotkey"
    static let pinnedKey = "glancy.notes.pinned"
    static let lastKey = "glancy.notes.last"
    static let inboxKey = "glancy.notes.inbox"
    static let voiceHotkeyKey = "glancy.notes.voiceHotkey"
    static let transcribeKey = "glancy.notes.transcribe"
    static let maxMinutesKey = "glancy.notes.voiceMaxMinutes"

    /// Quick note: opens the Notes tab with the cursor in a note. No modifiers = none.
    public var hotkey: Hotkey {
        didSet { if let data = try? JSONEncoder().encode(hotkey) { defaults.set(data, forKey: Self.hotkeyKey) } }
    }
    /// The note shown on the Home tab.
    public var pinnedID: String? { didSet { defaults.set(pinnedID, forKey: Self.pinnedKey) } }
    /// The note open in the editor last time.
    public var lastID: String? { didSet { defaults.set(lastID, forKey: Self.lastKey) } }
    /// Where "note buy milk" from the command bar lands.
    public var inboxID: String? { didSet { defaults.set(inboxID, forKey: Self.inboxKey) } }
    /// Starts / stops a voice note from anywhere. No modifiers = none.
    public var voiceHotkey: Hotkey {
        didSet { if let data = try? JSONEncoder().encode(voiceHotkey) { defaults.set(data, forKey: Self.voiceHotkeyKey) } }
    }
    /// Turn recordings into text on this Mac (only once Speech Recognition is allowed).
    public var transcribe: Bool { didSet { defaults.set(transcribe, forKey: Self.transcribeKey) } }
    /// A recording stops by itself after this long.
    public var maxMinutes: Int { didSet { defaults.set(maxMinutes, forKey: Self.maxMinutesKey) } }
    public static let maxMinutesChoices = [5, 15, 30, 60]

    /// ⌃⌥N: free among Glancy's ⌃⌥ shortcuts (Space, arrows, F Z B C R M G A J K 0) and ⌥⌘V, and
    /// not a macOS default.
    public static let defaultHotkey = Hotkey(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(controlKey | optionKey))

    /// ⌃⌥V ("voice"): free among Glancy's ⌃⌥ shortcuts (Space, arrows, F Z B C R M G A J K N 0,
    /// 1–9 for workspaces, the ⇧ arrange variants) and ⌥⌘V (clipboard), not a macOS default, and
    /// one chord where ⌃⌥⇧N would take four keys.
    public static let defaultVoiceHotkey = Hotkey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | optionKey))

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hotkey = defaults.data(forKey: Self.hotkeyKey).flatMap { try? JSONDecoder().decode(Hotkey.self, from: $0) }
            ?? Self.defaultHotkey
        pinnedID = defaults.string(forKey: Self.pinnedKey)
        lastID = defaults.string(forKey: Self.lastKey)
        inboxID = defaults.string(forKey: Self.inboxKey)
        voiceHotkey = defaults.data(forKey: Self.voiceHotkeyKey).flatMap { try? JSONDecoder().decode(Hotkey.self, from: $0) }
            ?? Self.defaultVoiceHotkey
        transcribe = defaults.object(forKey: Self.transcribeKey) as? Bool ?? true
        let minutes = defaults.integer(forKey: Self.maxMinutesKey)
        maxMinutes = minutes > 0 ? minutes : 30
    }
}
