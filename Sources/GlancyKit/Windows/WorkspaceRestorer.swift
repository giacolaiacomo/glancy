// Windows — restoring a workspace: match the live windows (bundle ID + title), launch the apps that
// are not running, wait for their windows, then place everything as ONE operation (one ⌃⌥Z puts
// it all back). Minimised, hidden and other-Space windows are left alone.
//
// Waiting is event-driven: the backend's window-change callback (the registry reconciles on
// NSWorkspace launch notifications and the new app's AX window-created notifications) re-checks;
// a single sleeping task is the timeout. Nothing polls.

import AppKit

/// Starts apps. The real one goes through NSWorkspace; tests use a fake.
@MainActor
protocol AppLauncher: AnyObject {
    func isRunning(_ bundleID: String) -> Bool
    /// Opens the app without bringing it to the front. False when it is not installed or failed.
    func launch(_ bundleID: String) async -> Bool
}

@MainActor
final class WorkspaceAppLauncher: AppLauncher {
    func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    func launch(_ bundleID: String) async -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            NSWorkspace.shared.openApplication(at: url, configuration: config) { @Sendable app, error in
                cont.resume(returning: app != nil && error == nil)
            }
        }
    }
}

/// What a restore did, for the peek and the tab's status line.
struct RestoreOutcome: Equatable {
    var name: String
    /// Windows now where the workspace wants them (already there counts).
    var placed = 0
    /// Apps started for it.
    var launched = 0
    /// Workspace windows with no live window (app missing, or no window came up in time).
    var notFound = 0
    /// Workspace windows whose app has only minimised, hidden or other-Space windows.
    var leftAlone = 0
    /// Windows that refused or could not be reached.
    var failed = 0
    var needsAccess = false
    var results: [PlacementResult] = []

    @MainActor var line: String {
        if needsAccess { return WindowsText.t("Windows needs Accessibility") }
        var parts = [WindowsText.f("Placed %d", placed)]
        if launched > 0 { parts.append(WindowsText.f("launched %d", launched)) }
        if notFound > 0 { parts.append(WindowsText.f("%d not found", notFound)) }
        if leftAlone > 0 { parts.append(WindowsText.f("%d left alone", leftAlone)) }
        if failed > 0 { parts.append(WindowsText.f("%d refused", failed)) }
        return parts.joined(separator: ", ")
    }

    var clean: Bool { !needsAccess && notFound == 0 && failed == 0 }
}

@MainActor
final class WorkspaceRestorer {
    private let launcher: AppLauncher
    /// How long launched apps get to show a window.
    var launchTimeout: Duration = .seconds(10)
    /// After the windows appear: apps restore their own frames first (as auto-fit waits).
    var settle: Duration = .milliseconds(400)
    private(set) var busy = false

    init(launcher: AppLauncher) { self.launcher = launcher }

