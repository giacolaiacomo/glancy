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

    /// ⌃⌥N: free among Glancy's ⌃⌥ shortcuts (Space, arrows, F Z B C R M G A J K 0) and ⌥⌘V, and
    /// not a macOS default.
    public static let defaultHotkey = Hotkey(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(controlKey | optionKey))

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hotkey = defaults.data(forKey: Self.hotkeyKey).flatMap { try? JSONDecoder().decode(Hotkey.self, from: $0) }
            ?? Self.defaultHotkey
        pinnedID = defaults.string(forKey: Self.pinnedKey)
        lastID = defaults.string(forKey: Self.lastKey)
        inboxID = defaults.string(forKey: Self.inboxKey)
    }
}
