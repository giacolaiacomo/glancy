import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import GlancyKit

// Lot J: the surface against the situations that break notch apps (RESEARCH Technical §1, §9):
// clamshell, hot-plug, resolution/scale change, duplicate display UUIDs, menu-bar auto-hide,
// sleep/wake, lock, fullscreen spaces, Mission Control. Synthetic screens and private
// notification centers: nothing here touches the real displays, the session or the Dock, and no
// panel is ever put on screen.

private let builtin = ScreenInfo(
    uuid: "BUILTIN", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    visibleFrame: CGRect(x: 0, y: 57, width: 1512, height: 892), safeTop: 32,
    auxLeft: CGRect(x: 0, y: 950, width: 665, height: 32), auxRight: CGRect(x: 850, y: 950, width: 662, height: 32),
    isBuiltin: true, scale: 2)

private let ultrawide = ScreenInfo(
    uuid: "ACER", frame: CGRect(x: -928, y: 982, width: 3440, height: 1440),
    visibleFrame: CGRect(x: -928, y: 982, width: 3440, height: 1416), safeTop: 0,
    auxLeft: nil, auxRight: nil, isBuiltin: false, scale: 1)

/// Records every visibility the surface fans out.
@MainActor final class RecordingModule: GlancyModule {
    let id: ModuleID
    var seen: [SurfaceVisibility] = []
    var onVisibility: ((SurfaceVisibility) -> Void)?
    init(_ id: ModuleID = .agents) { self.id = id }
    func start(hub: ActivityHub) {}
    func stop() {}
    func visibilityChanged(_ visibility: SurfaceVisibility) { seen.append(visibility); onVisibility?(visibility) }
}

@MainActor final class SurfaceHarness {
    final class Box { var screens: [ScreenInfo] = []; var full: Set<String> = [] }
    let box = Box()
    let ws = NotificationCenter(), dn = NotificationCenter(), appCenter = NotificationCenter()
    let module = RecordingModule()
    let settings: AppSettings
    let manager: SurfaceManager

    init(_ screens: [ScreenInfo], pill: Bool = false) {
        box.screens = screens
        settings = AppSettings(defaults: UserDefaults(suiteName: "glancy.test.surface.\(UUID().uuidString)")!)
        settings.externalPill = pill
        let context = SurfaceContext(hub: ActivityHub(), settings: settings, launchAtLogin: LaunchAtLogin(), modules: [module])
        let box = self.box
        manager = SurfaceManager(context: context, screens: { box.screens }, fullscreenSpaces: { box.full },
                                 events: SystemEvents(workspace: ws, distributed: dn, app: appCenter, observesDock: false),
                                 presents: false)
        manager.start()
    }

    func setScreens(_ s: [ScreenInfo]) {
        box.screens = s
        appCenter.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }
    func post(_ name: Notification.Name) { ws.post(name: name, object: nil) }
    func postDistributed(_ name: String) { dn.post(name: Notification.Name(name), object: nil) }

    var ids: [String] { manager.surfacesForTest.map(\.uuid).sorted() }
    var builtinSurface: SurfaceController? { manager.surface("BUILTIN") }
}

@MainActor
@Suite("Surface hardening: displays")
struct SurfaceDisplayTests {
    @Test func clamshellRemovesTheNotchAndBringsItBack() {
        let h = SurfaceHarness([builtin, ultrawide])
        #expect(h.ids == ["BUILTIN"])
        #expect(h.manager.visibility == .collapsed)
        // Lid closed: the built-in display disappears.
        h.setScreens([ultrawide])
        #expect(h.ids.isEmpty)
        #expect(h.manager.visibility == .hidden)
        // Lid opened.
        h.setScreens([ultrawide, builtin])
        #expect(h.ids == ["BUILTIN"])
        #expect(h.manager.visibility == .collapsed)
        #expect(h.module.seen == [.collapsed, .hidden, .collapsed])
    }

