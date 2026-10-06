import AppKit
import Foundation
import Testing
@testable import GlancyKit

private let offscreenScreen = ScreenInfo(
    uuid: "BUILTIN", frame: CGRect(x: -20_000, y: 0, width: 1512, height: 982),
    visibleFrame: CGRect(x: -20_000, y: 57, width: 1512, height: 892), safeTop: 32,
    auxLeft: CGRect(x: -20_000, y: 950, width: 665, height: 32), auxRight: CGRect(x: -19_150, y: 950, width: 662, height: 32),
    isBuiltin: true, scale: 2)

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

    /// One relief, a few seconds after the panel closed; reopening first cancels it.
    @Test func memoryIsHandedBackOnceAfterTheCollapse() async throws {
        let h = SurfaceHarness([offscreenScreen])
        defer { h.manager.stop() }
        h.manager.reliefDelay = .milliseconds(150)
        final class Owner {}
        let owner = Owner()
        var purged = 0
        MemoryRelief.register(owner) { purged += 1 }
        defer { MemoryRelief.unregister(owner) }
        #expect(!h.manager.pendingRelief)

        h.manager.open(tab: nil)
        h.manager.closeAll()
        #expect(h.manager.pendingRelief)
        h.manager.open(tab: nil)                 // reopened before it ran: cancelled
        #expect(!h.manager.pendingRelief)
        try await Delay.sleep(for: .milliseconds(400))
        #expect(purged == 0)

        let runs = MemoryRelief.runs
        h.manager.closeAll()
        try await Delay.sleep(for: .milliseconds(500))
        #expect(MemoryRelief.runs == runs + 1)
        #expect(purged == 1)
        #expect(!h.manager.pendingRelief)
    }

    /// Delay.sleep waits as long as asked, and a cancelled one ends at once (its timer goes with it).
    @Test func delayWaitsAndLetsGoWhenCancelled() async throws {
        let clock = ContinuousClock()
        var t0 = clock.now
        try await Delay.sleep(for: .milliseconds(120))
        let slept = clock.now - t0
        #expect(slept >= .milliseconds(115) && slept < .milliseconds(600))

        t0 = clock.now
        let task = Task { () -> Bool in
            do { try await Delay.sleep(for: .seconds(3600)); return false } catch { return error is CancellationError }
        }
        try await Delay.sleep(for: .milliseconds(50))
        task.cancel()
        #expect(await task.value)
        #expect(clock.now - t0 < .seconds(2))

        let early = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do { try await Delay.sleep(for: .seconds(3600)); return false } catch { return true }
        }
        #expect(await early.value)
    }

    /// The command bar's app list goes with the relief once the bar is closed, and comes back on
    /// the next open; a stopped bar leaves no hook behind.
    @Test func theBarDropsItsAppListAfterClosing() {
        let suite = "glancy.test.bar.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let apps = AppIndex(folders: [], extras: [])
        let bar = CommandModule(settings: CommandSettings(defaults: UserDefaults(suiteName: suite)!), history: PaletteHistory(url: nil),
                                apps: apps, rates: CurrencyRates(cacheURL: nil), sample: true)
        let hooks = MemoryRelief.hookCount
        bar.start(hub: ActivityHub())
        #expect(MemoryRelief.hookCount == hooks + 1)
        apps.setApps([AppEntry(path: "/Applications/Safari.app", name: "Safari", displayName: "Safari")])
        bar.visibilityChanged(.expanded(.command))
        MemoryRelief.run()
        #expect(apps.apps.count == 1)            // open: kept
        bar.visibilityChanged(.collapsed)
        MemoryRelief.run()
        #expect(apps.apps.isEmpty && apps.stale)  // closed: dropped, re-indexed on the next open
        bar.stop()
        #expect(MemoryRelief.hookCount == hooks)
    }

    /// An English Glancy never builds the Italian tables.
    @Test func italianTablesAreBuiltOnlyWhenNeeded() {
        var reads = 0
        var strings = LazyStrings { reads += 1; return ["Home": "Home"] }
        strings.add { reads += 1; return ["Memory test": "Prova memoria"] }
        #expect(reads == 0 && !strings.isBuilt)
        #expect(strings.table()["Memory test"] == "Prova memoria")
        #expect(reads == 2)
        strings.add { reads += 1; return ["Later": "Dopo"] }   // once built, a part merges at once
        #expect(reads == 3 && strings.table()["Later"] == "Dopo" && strings.table()["Home"] == "Home")
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
        try await Delay.sleep(for: .milliseconds(1200))
        let open = surface.layoutPasses
        try await Delay.sleep(for: .milliseconds(600))
        // Sanity: the harness really draws (the working dots pulse while open).
        #expect(surface.layoutPasses > open)
        manager.closeAll()
        try await Delay.sleep(for: .milliseconds(1500))   // the close spring settles
        let settled = surface.layoutPasses
        try await Delay.sleep(for: .seconds(2))
        #expect(surface.layoutPasses == settled, "the collapsed surface kept laying out")
    }
}
