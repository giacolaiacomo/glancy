// Tiling — one placement, step by step, against a window that answers like an AX window. The app
// thread runs it on an AXUIElement (AppHandle.place); the tests run it on a simulated window, so
// the order of the writes, the read-backs and the re-anchoring are checked without touching
// anyone's real windows. All rects in AX coordinates (y down, origin top-left of the primary).
//
// The read-back is the only truth about size. Nothing is decided from what the app *says* before
// trying (AXMinSize, a settable flag the app did not answer): a stale or wrong minimum would
// grow the target past its cell before the app was even asked, and a timed-out "settable?"
// would leave the window at its own size. The app is asked for the cell; whatever it keeps is
// re-anchored to the cell's edges and kept on its display.

import CoreGraphics
import Foundation

/// A window the placement drives. AX coordinates.
protocol PlaceableWindow {
    /// Nil when the app does not answer.
    var frame: CGRect? { get }
    var isMinimized: Bool { get }
    var isFullscreen: Bool { get }
    /// Whether AXPosition / AXSize are settable; nil when the app did not answer the question.
    var positionSettable: Bool? { get }
    var sizeSettable: Bool? { get }
    func setSize(_ size: CGSize)
    func setPosition(_ origin: CGPoint)
    /// Gives the app a moment to finish: until its next kAXMoved / kAXResized, or `timeout`.
    func settle(timeout: TimeInterval)
}

enum PlacementRun {
    struct Result: Equatable {
        let outcome: PlacementOutcome
        let original: CGRect?
        let landed: CGRect?
        let attempts: Int
        let note: String?
    }

    static let settleTimeout: TimeInterval = 0.05

    /// RESEARCH §3.2: size → position → size, read back, wait for the app (event or 50 ms), one
    /// retry, then re-anchor what the app kept to the edges the target touches, inside the usable
    /// rect. `prepare` runs once, right before the first write (EUI off).
    static func run(_ p: AXPlacement, on window: some PlaceableWindow, isCancelled: () -> Bool,
                    prepare: () -> Void = {}) -> Result {
        var attempts = 0
        func result(_ outcome: PlacementOutcome, _ original: CGRect?, _ landed: CGRect?, _ note: String? = nil) -> Result {
            Result(outcome: outcome, original: original, landed: landed, attempts: attempts, note: note)
        }
        if isCancelled() { return result(.cancelled, nil, nil) }
        guard let original = window.frame else { return result(.unreachable, nil, nil, "no answer from the app") }
        if window.isMinimized { return result(.unreachable, original, original, "minimized") }
        if window.isFullscreen { return result(.unreachable, original, original, "fullscreen") }
        // Only a definite "no" stops us; an unanswered question is answered by trying.
        guard window.positionSettable != false else { return result(.refused, original, original, "position not settable") }
        let canResize = window.sizeSettable != false

        let edges = PlacementMath.touchedEdges(of: p.target, in: p.usable, tolerance: p.edgeTolerance)
        let target = canResize ? p.target
            : PlacementMath.anchoredFrame(size: original.size, within: p.target, edges: edges, bounds: p.usable)

        prepare()
        // Size → position → size: a size that does not fit at the old origin (another display, the
        // bottom of the screen) is clamped by the system there; the second size lands it whole.
        func write() -> Bool {
            attempts += 1
            if canResize { window.setSize(target.size) }
            if isCancelled() { return false }
            window.setPosition(target.origin)
            if isCancelled() { return false }
            if canResize { window.setSize(target.size) }
            return !isCancelled()
        }
        func read() -> CGRect { window.frame ?? original }

        if !PlacementMath.approx(original, target, 1) {
            guard write() else { return result(.cancelled, original, read()) }
        }
        var landed = read()
        if !PlacementMath.approx(landed, target) {
            window.settle(timeout: settleTimeout)
            if isCancelled() { return result(.cancelled, original, read()) }
            let settled = read()
            // An app that kept a larger size is at its minimum: writing again cannot change that.
            if !PlacementMath.approx(settled, target), p.allowRetry, !keptLarger(settled.size, than: target.size) {
                guard write() else { return result(.cancelled, original, read()) }
                landed = read()
                if !PlacementMath.approx(landed, target) {
                    window.settle(timeout: settleTimeout)
                    landed = read()
                }
            } else {
                landed = settled
            }
        }
        if isCancelled() { return result(.cancelled, original, landed) }

        // The app kept its own size: hug the edges the cell touches, stay inside the screen.
        if !PlacementMath.approx(landed, target) {
            let anchored = PlacementMath.anchoredFrame(size: landed.size, within: p.target, edges: edges, bounds: p.usable)
            if !PlacementMath.approx(anchored, landed, 1) {
                window.setPosition(anchored.origin)
                landed = read()
            }
        }
        return result(PlacementMath.outcome(requested: p.target, original: original, landed: landed), original, landed)
    }

    /// The app answered with a size larger than asked on some axis (its minimum).
    static func keptLarger(_ size: CGSize, than asked: CGSize) -> Bool {
        size.width > asked.width + PlacementMath.tolerance || size.height > asked.height + PlacementMath.tolerance
    }
}
