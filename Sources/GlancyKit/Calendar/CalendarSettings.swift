import Carbon.HIToolbox
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
    /// The Join shortcut changed: the module re-registers it.
    @ObservationIgnored public var onHotkeyChange: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults

    static let focusKey = "glancy.calendar.focusDuringMeetings"
    static let triggerKey = "glancy.calendar.focusTrigger"
    static let warningKey = "glancy.calendar.endWarningMinutes"
    static let hotkeyKey = "glancy.calendar.joinHotkey"
    /// ⌃⌥J: free among Glancy's ⌃⌥ shortcuts (Space ← → ↑ ↓ F Z B C R M G A) and ⌥⌘V.
    public static let defaultJoinHotkey = Hotkey(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(controlKey | optionKey))

    /// Turn on a Focus while a meeting is in progress (off by default: needs two shortcuts).
    public var focusDuringMeetings = false {
        didSet { guard focusDuringMeetings != oldValue else { return }; defaults.set(focusDuringMeetings, forKey: Self.focusKey); onChange?() }
    }
    public var focusTrigger: MeetingFocusTrigger = .calls {
        didSet { guard focusTrigger != oldValue else { return }; defaults.set(focusTrigger.rawValue, forKey: Self.triggerKey); onChange?() }
    }
    /// "Ends in N min" peek: 0 (off), 2, 5 or 10.
    public var endWarningMinutes = 5 {
        didSet { guard endWarningMinutes != oldValue else { return }; defaults.set(endWarningMinutes, forKey: Self.warningKey); onChange?() }
    }
    /// Joins the current or next call. No modifiers = off.
    public var joinHotkey = CalendarSettings.defaultJoinHotkey {
        didSet {
            guard joinHotkey != oldValue else { return }
            if let data = try? JSONEncoder().encode(joinHotkey) { defaults.set(data, forKey: Self.hotkeyKey) }
            onHotkeyChange?()
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let ids = defaults.array(forKey: Self.defaultsKey) as? [String] {
            selectedCalendarIDs = Set(ids)
        }
        focusDuringMeetings = defaults.bool(forKey: Self.focusKey)
        if let raw = defaults.string(forKey: Self.triggerKey), let t = MeetingFocusTrigger(rawValue: raw) { focusTrigger = t }
        if defaults.object(forKey: Self.warningKey) != nil {
            let m = defaults.integer(forKey: Self.warningKey)
            endWarningMinutes = MeetingEndLogic.warningChoices.contains(m) ? m : 5
        }
        if let data = defaults.data(forKey: Self.hotkeyKey), let h = try? JSONDecoder().decode(Hotkey.self, from: data) {
            joinHotkey = h
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
    static var comingDays: String { t("Coming days", "Prossimi giorni") }
    static var nothingAhead: String { t("Nothing in the next 7 days", "Niente nei prossimi 7 giorni") }
    static var now: String { t("Now", "Ora") }
    static var inTwo: String { t("in 2 min", "tra 2 min") }
    static func `in`(_ s: String) -> String { t("in \(s)", "tra \(s)") }

    // Wave 4: meeting end, overrun, join, Focus
    static func endsIn(_ m: Int) -> String { t("ends in \(m) min", "finisce tra \(m) min") }
    static func nextAt(_ title: String, _ time: String) -> String { t("next: \(title) at \(time)", "poi: \(title) alle \(time)") }
    static var next: String { t("Next", "Prossima") }
    static var late: String { t("Late", "In ritardo") }
    static var overrunHelp: String { t("Your last call ran over and this one has started", "La call precedente è andata lunga e questa è iniziata") }
    static var nothingToJoin: String { t("No call to join now", "Nessuna call adesso") }
    static func laterCall(_ title: String, _ when: String) -> String { t("next: \(title) \(when)", "prossima: \(title) \(when)") }
    static var noLink: String { t("No meeting link", "Nessun link riunione") }
    static var linkCopied: String { t("Link copied", "Link copiato") }
    static var calendar: String { t("Calendar", "Calendario") }
    static var allow: String { t("Allow", "Consenti") }
    static var noAccess: String { t("Calendar access is off", "Accesso al calendario disattivato") }
    static var focusOn: String { t("Focus on", "Full immersion") }

    // Command bar
    static var cmdJoin: String { t("Join next meeting", "Partecipa alla prossima riunione") }
    static var cmdCopy: String { t("Copy meeting link", "Copia link riunione") }
    static var cmdOpenApp: String { t("Open Calendar", "Apri Calendario") }
    static var cmdAgenda: String { t("Today's agenda", "Agenda di oggi") }
    static var cmdFocusOff: String { t("Turn off meeting Focus", "Disattiva la full immersion della riunione") }
    static var openInCalendar: String { t("Open in Calendar", "Apri in Calendario") }

    // Settings
    static var meetings: String { t("Meetings", "Riunioni") }
    static var calendarsTitle: String { t("Calendars", "Calendari") }
    static var focusSwitch: String { t("Focus in meetings", "Full immersion in riunione") }
    static var focusNote: String { t("Off at the end, only if Glancy turned it on", "Si spegne alla fine, solo se l'ha accesa Glancy") }
    static var whichMeetings: String { t("Which meetings", "Quali riunioni") }
    static var withLink: String { t("Calls", "Call") }
    static var anyBusy: String { t("Busy events", "Eventi occupati") }
    static var endWarning: String { t("Warn before the end", "Avviso prima della fine") }
    static var endWarningNote: String { t("With what's next", "Con cosa viene dopo") }
    static var off: String { t("Off", "No") }
    static var joinShortcut: String { t("Join shortcut", "Scorciatoia Partecipa") }
    static var joinShortcutNote: String { t("The call now or within 10 min", "La call in corso o entro 10 min") }
}
