import AppKit
import SwiftUI

/// One surface on one display: its panel, its model, and the hover / click / leave behaviour.
@MainActor
final class SurfaceController: SurfaceModelDelegate {
    let uuid: String
    let model: SurfaceModel
    private let panel: NotchPanel
    private var host: SurfaceHostingView
    private let container: NSView
    private let context: SurfaceContext
    private weak var manager: SurfaceManager?

    private var hoverTask: Task<Void, Never>?
    private var leaveTask: Task<Void, Never>?
    private var intent = HoverIntent()
    private var faded = false
    /// false in tests: the panel is built but never ordered on screen, and springs are off.
    private let presents: Bool

    init(uuid: String, geometry: NotchGeometry, context: SurfaceContext, manager: SurfaceManager, presents: Bool = true) {
        self.uuid = uuid
        self.context = context
        self.manager = manager
        self.presents = presents
        model = SurfaceModel(geometry: geometry)
        model.animates = presents
        let frame = model.layout.windowFrame(in: geometry)
        panel = NotchPanel(frame: frame)
        host = SurfaceHostingView(rootView: SurfaceView(model: model, context: context))
        // The host is centred on the notch, not on the window: when one wing is narrower the
        // window is off-centre, and during a transition it is the union of two shapes.
        container = NSView(frame: CGRect(origin: .zero, size: frame.size))
        container.addSubview(host)
        panel.contentView = container
        model.delegate = self
        wire(host)
        applyCapture()
        setPanelFrame(frame, display: false)
        if presents { panel.orderFrontRegardless() }
    }

    private func wire(_ host: SurfaceHostingView) {
        host.onHover = { [weak self] inside, event in self?.hoverChanged(inside, event) }
        host.onMouseDown = { [weak self] p in self?.mouseDown(at: p) ?? false }
        host.onSwipe = { [weak self] step in self?.swipe(step) }
    }

    /// Tests: the hosting view currently in the panel.
    var hostForTest: NSView { host }
    /// Layout passes of the hosting view so far (an idle collapsed surface adds none).
    var layoutPasses: Int { host.layoutPasses }

    var panelFrame: CGRect { panel.frame }
    var panelVisible: Bool { panel.isVisible }
    var panelAlpha: CGFloat { panel.alphaValue }
    var isFaded: Bool { faded }
    /// Tests: a click at `p` in the hosting view's own (flipped) coordinates; true = consumed.
    func clickForTest(_ p: NSPoint) -> Bool { mouseDown(at: p) }
    var hostBoundsForTest: CGRect { host.bounds }
    /// Tests: one layout + draw pass of the SwiftUI content (its initial `onChange`s run here).
    func displayForTest() { panel.display() }

    func tearDown() {
        hoverTask?.cancel(); leaveTask?.cancel()
        model.delegate = nil
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
    }

    func applyCapture() {
        panel.sharingType = context.settings.hideFromCapture ? .none : .readOnly
    }

    /// Moves the window and keeps the host centred on the notch inside it, in one go.
    private func setPanelFrame(_ frame: CGRect, display: Bool) {
        panel.setFrame(frame, display: false)
        let h = SurfaceLayout.hostFrame(in: model.geometry, window: frame)
        let local = CGRect(x: h.minX - frame.minX, y: 0, width: h.width, height: h.height)
        if host.frame != local { host.frame = local }
        if display { panel.display() }
    }

    // MARK: Model delegate

    func surfaceLayoutWillChange(_ model: SurfaceModel, to layout: SurfaceLayout) {
        let target = layout.windowFrame(in: model.geometry)
        let frame = transitionFrame(from: panel.frame, to: target)
        if frame != panel.frame { setPanelFrame(frame, display: true) }
    }

    func surfaceLayoutDidSettle(_ model: SurfaceModel) {
        let target = model.layout.windowFrame(in: model.geometry)
        if target != panel.frame { setPanelFrame(target, display: true) }
        // The frame shrank under a still pointer: no exit event comes, so check once here.
        if model.hovering, !model.expanded, !target.contains(NSEvent.mouseLocation) {
            hoverTask?.cancel(); intent.exited()
            model.setHovering(false)
        }
    }

    func surfaceWillCollapse(_ model: SurfaceModel) {
        manager?.surfaceWillCollapse(self)
    }

    func surfaceStateDidChange(_ model: SurfaceModel) {
        if model.hidden {
            if panel.isVisible { panel.orderOut(nil) }
        } else if !panel.isVisible, presents {
            panel.orderFrontRegardless()
        }
        manager?.surfaceStateChanged(self)
    }

    // MARK: Fades (Space switch, Mission Control)

