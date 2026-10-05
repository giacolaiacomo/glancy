// Tiling — one running app: its own thread and CFRunLoop, its AX element and AXObservers.
//
// AeroSpace's model (MacApp.swift, MIT): every Accessibility call for an app happens on that
// app's thread, so one hung app blocks only itself, never the main thread and never the others.
// The main thread talks to a handle only through `perform`, which enqueues a block on the
// handle's run loop and awaits its result.
//
// Run-loop modes: the job queue lives in the default mode only. A placement that waits for the
// app's kAXMoved/kAXResized runs the loop nested in a private mode that carries the observer
// source (added to the common modes) but not the job queue, so no other job can start inside it.

import AppKit
import ApplicationServices
import os

/// A cancellation flag shared between the main thread and an app thread.
final class CancelToken: Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)
    var isCancelled: Bool { flag.withLock { $0 } }
    func cancel() { flag.withLock { $0 = true } }
}

/// An AX notification, reduced to what the registry needs.
struct AXEvent: Sendable {
    enum Kind: Sendable { case windowCreated, focusChanged, destroyed, minimized, deminimized, moved, resized, other }
    let pid: pid_t
    let kind: Kind
    let windowID: CGWindowID?
}

/// One window as read on its app thread. Frames are AX coordinates.
struct WindowSnapshot: Sendable {
    let id: CGWindowID
    let title: String
    let axFrame: CGRect
    let isMinimized: Bool
    let isFullscreen: Bool
    let canMove: Bool
    let canResize: Bool
    let minSize: CGSize?
    let traits: WindowTraits
    /// The ID is a stand-in (the private call and the CGWindowList match both failed).
    let isStandInID: Bool
}

struct AppSnapshot: Sendable {
    let pid: pid_t
    let windows: [WindowSnapshot]
    let focusedID: CGWindowID?
}

/// A placement as the app thread executes it. All rects in AX coordinates.
struct AXPlacement: Sendable {
    let windowID: CGWindowID
    let target: CGRect
    let usable: CGRect
    let edgeTolerance: CGFloat
    /// Whether to switch AXEnhancedUserInterface back on afterwards if it was on.
    let restoreEUI: Bool
    let allowRetry: Bool
}

struct AXPlacementReport: Sendable {
    let windowID: CGWindowID
    let outcome: PlacementOutcome
    let original: CGRect?
    let landed: CGRect?
    let attempts: Int
    let euiWasOn: Bool
    let note: String?
    let elapsed: TimeInterval
}

private let observerCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    Unmanaged<AppHandle>.fromOpaque(refcon).takeUnretainedValue().received(notification as String, element)
}

final class AppHandle: @unchecked Sendable {
    let pid: pid_t
    let bundleID: String?
    let name: String
    let isRegular: Bool

    static let messagingTimeout: Float = 0.25
    static let waitMode = CFRunLoopMode("ai.glancy.tiling.wait" as CFString)
    static let appNotifications = [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
                                   kAXMainWindowChangedNotification]
    static let windowNotifications = [kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification,
                                      kAXWindowDeminiaturizedNotification, kAXMovedNotification,
                                      kAXResizedNotification]

    // Shared between threads, guarded by `lock`.
    private let lock = NSLock()
    private var queue: [(Bool) -> Void] = []
    private var runLoop: CFRunLoop?
    private var jobSource: CFRunLoopSource?
    private var stopped = false

    // Confined to the app thread.
    private var app: AXUIElement?
    private var observer: AXObserver?
    private var appObserved = false
    private var windows: [CGWindowID: AXUIElement] = [:]
    private var cachedTraits: [CGWindowID: (traits: WindowTraits, canMove: Bool, canResize: Bool, minSize: CGSize?)] = [:]
    private var frameEventSerial: [CGWindowID: Int] = [:]
    private let observe: Bool
    private let onEvent: @Sendable (AXEvent) -> Void

    /// - Parameters:
    ///   - observe: register AXObservers (the registry does; the probe does not need to).
    ///   - onEvent: called on the app thread for every AX notification.
    init(pid: pid_t, bundleID: String?, name: String, isRegular: Bool = true, observe: Bool = true,
         onEvent: @escaping @Sendable (AXEvent) -> Void = { _ in }) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.isRegular = isRegular
        self.observe = observe
        self.onEvent = onEvent
        let thread = Thread { [self] in self.threadMain() }
        thread.name = "Glancy.AX.\(bundleID ?? String(pid))"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    // MARK: Cross-thread API

