import AppKit

/// Notices a content drag (a file, text, a link — not a window) coming within 32 pt of a notch
/// (SPEC §2). Zero cost at rest: one global `leftMouseDown` monitor, which fires only on clicks;
/// the `leftMouseDragged` / `leftMouseUp` monitors exist only while the button is down. A drag
/// is "content" when the drag pasteboard changed since the button went down (boring.notch's
/// DragDetector heuristic) — moving a window or selecting text never touches it.
@MainActor
final class ShelfDragWatcher {
    static let reach: CGFloat = 32

    /// The pointer came within reach of a notch carrying content. Once per drag.
    var onApproach: (() -> Void)?
    /// The button went up after a content drag (approached or not: the panel may already have
    /// been open, and the drop targets need to know the drag is over).
    var onDragEnded: (() -> Void)?

    private var downMonitor: Any?
    private var dragMonitor: Any?
    private var upMonitor: Any?
    private let dragPasteboard = NSPasteboard(name: .drag)
    private var startCount = 0
    private var zones: [CGRect] = []
    private var fired = false

    func start() {
        guard downMonitor == nil, !Lab.isActive else { return }
        downMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.buttonDown() }
        }
    }

    func stop() {
        if let downMonitor { NSEvent.removeMonitor(downMonitor) }
        downMonitor = nil
        removeDragMonitors()
    }

    private func buttonDown() {
        removeDragMonitors()
        zones = Self.notchRects().map { $0.insetBy(dx: -Self.reach, dy: -Self.reach) }
        guard !zones.isEmpty else { return }
        startCount = dragPasteboard.changeCount
        fired = false
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            MainActor.assumeIsolated { self?.dragged() }
        }
        upMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated { self?.buttonUp() }
        }
    }

    private func dragged() {
        guard !fired else { return }
        // Geometry first (free); the pasteboard only when the pointer is near a notch.
        let p = NSEvent.mouseLocation
        guard zones.contains(where: { $0.contains(p) }), dragPasteboard.changeCount != startCount else { return }
        fired = true
        onApproach?()
    }

    private func buttonUp() {
        let content = fired || dragPasteboard.changeCount != startCount
        removeDragMonitors()
        fired = false
        if content { onDragEnded?() }
    }

    private func removeDragMonitors() {
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        if let upMonitor { NSEvent.removeMonitor(upMonitor) }
        dragMonitor = nil; upMonitor = nil
    }

    /// The hardware notch of every notched display, in global screen coordinates.
    static func notchRects() -> [CGRect] {
        NSScreen.screens.compactMap { s in
            guard let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea, s.safeAreaInsets.top > 0 else { return nil }
            return CGRect(x: l.maxX, y: s.frame.maxY - s.safeAreaInsets.top, width: r.minX - l.maxX, height: s.safeAreaInsets.top)
        }
    }
}