    @Test func clamshellWhileExpandedLeavesNoEscOrClickMonitorBehind() {
        let h = SurfaceHarness([builtin])
        let s = try! #require(h.builtinSurface)
        h.manager.open(s)
        #expect(h.manager.visibility == .expanded(nil))
        #expect(h.manager.escapeRegistered)
        #expect(h.manager.clickMonitorInstalled)
        h.setScreens([ultrawide])
        #expect(!h.manager.escapeRegistered, "Esc must not stay hijacked once the panel's display is gone")
        #expect(!h.manager.clickMonitorInstalled)
        #expect(h.manager.visibility == .hidden)
    }

    @Test func externalPillFollowsTheSettingAndHotPlug() {
        let h = SurfaceHarness([builtin], pill: true)
        #expect(h.ids == ["BUILTIN"])
        h.setScreens([builtin, ultrawide])
        #expect(h.ids == ["ACER", "BUILTIN"])
        #expect(h.manager.surface("ACER")?.model.geometry.kind == .pill)
        h.setScreens([builtin])            // cable pulled
        #expect(h.ids == ["BUILTIN"])
    }

    @Test func resolutionAndScaleChangeKeepTheSurfaceAndRefitTheWindow() {
        let h = SurfaceHarness([builtin])
        let before = try! #require(h.builtinSurface)
        // "More space": a scaled resolution, the notch areas move with it; then 1× (mirroring).
        var scaled = builtin
        scaled.frame = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        scaled.auxLeft = CGRect(x: 0, y: 1137, width: 793, height: 32)
        scaled.auxRight = CGRect(x: 1007, y: 1137, width: 793, height: 32)
        scaled.scale = 1
        h.setScreens([scaled])
        let after = try! #require(h.builtinSurface)
        #expect(before === after, "same display UUID: the surface is updated, not recreated")
        let g = NotchGeometry.notch(for: scaled)!
        #expect(after.model.geometry == g)
        #expect(after.panelFrame == after.model.layout.windowFrame(in: g))
        #expect(after.panelFrame.maxY == scaled.frame.maxY)   // still flush to the top edge
    }

    @Test func identicalMonitorsSharingAUUIDEachGetAPill() {
        var twin = ultrawide
        twin.frame = CGRect(x: 2512, y: 982, width: 3440, height: 1440)
        twin.visibleFrame = twin.frame.insetBy(dx: 0, dy: 12).offsetBy(dx: 0, dy: -12)
        let w = SurfaceManager.wanted([builtin, ultrawide, twin], externalPill: true, menuBar: 24)
        #expect(Set(w.keys) == ["BUILTIN", "ACER", "ACER#2"])
        #expect(w["ACER"]!.notchRect.midX != w["ACER#2"]!.notchRect.midX)
        // Same input, same keys: re-layout diffs to nothing (no churn on every notification).
        let again = SurfaceManager.wanted([builtin, ultrawide, twin], externalPill: true, menuBar: 24)
        #expect(ScreenDiff.between(w, again).isEmpty)
    }

    @Test func menuBarAutoHideKeepsTheNotchAndThePillHeight() {
        var hidden = builtin
        hidden.visibleFrame = CGRect(x: 0, y: 57, width: 1512, height: 925)   // reaches the top
        #expect(NotchGeometry.notch(for: hidden) == NotchGeometry.notch(for: builtin))
        var ext = ultrawide
        ext.visibleFrame = ext.frame                                         // auto-hidden bar
        let w = SurfaceManager.wanted([ext], externalPill: true, menuBar: 24)
        #expect(w["ACER"]?.notchRect.height == 24)
    }

    @Test func repeatedNotificationsWithNoChangeDoNothing() {
        let h = SurfaceHarness([builtin])
        let s = h.builtinSurface
        for _ in 0..<5 { h.setScreens([builtin]) }
        #expect(h.builtinSurface === s)
        #expect(h.module.seen == [.collapsed])
    }
}

@MainActor
@Suite("Surface hardening: sleep, lock, spaces")
struct SurfaceSessionTests {
    @Test func sleepHidesAndCollapsesWakeRestores() {
        let h = SurfaceHarness([builtin])
        let s = try! #require(h.builtinSurface)
        h.manager.open(s)
        s.model.select(tab: .media)
        h.post(NSWorkspace.willSleepNotification)
        #expect(h.manager.isPaused)
        #expect(s.model.hidden)
        #expect(!s.model.expanded, "sleeping with the panel open must not wake up to it")
        #expect(!h.manager.escapeRegistered)
        h.post(NSWorkspace.didWakeNotification)
        #expect(!h.manager.isPaused)
        #expect(!s.model.hidden)
        #expect(h.manager.pendingSettle, "a second display read is armed after wake")
        #expect(h.module.seen == [.collapsed, .expanded(nil), .expanded(.media), .hidden, .collapsed])
    }

