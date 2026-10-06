import AppKit
import SwiftUI

/// The surface window (SPEC §2 "Window"): borderless, non-activating, above the menu bar, on every
/// Space, invisible to window cycling. Never key unless a module asks for keyboard input.
final class NotchPanel: NSPanel {
    /// Set by a module that needs typing (timer entry, tiling keyboard mode), while expanded only.
    var allowsKey = false

    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        appearance = NSAppearance(named: .darkAqua)
        // Explicitly on: the frame is the visible shape plus the hot zone, so every point of it is ours.
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = false
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
    // Never let AppKit nudge us below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Keyboard focus for the expanded panel (SPEC §2: never key unless a module needs typing). A
/// module whose tab is on screen asks with `request(true)`; the panel becomes key without
/// activating Glancy (it is a non-activating panel), and gives the keyboard back on
/// `request(false)` or on collapse. Wired by `SurfaceManager`; a no-op before that.
@MainActor
public enum SurfaceKeyFocus {
    static var handler: ((Bool) -> Void)?
    /// Who currently wants the keyboard. Tabs hand over in any order (the old tab's "off" may
    /// arrive after the new tab's "on"), so focus stays while anyone still holds it.
    private static var owners: Set<String> = []
    public static func request(_ on: Bool, owner: String = #fileID) {
        if on { owners.insert(owner) } else { owners.remove(owner) }
        handler?(!owners.isEmpty)
    }
    /// The panel collapsed: nobody holds the keyboard any more.
    static func reset() { owners.removeAll() }
    /// Whether `owner` currently holds the keyboard (tests, diagnostics).
    public static func holds(_ owner: String) -> Bool { owners.contains(owner) }
}

/// Hosts the SwiftUI surface. Takes the first click (the panel is never key), reports hover via
/// one tracking area, turns clicks into open / click-outside-close, and horizontal swipes into tabs.
final class SurfaceHostingView: NSHostingView<SurfaceView> {
    var onHover: ((Bool, NSEvent) -> Void)?
    /// Returns true when the click was consumed (collapsed → open, outside the panel → close).
    var onMouseDown: ((NSPoint) -> Bool)?
    var onSwipe: ((Int) -> Void)?
    private var swipe = SwipeTracker()
    private var area: NSTrackingArea?
    /// Layout passes so far: a collapsed, unchanging surface must add none (tests, the lab).
    private(set) var layoutPasses = 0

    override func layout() {
        super.layout()
        layoutPasses += 1
    }

    required init(rootView: SurfaceView) {
        super.init(rootView: rootView)
        // The window size is ours, never the content's.
        sizingOptions = []
        registerDropTypes()
        NotificationCenter.default.addObserver(self, selector: #selector(registerDropTypes), name: SurfaceDrop.changed, object: nil)
    }

    // MARK: Content dropped on the notch → the drop target (the Shelf), if one is installed.

    private var dropRegistered = false
    @objc private func registerDropTypes() {
        if let types = SurfaceDrop.target?.dropTypes {
            registerForDraggedTypes(types); dropRegistered = true
        } else if dropRegistered {
            unregisterDraggedTypes(); dropRegistered = false
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        SurfaceDrop.target?.dragUpdated(sender) ?? super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        SurfaceDrop.target?.dragUpdated(sender) ?? super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if let target = SurfaceDrop.target { target.dragExited() } else { super.draggingExited(sender) }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        SurfaceDrop.target?.performDrop(sender) ?? super.performDragOperation(sender)
    }

    /// No periodic updates while a drag hovers motionless: only real moves.
    override func wantsPeriodicDraggingUpdates() -> Bool { false }

    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) { fatalError("unused") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if event.trackingArea === area { onHover?(true, event) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === area { onHover?(false, event) }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if onMouseDown?(p) == true { return }
        super.mouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        guard event.hasPreciseScrollingDeltas else { return }
        let phase: SwipeTracker.Phase
        if event.momentumPhase != [] { phase = .momentum }
        else if event.phase.contains(.began) { phase = .began }
        else if event.phase.contains(.ended) || event.phase.contains(.cancelled) { phase = .ended }
        else { phase = .changed }
        if let step = swipe.feed(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY, phase: phase) {
            onSwipe?(step)
        }
    }
}
