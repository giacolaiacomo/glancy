import CoreGraphics
import SwiftUI

/// What we know about one display, captured from `NSScreen` (or built by hand in tests).
/// All rects are in AppKit global coordinates (origin bottom-left of the main display, y up).
public struct ScreenInfo: Equatable, Sendable {
    public var uuid: String
    public var frame: CGRect
    public var visibleFrame: CGRect
    public var safeTop: CGFloat
    public var auxLeft: CGRect?
    public var auxRight: CGRect?
    public var isBuiltin: Bool
    public var scale: CGFloat

    public init(uuid: String, frame: CGRect, visibleFrame: CGRect, safeTop: CGFloat,
                auxLeft: CGRect?, auxRight: CGRect?, isBuiltin: Bool, scale: CGFloat) {
        self.uuid = uuid; self.frame = frame; self.visibleFrame = visibleFrame; self.safeTop = safeTop
        self.auxLeft = auxLeft; self.auxRight = auxRight; self.isBuiltin = isBuiltin; self.scale = scale
    }

    public var hasNotch: Bool { safeTop > 0 && auxLeft != nil && auxRight != nil }
}

/// Where the notch is on one display, and how far the wings may grow (SPEC §2 "Geometry").
public struct NotchGeometry: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case notch, pill }

    public let kind: Kind
    public let screenFrame: CGRect
    /// The hardware notch (or the simulated pill), in global coordinates, flush to the top edge.
    public let notchRect: CGRect
    /// Largest wing on either side, so wings never reach the menus or status items.
    public let wingCap: CGFloat
    public let scale: CGFloat

    public init(kind: Kind, screenFrame: CGRect, notchRect: CGRect, wingCap: CGFloat, scale: CGFloat) {
        self.kind = kind; self.screenFrame = screenFrame; self.notchRect = notchRect
        self.wingCap = wingCap; self.scale = scale
    }

    public static let pillWidth: CGFloat = 186
    public static let fallbackMenuBarHeight: CGFloat = 24

    /// The notch of a notched display. Width comes from the unobscured areas either side of it
    /// (`frame.width − auxLeft.width − auxRight.width`), height from `safeAreaInsets.top`.
    public static func notch(for s: ScreenInfo) -> NotchGeometry? {
        guard s.hasNotch, let left = s.auxLeft, let right = s.auxRight else { return nil }
        var x0 = left.maxX, x1 = right.minX
        if x1 - x0 <= 0 {   // malformed areas: fall back to the width formula, centred
            let w = s.frame.width - left.width - right.width
            guard w > 0 else { return nil }
            x0 = s.frame.midX - w / 2; x1 = x0 + w
        }
        let h = s.safeTop
        let rect = CGRect(x: x0, y: s.frame.maxY - h, width: x1 - x0, height: h)
        let cap = min(Theme.wingMaxWidth, left.width, right.width)
        return NotchGeometry(kind: .notch, screenFrame: s.frame, notchRect: rect, wingCap: max(0, cap), scale: s.scale)
    }

    /// A floating pill for a display without a notch, menu-bar height, centred.
    public static func pill(for s: ScreenInfo, menuBarHeight: CGFloat) -> NotchGeometry {
        let h = menuBarHeight > 0 ? menuBarHeight : fallbackMenuBarHeight
        let w = min(pillWidth, s.frame.width)
        let rect = CGRect(x: (s.frame.midX - w / 2).rounded(), y: s.frame.maxY - h, width: w, height: h)
        let cap = min(Theme.wingMaxWidth, max(0, (s.frame.width - w) / 2 - 200))
        return NotchGeometry(kind: .pill, screenFrame: s.frame, notchRect: rect, wingCap: cap, scale: s.scale)
    }
}

// MARK: - States and layout

/// The five states of SPEC §2.
public enum SurfaceState: Equatable, Sendable {
    case idle, activity, peek, peekEvent, expanded

    public var isCollapsed: Bool { self != .expanded }

    /// Precedence: expanded > event drop-down > hover peek > wings > idle.
    public static func resolve(expanded: Bool, hovering: Bool, hasActivity: Bool, hasPeekEvent: Bool) -> SurfaceState {
        if expanded { return .expanded }
        if hasPeekEvent { return .peekEvent }
        if hovering { return .peek }
        if hasActivity { return .activity }
        return .idle
    }
}