    func fade(out: Bool) {
        guard faded != out else { return }
        faded = out
        guard presents else { panel.alphaValue = out ? 0 : 1; return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = out ? 0.12 : 0.22
            panel.animator().alphaValue = out ? 0 : 1
        }
    }

    /// After wake / unlock: the window server may have dropped our ordering, a Mission Control
    /// exit may have been missed while asleep (the panel would stay at alpha 0 for good), and the
    /// frame must be the visible shape again. Idempotent and cheap.
    func reassert() {
        if faded || panel.alphaValue < 1 {
            faded = false
            panel.alphaValue = 1
        }
        let target = model.layout.windowFrame(in: model.geometry)
        if panel.frame != target, !model.expanded { setPanelFrame(target, display: false) }
        if !model.hidden, presents { panel.orderFrontRegardless() }
    }

    /// A Space switch has just finished: dip and come back, so nothing is drawn over the transition.
    func dip() {
        guard !faded, model.state != .idle else { return }
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 1
        }
    }

    // MARK: Pointer

    private func hoverChanged(_ inside: Bool, _ event: NSEvent) {
        if inside {
            leaveTask?.cancel(); leaveTask = nil
            if !model.expanded, !model.hovering {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            model.setHovering(true)
            if !model.expanded, context.settings.openModel == .hover { startDwell(event) }
        } else {
            hoverTask?.cancel(); hoverTask = nil
            intent.exited()
            model.setHovering(false)
            if model.expanded { scheduleLeaveClose() }
        }
    }

    /// Hover-to-open: sample the speed just after entry, then open if still inside after the dwell.
    private func startDwell(_ event: NSEvent) {
        hoverTask?.cancel()
        let entry = panel.convertPoint(toScreen: event.locationInWindow)
        intent.entered(at: entry, time: ProcessInfo.processInfo.systemUptime)
        hoverTask = Task { [weak self] in
            try? await Delay.sleep(for: .seconds(HoverIntent.sampleDelay))
            guard let self, !Task.isCancelled else { return }
            self.intent.sample(at: NSEvent.mouseLocation, time: ProcessInfo.processInfo.systemUptime)
            try? await Delay.sleep(for: .seconds(HoverIntent.dwell - HoverIntent.sampleDelay))
            guard !Task.isCancelled else { return }
            if self.intent.shouldOpen(stillInside: self.model.hovering) { self.manager?.open(self) }
        }
    }

    /// Expanded and the pointer left: close after 400 ms unless it comes back.
    private func scheduleLeaveClose() {
        leaveTask?.cancel()
        leaveTask = Task { [weak self] in
            try? await Delay.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled, !self.model.hovering else { return }
            self.manager?.close(self)
        }
    }

    private func mouseDown(at p: NSPoint) -> Bool {
        if !model.expanded {
            manager?.open(self)
            return true
        }
        // Expanded: a click in the shadow margin, outside the panel, closes it.
        let size = model.layout.size
        // The hosting view is flipped (y grows downward): the panel hangs from y = 0.
        let top = host.isFlipped ? 0 : host.bounds.height - size.height
        let panelRect = CGRect(x: (host.bounds.width - size.width) / 2, y: top,
                               width: size.width, height: size.height)
        if !panelRect.contains(p) {
            manager?.close(self)
            return true
        }
        return false
    }

    private func swipe(_ step: Int) {
        guard model.expanded, !model.showingSettings else { return }
        let seq = context.tabSequence
        let i = seq.firstIndex(where: { $0 == model.selectedTab }) ?? 0
        let next = min(max(i + step, 0), seq.count - 1)
        if next != i { model.select(tab: seq[next]) }
    }

    func expand(tab: ModuleID?) {
        leaveTask?.cancel()
        // Already open (a file dragged in over Home, a hotkey): switch to the requested tab.
        if model.expanded { model.select(tab: tab) } else { model.expand(tab: tab) }
    }

    func collapse() {
        leaveTask?.cancel()
        SurfaceKeyFocus.reset(); setKeyFocus(false)
        model.collapse()
    }

    /// Makes the expanded panel key (keyboard to the open tab) or gives the keyboard back to the
    /// frontmost app. Ordering the panel out and in again drops key status without activating
    /// anything; the app that was active never stopped being active.
    func setKeyFocus(_ on: Bool) {
        let want = on && model.expanded && !model.hidden
        guard want != panel.allowsKey else { return }
        panel.allowsKey = want
        if want {
            panel.makeKey()
        } else if panel.isKeyWindow {
            panel.orderOut(nil)
            if !model.hidden { panel.orderFrontRegardless() }
        }
    }
}