    @Test func lidOpenedWhileAsleepIsSeenOnWake() {
        let h = SurfaceHarness([ultrawide])
        #expect(h.ids.isEmpty)
        h.post(NSWorkspace.willSleepNotification)
        h.box.screens = [ultrawide, builtin]    // changed while asleep, no notification
        h.post(NSWorkspace.didWakeNotification)
        #expect(h.ids == ["BUILTIN"])
        #expect(h.manager.visibility == .collapsed)
    }

    @Test func settleReadCatchesDisplaysThatComeBackLate() async throws {
        let h = SurfaceHarness([builtin])
        h.post(NSWorkspace.willSleepNotification)
        h.box.screens = []                      // displays not back yet at wake
        h.post(NSWorkspace.didWakeNotification)
        #expect(h.ids.isEmpty)
        h.box.screens = [builtin]               // they settle, silently
        // One delayed read (no polling in the app); the test waits generously, main may be busy.
        try await Task.sleep(for: SurfaceManager.settleDelay)
        for _ in 0..<100 where h.ids.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        #expect(h.ids == ["BUILTIN"])
        #expect(!h.manager.pendingSettle)
    }

    @Test func lockAndScreenSleepCombine() {
        let h = SurfaceHarness([builtin])
        h.postDistributed("com.apple.screenIsLocked")
        h.post(NSWorkspace.screensDidSleepNotification)
        #expect(h.manager.visibility == .hidden)
        h.post(NSWorkspace.screensDidWakeNotification)     // screen on, still locked
        #expect(h.manager.visibility == .hidden)
        h.postDistributed("com.apple.screenIsUnlocked")
        #expect(h.manager.visibility == .collapsed)
        h.post(NSWorkspace.sessionDidResignActiveNotification)   // fast user switching
        #expect(h.manager.visibility == .hidden)
        h.post(NSWorkspace.sessionDidBecomeActiveNotification)
        #expect(h.module.seen == [.collapsed, .hidden, .collapsed, .hidden, .collapsed])
    }

    @Test func missedMissionControlExitIsRepairedOnWake() {
        let h = SurfaceHarness([builtin])
        let s = try! #require(h.builtinSurface)
        h.manager.missionControl(true)
        #expect(s.isFaded && s.panelAlpha == 0)
        // Asleep in Mission Control: the Dock's exit notification never comes.
        h.post(NSWorkspace.willSleepNotification)
        h.post(NSWorkspace.didWakeNotification)
        #expect(!s.isFaded)
        #expect(s.panelAlpha == 1, "the notch must not stay invisible after wake")
    }

    @Test func fullscreenSpaceHidesItsDisplayOnly() {
        let h = SurfaceHarness([builtin, ultrawide], pill: true)
        h.box.full = ["ACER"]
        h.post(NSWorkspace.activeSpaceDidChangeNotification)
        #expect(h.manager.surface("ACER")?.model.hidden == true)
        #expect(h.builtinSurface?.model.hidden == false)
        #expect(h.manager.visibility == .collapsed)
        // "Displays have separate Spaces" off: "Main" means the main (first) display.
        h.box.full = ["Main"]
        h.post(NSWorkspace.activeSpaceDidChangeNotification)
        #expect(h.builtinSurface?.model.hidden == true)
        #expect(h.manager.surface("ACER")?.model.hidden == false)
        h.box.full = []
        h.post(NSWorkspace.activeSpaceDidChangeNotification)
        #expect(h.builtinSurface?.model.hidden == false)
    }

    @Test func noDuplicateVisibilityWhileNothingChanges() {
        let h = SurfaceHarness([builtin])
        for _ in 0..<3 { h.post(NSWorkspace.activeSpaceDidChangeNotification) }
        h.post(NSWorkspace.screensDidWakeNotification)   // spurious wake while awake
        #expect(h.module.seen == [.collapsed])
    }
}

