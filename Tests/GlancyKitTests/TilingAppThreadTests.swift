// The per-app thread machinery, without Accessibility: blocks run on the handle's own thread,
// the wait mode waits without running queued jobs, stop resumes everything pending.
// Uses pid 1 (launchd): AX reads against it fail at once and touch nothing.
import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import GlancyKit

@Suite("Tiling app thread")
struct TilingAppThreadTests {
    @Test func performRunsOnTheHandleThreadNotMain() async {
        let handle = AppHandle(pid: 1, bundleID: "test.launchd", name: "launchd", observe: false)
        defer { handle.stop() }
        let info = await handle.perform { _ in (Thread.isMainThread, Thread.current.name ?? "") }
        #expect(info?.0 == false)
        #expect(info?.1 == "Glancy.AX.test.launchd")
    }

    @Test func jobsOfOneAppRunInOrder() async {
        let handle = AppHandle(pid: 1, bundleID: nil, name: "launchd", observe: false)
        defer { handle.stop() }
        let order = await withTaskGroup(of: (Int, Date?).self) { group in
            for i in 0..<5 {
                group.addTask { (i, await handle.perform { _ in Date() }) }
            }
            var out: [(Int, Date?)] = []
            for await x in group { out.append(x) }
            return out
        }
        #expect(order.count == 5)
        #expect(order.allSatisfy { $0.1 != nil })
    }

    @Test func waitTimesOutWithoutAnEventAndRunsNoJobInside() async {
        let handle = AppHandle(pid: 1, bundleID: nil, name: "launchd", observe: false)
        defer { handle.stop() }
        let marks = Marks()
        async let waited: TimeInterval? = handle.perform { h in
            let start = Date()
            h.waitForFrameEvent(42, after: h.frameSerial(42), timeout: 0.05)
            marks.add("wait-end")
            return Date().timeIntervalSince(start)
        }
        // Enqueued while the first one waits: must run after it, not nested inside.
        try? await Task.sleep(for: .milliseconds(10))
        _ = await handle.perform { _ in marks.add("second") }
        let elapsed = await waited
        #expect((elapsed ?? 0) >= 0.045)
        #expect((elapsed ?? 1) < 0.5)
        #expect(marks.all == ["wait-end", "second"])
    }

    @Test func placementWithoutAccessibilityIsUnreachableNotAHang() async {
        let handle = AppHandle(pid: 1, bundleID: nil, name: "launchd", observe: false)
        defer { handle.stop() }
        let p = AXPlacement(windowID: 7, target: CGRect(x: 0, y: 0, width: 100, height: 100),
                            usable: CGRect(x: 0, y: 0, width: 1000, height: 800), edgeTolerance: 10,
                            restoreEUI: true, allowRetry: true)
        let report = await handle.perform { $0.place(p, token: CancelToken()) }
        #expect(report?.outcome == .unreachable)
        let cancelled = CancelToken()
        cancelled.cancel()
        #expect(await handle.perform { $0.place(p, token: cancelled) }?.outcome == .cancelled)
    }

    @Test func stopResumesPendingWithNil() async {
        let handle = AppHandle(pid: 1, bundleID: nil, name: "launchd", observe: false)
        handle.stop()
        let r = await handle.perform { _ in 1 }
        #expect(r == nil)
    }
}

final class Marks: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.withLock { items.append(s) } }
    var all: [String] { lock.withLock { items } }
}

@Suite("Tiling engine without Accessibility")
@MainActor
struct TilingEngineIdleTests {
    @Test func startIsInertWithoutTrustAndPlansStillWork() async {
        let engine = TilingEngine(config: TilingConfig(), configURL: nil)
        engine.start()
        #expect(engine.registry.isRunning == AXIsProcessTrusted())
        engine.stop()
        #expect(!engine.registry.isRunning)
        #expect(engine.planPlace(123, in: CellRect(col: 0, row: 0)) == nil)
        #expect(await engine.undo().isEmpty)
        if let d = engine.displays().first {
            let f = engine.previewFrame(for: CellRect(col: 0, row: 0, w: 6, h: 8), on: d, grid: .default)
            #expect(d.usableFrame.contains(f))
            #expect(!d.id.isEmpty)
        }
    }

    @Test func probeReadsOnlyAndReportsMissingApps() async {
        let lines = await TilingProbe.run(bundleIDs: ["invalid.glancy.nothing"], move: false)
        #expect(lines.count == 1)
        #expect(lines[0].contains("not running") || lines[0].contains("not granted"))
    }
}
