import AppKit
import Foundation
import SwiftUI
import Testing
@testable import GlancyKit

/// One collapsed state on two displays far off-screen: a notched built-in and an external one
/// with the pill, as on the owner's desk. The surfaces render for real (presents: true).
@MainActor
final class CostRig {
    let state: CollapsedStates.Case
    let rig: CollapsedStates.Rig
    let manager: SurfaceManager
    let root: URL
    let suite: String
    let started: [any GlancyModule]
    let notchID: String, pillID: String

    init(_ state: CollapsedStates.Case, slot: Int) {
        self.state = state
        root = FileManager.default.temporaryDirectory.appendingPathComponent("glancy-cost-\(UUID().uuidString)")
        let set = DemoData.make(root: root)
        suite = "glancy.test.cost.\(UUID().uuidString)"
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.permissions.probe = .fixed([:])
        settings.externalPill = true
        for id in AppSettings.defaultDisabled { settings.setEnabled(id, true) }
        let modules = state.modules.map { ids in set.modules.filter { ids.contains($0.id) } } ?? set.modules
        let hub = ActivityHub()
        let context = SurfaceContext(hub: hub, settings: settings, launchAtLogin: LaunchAtLogin(), modules: modules)
        rig = CollapsedStates.Rig(set: set, hub: hub, context: context)
        state.prepare?(rig)
        started = context.enabledModules
        for m in started { m.start(hub: hub) }
        // Each rig on its own pair of displays, far from every real one and from each other.
        let x = CGFloat(-40_000 - slot * 6_000)
        let notch = ScreenInfo(
            uuid: "COST-NOTCH-\(slot)", frame: CGRect(x: x, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: x, y: 57, width: 1512, height: 892), safeTop: 32,
            auxLeft: CGRect(x: x, y: 950, width: 665, height: 32), auxRight: CGRect(x: x + 850, y: 950, width: 662, height: 32),
            isBuiltin: true, scale: 2)
        let pill = ScreenInfo(
            uuid: "COST-PILL-\(slot)", frame: CGRect(x: x + 2_000, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: x + 2_000, y: 0, width: 2560, height: 1415), safeTop: 0,
            auxLeft: nil, auxRight: nil, isBuiltin: false, scale: 2)
        notchID = notch.uuid; pillID = pill.uuid
        manager = SurfaceManager(context: context, screens: { [notch, pill] }, fullscreenSpaces: { [] },
                                 events: SystemEvents(workspace: NotificationCenter(), distributed: NotificationCenter(),
                                                      app: NotificationCenter(), observesDock: false),
                                 presents: true, systemInput: false)
        manager.start()
        state.apply?(rig)
    }

    var notch: SurfaceController { manager.surface(notchID)! }
    var pill: SurfaceController { manager.surface(pillID)! }
    var passes: (Int, Int) { (notch.layoutPasses, pill.layoutPasses) }

