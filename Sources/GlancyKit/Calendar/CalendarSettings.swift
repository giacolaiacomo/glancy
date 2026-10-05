import Foundation
import Observation

/// Calendar preferences. The settings page binds to this later.
/// `selectedCalendarIDs == nil` means "all calendars" (the default).
@MainActor @Observable
public final class CalendarSettings {
    public static let defaultsKey = "glancy.calendar.selectedIDs"

    public var selectedCalendarIDs: Set<String>? {
        didSet {
            guard selectedCalendarIDs != oldValue else { return }
            persist()
            onChange?()
        }
    }
    /// Filled by the module from EventKit; the settings list renders from it.
    public internal(set) var availableCalendars: [CalendarInfo] = []
    @ObservationIgnored public var onChange: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let ids = defaults.array(forKey: Self.defaultsKey) as? [String] {
            selectedCalendarIDs = Set(ids)
        }
    }

    public func isSelected(_ id: String) -> Bool { selectedCalendarIDs?.contains(id) ?? true }

    public func setSelected(_ id: String, _ on: Bool) {
        var set = selectedCalendarIDs ?? Set(availableCalendars.map(\.id))
        if on { set.insert(id) } else { set.remove(id) }
        // Everything ticked again = back to the "all" default (new calendars then join automatically).
        selectedCalendarIDs = set.isSuperset(of: availableCalendars.map(\.id)) ? nil : set
    }

    private func persist() {
        if let ids = selectedCalendarIDs { defaults.set(Array(ids).sorted(), forKey: Self.defaultsKey) }
        else { defaults.removeObject(forKey: Self.defaultsKey) }
    }
}

/// EN / IT strings for the Calendar module.
enum CalL10n {
    nonisolated(unsafe) static var languageOverride: String?  // "en" / "it"; nil = the app's language
    static var italian: Bool {
        (languageOverride ?? L10n.current).lowercased().hasPrefix("it")
    }
    static func t(_ en: String, _ it: String) -> String { italian ? it : en }

    static var today: String { t("Today", "Oggi") }
    static var tomorrow: String { t("Tomorrow", "Domani") }
    static var join: String { t("Join", "Partecipa") }
    static var allDay: String { t("All day", "Tutto il giorno") }
    static var allowTitle: String { t("Allow calendar access", "Consenti l'accesso al calendario") }
    static var allowBody: String { t("Glancy shows your next meeting and a Join button. Nothing leaves this Mac.",
                                     "Glancy mostra la prossima riunione e il tasto Partecipa. Nulla lascia questo Mac.") }
    static var openSettings: String { t("Open Settings", "Apri Impostazioni") }
    static var nothingToday: String { t("Nothing else today", "Nient'altro per oggi") }
    static var nothing: String { t("No events", "Nessun evento") }
    static var now: String { t("Now", "Ora") }
    static var inTwo: String { t("in 2 min", "tra 2 min") }
    static func `in`(_ s: String) -> String { t("in \(s)", "tra \(s)") }
}
