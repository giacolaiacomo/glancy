import AppKit
import Foundation

/// `Glancy --self-test`: a quick, headless check for CI, Homebrew and release builds. No panel,
/// no window, no permission prompt, no user data: every module runs on throwaway state
/// (`IsolatedModules`) through start → visibility changes → stop, and must hold nothing live
/// afterwards. Also checks the Agents pipeline end to end on a synthetic log, the notch and pill
/// geometry, the tiling planner, and, when run from inside Glancy.app, the bundled parts.
/// Prints one line per check; exits 0 when all pass. (`--selftest`, without the hyphen, is the
/// live-panel walkthrough in Surface/SelfTest.swift.)
@MainActor
public enum SelfCheck {
    public static func run() async -> Int32 {
        var failures: [String] = []
        var passed = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            if ok { passed += 1; print("self-test: ok   \(name)") } else {
                let d = detail()
                failures.append(name)
                print("self-test: FAIL \(name)\(d.isEmpty ? "" : " — \(d)")")
            }
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("glancy-self-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // The isolated set mirrors what the app ships.
        let set = IsolatedModules.make(root: root)
        defer { set.removeDefaults() }
        let shippedIDs = Swift.Set(Modules.make().map(\.id))
        let ids = set.modules.map(\.id)
        check("modules: \(ids.count) ids, unique, same set as the app", Swift.Set(ids).count == ids.count && Swift.Set(ids) == shippedIDs,
              "isolated \(ids.map(\.rawValue).sorted()) vs shipped \(shippedIDs.map(\.rawValue).sorted())")

        // Agents: a synthetic hook log through the real reader and state machine.
        let now = Int(Date.now.timeIntervalSince1970 * 1000)
        let lines = [
            #"{"ts":\#(now - 4000),"event":"UserPromptSubmit","session_id":"self-test-1","cwd":"/tmp/web-app","prompt":"build"}"#,
            #"{"ts":\#(now - 2000),"event":"PostToolUse","session_id":"self-test-1","cwd":"/tmp/web-app","tool_name":"Edit","prompt":""}"#,
            #"{"ts":\#(now - 1000),"event":"PermissionRequest","session_id":"self-test-2","cwd":"/tmp/api","tool_name":"Bash","prompt":""}"#,
        ]
        try? (lines.joined(separator: "\n") + "\n").write(to: set.agentsLog, atomically: true, encoding: .utf8)

        let hub = ActivityHub()
        for m in set.modules {
            m.start(hub: hub)
            m.start(hub: hub)   // idempotent
            for v in [SurfaceVisibility.collapsed, .expanded(nil), .hidden, .collapsed] { m.visibilityChanged(v) }
            if let tab = m.tab {
                _ = tab.content()
                m.visibilityChanged(.expanded(tab.module))
                m.visibilityChanged(.collapsed)
            }
            _ = m.homeCard()
        }
        let agents = set.modules.compactMap { $0 as? AgentsModule }.first
        let sawSessions = await waitUntil(3) { (agents?.model.sessions.count ?? 0) >= 2 }
        check("agents: synthetic hook log → \(agents?.model.sessions.count ?? 0) sessions", sawSessions)
        check("agents: a permission request reads as waiting", agents?.model.summary.state == .waiting,
              "summary \(String(describing: agents?.model.summary.state))")

        for m in set.modules { m.stop() }
        var dirty: [String] = []
        for m in set.modules {
            _ = await waitUntil(2) { ResourceCensus.of(m).total == 0 }
            let c = ResourceCensus.of(m)
            if c.total != 0 { dirty.append("\(m.id.rawValue): \(c)") }
        }
        check("lifecycle: every module started, cycled and stopped holding nothing live", dirty.isEmpty, dirty.joined(separator: "; "))

        // Geometry: a 14" notch and the pill on a display without one.
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let builtIn = ScreenInfo(uuid: "builtin", frame: frame, visibleFrame: frame, safeTop: 32,
                                 auxLeft: CGRect(x: 0, y: 950, width: 665, height: 32),
                                 auxRight: CGRect(x: 850, y: 950, width: 662, height: 32), isBuiltin: true, scale: 2)
        let notch = NotchGeometry.notch(for: builtIn)
        check("geometry: notch found on a notched display", notch.map { $0.notchRect.width > 100 } ?? false)
        let external = ScreenInfo(uuid: "external", frame: frame, visibleFrame: frame, safeTop: 0, auxLeft: nil, auxRight: nil,
                                  isBuiltin: false, scale: 2)
        check("geometry: pill on a display without a notch", NotchGeometry.pill(for: external, menuBarHeight: 24).kind == .pill)

        // Tiling: the pure planner on the synthetic desk (nothing is moved).
        let desk = SampleWindowsBackend()
        let plan = desk.planArrange(on: SampleWindowsBackend.builtIn, strategy: .balanced, grid: nil, windowIDs: nil)
        check("tiling: Balanced plans \(plan.moves.count) moves on the synthetic desk", !plan.moves.isEmpty)

        // The app bundle, when run from one.
        let bundle = Bundle.main
        if bundle.bundleURL.pathExtension == "app" {
            check("bundle: identifier", bundle.bundleIdentifier == "ai.glancy.app", bundle.bundleIdentifier ?? "none")
            let fw = bundle.privateFrameworksURL?.appendingPathComponent("MediaRemoteAdapter.framework")
            let parts = [fw?.path, bundle.path(forResource: "mediaremote-adapter", ofType: "pl"),
                         bundle.path(forAuxiliaryExecutable: "MediaRemoteAdapterTestClient"),
                         bundle.path(forResource: "AppIcon", ofType: "icns")]
            check("bundle: media adapter, test client and icon present",
                  parts.allSatisfy { $0.map { FileManager.default.fileExists(atPath: $0) } ?? false })
        } else {
            print("self-test: skip bundle checks (not running from Glancy.app)")
        }

        print(failures.isEmpty ? "self-test: passed (\(passed) checks)" : "self-test: FAILED \(failures.count) of \(passed + failures.count)")
        return failures.isEmpty ? 0 : 1
    }

    private static func waitUntil(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
        let end = Date.now.addingTimeInterval(seconds)
        while !cond() {
            if Date.now > end { return false }
            try? await Delay.sleep(for: .milliseconds(50))
        }
        return true
    }
}
