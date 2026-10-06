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
@MainActor
@Suite("Collapsed cost", .serialized)
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

        // Steady, never opened.
        try await wait(cases.map(\.settle).max() ?? 1)
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
        try await measure("after open/close", window: 2)

        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }
}
