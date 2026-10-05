// Tiling — the live list of windows, keyed by CGWindowID.
//
// Truth comes from reconciliation, not from events (AeroSpace): AX notifications, NSWorkspace
// notifications and a global left-mouse-up only *trigger* a debounced reconcile of the apps
// concerned, which re-reads their windows on their own threads and diffs the alive IDs.
// Idle cost: nothing runs unless the OS delivers a notification. No timers, no polling.

import AppKit
import ApplicationServices
import Observation

/// One window as the UI and the planner see it. Frames are Cocoa coordinates, real (not snapped).
public struct TrackedWindow: Identifiable, Equatable, Sendable {
    public let id: CGWindowID
    public let pid: pid_t
    public let bundleID: String?
    public let appName: String
    public var title: String
    public var frame: CGRect
    public var isMinimized: Bool
    public var isFullscreen: Bool
    /// In CGWindowList's on-screen list: visible on the current Space.
    public var isOnScreen: Bool
    public var isFocused: Bool
    public var kind: WindowKind
    /// No title yet: a window still being set up by its app (Amethyst).
    public var isProvisional: Bool
    public var canMove: Bool
    public var canResize: Bool
    public var minSize: CGSize?
    /// 0 = frontmost; nil when not on screen.
    public var zIndex: Int?

    /// A window the tiler may move.
    public var isTileable: Bool {
        kind == .tile && canMove && !isMinimized && !isFullscreen && isOnScreen
    }
}

/// What changed in one reconcile, for the engine (history resets, auto-fit, drag-away).
struct RegistryChange {
    var added: [CGWindowID] = []
    var removed: [CGWindowID] = []
    /// Frame changed and the window has no placement in flight (or just finished).
    var movedExternally: [CGWindowID: (old: CGRect, new: CGRect)] = [:]
    /// Provisional windows that just got a title (auto-fit waits for it).
    var titled: [CGWindowID] = []
    var afterMouseUp = false
}

@MainActor @Observable
public final class WindowRegistry {
    /// Every known window, front to back (on-screen windows first, by z-order).
    public private(set) var windows: [TrackedWindow] = []
    /// The focused window of the frontmost app.
    public private(set) var focusedWindowID: CGWindowID?
    public private(set) var isRunning = false

    @ObservationIgnored private var apps: [pid_t: AppHandle] = [:]
    @ObservationIgnored private var appFocus: [pid_t: CGWindowID] = [:]
    @ObservationIgnored private var pendingPids = Set<pid_t>()
    @ObservationIgnored private var pendingFull = false
    @ObservationIgnored private var pendingMouseUp = false
    @ObservationIgnored private var reconcileTask: Task<Void, Never>?
    @ObservationIgnored private var reconciling = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var mouseMonitor: Any?
    @ObservationIgnored private var inFlight: [CGWindowID: Int] = [:]
    @ObservationIgnored private var settledAt: [CGWindowID: Date] = [:]
    @ObservationIgnored private var registrationAttempts: [pid_t: Int] = [:]
    @ObservationIgnored var onChange: ((RegistryChange) -> Void)?

    /// Move/resize events this soon after our own placement are ours, not the user's.
    static let ownEventGrace: TimeInterval = 0.15
    static let debounce: Duration = .milliseconds(50)

    public init() {}

    // MARK: Lifecycle

