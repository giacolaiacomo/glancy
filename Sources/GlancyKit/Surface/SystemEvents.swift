import AppKit
import ApplicationServices
import Carbon.HIToolbox

// Everything the surface listens to, all event-driven: sleep, lock, screens, Spaces, fullscreen,
// Mission Control, and a global Esc that exists only while the panel is open.

// MARK: - Display identity

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Stable across reboots and re-plugging (`CGDisplayCreateUUIDFromDisplayID`).
    var displayUUID: String? {
        guard let id = displayID, let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    var info: ScreenInfo? {
        guard let uuid = displayUUID, let id = displayID else { return nil }
        return ScreenInfo(uuid: uuid, frame: frame, visibleFrame: visibleFrame, safeTop: safeAreaInsets.top,
                          auxLeft: auxiliaryTopLeftArea, auxRight: auxiliaryTopRightArea,
                          isBuiltin: CGDisplayIsBuiltin(id) != 0, scale: backingScaleFactor)
    }
}

// MARK: - Fullscreen spaces
//
// Technique from MacroVisionKit's FullScreenMonitor (MIT, see NOTICE): on each Space change read
// the managed display spaces; a display whose current space has a TileLayoutManager is showing a
// fullscreen app. One read per event, no polling.

private typealias CGSConnectionID = Int32
@_silgen_name("CGSMainConnectionID") private func CGSMainConnectionID() -> CGSConnectionID
@_silgen_name("CGSCopyManagedDisplaySpaces") private func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> CFArray?

enum FullscreenSpaces {
    /// Display identifiers whose current space is fullscreen. "Main" stands for every display when
    /// "Displays have separate Spaces" is off.
    static func current() -> Set<String> {
        guard let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]] else { return [] }
        return fullscreenDisplays(in: displays)
    }

    static func fullscreenDisplays(in displays: [[String: Any]]) -> Set<String> {
        var out = Set<String>()
        for d in displays {
            guard let current = d["Current Space"] as? [String: Any],
                  let spaces = d["Spaces"] as? [[String: Any]],
                  let display = d["Display Identifier"] as? String else { continue }
            let activeID = current["ManagedSpaceID"] as? Int ?? -1
            guard let active = spaces.first(where: { ($0["ManagedSpaceID"] as? Int) == activeID }) else { continue }
            if active["TileLayoutManager"] != nil { out.insert(display) }
        }
        return out
    }
}

// MARK: - System notifications

@MainActor
final class SystemEvents {
    var onPauseChanged: ((Bool) -> Void)?
    var onScreensChanged: (() -> Void)?
    var onSpaceChanged: (() -> Void)?
    var onMissionControl: ((Bool) -> Void)?

    private(set) var paused = false
    private var systemAsleep = false, screensAsleep = false, locked = false, sessionInactive = false
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var dock: MissionControlObserver?
    private var dockRetry: Task<Void, Never>?

    /// The centers to listen on. Tests pass private ones: nothing reaches the real system and a
    /// posted "sleep" or "lock" stays inside the test.
    private let workspace: NotificationCenter
    private let distributed: NotificationCenter
    private let app: NotificationCenter
    private let observesDock: Bool

    init(workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
         distributed: NotificationCenter = DistributedNotificationCenter.default(),
         app: NotificationCenter = .default, observesDock: Bool = true) {
        self.workspace = workspace; self.distributed = distributed; self.app = app; self.observesDock = observesDock
    }

    /// Observer tokens currently registered (diagnostics, tests).
    var observerCount: Int { tokens.count }

    func start() {
        guard tokens.isEmpty else { return }
        let ws = workspace, dn = distributed
        observe(ws, NSWorkspace.willSleepNotification) { $0.systemAsleep = true }
        observe(ws, NSWorkspace.didWakeNotification) { $0.systemAsleep = false }
        observe(ws, NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true }
        observe(ws, NSWorkspace.screensDidWakeNotification) { $0.screensAsleep = false }
        observe(ws, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionInactive = true }
        observe(ws, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionInactive = false }
        observe(dn, Notification.Name("com.apple.screenIsLocked")) { $0.locked = true }
        observe(dn, Notification.Name("com.apple.screenIsUnlocked")) { $0.locked = false }
        add(ws, NSWorkspace.activeSpaceDidChangeNotification) { $0.onSpaceChanged?() }
        add(app, NSApplication.didChangeScreenParametersNotification) { $0.onScreensChanged?() }
        guard observesDock else { return }
        add(ws, NSWorkspace.didLaunchApplicationNotification) { me, note in
            // Only the Dock restarting matters: re-attach the Mission Control observer.
            let launched = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if launched?.bundleIdentifier == "com.apple.dock" { me.attachDock() }
        }
        // Accessibility granted after launch: the TCC write lands just after this notification.
        add(dn, Notification.Name("com.apple.accessibility.api")) { me in
            me.dockRetry?.cancel()
            me.dockRetry = Task { [weak me] in
                try? await Delay.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                me?.attachDock()
            }
        }
        attachDock()
    }