    /// `launchMissing`: start apps that are not running (off for the automatic display-connect apply).
    /// `raise`: the restored windows go above every other window in the stacking order they were
    /// saved in, the frontmost one's app activated (off for the automatic display-connect apply,
    /// which must not take focus by itself). `onLaunching`: told the app names being started.
    func restore(_ w: Workspace, on backend: WindowsBackend, launchMissing: Bool = true, raise: Bool = true,
                 onLaunching: (([String]) -> Void)? = nil) async -> RestoreOutcome {
        var out = RestoreOutcome(name: w.name)
        guard backend.isTrusted, backend.isRunning else { out.needsAccess = true; return out }
        guard !busy else { return out }
        busy = true
        defer { busy = false }
        await backend.refresh()

        var plan = Self.plan(w, backend)
        // Apps with no window at all (not even minimised or hidden) and not running: start them.
        let present = Set(backend.allWindows().compactMap(\.bundleID))
        var need: [String: Int] = [:]
        for i in plan.unmatched {
            let b = w.windows[i].bundleID
            if !present.contains(b), launchMissing, !launcher.isRunning(b) { need[b, default: 0] += 1 }
        }
        var launched: [String] = []
        if !need.isEmpty {
            let names = w.bundleIDs.filter { need[$0] != nil }
                .map { b in w.windows.first { $0.bundleID == b }?.appName ?? b }
            onLaunching?(names)
            for b in w.bundleIDs where need[b] != nil {
                if await launcher.launch(b) { launched.append(b) }
            }
            if !launched.isEmpty {
                let wanted = need.filter { launched.contains($0.key) }
                if await waitForWindows(wanted, backend: backend) { try? await Delay.sleep(for: settle) }
                await backend.refresh()
                plan = Self.plan(w, backend)
            }
        }
        out.launched = launched.count
        let results = await backend.commit(plan.plans, label: w.name)
        out.results = results
        let bad = Set(results.filter { $0.outcome != .exact && $0.outcome != .appSized }.map(\.windowID))
        out.failed = bad.count
        if raise {
            let ids = Self.raiseOrder(w, plan: plan, results: results)
            if !ids.isEmpty { await backend.raise(ids) }
        }
        out.placed = plan.matched.values.filter { !bad.contains($0) }.count
        let still = Set(backend.allWindows().compactMap(\.bundleID))
        for i in plan.unmatched {
            if still.contains(w.windows[i].bundleID) { out.leftAlone += 1 } else { out.notFound += 1 }
        }
        return out
    }

    /// The restored windows, front first in the order the workspace saved them; windows whose
    /// placement failed keep their place in the stack.
    static func raiseOrder(_ w: Workspace, plan: WorkspacePlan, results: [PlacementResult]) -> [CGWindowID] {
        let placed = Set(results.filter { $0.outcome == .exact || $0.outcome == .appSized }.map(\.windowID))
        return plan.matched.sorted { a, b in
            let oa = w.windows.indices.contains(a.key) ? w.windows[a.key].order : Int.max
            let ob = w.windows.indices.contains(b.key) ? w.windows[b.key].order : Int.max
            return oa != ob ? oa < ob : a.key < b.key
        }.map(\.value).filter { placed.contains($0) }
    }

    static func plan(_ w: Workspace, _ backend: WindowsBackend) -> WorkspacePlan {
        WorkspacePlanner.plan(w, windows: backend.allWindows(), displays: backend.displays(), grid: backend.grid(for:))
    }

    /// True once every app in `wanted` has that many tileable windows; false at the timeout.
    func waitForWindows(_ wanted: [String: Int], backend: WindowsBackend) async -> Bool {
        func satisfied() -> Bool {
            let counts = backend.allWindows().filter(\.isTileable).reduce(into: [String: Int]()) { c, w in
                if let b = w.bundleID { c[b, default: 0] += 1 }
            }
            return wanted.allSatisfy { counts[$0.key, default: 0] >= $0.value }
        }
        if satisfied() { return true }
        let gate = Gate()
        let timeout = launchTimeout
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            // The body runs synchronously on the caller's actor (main).
            MainActor.assumeIsolated {
                gate.continuation = cont
                gate.timeout = Task { @MainActor in
                    try? await Delay.sleep(for: timeout)
                    gate.finish(false)
                }
                @MainActor func arm() {
                    backend.onWindowsChange {
                        guard !gate.done else { return }
                        if satisfied() { gate.finish(true) } else { arm() }
                    }
                }
                arm()
            }
        }
    }

    /// Resumes the wait once, whichever comes first: the windows or the timeout.
    @MainActor private final class Gate {
        var continuation: CheckedContinuation<Bool, Never>?
        var timeout: Task<Void, Never>?
        var done = false
        func finish(_ ok: Bool) {
            guard !done else { return }
            done = true
            timeout?.cancel()
            continuation?.resume(returning: ok)
            continuation = nil
        }
    }
}