/// The visible black shape for a state, and the window that holds it.
///
/// Wings may differ per side (one side's menus can reach the notch): the shape is then off-centre
/// by `shift` (its centre minus the notch's centre, in points). Peek and expanded are centred.
public struct SurfaceLayout: Equatable, Sendable {
    public var size: CGSize
    public var topRadius: CGFloat
    public var bottomRadius: CGFloat
    /// Wing width on each side (0 = none on that side).
    public var wingLeft: CGFloat
    public var wingRight: CGFloat
    /// Horizontal offset of the shape's centre from the notch's centre.
    public var shift: CGFloat
    public var shadow: Bool
    /// Drop-downs only: how far the shape's sides are pulled in, on each side, within the menu-bar
    /// band (the top `bandHeight` points), so a wide peek never sits on a menu title or status item.
    /// 0 = the shape is as wide at the top as below.
    public var bandInsetLeft: CGFloat = 0
    public var bandInsetRight: CGFloat = 0
    public var bandHeight: CGFloat = 0

    /// The wider wing (0 = no wings).
    public var wing: CGFloat { max(wingLeft, wingRight) }

    /// Room around the expanded panel for its shadow.
    public static let shadowInset = CGSize(width: 20, height: 28)
    /// Inside a wing: the outer padding (ear included) and the gap from the notch.
    public static let wingOuterPad: CGFloat = 14
    public static let wingInnerGap: CGFloat = 8
    /// Horizontal padding around peekEvent content, and its width bounds.
    public static let peekEventPad: CGFloat = 22
    public static let peekEventMaxWidth: CGFloat = 440
    /// Radius of the two curves where a drop-down widens below the menu bar.
    public static let bandShoulder: CGFloat = 6

    public init(size: CGSize, topRadius: CGFloat, bottomRadius: CGFloat, wingLeft: CGFloat, wingRight: CGFloat,
                shift: CGFloat = 0, shadow: Bool) {
        self.size = size; self.topRadius = topRadius; self.bottomRadius = bottomRadius
        self.wingLeft = wingLeft; self.wingRight = wingRight; self.shift = shift; self.shadow = shadow
    }

    /// Wing width from the measured content, clamped between a square and the cap.
    public static func wingWidth(left: CGFloat, right: CGFloat, geometry g: NotchGeometry) -> CGFloat {
        let content = max(left, right)
        guard content > 0 else { return 0 }
        let w = (content + wingOuterPad + wingInnerGap).rounded(.up)
        return min(max(w, g.notchRect.height), g.wingCap)
    }

    /// Per-side wings: the symmetric width, then each side kept clear of the menu bar's items
    /// (notched displays only; a pill and an unknown clearance keep the symmetric width).
    public static func wings(left: CGFloat, right: CGFloat, geometry g: NotchGeometry,
                             clearance: MenuBarClearance?) -> (left: CGFloat, right: CGFloat) {
        let w = wingWidth(left: left, right: right, geometry: g)
        guard g.kind == .notch, let clearance else { return (w, w) }
        func need(_ c: CGFloat) -> CGFloat { c > 0 ? (c + wingOuterPad + wingInnerGap).rounded(.up) : 0 }
        return clearance.clamp(w, need: (need(left), need(right)))
    }

    /// Symmetric wings (tests, renderer).
    public static func make(state: SurfaceState, geometry g: NotchGeometry,
                            wing: CGFloat, peekEventContentWidth: CGFloat) -> SurfaceLayout {
        make(state: state, geometry: g, wingLeft: wing, wingRight: wing, peekEventContentWidth: peekEventContentWidth)
    }

