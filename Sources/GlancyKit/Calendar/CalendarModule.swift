import EventKit
import SwiftUI

/// Observable state the calendar views render from.
@MainActor @Observable
public final class CalendarModel {
    public internal(set) var access: CalendarAccess = .notDetermined
    public internal(set) var events: [CalendarEvent] = []
    /// Re-stamped at every refresh / boundary; views use it only to split past from upcoming.
    public internal(set) var now: Date = .now
    public init() {}
    public var next: CalendarEvent? { CalendarLogic.nextEvent(events, now: now) }
}

@MainActor
public final class CalendarModule: GlancyModule {
    public let id: ModuleID = .calendar
    public let settings: CalendarSettings
    public let model = CalendarModel()

    private let source: CalendarEventSource
    private(set) var hub: ActivityHub?
    private var observer: NSObjectProtocol?
    private var wakeObservers: [NSObjectProtocol] = []
    private var debounce: Task<Void, Never>?
    private var wake: Task<Void, Never>?
    private var bootstrap: Task<Void, Never>?
    private var peeked: Set<String> = []
    private var started = false
    /// Meetings whose Focus the user turned off by hand (until they end).
    private(set) var focusSkipped: Set<String> = []
    /// Meetings joined through Glancy (Join pill, hotkey, command bar): feeds the overrun indicator.
    private(set) var joined: Set<String> = []
    /// Focus during meetings; nil = none (tests, isolated runs).
    public let focus: FocusController?
    private var hotkeyToken: HotkeyManager.Token?
    /// The Join shortcut could not be registered (another app holds it).
    public private(set) var hotkeyFailed = false
    /// Overrides "now" for renders and tests; nil = the clock.
    var clock: () -> Date = { .now }

    public convenience init() {
        self.init(source: EventKitSource(), settings: CalendarSettings(), focus: .shared, registersHotkey: true)
    }

    /// `focus` nil and `registersHotkey` false keep tests and isolated runs away from the user's
    /// Focus and from global shortcuts.
    public init(source: CalendarEventSource, settings: CalendarSettings, focus: FocusController? = nil,
                registersHotkey: Bool = false) {
        self.source = source
        self.settings = settings
        self.focus = focus
        self.registersHotkey = registersHotkey
    }

    // MARK: Lifecycle

