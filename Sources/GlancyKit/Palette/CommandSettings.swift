import Carbon.HIToolbox
import Foundation
import Observation

/// Command bar preferences (Settings → Command bar).
@MainActor @Observable
public final class CommandSettings {
    enum Key {
        static let hotkey = "glancy.command.hotkey"
        static let apps = "glancy.command.apps"
        static let calculator = "glancy.command.calculator"
        static let units = "glancy.command.units"
        static let currency = "glancy.command.currency"
        static let webSearch = "glancy.command.webSearch"
    }

    /// Opens the bar. No modifiers = none.
    public var hotkey: Hotkey {
        didSet { if let data = try? JSONEncoder().encode(hotkey) { defaults.set(data, forKey: Key.hotkey) } }
    }
    public var apps: Bool { didSet { defaults.set(apps, forKey: Key.apps) } }
    public var calculator: Bool { didSet { defaults.set(calculator, forKey: Key.calculator) } }
    public var units: Bool { didSet { defaults.set(units, forKey: Key.units) } }
    /// Fetches exchange rates from the ECB when a currency query is typed.
    public var currency: Bool { didSet { defaults.set(currency, forKey: Key.currency) } }
    public var webSearch: Bool { didSet { defaults.set(webSearch, forKey: Key.webSearch) } }

    /// ⌃⌥K: the Glancy family (⌃⌥), K as in every "command-K" palette. Free on a stock Mac and in
    /// Glancy (⌃⌥ Space/arrows/F/Z/B/C/R/M/G/A, ⌥⌘V); ⌥⌘Space is Finder's search, ⌘Space Spotlight,
    /// ⌥Space Raycast/Alfred/ChatGPT.
    public static let defaultHotkey = Hotkey(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey))

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hotkey = defaults.data(forKey: Key.hotkey).flatMap { try? JSONDecoder().decode(Hotkey.self, from: $0) } ?? Self.defaultHotkey
        func flag(_ k: String) -> Bool { defaults.object(forKey: k) as? Bool ?? true }
        apps = flag(Key.apps)
        calculator = flag(Key.calculator)
        units = flag(Key.units)
        currency = flag(Key.currency)
        webSearch = flag(Key.webSearch)
    }
}
