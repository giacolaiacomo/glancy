// Windows — drag a window to the notch. Global monitors on left-mouse down / dragged / up only
// (never mouseMoved): nothing fires while the mouse is still. Per event the work is a state check;
// the window list is read once per drag, and only when the pointer reaches the notch hot zone.

import AppKit

@MainActor
final class DragMonitor {
    /// The tracked, tileable window with this ID (nil = not ours to tile).
    var lookup: (CGWindowID) -> TrackedWindow? = { _ in nil }
    /// The notch took over: the window, its frame before the drag, the hot zone it entered.
    var onOpen: (CGWindowID, CGRect, CGRect) -> Void = { _, _, _ in }
    var onTrack: (CGPoint) -> Void = { _ in }
    var onDrop: (CGPoint) -> Void = { _ in }

    private var monitors: [Any] = []
    private var machine = DragMachine()
    private var zones: [CGRect] = []

    var isActive: Bool { machine.isActive }

    func start() {
        guard monitors.isEmpty else { return }
        let types: [(NSEvent.EventTypeMask, (NSEvent) -> Void)] = [
            (.leftMouseDown, { [weak self] e in self?.down(e) }),
            (.leftMouseDragged, { [weak self] _ in self?.dragged() }),
            (.leftMouseUp, { [weak self] _ in self?.up() }),
        ]
        for (mask, body) in types {
            if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { e in
                MainActor.assumeIsolated { body(e) }
            }) { monitors.append(m) }
        }
    }

    func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        machine = DragMachine()
    }

    /// Esc or the pointer left the panel: the rest of this drag is an ordinary move.
    func cancel() { machine.cancel() }

    private func down(_ e: NSEvent) {
        var id = CGWindowID(e.cgEvent?.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent) ?? 0)
        if id == 0 { id = CGWindowID(NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)) }
        guard id != 0, let w = lookup(id), w.isTileable else { machine.down(window: nil, frame: nil); return }
        machine.down(window: w.id, frame: w.frame)
        zones = Self.hotZones()
    }

    private func dragged() {
        guard machine.isTracking else { return }
        let p = NSEvent.mouseLocation
        let zone = zones.first { $0.contains(p) }
        let pressed = machineWindow
        let effect = machine.dragged(to: p, inHotZone: zone != nil) { pressed.flatMap(Self.liveFrame) }
        switch effect {
        case let .open(window, frame): onOpen(window, frame, zone ?? .zero)
        case let .track(point): onTrack(point)
        default: break
        }
    }

    private func up() {
        guard machine.isTracking || machine.state == .ignoring else { return }
        if case let .drop(p) = machine.up(at: NSEvent.mouseLocation) { onDrop(p) }
    }

    private var machineWindow: CGWindowID? {
        if case let .pressed(w, _) = machine.state { return w }
        return nil
    }

    /// The window's frame right now, from the window server (Cocoa coordinates).
    static func liveFrame(_ id: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let dict = list.first?[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return nil }
        return ScreenSpace.fromAX(bounds)
    }

    /// The notch of every notched display, a little wider and 6 pt deeper (SPEC hot zone + slack
    /// for a pointer dragging a title bar).
    static func hotZones() -> [CGRect] {
        NSScreen.screens.compactMap { s in
            guard let info = s.info, let g = NotchGeometry.notch(for: info) else { return nil }
            let n = g.notchRect
            return CGRect(x: n.minX - 8, y: n.minY - 6, width: n.width + 16, height: n.height + 6)
        }
    }
}