    public func start(hub: ActivityHub) {
        guard !started else { return }
        started = true
        self.hub = hub
        settings.onChange = { [weak self] in self?.refresh() }
        settings.onHotkeyChange = { [weak self] in self?.registerHotkey() }
        CalendarJoin.onJoined = { [weak self] id in self?.didJoin(id) }
        focus?.register(Self.focusOwner) { [weak self] in self?.skipFocusNow() }
        registerHotkey()
        if let ek = (source as? EventKitSource)?.store {
            observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: ek, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.storeChanged() }
            }
        }
        // A sleeping Mac or a new day invalidates the agenda and the armed wake-up.
        wakeObservers = [
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
            NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
        ]
        bootstrap = Task { [weak self] in
            guard let self else { return }
            if source.authorization == .notDetermined { _ = await source.requestAccess() }
            refresh()
        }
    }

    public func stop() {
        started = false
        bootstrap?.cancel(); debounce?.cancel(); wake?.cancel()
        bootstrap = nil; debounce = nil; wake = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        wakeObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); NotificationCenter.default.removeObserver($0) }
        wakeObservers = []
        settings.onChange = nil
        settings.onHotkeyChange = nil
        if let hotkeyToken { HotkeyManager.shared.unregister(hotkeyToken) }
        hotkeyToken = nil
        CalendarJoin.onJoined = nil
        focus?.unregister(Self.focusOwner)
        hub?.clearAll(from: .calendar)
        hub = nil
        peeked.removeAll()
    }

    static let focusOwner = "calendar"


    public func visibilityChanged(_ visibility: SurfaceVisibility) {
        // The agenda's now-line is only meaningful on screen; re-stamp when it opens.
        if case .expanded = visibility, started { refresh() }
    }

    /// Asks for calendar access on the module's own store (the onboarding checklist), then reloads.
    public func requestAccess() async {
        _ = await source.requestAccess()
        refresh()
    }

    /// A permission may have changed (System Settings, the onboarding checklist): reload.
    public func permissionsChanged() { refresh() }

    private func storeChanged() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    // MARK: Refresh

    /// Re-query today and the next 7 days, republish activities, and arm the single next wake-up.
    public func refresh() {
        guard started, !frozen else { return }
        let access = source.authorization
        model.access = access
        let now = clock()
        model.now = now
        if access == .granted {
            settings.availableCalendars = source.calendars()
            let cal = Calendar.current
            let from = cal.startOfDay(for: now)
            let to = cal.date(byAdding: .day, value: 8, to: from) ?? from.addingTimeInterval(8 * 86_400)
            let raw = source.events(from: from, to: to, calendarIDs: settings.selectedCalendarIDs)
            model.events = CalendarLogic.visible(raw, calendarIDs: settings.selectedCalendarIDs)
        } else {
            model.events = []
        }
        publish(now: now)
        showEndPeeks(now: now)
        claimFocus(now: now)
        armWake(now: now)
    }

    private func publish(now: Date) {
        guard let hub else { return }
        if let (previous, next) = MeetingEndLogic.overrun(model.events, now: now, joined: joined) {
            hub.post(LiveActivity(
                id: "calendar", module: .calendar, priority: CalendarPhase.started.priority, updated: now,
                expires: next.start.addingTimeInterval(CalendarLogic.startedTail),
                left: AnyView(CalendarOverrunWingLeft(previous: previous).environment(\.locale, L10n.locale)),
                right: AnyView(CalendarWingRight(event: next, phase: .started))))
            return
        }
        guard let (event, phase) = CalendarLogic.activeEvent(model.events, now: now) else {
            hub.clear("calendar"); return
        }
        hub.post(LiveActivity(
            id: "calendar", module: .calendar, priority: phase.priority, updated: now,
            expires: CalendarLogic.phaseEnd(of: event, phase: phase),
            left: AnyView(CalendarWingLeft(event: event, phase: phase).environment(\.locale, L10n.locale)),
            right: AnyView(CalendarWingRight(event: event, phase: phase))))
        if phase == .imminent, peeked.insert(event.id).inserted {
            hub.show(PeekEvent(module: .calendar, duration: 4, content: AnyView(CalendarPeek(event: event).environment(\.locale, L10n.locale))))
        }
    }

    /// "Ends in 5 min · next: …" and, at the end of a back-to-back, "Next: … in 10 min". Once each.
    private func showEndPeeks(now: Date) {
        guard let hub else { return }
        for p in MeetingEndLogic.due(model.events, now: now, warningMinutes: settings.endWarningMinutes)
        where peeked.insert(p.key).inserted {
            hub.show(PeekEvent(module: .calendar, duration: 5, content: AnyView(MeetingEndPeekView(peek: p, now: now)
                .environment(\.locale, L10n.locale))))
        }
    }

    // MARK: Focus

    private func claimFocus(now: Date) {
        guard let focus else { return }
        focusSkipped = MeetingFocusLogic.pruneSkipped(focusSkipped, events: model.events, now: now)
        let wants = settings.focusDuringMeetings && model.access == .granted
            && MeetingFocusLogic.wants(model.events, now: now, trigger: settings.focusTrigger, skipped: focusSkipped)
        focus.claim(Self.focusOwner, wants)
    }

    /// The user turned Focus off: leave it off for the meetings in progress.
    private func skipFocusNow() {
        let now = clock()
        focusSkipped.formUnion(MeetingFocusLogic.current(model.events, now: now, trigger: settings.focusTrigger).map(\.id))
        focus?.claim(Self.focusOwner, false)
    }

    // MARK: Join

    private func didJoin(_ id: String?) {
        guard let id else { return }
        if joined.insert(id).inserted { refresh() }
    }

    /// Joins `event`'s call and remembers it (overrun indicator).
    public func join(_ event: CalendarEvent) {
        guard let link = event.link else { return }
        opener(link)
        didJoin(event.id)
    }

    /// Opens a call (tests replace it).
    var opener: @MainActor (MeetingLink) -> Void = { CalendarJoin.open($0) }

    /// The Join hotkey / command: the call running now or starting within 10 minutes. Nothing
    /// to join → a peek saying so, with the next call (and its Join) when there is one.
    public func joinNow() {
        let now = clock()
        guard model.access == .granted else {
            hub?.show(PeekEvent(module: .calendar, content: AnyView(CalendarNoticePeek(text: CalL10n.noAccess))))
            return
        }
        if let e = MeetingJoinLogic.target(model.events, now: now) { join(e); return }
        hub?.show(PeekEvent(module: .calendar, duration: 4, content: AnyView(
            CalendarNothingToJoinPeek(later: MeetingJoinLogic.later(model.events, now: now), now: now)
                .environment(\.locale, L10n.locale))))
    }

    /// Copies the link of the call to join now, or of the next one.
    public func copyLink(to pasteboard: NSPasteboard = .general) {
        let now = clock()
        guard let e = MeetingJoinLogic.linkTarget(model.events, now: now), let link = e.link else {
            hub?.show(PeekEvent(module: .calendar, content: AnyView(CalendarNoticePeek(text: CalL10n.noLink))))
            return
        }
        pasteboard.clearContents()
        pasteboard.setString(link.webURL.absoluteString, forType: .string)
        hub?.show(PeekEvent(module: .calendar, content: AnyView(CalendarNoticePeek(text: CalL10n.linkCopied, detail: e.title, symbol: "link"))))
    }

    private func registerHotkey() {
        if let hotkeyToken { HotkeyManager.shared.unregister(hotkeyToken) }
        hotkeyToken = nil
        hotkeyFailed = false
        let h = settings.joinHotkey
        guard started, registersHotkey, h.modifiers != 0 else { return }
        hotkeyToken = HotkeyManager.shared.register(h) { [weak self] in self?.joinNow() }
        hotkeyFailed = hotkeyToken == nil
    }

    private let registersHotkey: Bool

    private func armWake(now: Date) {
        wake?.cancel()
        let midnight = Calendar.current.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime)
        let warning = TimeInterval(settings.endWarningMinutes * 60)
        guard let target = [CalendarLogic.nextBoundary(model.events, after: now, endWarning: warning), midnight].compactMap({ $0 }).min() else { return }
        wake = Task { [weak self] in
            // +0.5 s so the boundary has strictly passed when we re-evaluate.
            try? await Task.sleep(for: .seconds(max(0.5, target.timeIntervalSinceNow + 0.5)))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    // MARK: Renders

    /// Renders only: the module keeps the synthetic state below and stops refreshing.
    private var frozen = false

    public enum RenderState: String, CaseIterable, Sendable { case ending, backToBack, nothingToJoin, overrun }

    /// Synthetic meetings around now for `glancy-render`: peeks go to the hub, the overrun to the
    /// wings. Nothing of the user's calendar is changed; Focus is never touched.
    public func prepareForRender(_ r: RenderState) {
        guard let hub else { return }
        frozen = true
        wake?.cancel()
        let now = Date.now
        func make(_ id: String, _ title: String, _ from: Double, _ to: Double, _ rgb: CalendarRGB, link: Bool = true) -> CalendarEvent {
            CalendarEvent(id: "render-\(id)", title: title, start: now.addingTimeInterval(from * 60), end: now.addingTimeInterval(to * 60),
                          calendarID: "render", color: rgb,
                          link: link ? MeetingLink.extract(url: nil, location: nil, notes: "https://meet.google.com/abc-defg-hij") : nil)
        }
        let blue = CalendarRGB(r: 0.36, g: 0.55, b: 1.0), orange = CalendarRGB(r: 0.98, g: 0.62, b: 0.30)
        switch r {
        case .ending:
            let a = make("a", "Design review", -40, 5, blue), b = make("b", "Weekly planning", 15, 45, orange)
            model.events = [a, b]
            hub.show(PeekEvent(module: .calendar, duration: 60, content: AnyView(MeetingEndPeekView(
                peek: .ending(a, minutes: 5, next: b), now: now).environment(\.locale, L10n.locale))))
        case .backToBack:
            let a = make("a", "Design review", -45, 0, blue), b = make("b", "Weekly planning", 10, 40, orange)
            model.events = [a, b]
            hub.show(PeekEvent(module: .calendar, duration: 60, content: AnyView(MeetingEndPeekView(
                peek: .backToBack(ended: a, next: b), now: now).environment(\.locale, L10n.locale))))
        case .nothingToJoin:
            let later = make("l", "Client call", 95, 125, orange)
            model.events = [later]
            hub.show(PeekEvent(module: .calendar, duration: 60, content: AnyView(
                CalendarNothingToJoinPeek(later: later, now: now).environment(\.locale, L10n.locale))))
        case .overrun:
            let a = make("a", "Design review", -62, -2, blue), b = make("b", "Weekly planning", -2, 28, orange)
            model.events = [a, b]
            joined = [a.id]
            model.now = now
            publish(now: now)
        }
    }

    // MARK: Surface

    public var tab: PanelTab? {
        PanelTab(module: .calendar, symbol: "calendar", title: "Calendar") { [model, focus] in
            AnyView(CalendarTabView(model: model, focus: focus).environment(\.locale, L10n.locale))
        }
    }

    public func homeCard() -> AnyView? {
        guard model.access == .granted, model.next != nil else { return nil }
        return AnyView(CalendarHomeCard(model: model).environment(\.locale, L10n.locale))
    }
}

enum CalendarJoin {
    /// Set by the running module: a Join pill was clicked for this event id.
    @MainActor static var onJoined: ((String?) -> Void)?

    @MainActor static func join(_ link: MeetingLink, eventID: String?) {
        open(link)
        onJoined?(eventID)
    }

    @MainActor static func open(_ link: MeetingLink) {
        if link.joinURL != link.webURL {
            NSWorkspace.shared.open(link.joinURL, configuration: NSWorkspace.OpenConfiguration()) { app, _ in
                if app == nil { DispatchQueue.main.async { _ = NSWorkspace.shared.open(link.webURL) } }
            }
        } else {
            NSWorkspace.shared.open(link.webURL)
        }
    }
    static let privacyURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
}