    public static func make(state: SurfaceState, geometry g: NotchGeometry, wingLeft: CGFloat, wingRight: CGFloat,
                            peekEventContentWidth: CGFloat, clearance: MenuBarClearance? = nil) -> SurfaceLayout {
        let notch = g.notchRect.size
        let showWings = state != .expanded && (wingLeft > 0 || wingRight > 0)
        let wl = showWings ? wingLeft : 0, wr = showWings ? wingRight : 0
        let base = CGSize(width: notch.width + wl + wr, height: notch.height)
        let shift = (wr - wl) / 2
        let closedTop = Theme.closedTopRadius, closedBottom = Theme.closedBottomRadius
        switch state {
        case .idle:
            return .init(size: notch, topRadius: closedTop, bottomRadius: closedBottom, wingLeft: 0, wingRight: 0, shadow: false)
        case .activity:
            return .init(size: base, topRadius: closedTop, bottomRadius: closedBottom, wingLeft: wl, wingRight: wr,
                         shift: shift, shadow: false)
        case .peek:
            // Grows by half the growth on each side: never more than the menu-bar gap.
            let grow = Theme.peekGrow
            return .init(size: CGSize(width: base.width + grow.width, height: base.height + grow.height),
                         topRadius: closedTop, bottomRadius: closedBottom, wingLeft: wl, wingRight: wr, shift: shift, shadow: false)
        case .peekEvent:
            let wanted = min(peekEventContentWidth + 2 * peekEventPad + 2 * closedTop, peekEventMaxWidth)
            let w = max(notch.width + 2 * max(wl, wr), wanted, notch.width + 2 * 44)
            var l = SurfaceLayout(size: CGSize(width: w.rounded(.up), height: notch.height + Theme.peekEventDrop),
                                  topRadius: closedTop, bottomRadius: closedBottom + 4, wingLeft: wl, wingRight: wr, shadow: false)
            // Within the menu bar the drop-down keeps to the free room either side of the notch;
            // only below it does it widen (SPEC §1.3: never covers menu-bar items).
            if g.kind == .notch, let clearance {
                let half = l.size.width / 2
                func inset(_ room: CGFloat, _ wing: CGFloat) -> CGFloat {
                    let allowed = notch.width / 2 + max(wing, room - MenuBarClearance.gap, 0)
                    let i = max(0, half - allowed)
                    return i < bandShoulder * 2 + 1 ? 0 : i   // too small a step: keep the plain shape
                }
                l.bandInsetLeft = inset(clearance.left, wl)
                l.bandInsetRight = inset(clearance.right, wr)
                l.bandHeight = notch.height
            }
            return l
        case .expanded:
            let s = Theme.expandedSize
            return .init(size: CGSize(width: max(s.width, notch.width + 160), height: max(s.height, notch.height + 120)),
                         topRadius: Theme.openTopRadius, bottomRadius: Theme.openBottomRadius, wingLeft: 0, wingRight: 0, shadow: true)
        }
    }

    /// Width of the room left of the notch inside the shape (the left wing slot), and right of it.
    public func slots(notchWidth: CGFloat) -> (left: CGFloat, right: CGFloat) {
        let left = max(0, size.width / 2 - shift - notchWidth / 2)
        return (left, max(0, size.width - notchWidth - left))
    }

    /// The window frame that holds this layout: the shape (centred on the notch plus `shift`),
    /// flush to the top edge, plus the hot-zone strip when collapsed or the shadow inset when expanded.
    public func windowFrame(in g: NotchGeometry) -> CGRect {
        let pad = shadow ? Self.shadowInset : CGSize(width: 0, height: Theme.hotZoneBelow)
        let w = size.width + 2 * pad.width
        let h = size.height + pad.height
        let scale = max(g.scale, 1)
        let x = ((g.notchRect.midX + shift - w / 2) * scale).rounded() / scale
        return CGRect(x: x, y: g.screenFrame.maxY - h, width: w, height: h)
    }

    /// The SwiftUI root is laid out centred on the notch (and offsets the shape by `shift`), so the
    /// view that hosts it spans symmetrically around the notch's centre, covering `window`.
    public static func hostFrame(in g: NotchGeometry, window: CGRect) -> CGRect {
        let half = max(g.notchRect.midX - window.minX, window.maxX - g.notchRect.midX)
        return CGRect(x: g.notchRect.midX - half, y: window.minY, width: 2 * half, height: window.height)
    }
}

/// While a transition runs, the window must hold both the old and the new shape; once the spring
/// settles it shrinks to the new one. Both rects are top-flush; the union holds both shapes.
public func transitionFrame(from current: CGRect?, to target: CGRect) -> CGRect {
    guard let current, !current.isEmpty else { return target }
    return current.union(target)
}
