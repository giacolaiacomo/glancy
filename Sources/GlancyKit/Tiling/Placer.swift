// Tiling — dispatches placements to the app threads. One cancellable job per window ID: a new
// request for a window cancels the one in flight. Different apps run in parallel; windows of one
// app run in sequence on its thread. The main thread only enqueues and awaits.

import AppKit

/// A placement to perform. Cocoa coordinates.
public struct PlacementRequest: Sendable, Equatable {
    public let windowID: CGWindowID
    public let target: CGRect
    /// The usable rect of the target display: anchoring and push-inside bounds.
    public let usable: CGRect
    /// Distance within which a target edge counts as touching the usable rect's edge.
    public let edgeTolerance: CGFloat
    public init(windowID: CGWindowID, target: CGRect, usable: CGRect, edgeTolerance: CGFloat = 10) {
        self.windowID = windowID; self.target = target; self.usable = usable; self.edgeTolerance = edgeTolerance
    }
}

/// How one placement ended. Cocoa coordinates.
public struct PlacementResult: Sendable, Equatable, Identifiable {
    public var id: CGWindowID { windowID }
    public let windowID: CGWindowID
    public let outcome: PlacementOutcome
    public let requested: CGRect
    public let original: CGRect?
    public let landed: CGRect?
    public let attempts: Int
    /// AXEnhancedUserInterface was on for the app and was switched off around the write.
    public let euiWasOn: Bool
    public let note: String?
    public let elapsed: TimeInterval
}

@MainActor
final class Placer {
    private let registry: WindowRegistry
    private var tokens: [CGWindowID: CancelToken] = [:]

    init(registry: WindowRegistry) { self.registry = registry }

    /// Rectangle's `automatic` policy: never switch EUI back on for Chromium-family browsers
    /// (it re-enables their expensive web accessibility) unless VoiceOver/Switch Control is on.
    static let chromiumFamily = [
        "com.google.Chrome", "org.chromium.Chromium", "com.microsoft.edgemac", "com.brave.Browser",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "com.operasoftware.OperaNext",
        "com.operasoftware.OperaDeveloper", "com.operasoftware.OperaNightly", "com.operasoftware.OperaGX",
        "com.operasoftware.OperaGXNext", "com.operasoftware.OperaGXDeveloper", "com.operasoftware.OperaGXNightly",
        "company.thebrowser.Browser", "company.thebrowser.dia", "ai.perplexity.comet", "com.openai.atlas",
    ]

    static func isChromium(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return chromiumFamily.contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
    }

    static func restoresEUI(bundleID: String?, assistiveTechnologyOn: Bool) -> Bool {
        assistiveTechnologyOn || !isChromium(bundleID)
    }

    /// Cancels whatever is in flight for these windows.
    func cancel(_ ids: [CGWindowID]) {
        for id in ids { tokens.removeValue(forKey: id)?.cancel() }
    }

    /// Runs every request, grouped per app, and returns one result per request (same order).
    func place(_ requests: [PlacementRequest], allowRetry: Bool = true) async -> [PlacementResult] {
        let h = ScreenSpace.primaryHeight
        let assistive = NSWorkspace.shared.isVoiceOverEnabled || NSWorkspace.shared.isSwitchControlEnabled
        typealias Job = (index: Int, handle: AppHandle?, placement: AXPlacement, token: CancelToken, request: PlacementRequest)
        var jobs: [Job] = []
        for (i, r) in requests.enumerated() {
            tokens.removeValue(forKey: r.windowID)?.cancel()
            let token = CancelToken()
            tokens[r.windowID] = token
            let window = registry.window(r.windowID)
            let handle = window.flatMap { registry.handle(for: $0.pid) }
            let placement = AXPlacement(
                windowID: r.windowID,
                target: ScreenSpace.flip(r.target, primaryHeight: h),
                usable: ScreenSpace.flip(r.usable, primaryHeight: h),
                edgeTolerance: r.edgeTolerance,
                restoreEUI: Self.restoresEUI(bundleID: window?.bundleID, assistiveTechnologyOn: assistive),
                allowRetry: allowRetry)
            registry.beginPlacement(r.windowID)
            jobs.append((i, handle, placement, token, r))
        }
        // One child task per window; each enqueues on its app's thread, which runs them in order.
        let reports = await withTaskGroup(of: (Int, AXPlacementReport?).self) { group in
            for job in jobs {
                let handle = job.handle, placement = job.placement, token = job.token
                group.addTask {
                    guard let handle else { return (job.index, nil) }
                    return (job.index, await handle.perform { $0.place(placement, token: token) })
                }
            }
            var out = [AXPlacementReport?](repeating: nil, count: jobs.count)
            for await (i, report) in group { out[i] = report }
            return out
        }
        var results: [PlacementResult] = []
        for job in jobs {
            let report = reports[job.index]
            let landed = report?.landed.map { ScreenSpace.flip($0, primaryHeight: h) }
            registry.endPlacement(job.request.windowID, landed: landed)
            if tokens[job.request.windowID] === job.token { tokens[job.request.windowID] = nil }
            results.append(PlacementResult(
                windowID: job.request.windowID,
                outcome: report?.outcome ?? .unreachable,
                requested: job.request.target,
                original: report?.original.map { ScreenSpace.flip($0, primaryHeight: h) },
                landed: landed,
                attempts: report?.attempts ?? 0,
                euiWasOn: report?.euiWasOn ?? false,
                note: report?.note ?? (job.handle == nil ? "app not tracked" : nil),
                elapsed: report?.elapsed ?? 0))
        }
        return results
    }
}
