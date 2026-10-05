import AppKit
import SwiftUI

/// Notifications from other apps (SPEC §3, opt-in, experimental; off by default: needs Full Disk
/// Access). Read-only on the Notification Center store, event-driven (file events on db / db-wal),
/// never polling. Peek on arrival (3 s, bursts coalesced into one peek, never while the panel is open
/// or the screen is hidden/locked) and a Notifications tab with the last 20. No Home card, no wings.
///
/// Focus: not honoured. No cheap public signal exists (`INFocusStatusCenter` needs the Communication
/// Notifications entitlement and its own authorization); the per-app mute list is the control.
@MainActor
public final class NotificationsModule: GlancyModule {
    public let id: ModuleID = .notifications
    public let model: NotificationsModel
    let databaseURL: URL
    /// Synthetic notifications, no observers (the renderer; never shows real ones).
    let sample: Bool

    private var hub: ActivityHub?
    private var watcher: NotificationWatcher?
    private var activeObserver: NSObjectProtocol?
    private var visibility: SurfaceVisibility = .collapsed
    private var panelOpen = false
    private var coalescer = PeekCoalescer(window: NotificationsModule.peekDuration)
    private var peekState: NotificationPeekState?
    private var started = false

    static let peekDuration: TimeInterval = 3
    static let privacyURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// `~/Library/Group Containers/group.com.apple.usernoted/db2/db` (macOS 15+).
    public static var systemDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")
    }

    public convenience init() {
        let env = ProcessInfo.processInfo
        let sample = env.processName == "glancy-render" || env.environment["GLANCY_NOTIFICATIONS_SAMPLE"] == "1"
        let defaults: UserDefaults
        if sample {
            let suite = "ai.glancy.notifications.sample"
            defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
        } else {
            defaults = .standard
        }
        self.init(databaseURL: Self.systemDatabaseURL, settings: NotificationsSettings(defaults: defaults), sample: sample)
    }

    public init(databaseURL: URL, settings: NotificationsSettings, sample: Bool = false) {
        self.databaseURL = databaseURL
        self.model = NotificationsModel(settings: settings)
        self.sample = sample
    }

    // MARK: Lifecycle

    public func start(hub: ActivityHub) {
        guard !started else { return }
        started = true
        self.hub = hub
        L10n.addItalian(NotifText.italian)
        if sample {
            model.replace(with: NotificationsSample.items())
            model.state = .live
            return
        }
        model.state = .starting
        let watcher = NotificationWatcher(url: databaseURL, keep: NotificationsModel.keep)
        self.watcher = watcher
        watcher.start { [weak self] event in
            // FIFO onto main: events keep their order.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event) } }
        }
        // Full Disk Access is granted in System Settings: look again when the user comes back.
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recheck() }
        }
    }

    public func stop() {
        guard started else { return }
        started = false
        watcher?.stop()
        watcher = nil
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        activeObserver = nil
        model.clear()
        model.state = .starting
        model.apps.purgeIcons()
        coalescer.reset()
        peekState = nil
        hub = nil
        panelOpen = false
    }

    public func visibilityChanged(_ visibility: SurfaceVisibility) {
        self.visibility = visibility
        guard started else { return }
        if case .expanded = visibility {
            if !panelOpen {
                panelOpen = true
                model.now = .now
                recheck()
            }
        } else {
            panelOpen = false
        }
    }

    /// Retries the store when it could not be read. Called on panel open and app activation only.
    func recheck() {
        guard started, !sample else { return }
        switch model.state {
        case .needsFullDiskAccess, .unavailable: watcher?.retry()
        case .starting, .live: break
        }
    }

    // MARK: Events

    func handle(_ event: NotificationWatcher.Event) {
        guard started else { return }
        switch event {
        case .unavailable(let error):
            model.state = Self.state(for: error)
        case .initial(let list):
            model.state = .live
            model.replace(with: list)
        case .new(let list):
            model.state = .live
            announce(model.ingest(list))
        }
    }

    static func state(for error: NotificationSourceError) -> NotificationsState {
        switch error {
        case .needsFullDiskAccess: .needsFullDiskAccess
        case .missing: .unavailable(detail: "store not found")
        case .unsupportedSchema(let what): .unavailable(detail: "unexpected schema: " + what)
        case .sqlite(let rc, let message): .unavailable(detail: "sqlite \(rc): " + message)
        }
    }

    /// One peek per burst; the peek on screen is updated in place. Never while the panel is open or
    /// the surface is hidden (asleep, locked, fullscreen).
    private func announce(_ shown: [SystemNotification]) {
        guard let latest = shown.last, let hub, visibility == .collapsed else { return }
        if coalescer.offer(at: .now) == .update, let peekState {
            peekState.latest = latest
            peekState.more += shown.count
            return
        }
        let state = NotificationPeekState(latest: latest, more: shown.count - 1)
        peekState = state
        hub.show(PeekEvent(module: .notifications, duration: Self.peekDuration,
                           content: AnyView(NotificationPeek(model: model, state: state))))
    }

    // MARK: Actions

    func grantAccess() {
        NSWorkspace.shared.open(Self.privacyURL)
    }

    func openApp(_ bundleID: String) {
        model.apps.open(bundleID)
        hub?.requestClose()
    }

    // MARK: Surface

    public var tab: PanelTab? {
        PanelTab(module: .notifications, symbol: "bell", title: "Notifications") { [model, weak self] in
            AnyView(NotificationsTabView(model: model,
                                         onOpen: { self?.openApp($0) },
                                         onGrantAccess: { self?.grantAccess() }))
        }
    }

    // MARK: Renderer

    public enum RenderState: String, CaseIterable, Sendable {
        case list, hiddenPreviews, needsAccess, unavailable, empty
    }

    /// Puts synthetic content on screen for `glancy-render` (never real notifications).
    public func prepareForRender(_ state: RenderState) {
        L10n.addItalian(NotifText.italian)
        model.settings.hidePreviews = state == .hiddenPreviews
        model.replace(with: state == .empty ? [] : NotificationsSample.items())
        switch state {
        case .list, .hiddenPreviews, .empty: model.state = .live
        case .needsAccess: model.state = .needsFullDiskAccess
        case .unavailable: model.state = Self.state(for: .unsupportedSchema("missing record.data"))
        }
    }

    /// A peek as a new notification would show it, coalesced with one more.
    public func showSamplePeek() {
        guard let hub else { return }
        model.settings.hidePreviews = false
        let items = NotificationsSample.items()
        let state = NotificationPeekState(latest: items[items.count - 2], more: 1)
        hub.show(PeekEvent(module: .notifications, duration: Self.peekDuration,
                           content: AnyView(NotificationPeek(model: model, state: state))))
    }
}
