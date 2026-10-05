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
    private var hub: ActivityHub?
    private var observer: NSObjectProtocol?
    private var wakeObservers: [NSObjectProtocol] = []
    private var debounce: Task<Void, Never>?
    private var wake: Task<Void, Never>?
    private var bootstrap: Task<Void, Never>?
    private var peeked: Set<String> = []
    private var started = false

    public convenience init() { self.init(source: EventKitSource(), settings: CalendarSettings()) }

    public init(source: CalendarEventSource, settings: CalendarSettings) {
        self.source = source
        self.settings = settings
    }

    // MARK: Lifecycle

    public func start(hub: ActivityHub) {
        guard !started else { return }
        started = true
        self.hub = hub
        settings.onChange = { [weak self] in self?.refresh() }
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
        hub?.clearAll(from: .calendar)
        hub = nil
        peeked.removeAll()
    }

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
        guard started else { return }
        let access = source.authorization
        model.access = access
        let now = Date.now
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
        armWake(now: now)
    }

    private func publish(now: Date) {
        guard let hub else { return }
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

    private func armWake(now: Date) {
        wake?.cancel()
        let midnight = Calendar.current.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime)
        guard let target = [CalendarLogic.nextBoundary(model.events, after: now), midnight].compactMap({ $0 }).min() else { return }
        wake = Task { [weak self] in
            // +0.5 s so the boundary has strictly passed when we re-evaluate.
            try? await Task.sleep(for: .seconds(max(0.5, target.timeIntervalSinceNow + 0.5)))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    // MARK: Surface

    public var tab: PanelTab? {
        PanelTab(module: .calendar, symbol: "calendar", title: "Calendar") { [model] in
            AnyView(CalendarTabView(model: model).environment(\.locale, L10n.locale))
        }
    }

    public func homeCard() -> AnyView? {
        guard model.access == .granted, model.next != nil else { return nil }
        return AnyView(CalendarHomeCard(model: model).environment(\.locale, L10n.locale))
    }
}

enum CalendarJoin {
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
