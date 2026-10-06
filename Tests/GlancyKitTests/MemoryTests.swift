import AppKit
import Foundation
import Testing
@testable import GlancyKit

// Lot RAM: an idle notch costs nothing — no frame redrawn while collapsed, no work left behind by
// the panel, memory handed back after it closes.

@MainActor
@Suite("Memory and idle cost", .serialized)
struct MemoryTests {
    /// The modules hear "collapsed" before the expanded views are removed: a repeating animation
    /// still running at removal kept the removed views animating, unseen, for good.
    @Test func modulesHearTheCollapseBeforeTheViewsGo() {
        let h = SurfaceHarness([ScreenInfo(
            uuid: "BUILTIN", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 57, width: 1512, height: 892), safeTop: 32,
            auxLeft: CGRect(x: 0, y: 950, width: 665, height: 32), auxRight: CGRect(x: 850, y: 950, width: 662, height: 32),
            isBuiltin: true, scale: 2)])
        guard let surface = h.builtinSurface else { Issue.record("no surface"); return }
        var expandedWhenTold: [Bool] = []
        h.module.onVisibility = { v in if v == .collapsed { expandedWhenTold.append(surface.model.expanded) } }
        h.manager.open(tab: .agents)
        h.manager.closeAll()
        #expect(expandedWhenTold == [true])
        #expect(h.module.seen.suffix(2) == [.expanded(.agents), .collapsed])
        h.manager.stop()
    }

    /// Every module on its sample data, the panel opened on a tab with pulsing sessions, then
    /// closed: once settled, the collapsed surface lays out nothing more (it was ~4.5% CPU, the
    /// surface redrawn every frame). The window lives 20 000 pt off-screen.
    @Test func aClosedSurfaceDrawsNothing() async throws {
        guard !NSScreen.screens.isEmpty else { return }   // no window server
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("glancy-idle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let set = DemoData.make(root: root)
        defer { set.removeDefaults() }
        let suite = "glancy.test.idle.\(UUID().uuidString)"
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        settings.permissions.probe = .fixed([:])
        let hub = ActivityHub()
        let context = SurfaceContext(hub: hub, settings: settings, launchAtLogin: LaunchAtLogin(), modules: set.modules)
        for m in context.enabledModules { m.start(hub: hub) }
        defer { for m in context.enabledModules { m.stop() } }
        let screen = ScreenInfo(
            uuid: "OFFSCREEN", frame: CGRect(x: -20_000, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: -20_000, y: 57, width: 1512, height: 892), safeTop: 32,
            auxLeft: CGRect(x: -20_000, y: 950, width: 665, height: 32), auxRight: CGRect(x: -19_150, y: 950, width: 662, height: 32),
            isBuiltin: true, scale: 2)
        let manager = SurfaceManager(context: context, screens: { [screen] }, fullscreenSpaces: { [] },
                                     events: SystemEvents(workspace: NotificationCenter(), distributed: NotificationCenter(),
                                                          app: NotificationCenter(), observesDock: false),
                                     presents: true, systemInput: false)
        manager.start()
        defer { manager.stop() }
        guard let surface = manager.surfacesForTest.first else { Issue.record("no surface"); return }

        manager.open(tab: .agents)
        try await Task.sleep(for: .milliseconds(1200))
        let open = surface.layoutPasses
        try await Task.sleep(for: .milliseconds(600))
        // Sanity: the harness really draws (the working dots pulse while open).
        #expect(surface.layoutPasses > open)
        manager.closeAll()
        try await Task.sleep(for: .milliseconds(1500))   // the close spring settles
        let settled = surface.layoutPasses
        try await Task.sleep(for: .seconds(2))
        #expect(surface.layoutPasses == settled, "the collapsed surface kept laying out")
    }
}
