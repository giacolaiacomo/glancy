import SwiftUI

// The seams every module plugs into. Owned by the lead; change only through the plan.

public enum ModuleID: String, CaseIterable, Codable, Sendable {
    case agents, calendar, media, hud, power, timer, shelf, clipboard, windows, notifications
    case command, control, notes
    case monitor
}

/// What the surface is doing right now. Modules use it to start/stop work that only matters
/// while something is on screen (progress bars, pulses, refreshes). Collapsed = no periodic work.
public enum SurfaceVisibility: Sendable, Equatable {
    case hidden          // screen asleep, locked, fullscreen space, or module not shown
    case collapsed       // idle / activity wings only
    case expanded(ModuleID?)  // panel open; the tab on screen (nil = Home)
}

/// A module of Glancy. Must be cheap to construct; all observation begins in `start`.
@MainActor
public protocol GlancyModule: AnyObject {
    var id: ModuleID { get }
    /// Begin event-driven observation. Never polls. Posts activities to `hub`.
    func start(hub: ActivityHub)
    /// Tear down every observer, task, child process. Must leave nothing running.
    func stop()
    /// Called on every visibility change.
    func visibilityChanged(_ visibility: SurfaceVisibility)
    /// The tab in the expanded panel, built lazily and destroyed on collapse. nil = no tab.
    var tab: PanelTab? { get }
    /// A compact card for the Home tab, or nil when the module has nothing worth a glance.
    func homeCard() -> AnyView?
    /// Fixed actions this module offers to the command bar (filtered there by title/keywords).
    /// Built on demand when the bar opens; never cached across opens.
    func commands() -> [GlancyCommand]
    /// Results computed from what the user typed (search, a calculation…). Must be fast (< 5 ms)
    /// and synchronous; return [] when the query is not for this module.
    func results(for query: String) -> [GlancyCommand]
}

public extension GlancyModule {
    func visibilityChanged(_ visibility: SurfaceVisibility) {}
    var tab: PanelTab? { nil }
    func homeCard() -> AnyView? { nil }
    func commands() -> [GlancyCommand] { [] }
    func results(for query: String) -> [GlancyCommand] { [] }
}

/// One entry of the command bar (⌃⌥K style launcher in the notch).
public struct GlancyCommand: Identifiable {
    public var id: String               // stable, "<module>.<action>[.<arg>]"
    public var module: ModuleID
    public var title: String            // localized, shown as-is
    public var subtitle: String?
    public var symbol: String           // SF Symbol
    public var keywords: [String]       // extra match terms (EN + IT)
    /// Higher wins when scores tie; results(for:) entries usually 50–100, commands() 0.
    public var rank: Int
    /// true = the bar closes the panel after running; false = keeps it open (e.g. a toggle).
    public var closesPanel: Bool
    public var run: @MainActor () -> Void
    public init(id: String, module: ModuleID, title: String, subtitle: String? = nil, symbol: String,
                keywords: [String] = [], rank: Int = 0, closesPanel: Bool = true, run: @escaping @MainActor () -> Void) {
        self.id = id; self.module = module; self.title = title; self.subtitle = subtitle; self.symbol = symbol
        self.keywords = keywords; self.rank = rank; self.closesPanel = closesPanel; self.run = run
    }
}

public struct PanelTab {
    public let module: ModuleID
    public let symbol: String          // SF Symbol for the tab strip
    public let title: LocalizedStringKey
    public let content: @MainActor () -> AnyView
    public init(module: ModuleID, symbol: String, title: LocalizedStringKey, content: @escaping @MainActor () -> AnyView) {
        self.module = module; self.symbol = symbol; self.title = title; self.content = content
    }
}

/// Something worth showing in the wings left/right of the notch while collapsed.
public struct LiveActivity: Identifiable {
    public let id: String              // stable per subject, e.g. "agents", "media", "hud.volume"
    public let module: ModuleID
    public var priority: Int           // see SPEC §2 "Live-activity arbitration"
    public var updated: Date
    public var expires: Date?          // nil = until cleared
    public var left: AnyView           // ≤ Theme.wingMaxWidth wide, menu-bar height
    public var right: AnyView
    public init(id: String, module: ModuleID, priority: Int, updated: Date = .now, expires: Date? = nil,
                left: AnyView, right: AnyView) {
        self.id = id; self.module = module; self.priority = priority; self.updated = updated
        self.expires = expires; self.left = left; self.right = right
    }
}

/// A transient drop-down (track changed, session finished, AirPods connected, meeting in 2').
public struct PeekEvent: Identifiable {
    public let id = UUID()
    public let module: ModuleID
    public var duration: TimeInterval
    public var content: AnyView
    public init(module: ModuleID, duration: TimeInterval = 2.5, content: AnyView) {
        self.module = module; self.duration = duration; self.content = content
    }
}

/// Arbitration between modules. The surface observes `top` and `peek`; nothing else.
@MainActor @Observable
public final class ActivityHub {
    public private(set) var top: LiveActivity?
    public private(set) var peek: PeekEvent?

    @ObservationIgnored private var activities: [String: LiveActivity] = [:]
    @ObservationIgnored private var peekQueue: [PeekEvent] = []
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var peekTask: Task<Void, Never>?

    public init() {}

    public func post(_ activity: LiveActivity) {
        activities[activity.id] = activity
        recompute()
    }

    /// The highest live priority a module currently holds (0 when none) — used to rank Home.
    public func priority(of module: ModuleID) -> Int {
        activities.values.filter { $0.module == module && ($0.expires ?? .distantFuture) > .now }
            .map(\.priority).max() ?? 0
    }

    public func clear(_ id: String) {
        guard activities.removeValue(forKey: id) != nil else { return }
        recompute()
    }

    public func clearAll(from module: ModuleID) {
        activities = activities.filter { $0.value.module != module }
        recompute()
    }

    /// Modules ask the surface to open (a file dragged to the notch → Shelf, a window dragged to
    /// the notch → Windows, a hotkey → a tab) or to close. Wired by the surface; no-op before that.
    @ObservationIgnored public var onOpenRequest: ((ModuleID?) -> Void)?
    @ObservationIgnored public var onCloseRequest: (() -> Void)?
    public func requestOpen(_ tab: ModuleID?) { onOpenRequest?(tab) }
    public func requestClose() { onCloseRequest?() }

    public func show(_ event: PeekEvent) {
        peekQueue.append(event)
        if peek == nil { advancePeek() }
    }

    private func advancePeek() {
        peekTask?.cancel()
        guard !peekQueue.isEmpty else { peek = nil; return }
        let next = peekQueue.removeFirst()
        peek = next
        peekTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(next.duration))
            guard !Task.isCancelled else { return }
            self?.advancePeek()
        }
    }

    private func recompute() {
        let now = Date.now
        activities = activities.filter { ($0.value.expires ?? .distantFuture) > now }
        let best = activities.values.max { a, b in
            a.priority != b.priority ? a.priority < b.priority : a.updated < b.updated
        }
        if best?.id != top?.id || best?.updated != top?.updated { top = best }
        // One wake-up at the next expiry, never a ticking timer.
        expiryTask?.cancel()
        if let soonest = activities.values.compactMap(\.expires).min() {
            expiryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, soonest.timeIntervalSinceNow)))
                guard !Task.isCancelled else { return }
                self?.recompute()
            }
        }
    }
}