@MainActor
@Suite("Surface hardening: lifecycle")
struct SurfaceLifecycleTests {
    @Test func stopRemovesEveryObserverAndRestartIsClean() {
        let h = SurfaceHarness([builtin])
        let n = h.manager.systemObserverCount
        #expect(n == 10)
        h.manager.stop()
        #expect(h.manager.systemObserverCount == 0)
        #expect(h.ids.isEmpty)
        #expect(!h.manager.escapeRegistered && !h.manager.clickMonitorInstalled)
        // Posting after stop reaches nobody.
        h.post(NSWorkspace.willSleepNotification)
        #expect(!h.manager.isPaused)
        h.manager.start()
        #expect(h.manager.systemObserverCount == n)
        #expect(h.ids == ["BUILTIN"])
        h.manager.stop()
    }

    @Test func managerAndSurfacesDeallocateAfterStop() {
        weak var weakManager: SurfaceManager?
        weak var weakSurface: SurfaceController?
        weak var weakModel: SurfaceModel?
        autoreleasepool {
            let h = SurfaceHarness([builtin])
            let s = h.builtinSurface!
            h.manager.open(s)
            h.manager.closeAll()
            weakManager = h.manager
            weakSurface = s
            weakModel = s.model
            h.manager.stop()
        }
        #expect(weakManager == nil)
        #expect(weakSurface == nil)
        #expect(weakModel == nil)
    }
}

@MainActor
@Suite("Surface hardening: Esc hot key")
struct EscapeHotKeyTests {
    private func send(signature: OSType, id: UInt32) -> OSStatus {
        var event: EventRef?
        CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), GetCurrentEventTime(), EventAttributes(kEventAttributeNone), &event)
        guard let event else { return -1 }
        defer { ReleaseEvent(event) }
        var hk = EventHotKeyID(signature: signature, id: id)
        SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                          MemoryLayout<EventHotKeyID>.size, &hk)
        return SendEventToEventTarget(event, GetEventDispatcherTarget())
    }

    @Test func claimsOnlyItsOwnHotKey() {
        let esc = EscapeHotKey()
        var presses = 0
        esc.onPress = { presses += 1 }
        esc.installHandlerOnce()                  // handler only: nothing registered with the system
        defer { esc.tearDown() }
        #expect(esc.hasHandler)
        // Someone else's hot key ('TEST') passes through untouched…
        #expect(send(signature: OSType(0x5445_5354), id: 3) != noErr)
        #expect(presses == 0)
        // …the panel's Esc is handled.
        #expect(send(signature: EscapeHotKey.signature, id: EscapeHotKey.hotKeyID) == noErr)
        #expect(presses == 1)
        esc.tearDown()
        #expect(!esc.hasHandler)
        #expect(send(signature: EscapeHotKey.signature, id: EscapeHotKey.hotKeyID) != noErr)
        #expect(presses == 1)
    }
}

@MainActor
@Suite("Surface: clicks on the expanded panel")
struct SurfaceClickTests {
    /// Regression: the hosting view is flipped, and the panel rect was computed bottom-up, so
    /// clicks on the tab strip (the top band) counted as "outside" and never reached the icons.
    @Test func tabStripClicksReachThePanelAndShadowClicksClose() throws {
        let h = SurfaceHarness([builtin])
        let s = try #require(h.builtinSurface)
        s.expand(tab: nil)
        #expect(s.model.expanded)
        let b = s.hostBoundsForTest
        let size = s.model.layout.size
        // A tab icon, left of the notch, inside the top band.
        #expect(!s.clickForTest(NSPoint(x: b.midX - size.width / 2 + 40, y: 12)))
        #expect(s.model.expanded)
        // The gear, right of the notch.
        #expect(!s.clickForTest(NSPoint(x: b.midX + size.width / 2 - 40, y: 12)))
        #expect(s.model.expanded)
        // The shadow margin below the panel closes it.
        #expect(s.clickForTest(NSPoint(x: b.midX, y: b.height - 4)))
        #expect(!s.model.expanded)
    }
}
