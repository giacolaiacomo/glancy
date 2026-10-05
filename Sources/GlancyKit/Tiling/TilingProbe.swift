// Tiling — the probe SPEC §3 asks for before trusting the engine on real apps: per app it logs
// AXEnhancedUserInterface, the front window's AXMinSize/AXMinimumSize and settable flags, and,
// only when called with `move: true`, places that window on two frames with and without the
// EUI toggle and logs the read-backs over time. Meant to be run by hand from the app; an
// automated run must never pass `move: true` on someone's real windows.

import AppKit
import os

public enum TilingProbe {
    public static let defaultBundleIDs = ["com.apple.mail", "com.google.Chrome", "com.apple.Terminal"]
    static let logger = Logger(subsystem: "ai.glancy.app", category: "tiling-probe")
    /// Read-back times after each write, in seconds.
    static let readTimes: [TimeInterval] = [0, 0.05, 0.15, 0.3, 0.6]

    /// Runs the probe and returns the log lines (also sent to the unified log, category
    /// "tiling-probe").
    /// - Parameters:
    ///   - move: place the front window of each app. Off by default; the window is put back.
    ///   - targets: two Cocoa frames to place on; default: left half and bottom-right quarter
    ///     of the window's display.
    @MainActor
    public static func run(bundleIDs: [String] = defaultBundleIDs, move: Bool = false,
                           targets: [CGRect]? = nil) async -> [String] {
        var lines: [String] = []
        func log(_ s: String) { lines.append(s); logger.notice("\(s, privacy: .public)") }
        guard Lab.accessibilityTrusted() else {
            log("Accessibility not granted: nothing probed")
            return lines
        }
        let h = ScreenSpace.primaryHeight
        let displays = ScreenSpace.displays()
        for bundleID in bundleIDs {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
                log("[\(bundleID)] not running")
                continue
            }
            let handle = AppHandle(pid: app.processIdentifier, bundleID: bundleID, name: app.localizedName ?? bundleID,
                                   observe: move)
            defer { handle.stop() }
            guard let info = await handle.perform({ $0.probeRead() }) else { log("[\(bundleID)] no answer"); continue }
            for l in info.lines { log("[\(bundleID)] \(l)") }
            guard move, let ax = info.axFrame else { continue }
            let cocoa = ScreenSpace.flip(ax, primaryHeight: h)
            let usable = ScreenSpace.display(for: cocoa, in: displays)?.usableFrame ?? cocoa
            let frames = targets ?? [
                CGRect(x: usable.minX, y: usable.minY, width: (usable.width / 2).rounded(), height: usable.height),
                CGRect(x: usable.midX.rounded(), y: usable.minY, width: (usable.width / 2).rounded(), height: (usable.height / 2).rounded()),
            ]
            let axTargets = frames.map { ScreenSpace.flip($0, primaryHeight: h) }
            let out = await handle.perform { $0.probeMove(targets: axTargets, original: ax) } ?? ["no answer"]
            for l in out { log("[\(bundleID)] \(l)") }
        }
        return lines
    }
}

extension AppHandle {
    struct ProbeInfo: Sendable {
        let lines: [String]
        let axFrame: CGRect?
    }

    private static func fmt(_ r: CGRect?) -> String {
        guard let r else { return "nil" }
        return "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height)))"
    }

    func probeRead() -> ProbeInfo {
        guard let app = appElement else { return ProbeInfo(lines: ["no app element"], axFrame: nil) }
        var lines: [String] = []
        let eui = app.bool(AXAttr.enhancedUserInterface)
        lines.append("AXEnhancedUserInterface=\(eui.map(String.init) ?? "absent") settable=\(app.isSettable(AXAttr.enhancedUserInterface))")
        guard let w = frontWindow() else {
            lines.append("no window")
            return ProbeInfo(lines: lines, axFrame: nil)
        }
        let frame = w.axFrame
        lines.append("window id=\(w.windowID.map(String.init) ?? "nil") role=\(w.string(AXAttr.role) ?? "-") subrole=\(w.string(AXAttr.subrole) ?? "-") frame(AX)=\(Self.fmt(frame))")
        lines.append("AXMinSize=\(w.size(AXAttr.minSize).map { "\(Int($0.width))×\(Int($0.height))" } ?? "absent") AXMinimumSize=\(w.size(AXAttr.minimumSize).map { "\(Int($0.width))×\(Int($0.height))" } ?? "absent")")
        lines.append("settable position=\(w.isSettable(AXAttr.position)) size=\(w.isSettable(AXAttr.size)) minimized=\(w.bool(AXAttr.minimized) ?? false) fullscreen=\(w.bool(AXAttr.fullscreen) ?? false)")
        return ProbeInfo(lines: lines, axFrame: frame)
    }

    /// Runs the run loop (observer events included, job queue excluded) for `seconds`.
    private func pause(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while deadline.timeIntervalSinceNow > 0 {
            let r = CFRunLoopRunInMode(Self.waitMode, deadline.timeIntervalSinceNow, false)
            if r == .finished || r == .stopped { break }
        }
    }

    func probeMove(targets: [CGRect], original: CGRect) -> [String] {
        guard let app = appElement, let front = frontWindow() else { return ["no window"] }
        let id = front.windowID ?? 0
        // Through the cache so the window's kAXMoved/kAXResized observers are registered.
        let w = front.windowID.flatMap { element(for: $0) } ?? front
        var lines: [String] = []
        let euiOriginal = app.bool(AXAttr.enhancedUserInterface) == true
        if !euiOriginal { lines.append("EUI is off for this app: both passes behave the same") }
        let canResize = w.isSettable(AXAttr.size)
        for toggle in [true, false] {
            for (i, t) in targets.enumerated() {
                if toggle, euiOriginal { app.setBool(AXAttr.enhancedUserInterface, false) }
                let serial = frameSerial(id)
                let start = Date()
                if canResize { w.setSize(t.size) }
                w.setPosition(t.origin)
                if canResize { w.setSize(t.size) }
                let writeMs = Int(Date().timeIntervalSince(start) * 1000)
                var reads: [String] = []
                var elapsed: TimeInterval = 0
                for at in TilingProbe.readTimes {
                    if at > elapsed { pause(at - elapsed); elapsed = at }
                    let r = w.axFrame
                    let ok = r.map { PlacementMath.approx($0, t) } ?? false
                    reads.append("+\(Int(at * 1000))ms \(Self.fmt(r))\(ok ? " ✓" : "")")
                }
                if toggle, euiOriginal { app.setBool(AXAttr.enhancedUserInterface, true) }
                lines.append("EUI toggle=\(toggle ? "off-around-write" : "left-as-is") target#\(i + 1) \(Self.fmt(t)) write=\(writeMs)ms events=\(frameSerial(id) - serial)")
                lines.append("  " + reads.joined(separator: " | "))
            }
        }
        // Put the window back where it was.
        if euiOriginal { app.setBool(AXAttr.enhancedUserInterface, false) }
        if canResize { w.setSize(original.size) }
        w.setPosition(original.origin)
        if canResize { w.setSize(original.size) }
        pause(0.1)
        if euiOriginal { app.setBool(AXAttr.enhancedUserInterface, true) }
        lines.append("restored → \(Self.fmt(w.axFrame)) (was \(Self.fmt(original)))")
        return lines
    }
}