    /// Runs `body` on the app thread and returns its result; nil when the handle is stopped.
    func perform<T: Sendable>(_ body: @escaping @Sendable (AppHandle) -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let accepted = enqueue { alive in
                continuation.resume(returning: alive ? body(self) : nil)
            }
            if !accepted { continuation.resume(returning: nil) }
        }
    }

    /// Stops the thread: pending blocks resume with nil, observers are removed on the way out.
    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let pending = queue
        queue.removeAll()
        let rl = runLoop
        lock.unlock()
        for block in pending { block(false) }
        if let rl { CFRunLoopStop(rl); CFRunLoopWakeUp(rl) }
    }

    var isStopped: Bool { lock.withLock { stopped } }

    private func enqueue(_ block: @escaping (Bool) -> Void) -> Bool {
        lock.lock()
        guard !stopped else { lock.unlock(); return false }
        queue.append(block)
        let rl = runLoop, source = jobSource
        lock.unlock()
        if let rl, let source { CFRunLoopSourceSignal(source); CFRunLoopWakeUp(rl) }
        return true
    }

    // MARK: Thread

    private func threadMain() {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        app = element
        let rl = CFRunLoopGetCurrent()!
        let info = Unmanaged.passUnretained(self).toOpaque()
        var jobContext = CFRunLoopSourceContext(
            version: 0, info: info, retain: nil, release: nil, copyDescription: nil, equal: nil, hash: nil,
            schedule: nil, cancel: nil,
            perform: { info in Unmanaged<AppHandle>.fromOpaque(info!).takeUnretainedValue().drain() })
        let source = CFRunLoopSourceCreate(nil, 0, &jobContext)!
        CFRunLoopAddSource(rl, source, .defaultMode)
        // Keeps the wait mode alive (a mode without sources returns at once) without ever firing.
        var idleContext = CFRunLoopSourceContext()
        let idle = CFRunLoopSourceCreate(nil, 0, &idleContext)!
        CFRunLoopAddSource(rl, idle, Self.waitMode)
        CFRunLoopAddCommonMode(rl, Self.waitMode)

        if observe { _ = registerAppObservers() }

        lock.lock()
        runLoop = rl
        jobSource = source
        let hasPending = !queue.isEmpty
        lock.unlock()
        if hasPending { CFRunLoopSourceSignal(source) }

        while !isStopped {
            _ = CFRunLoopRunInMode(.defaultMode, 1.0e10, false)
        }

        // Tear down in reverse order of creation.
        if let observer {
            CFRunLoopRemoveSource(rl, AXObserverGetRunLoopSource(observer), .commonModes)
        }
        CFRunLoopRemoveSource(rl, source, .defaultMode)
        CFRunLoopRemoveSource(rl, idle, Self.waitMode)
        observer = nil
        windows.removeAll()
        app = nil
    }

    private func drain() {
        while true {
            lock.lock()
            let batch = queue
            queue.removeAll()
            lock.unlock()
            if batch.isEmpty { return }
            for block in batch { block(!isStopped) }
        }
    }

    // MARK: Observers (app thread)

    /// App-level notifications. False when the app is not ready yet (Amethyst retries with a
    /// quadratic backoff; the registry drives that).
    func registerAppObservers() -> Bool {
        guard observe, let app else { return false }
        if appObserved { return true }
        if observer == nil {
            var created: AXObserver?
            guard AXObserverCreate(pid, observerCallback, &created) == .success, let created else { return false }
            observer = created
            CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(created), .commonModes)
        }
        guard let observer else { return false }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var ok = true
        for name in Self.appNotifications {
            let r = AXObserverAddNotification(observer, app, name as CFString, refcon)
            if r != .success && r != .notificationAlreadyRegistered { ok = false }
        }
        appObserved = ok
        return ok
    }

    private func observeWindow(_ element: AXUIElement) {
        guard observe, let observer else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.windowNotifications {
            _ = AXObserverAddNotification(observer, element, name as CFString, refcon)
        }
    }

    private func unobserveWindow(_ element: AXUIElement) {
        guard let observer else { return }
        for name in Self.windowNotifications {
            _ = AXObserverRemoveNotification(observer, element, name as CFString)
        }
    }

    fileprivate func received(_ name: String, _ element: AXUIElement) {
        var id = element.windowID
        if id == nil { id = windows.first { CFEqual($0.value, element) }?.key }
        let kind: AXEvent.Kind
        switch name {
        case kAXWindowCreatedNotification: kind = .windowCreated
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification: kind = .focusChanged
        case kAXUIElementDestroyedNotification: kind = .destroyed
        case kAXWindowMiniaturizedNotification: kind = .minimized
        case kAXWindowDeminiaturizedNotification: kind = .deminimized
        case kAXMovedNotification: kind = .moved
        case kAXResizedNotification: kind = .resized
        default: kind = .other
        }
        if let id, kind == .moved || kind == .resized { frameEventSerial[id, default: 0] &+= 1 }
        if kind == .destroyed, let id, let dead = windows.removeValue(forKey: id) {
            unobserveWindow(dead)
            cachedTraits[id] = nil
        }
        onEvent(AXEvent(pid: pid, kind: kind, windowID: id))
    }

    // MARK: Reading (app thread)

    /// All windows of the app, with IDs, frames and classification. `onScreen` is this app's
    /// part of CGWindowList (front to back), used for the ID fallback and the window level.
    func snapshot(onScreen: [CGWindowInfo]) -> AppSnapshot {
        guard let app else { return AppSnapshot(pid: pid, windows: [], focusedID: nil) }
        if observe, !appObserved { _ = registerAppObservers() }
        let elements = app.elements(AXAttr.windows)
        var claimed = Set<CGWindowID>()
        var result: [WindowSnapshot] = []
        var alive: [CGWindowID: AXUIElement] = [:]
        for element in elements {
            guard let frame = element.axFrame else { continue }
            var standIn = false
            var id = element.windowID
            if id == nil {
                // Rectangle's fallbacks: the CGWindowList entry of this pid at the same frame,
                // then a stand-in from the element's hash (IDs can vanish after session changes).
                id = onScreen.first { !claimed.contains($0.id) && PlacementMath.approx($0.bounds, frame, 1) }?.id
                if id == nil {
                    id = 0x8000_0000 | (CGWindowID(truncatingIfNeeded: CFHash(element)) & 0x7FFF_FFFF)
                    standIn = true
                }
            }
            guard let id, !claimed.contains(id) else { continue }
            claimed.insert(id)
            alive[id] = element
            if windows[id] == nil {
                AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
                observeWindow(element)
            }
            let level = onScreen.first { $0.id == id }?.layer
            var cached = cachedTraits[id] ?? readTraits(element)
            cached.traits.windowLevel = level ?? cached.traits.windowLevel
            cachedTraits[id] = cached
            result.append(WindowSnapshot(
                id: id, title: element.string(AXAttr.title) ?? "", axFrame: frame,
                isMinimized: element.bool(AXAttr.minimized) ?? false,
                isFullscreen: element.bool(AXAttr.fullscreen) ?? false,
                canMove: cached.canMove, canResize: cached.canResize, minSize: cached.minSize,
                traits: cached.traits, isStandInID: standIn))
        }
        for (id, element) in windows where alive[id] == nil {
            unobserveWindow(element)
            cachedTraits[id] = nil
            frameEventSerial[id] = nil
        }
        windows = alive
        let focused = app.element(AXAttr.focusedWindow).flatMap { f in
            f.windowID ?? alive.first { CFEqual($0.value, f) }?.key
        }
        return AppSnapshot(pid: pid, windows: result, focusedID: focused)
    }

    private func readTraits(_ w: AXUIElement) -> (traits: WindowTraits, canMove: Bool, canResize: Bool, minSize: CGSize?) {
        var t = WindowTraits(bundleID: bundleID, role: w.string(AXAttr.role), subrole: w.string(AXAttr.subrole))
        t.identifier = w.string(AXAttr.identifier)
        let close = w.element(AXAttr.closeButton)
        let minimize = w.element(AXAttr.minimizeButton)
        let fullscreen = w.element(AXAttr.fullscreenButton)
        t.hasCloseButton = close != nil
        t.hasMinimizeButton = minimize != nil
        t.hasZoomButton = w.element(AXAttr.zoomButton) != nil
        t.hasFullscreenButton = fullscreen != nil
        t.closeButtonEnabled = close?.bool(AXAttr.enabled)
        t.minimizeButtonEnabled = minimize?.bool(AXAttr.enabled)
        t.fullscreenButtonEnabled = fullscreen?.bool(AXAttr.enabled)
        t.isFocused = w.bool(AXAttr.focused) ?? false
        t.isMain = w.bool(AXAttr.main) ?? false
        t.isRegularApp = isRegular
        return (t, w.isSettable(AXAttr.position), w.isSettable(AXAttr.size), w.minimumSize)
    }

    /// The element for a window ID, looked up again if the cache does not have it.
    func element(for id: CGWindowID) -> AXUIElement? {
        if let e = windows[id] { return e }
        guard let app else { return nil }
        for e in app.elements(AXAttr.windows) where e.windowID == id {
            AXUIElementSetMessagingTimeout(e, Self.messagingTimeout)
            windows[id] = e
            observeWindow(e)
            return e
        }
        return nil
    }

    /// The focused (else main, else first) window of the app — for the probe.
    func frontWindow() -> AXUIElement? {
        guard let app else { return nil }
        return app.element(AXAttr.focusedWindow) ?? app.element(AXAttr.mainWindow) ?? app.elements(AXAttr.windows).first
    }

    var appElement: AXUIElement? { app }

    // MARK: Waiting (app thread)

    func frameSerial(_ id: CGWindowID) -> Int { frameEventSerial[id, default: 0] }

    /// Runs the run loop in the private wait mode until a kAXMoved/kAXResized for `id` arrives
    /// after `serial`, or `timeout` passes. Only the app thread waits; main never does.
    func waitForFrameEvent(_ id: CGWindowID, after serial: Int, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while frameEventSerial[id, default: 0] == serial, !isStopped {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            let result = CFRunLoopRunInMode(Self.waitMode, remaining, true)
            if result == .finished || result == .stopped { break }
        }
    }

    // MARK: Placing (app thread)

    /// RESEARCH §3.2, per window: EUI off → size, position, size → read back → wait for the app
    /// (event or 50 ms) → one retry → re-anchor the size the app chose to the edges the target
    /// touches, inside the usable rect → name the outcome.
    func place(_ p: AXPlacement, token: CancelToken) -> AXPlacementReport {
        let start = Date()
        var attempts = 0
        var euiWasOn = false
        func report(_ outcome: PlacementOutcome, original: CGRect?, landed: CGRect?, _ note: String? = nil) -> AXPlacementReport {
            AXPlacementReport(windowID: p.windowID, outcome: outcome, original: original, landed: landed,
                              attempts: attempts, euiWasOn: euiWasOn, note: note,
                              elapsed: Date().timeIntervalSince(start))
        }
        if token.isCancelled { return report(.cancelled, original: nil, landed: nil) }
        guard let app, let window = element(for: p.windowID) else {
            return report(.unreachable, original: nil, landed: nil, "window gone")
        }
        guard let original = window.axFrame else {
            return report(.unreachable, original: nil, landed: nil, "no answer from the app")
        }
        if window.bool(AXAttr.minimized) == true { return report(.unreachable, original: original, landed: original, "minimized") }
        if window.bool(AXAttr.fullscreen) == true { return report(.unreachable, original: original, landed: original, "fullscreen") }
        let canMove = window.isSettable(AXAttr.position)
        let canResize = window.isSettable(AXAttr.size)
        guard canMove else { return report(.refused, original: original, landed: original, "position not settable") }

        let edges = PlacementMath.touchedEdges(of: p.target, in: p.usable, tolerance: p.edgeTolerance)
        let target = canResize
            ? PlacementMath.respectingMinimum(p.target, minSize: window.minimumSize, edges: edges, bounds: p.usable)
            : PlacementMath.anchoredFrame(size: original.size, within: p.target, edges: edges, bounds: p.usable)

        euiWasOn = app.bool(AXAttr.enhancedUserInterface) == true
        if euiWasOn { app.setBool(AXAttr.enhancedUserInterface, false) }
        defer { if euiWasOn && p.restoreEUI { app.setBool(AXAttr.enhancedUserInterface, true) } }

        // Size → position → size: a size that does not fit at the new origin would otherwise
        // clamp the position (RESEARCH A2). Each step checks for cancellation.
        func write() -> Bool {
            attempts += 1
            if canResize { window.setSize(target.size) }
            if token.isCancelled { return false }
            window.setPosition(target.origin)
            if token.isCancelled { return false }
            if canResize { window.setSize(target.size) }
            return !token.isCancelled
        }
        func read() -> CGRect { window.axFrame ?? original }

        if !PlacementMath.approx(original, target, 1) {
            guard write() else { return report(.cancelled, original: original, landed: read()) }
        }
        var landed = read()
        if !PlacementMath.approx(landed, target) {
            waitForFrameEvent(p.windowID, after: frameSerial(p.windowID), timeout: 0.05)
            if token.isCancelled { return report(.cancelled, original: original, landed: read()) }
            let settled = read()
            if !PlacementMath.approx(settled, target), p.allowRetry {
                guard write() else { return report(.cancelled, original: original, landed: read()) }
                landed = read()
                if !PlacementMath.approx(landed, target) {
                    waitForFrameEvent(p.windowID, after: frameSerial(p.windowID), timeout: 0.05)
                    landed = read()
                }
            } else {
                landed = settled
            }
        }
        if token.isCancelled { return report(.cancelled, original: original, landed: landed) }

        // The app kept its own size: hug the edges the cell touches, stay inside the screen.
        if !PlacementMath.approx(landed, target) {
            let anchored = PlacementMath.anchoredFrame(size: landed.size, within: p.target, edges: edges, bounds: p.usable)
            if !PlacementMath.approx(anchored, landed, 1) {
                window.setPosition(anchored.origin)
                landed = read()
            }
        }
        return report(PlacementMath.outcome(requested: p.target, original: original, landed: landed),
                      original: original, landed: landed)
    }
}