    func stop() {
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
        dockRetry?.cancel(); dockRetry = nil
        dock = nil
        systemAsleep = false; screensAsleep = false; locked = false; sessionInactive = false
        paused = false
    }

    /// Mission Control enter/exit comes from the Dock's accessibility notifications, which need
    /// the Accessibility grant. Without it, only the Space-switch fade applies.
    func attachDock() {
        guard Lab.accessibilityTrusted(),
              let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        else { return }
        if dock?.pid == pid { return }
        dock = MissionControlObserver(pid: pid) { [weak self] active in self?.onMissionControl?(active) }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ apply: @escaping @MainActor (SystemEvents) -> Void) {
        add(center, name) { me in
            apply(me)
            me.recompute()
        }
    }

    private func add(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping @MainActor (SystemEvents) -> Void) {
        add(center, name) { me, _ in body(me) }
    }

    private func add(_ center: NotificationCenter, _ name: Notification.Name,
                     _ body: @escaping @MainActor (SystemEvents, Notification) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            // Delivered on the main queue; the note never leaves it.
            nonisolated(unsafe) let note = note
            MainActor.assumeIsolated {
                guard let self else { return }
                body(self, note)
            }
        }
        tokens.append((center, token))
    }

    private func recompute() {
        let now = systemAsleep || screensAsleep || locked || sessionInactive
        guard now != paused else { return }
        paused = now
        onPauseChanged?(now)
    }
}

// MARK: - Mission Control

/// Observes the Dock's "AXExpose…" notifications (the ones window managers use to tell when
/// Mission Control is on screen).
@MainActor
final class MissionControlObserver {
    let pid: pid_t
    nonisolated(unsafe) private var observer: AXObserver?
    private let element: AXUIElement
    private let handler: (Bool) -> Void

    private static let enter = ["AXExposeShowAllWindows", "AXExposeShowFrontWindows", "AXExposeShowDesktop"]
    private static let exit = "AXExposeExit"

    init?(pid: pid_t, handler: @escaping (Bool) -> Void) {
        self.pid = pid
        self.handler = handler
        element = AXUIElementCreateApplication(pid)
        // Registration messages the Dock synchronously, on main: never wait on a busy Dock for
        // the default 6 s (a stuck launch looks exactly like that).
        AXUIElementSetMessagingTimeout(element, 0.25)
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, name, refcon in
            guard let refcon else { return }
            let me = Unmanaged<MissionControlObserver>.fromOpaque(refcon).takeUnretainedValue()
            let entering = (name as String) != MissionControlObserver.exit
            MainActor.assumeIsolated { me.handler(entering) }
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return nil }
        observer = obs
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.enter + [Self.exit] {
            AXObserverAddNotification(obs, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
    }

    deinit {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
    }
}

// MARK: - Esc while expanded

/// A Carbon hot key on Esc, registered only while the panel is open: closes it without the panel
/// ever becoming key and without any permission. Unregistered on collapse, so Esc is untouched.
///
/// The handler sits on the event dispatcher, which sees every hot key of the process before its
/// target does: it must claim only its own (signature + id) and pass the others on — otherwise,
/// once the panel had been opened, ⌥⌘V and the tiling hot keys would just close the panel.
@MainActor
final class EscapeHotKey {
    nonisolated static let signature = OSType(0x4C4E5441)   // 'LNTA'
    nonisolated static let hotKeyID: UInt32 = 1

    nonisolated(unsafe) private var ref: EventHotKeyRef?
    nonisolated(unsafe) private var handlerRef: EventHandlerRef?
    private var registeredFlag = false
    /// false in tests: only the state changes, nothing is registered with the system.
    private let system: Bool
    var onPress: (() -> Void)?

    init(system: Bool = true) { self.system = system }

    var isRegistered: Bool { registeredFlag }
    var hasHandler: Bool { handlerRef != nil }

    func register() {
        guard !registeredFlag else { return }
        registeredFlag = true
        guard system else { return }
        installHandlerOnce()
        let id = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        RegisterEventHotKey(UInt32(kVK_Escape), 0, id, GetEventDispatcherTarget(), 0, &ref)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        registeredFlag = false
    }

    /// Unregisters and removes the dispatcher handler (its refcon points at self).
    func tearDown() {
        unregister()
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
    }

    /// Whether a hot-key event is ours. Pure, for tests.
    nonisolated static func isOurs(_ id: EventHotKeyID) -> Bool {
        id.signature == signature && id.id == hotKeyID
    }

    /// Installs the dispatcher handler (tests drive it with synthetic events).
    func installHandlerOnce() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, refcon in
            guard let event, let refcon else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, EscapeHotKey.isOurs(id) else { return OSStatus(eventNotHandledErr) }
            let me = Unmanaged<EscapeHotKey>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { me.onPress?() }
            return noErr
        }, 1, &spec, refcon, &handlerRef)
    }

    deinit {
        // Never leave a handler whose refcon outlives us.
        if let handlerRef { RemoveEventHandler(handlerRef) }
        if let ref { UnregisterEventHotKey(ref) }
    }
}
