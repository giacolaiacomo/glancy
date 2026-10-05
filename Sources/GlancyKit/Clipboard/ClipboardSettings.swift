import Carbon.HIToolbox
import Foundation
import Observation

/// Clipboard preferences, edited from the tab's menu and Settings → Clipboard.
@MainActor @Observable
public final class ClipboardSettings {
    static let pausedKey = "glancy.clipboard.paused"
    static let pasteKey = "glancy.clipboard.pasteAfterChoosing"
    static let excludedKey = "glancy.clipboard.excluded"
    static let hotkeyKey = "glancy.clipboard.hotkey"

    /// Nothing is recorded while on.
    public var paused: Bool { didSet { defaults.set(paused, forKey: Self.pausedKey) } }
    /// After choosing an item, close the panel and press ⌘V in the app underneath (Accessibility).
    public var pasteAfterChoosing: Bool { didSet { defaults.set(pasteAfterChoosing, forKey: Self.pasteKey) } }
    /// Apps never recorded from: bundle ID → display name.
    public var excluded: [String: String] { didSet { defaults.set(excluded, forKey: Self.excludedKey) } }

    /// Opens the notch on the Clipboard tab. No modifiers = none (cleared in Settings).
    public var hotkey: Hotkey {
        didSet { if let data = try? JSONEncoder().encode(hotkey) { defaults.set(data, forKey: Self.hotkeyKey) } }
    }

    /// ⌥⌘V.
    public static let defaultHotkey = Hotkey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | optionKey))

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        paused = defaults.bool(forKey: Self.pausedKey)
        pasteAfterChoosing = defaults.bool(forKey: Self.pasteKey)
        excluded = defaults.dictionary(forKey: Self.excludedKey) as? [String: String] ?? [:]
        hotkey = defaults.data(forKey: Self.hotkeyKey).flatMap { try? JSONDecoder().decode(Hotkey.self, from: $0) }
            ?? Self.defaultHotkey
    }

    var excludedIDs: Set<String> { Set(excluded.keys) }
}
