import SwiftUI

/// Receives layout changes so the window can grow before a transition and shrink after it settles.
@MainActor
protocol SurfaceModelDelegate: AnyObject {
    func surfaceLayoutWillChange(_ model: SurfaceModel, to layout: SurfaceLayout)
    func surfaceLayoutDidSettle(_ model: SurfaceModel)
    func surfaceStateDidChange(_ model: SurfaceModel)
}

/// The state of one surface (one display). Fine-grained so the collapsed view observes only what it
/// shows. Every visible change goes through `transition`, which drives the window frame too.
@MainActor @Observable
public final class SurfaceModel {
    public private(set) var geometry: NotchGeometry
    public private(set) var hovering = false
    public private(set) var expanded = false
    /// Paused: screen asleep, locked, or a fullscreen space owns this display.
    public private(set) var hidden = false
    /// The tab on screen while expanded; nil = Home.
    public var selectedTab: ModuleID?
    public var showingSettings = false

    /// Measured ideal widths of the top activity's wing content.
    public private(set) var wingContent: (left: CGFloat, right: CGFloat) = (0, 0)
    public private(set) var hasActivity = false
    /// The peek event currently dropped down, once its content has been measured.
    public private(set) var shownPeek: UUID?
    public private(set) var peekContentWidth: CGFloat = 0
    /// Free room beside the notch in the menu bar (nil = not known yet: symmetric wings).
    public private(set) var clearance: MenuBarClearance?

    /// Off in the renderer and in tests: state changes apply without springs.
    @ObservationIgnored public var animates = true
    @ObservationIgnored weak var delegate: SurfaceModelDelegate?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var animating = false
    @ObservationIgnored var lastTab: ModuleID?
    @ObservationIgnored var closedAt: Date?

    public init(geometry: NotchGeometry) { self.geometry = geometry }

    public var state: SurfaceState {
        .resolve(expanded: expanded, hovering: hovering, hasActivity: hasActivity, hasPeekEvent: shownPeek != nil)
    }

    /// Wings per side, kept clear of the menus and status items.
    public var wings: (left: CGFloat, right: CGFloat) {
        guard hasActivity else { return (0, 0) }
        return SurfaceLayout.wings(left: wingContent.left, right: wingContent.right, geometry: geometry, clearance: clearance)
    }

    /// The wider wing (0 = none shown).
    public var wing: CGFloat { max(wings.left, wings.right) }

    public var layout: SurfaceLayout {
        let w = wings
        return .make(state: state, geometry: geometry, wingLeft: w.left, wingRight: w.right, peekEventContentWidth: peekContentWidth,
                     clearance: clearance)
    }

    public var visibility: SurfaceVisibility {
        hidden ? .hidden : expanded ? .expanded(showingSettings ? nil : selectedTab) : .collapsed
    }

    // MARK: Inputs

    public func setHovering(_ on: Bool) {
        guard hovering != on else { return }
        transition(expanded ? nil : Theme.peek) { hovering = on }
    }

    public func expand(tab: ModuleID?) {
        guard !expanded, !hidden else { return }
        transition(Theme.open) {
            selectedTab = tab
            showingSettings = false
            expanded = true
        }
    }

    public func collapse() {
        guard expanded else { return }
        lastTab = selectedTab
        closedAt = .now
        transition(Theme.close) {
            expanded = false
            showingSettings = false
        }
    }

    public func setHidden(_ on: Bool) {
        guard hidden != on else { return }
        // Hidden first, then collapse: modules go straight from expanded to hidden, never through
        // a transient "collapsed" (which restarts wing work just to stop it again).
        if on { hovering = false }
        hidden = on
        if on, expanded { collapse() }
        delegate?.surfaceStateDidChange(self)
    }

    public func updateGeometry(_ g: NotchGeometry) {
        guard g != geometry else { return }
        transition(nil) { geometry = g }
    }

    /// The menu bar changed (another app in front, a status item appeared): wings re-clamp.
    public func setClearance(_ c: MenuBarClearance?) {
        guard c != clearance else { return }
        transition(Theme.close) { clearance = c }
    }

    /// Wing content measured by the view (fixed-size ideal widths). Zero widths = no activity.
    public func setActivity(present: Bool, left: CGFloat, right: CGFloat) {
        let l = present ? left : 0, r = present ? right : 0
        guard present != hasActivity || abs(l - wingContent.left) > 0.5 || abs(r - wingContent.right) > 0.5 else { return }
        transition(present && !hasActivity ? Theme.open : Theme.close) {
            hasActivity = present
            wingContent = (l, r)
        }
    }

    /// A peek event's content has been measured: drop it down. nil retracts.
    public func showPeek(_ id: UUID?, contentWidth: CGFloat) {
        guard id != shownPeek || (id != nil && abs(contentWidth - peekContentWidth) > 0.5) else { return }
        transition(id == nil ? Theme.close : Theme.open) {
            shownPeek = id
            if id != nil { peekContentWidth = contentWidth }
        }
    }

    public func select(tab: ModuleID?) {
        guard selectedTab != tab || showingSettings else { return }
        withMaybeAnimation(Theme.peek) {
            selectedTab = tab
            showingSettings = false
        }
        delegate?.surfaceStateDidChange(self)
    }

    public func toggleSettings() {
        withMaybeAnimation(Theme.peek) { showingSettings.toggle() }
        delegate?.surfaceStateDidChange(self)
    }

    // MARK: Transitions

    /// Applies a change with the given spring (nil = no animation). The delegate grows the window
    /// to hold both shapes now and shrinks it to the final shape once the spring has settled.
    func transition(_ animation: Animation?, _ change: () -> Void) {
        let before = layout
        let wasState = state
        let animated = animates && animation != nil
        if animated, let animation {
            generation += 1
            let gen = generation
            animating = true
            withAnimation(animation, completionCriteria: .removed) {
                change()
            } completion: { [weak self] in
                // Only the latest spring settles the window; an interrupted one never shrinks it.
                guard let self, self.generation == gen else { return }
                self.animating = false
                self.delegate?.surfaceLayoutDidSettle(self)
            }
        } else {
            change()
        }
        let after = layout
        if after != before { delegate?.surfaceLayoutWillChange(self, to: after) }
        if !animated, !animating { delegate?.surfaceLayoutDidSettle(self) }
        if state != wasState { delegate?.surfaceStateDidChange(self) }
    }

    private func withMaybeAnimation(_ a: Animation, _ change: () -> Void) {
        if animates { withAnimation(a, change) } else { change() }
    }
}