    func tearDown() {
        manager.stop()
        for m in started { m.stop() }
        rig.set.removeDefaults()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

// Lot CPU: a closed notch costs nothing. Every live state of every module, alone and all together,
// on a notched display and a pill, before and after the panel was opened and closed on each: at most
// one layout pass a second for a countdown that shows seconds, none for anything else. A continuous
// animation in a closed surface lays out on every frame and fails by thousands.
/// Dozens of off-screen surfaces measuring their own layout: run on their own (CI's
/// "Collapsed cost" step), because they slow the main actor for every timing test running beside them.
let collapsedCostTestsEnabled = ProcessInfo.processInfo.environment["GLANCY_COST_TESTS"] == "1"

@MainActor
@Suite("Collapsed cost", .serialized, .enabled(if: collapsedCostTestsEnabled))
struct CollapsedCostTests {
    @Test func everyCollapsedStateIsQuiet() async throws {
        guard !NSScreen.screens.isEmpty else { return }   // no window server
        let only = ProcessInfo.processInfo.environment["COST_ONLY"]
        let cases = CollapsedStates.all.filter { only == nil || $0.name.hasPrefix(only!) }
        let rigs = cases.enumerated().map { CostRig($1, slot: $0) }
        defer { rigs.forEach { $0.tearDown() } }
        func wait(_ s: Double) async throws { try await Delay.sleep(for: .milliseconds(Int(s * 1000))) }
        var failures: [String] = []
        /// Polls every rig's two surfaces every 50 ms over `window`: passes in total and the slots
        /// in which any happened.
        func measure(_ label: String, window: Double) async throws {
            let slots = Int(window / 0.05)
            var last = rigs.map(\.passes)
            var busy = Array(repeating: (0, 0), count: rigs.count)
            let first = last
            for _ in 0..<slots {
                try await wait(0.05)
                for (i, rig) in rigs.enumerated() {
                    let (n, p) = rig.passes
                    if n != last[i].0 { busy[i].0 += 1 }
                    if p != last[i].1 { busy[i].1 += 1 }
                    last[i] = (n, p)
                }
            }
            for (i, rig) in rigs.enumerated() {
                let dn = last[i].0 - first[i].0, dp = last[i].1 - first[i].1
                let share = Double(max(busy[i].0, busy[i].1)) / Double(slots)
                print(String(format: "cost: %-26@ %-17@ notch %6d passes (%2d/%d slots)  pill %6d passes (%2d/%d slots)",
                             rig.state.name as NSString, label as NSString, dn, busy[i].0, slots, dp, busy[i].1, slots))
                let ok = rig.state.busyShare == 0 ? dn == 0 && dp == 0 : share <= rig.state.busyShare
                if !ok {
                    failures.append("\(rig.state.name) \(label): notch \(dn) passes in \(busy[i].0)/\(slots) slots, pill \(dp) in \(busy[i].1)/\(slots)"
                                    + " (allowed: \(rig.state.busyShare == 0 ? "none" : "\(Int(rig.state.busyShare * 100))% of slots"))")
                }
            }
        }

        /// Waits (up to 10 s) for one quiet 0.5 s across every rig, so a single late settle on a slow
        /// machine (CI: one pass in every state at once) isn't counted; a burn never goes quiet.
        func quiesce() async throws {
            var last = rigs.map(\.passes), quiet = 0.0, waited = 0.0
            while quiet < 0.5, waited < 10 {
                try await wait(0.05); waited += 0.05
                let now = rigs.map(\.passes)
                quiet = zip(now, last).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 } ? quiet + 0.05 : 0
                last = now
            }
        }

        // Steady, never opened. The margin covers a main actor slowed by the parallel suite: a peek
        // timer that fires late retracts late.
        try await wait((cases.map(\.settle).max() ?? 1) + 1.5)
        try await quiesce()
        try await measure("closed", window: 2)

        // Opened and closed on the built-in notch, then on the external pill.
        for rig in rigs { rig.notch.expand(tab: nil) }
        try await wait(1)
        for rig in rigs { rig.manager.closeAll() }
        try await wait(0.8)
        for rig in rigs { rig.pill.expand(tab: rig.state.modules?.first) }
        try await wait(1)
        for rig in rigs { rig.manager.closeAll() }
        try await wait(1.5)   // the close springs settle
        try await quiesce()
        try await measure("after open/close", window: 2)

        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    /// The menu bar is read on events only (app switch, launch, quit, display change, an activity
    /// appearing), never in a loop: a read moves the wings, and moving them must not ask for another.
    @Test func theMenuBarIsReadOnEventsOnly() async throws {
        guard !NSScreen.screens.isEmpty else { return }
        final class Count: @unchecked Sendable { var n = 0 }
        let count = Count()
        let x: CGFloat = -90_000
        let menus = [CGRect(x: x + 62, y: 949, width: 560, height: 33)]    // titles up to 8 pt before the notch
        let status = [CGRect(x: x + 942, y: 949, width: 44, height: 33)]
        let watcher = MenuBarWatcher(reader: .init(menus: { _ in count.n += 1; return menus }, status: { status },
                                                   trusted: { true }, owner: { 42 }), observes: false)
        let state = try #require(CollapsedStates.named("agents.claude.working"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("glancy-menubar-\(UUID().uuidString)")
        let set = DemoData.make(root: root)
        let suite = "glancy.test.menubar.\(UUID().uuidString)"
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.permissions.probe = .fixed([:])
        let hub = ActivityHub()
        let modules = set.modules.filter { $0.id == .agents }
        let context = SurfaceContext(hub: hub, settings: settings, launchAtLogin: LaunchAtLogin(), modules: modules)
        for m in modules { m.start(hub: hub) }
        let screen = ScreenInfo(
            uuid: "MENUBAR", frame: CGRect(x: x, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: x, y: 57, width: 1512, height: 892), safeTop: 32,
            auxLeft: CGRect(x: x, y: 950, width: 665, height: 32), auxRight: CGRect(x: x + 850, y: 950, width: 662, height: 32),
            isBuiltin: true, scale: 2)
        let manager = SurfaceManager(context: context, screens: { [screen] }, fullscreenSpaces: { [] },
                                     events: SystemEvents(workspace: NotificationCenter(), distributed: NotificationCenter(),
                                                          app: NotificationCenter(), observesDock: false),
                                     menuBar: watcher, presents: true, systemInput: false)
        manager.start()
        defer {
            manager.stop(); for m in modules { m.stop() }; set.removeDefaults()
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        state.apply?(CollapsedStates.Rig(set: set, hub: hub, context: context))
        try await Delay.sleep(for: .seconds(1.5))
        let surface = try #require(manager.surface("MENUBAR"))
        #expect(surface.model.hasActivity && surface.model.clearance != nil)
        let reads = watcher.reads
        #expect(reads <= 2)                       // the start, the activity appearing
        try await Delay.sleep(for: .seconds(2))
        #expect(watcher.reads == reads && count.n == reads)
    }

    /// The panel opened (Home for an instant) and switched straight to another tab, every module
    /// running: once the breaths are over, the open Monitor tab lays out on its updates only. The
    /// Home page's working dots, removed while breathing, kept the page in the window animating
    /// for as long as the panel stayed open (~4% CPU in the lab).
    @Test func anOpenPanelOnAnotherTabIsQuiet() async throws {
        guard !NSScreen.screens.isEmpty else { return }
        let rig = CostRig(try #require(CollapsedStates.named("all")), slot: 300)
        defer { rig.tearDown() }
        try await Delay.sleep(for: .seconds(4))
        rig.manager.open(rig.notch)
        rig.notch.model.select(tab: .monitor)
        try await Delay.sleep(for: .seconds(Double(AgentStateDot.breaths) * 1.6 + 2))
        let before = rig.notch.layoutPasses
        try await Delay.sleep(for: .seconds(2))
        let passes = rig.notch.layoutPasses - before
        #expect(passes <= 6, "the open panel laid out \(passes) times in 2 s on a tab updated every 2 s")
        rig.manager.closeAll()
    }
}