    /// Starts observing. Does nothing without Accessibility permission (never prompts).
    public func start() {
        guard !isRunning, AXIsProcessTrusted() else { return }
        isRunning = true
        let ws = NSWorkspace.shared.notificationCenter
        func on(_ name: Notification.Name, _ body: @escaping @MainActor (NSRunningApplication?) -> Void) {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { body(app) }
            })
        }
        on(NSWorkspace.didLaunchApplicationNotification) { [weak self] app in
            guard let self, let app else { return }
            self.register(app)
            self.scheduleReconcile(pids: [app.processIdentifier])
        }
        on(NSWorkspace.didTerminateApplicationNotification) { [weak self] app in
            guard let self, let app else { return }
            self.unregister(app.processIdentifier)
        }
        on(NSWorkspace.didActivateApplicationNotification) { [weak self] app in
            guard let self, let app else { return }
            if self.apps[app.processIdentifier] == nil { self.register(app) }
            self.scheduleReconcile(pids: [app.processIdentifier])
        }
        on(NSWorkspace.didHideApplicationNotification) { [weak self] app in
            if let app { self?.scheduleReconcile(pids: [app.processIdentifier]) }
        }
        on(NSWorkspace.didUnhideApplicationNotification) { [weak self] app in
            if let app { self?.scheduleReconcile(pids: [app.processIdentifier]) }
        }
        on(NSWorkspace.activeSpaceDidChangeNotification) { [weak self] _ in self?.scheduleReconcile(pids: nil) }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleReconcile(pids: nil) }
            })
        // "kAXUIElementDestroyedNotification is that unreliable" (AeroSpace): a click anywhere
        // re-reads the frontmost app. One event per click, nothing while idle.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
                self.pendingMouseUp = true
                self.scheduleReconcile(pids: [pid])
            }
        }
        for app in NSWorkspace.shared.runningApplications { register(app) }
        scheduleReconcile(pids: nil, delay: .zero)
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        reconcileTask?.cancel()
        reconcileTask = nil
        let ws = NSWorkspace.shared.notificationCenter
        for o in observers { ws.removeObserver(o); NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        for handle in apps.values { handle.stop() }
        apps.removeAll()
        appFocus.removeAll()
        windows.removeAll()
        focusedWindowID = nil
    }

    private func register(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, pid != ProcessInfo.processInfo.processIdentifier,
              !app.isTerminated, apps[pid] == nil else { return }
        let handle = AppHandle(pid: pid, bundleID: app.bundleIdentifier, name: app.localizedName ?? "") { [weak self] event in
            Task { @MainActor in self?.received(event) }
        }
        apps[pid] = handle
        registrationAttempts[pid] = 0
        Task { [weak self] in await self?.ensureObserved(pid) }
    }

    /// Amethyst's backoff for apps that are not ready at launch: count² × 100 ms, 6 tries.
    private func ensureObserved(_ pid: pid_t) async {
        while let handle = apps[pid], let attempt = registrationAttempts[pid], attempt < 6 {
            if await handle.perform({ $0.registerAppObservers() }) == true { registrationAttempts[pid] = nil; return }
            registrationAttempts[pid] = attempt + 1
            try? await Task.sleep(for: .milliseconds(100 * (attempt + 1) * (attempt + 1)))
        }
    }

    private func unregister(_ pid: pid_t) {
        apps.removeValue(forKey: pid)?.stop()
        appFocus[pid] = nil
        registrationAttempts[pid] = nil
        let gone = windows.filter { $0.pid == pid }.map(\.id)
        guard !gone.isEmpty else { return }
        windows.removeAll { $0.pid == pid }
        if let f = focusedWindowID, gone.contains(f) { focusedWindowID = nil }
        onChange?(RegistryChange(removed: gone))
    }

    // MARK: Events

    private func received(_ event: AXEvent) {
        guard isRunning else { return }
        if event.kind == .moved || event.kind == .resized, let id = event.windowID, isOwnEvent(id) { return }
        scheduleReconcile(pids: [event.pid])
    }

    private func isOwnEvent(_ id: CGWindowID) -> Bool {
        if inFlight[id, default: 0] > 0 { return true }
        if let t = settledAt[id], Date().timeIntervalSince(t) < Self.ownEventGrace { return true }
        return false
    }

    /// Debounced, cancellable: a burst of notifications becomes one reconcile.
    func scheduleReconcile(pids: Set<pid_t>?, delay: Duration = debounce) {
        guard isRunning else { return }
        if let pids { pendingPids.formUnion(pids) } else { pendingFull = true }
        reconcileTask?.cancel()
        reconcileTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.reconcile()
        }
    }

    // MARK: Placement bookkeeping (used by the Placer)

    func handle(for pid: pid_t) -> AppHandle? { apps[pid] }

    func beginPlacement(_ id: CGWindowID) { inFlight[id, default: 0] += 1 }

    func hasPlacementInFlight(_ id: CGWindowID) -> Bool { inFlight[id, default: 0] > 0 }

    func endPlacement(_ id: CGWindowID, landed: CGRect?) {
        inFlight[id] = max(0, inFlight[id, default: 1] - 1)
        if inFlight[id] == 0 { inFlight[id] = nil }
        settledAt[id] = Date()
        if let landed, let i = windows.firstIndex(where: { $0.id == id }) { windows[i].frame = landed }
    }

    public func window(_ id: CGWindowID) -> TrackedWindow? { windows.first { $0.id == id } }

    /// Reconciles every app now and returns when done (the UI calls this when the map opens).
    public func refresh() async {
        guard isRunning else { return }
        pendingFull = true
        reconcileTask?.cancel()
        await reconcile()
    }

    // MARK: Reconcile

    private func reconcile() async {
        guard isRunning else { return }
        if reconciling {
            // One at a time; whatever arrived meanwhile runs right after.
            scheduleReconcile(pids: [], delay: Self.debounce)
            return
        }
        reconciling = true
        defer { reconciling = false }
        let full = pendingFull
        let pids = full ? Set(apps.keys) : pendingPids
        let mouseUp = pendingMouseUp
        pendingFull = false
        pendingPids.removeAll()
        pendingMouseUp = false

        let onScreen = await Task.detached(priority: .userInitiated) { CGWindowInfo.onScreen() }.value
        let targets = pids.compactMap { apps[$0] }
        let snapshots = await withTaskGroup(of: (pid_t, AppSnapshot?).self) { group in
            for handle in targets {
                let mine = onScreen.filter { $0.pid == handle.pid }
                group.addTask { (handle.pid, await handle.perform { $0.snapshot(onScreen: mine) }) }
            }
            var out: [(pid_t, AppSnapshot?)] = []
            for await item in group { out.append(item) }
            return out
        }
        guard isRunning else { return }
        apply(snapshots: snapshots, onScreen: onScreen, mouseUp: mouseUp)
    }

    private func apply(snapshots: [(pid_t, AppSnapshot?)], onScreen: [CGWindowInfo], mouseUp: Bool) {
        let h = ScreenSpace.primaryHeight
        var byID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        var change = RegistryChange(afterMouseUp: mouseUp)
        let z = Dictionary(onScreen.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })

        for (pid, snapshot) in snapshots {
            guard let snapshot, let handle = apps[pid] else { continue }
            let seen = Set(snapshot.windows.map(\.id))
            for (id, w) in byID where w.pid == pid && !seen.contains(id) {
                byID[id] = nil
                change.removed.append(id)
            }
            appFocus[pid] = snapshot.focusedID
            for s in snapshot.windows {
                let frame = ScreenSpace.flip(s.axFrame, primaryHeight: h)
                let kind = WindowClassifier.classify(s.traits)
                if let old = byID[s.id] {
                    if !PlacementMath.approx(old.frame, frame, 1), !isOwnEvent(s.id) {
                        change.movedExternally[s.id] = (old.frame, frame)
                    }
                    if old.title.isEmpty, !s.title.isEmpty { change.titled.append(s.id) }
                } else {
                    change.added.append(s.id)
                }
                byID[s.id] = TrackedWindow(
                    id: s.id, pid: pid, bundleID: handle.bundleID, appName: handle.name, title: s.title,
                    frame: frame, isMinimized: s.isMinimized, isFullscreen: s.isFullscreen,
                    isOnScreen: z[s.id] != nil, isFocused: false, kind: kind,
                    isProvisional: s.title.isEmpty, canMove: s.canMove, canResize: s.canResize,
                    minSize: s.minSize, zIndex: z[s.id])
            }
        }
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let focused = frontPid.flatMap { appFocus[$0] }
        for id in Array(byID.keys) {
            byID[id]?.zIndex = z[id]
            byID[id]?.isOnScreen = z[id] != nil
            byID[id]?.isFocused = id == focused
        }
        let sorted = byID.values.sorted { a, b in
            switch (a.zIndex, b.zIndex) {
            case let (x?, y?): return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.id < b.id
            }
        }
        if sorted != windows { windows = sorted }
        if focusedWindowID != focused { focusedWindowID = focused }
        for id in change.removed { settledAt[id] = nil; inFlight[id] = nil }
        if !change.added.isEmpty || !change.removed.isEmpty || !change.movedExternally.isEmpty
            || !change.titled.isEmpty || mouseUp {
            onChange?(change)
        }
    }
}
