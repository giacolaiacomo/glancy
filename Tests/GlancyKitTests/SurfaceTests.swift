import Foundation
import Testing
@testable import GlancyKit

// Geometry, layout and state transitions of the surface (Lot A).

/// The 14" MacBook Pro this was built on: 1512×982, notch between x 665 and 850, 32 pt tall.
private let mbp14 = ScreenInfo(
    uuid: "BUILTIN", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    visibleFrame: CGRect(x: 0, y: 57, width: 1512, height: 892), safeTop: 32,
    auxLeft: CGRect(x: 0, y: 950, width: 665, height: 32), auxRight: CGRect(x: 850, y: 950, width: 662, height: 32),
    isBuiltin: true, scale: 2)

private let ultrawide = ScreenInfo(
    uuid: "ACER", frame: CGRect(x: -928, y: 982, width: 3440, height: 1440),
    visibleFrame: CGRect(x: -928, y: 982, width: 3440, height: 1416), safeTop: 0,
    auxLeft: nil, auxRight: nil, isBuiltin: false, scale: 1)

private var g14: NotchGeometry { NotchGeometry.notch(for: mbp14)! }

@Suite("Notch geometry")
struct GeometryTests {
    @Test func notchFromAuxiliaryAreas() {
        let g = g14
        #expect(g.kind == .notch)
        #expect(g.notchRect == CGRect(x: 665, y: 950, width: 185, height: 32))
        // Width formula of SPEC §2 agrees: frame − left − right.
        #expect(g.notchRect.width == mbp14.frame.width - mbp14.auxLeft!.width - mbp14.auxRight!.width)
        #expect(g.notchRect.maxY == mbp14.frame.maxY)   // flush to the top edge, no 1 px gap
        #expect(g.wingCap == Theme.wingMaxWidth)
    }

    @Test func noNotchNoGeometry() {
        #expect(NotchGeometry.notch(for: ultrawide) == nil)
    }

    @Test func malformedAreasFallBackToCentredWidth() {
        var s = mbp14
        s.auxLeft = CGRect(x: 0, y: 950, width: 665, height: 32)
        s.auxRight = CGRect(x: 600, y: 950, width: 662, height: 32)   // overlapping: maxX > minX
        let g = NotchGeometry.notch(for: s)!
        let expected: CGFloat = 1512 - 665 - 662
        #expect(g.notchRect.width == expected)
        #expect(abs(g.notchRect.midX - 756) < 0.01)
    }

    @Test func wingCapNeverExceedsTheRoomBesideTheNotch() {
        var s = mbp14
        s.auxLeft = CGRect(x: 0, y: 950, width: 80, height: 32)
        s.auxRight = CGRect(x: 1432, y: 950, width: 80, height: 32)
        s.frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        #expect(NotchGeometry.notch(for: s)!.wingCap == 80)
    }

    @Test func pillOnExternalDisplay() {
        let g = NotchGeometry.pill(for: ultrawide, menuBarHeight: 24)
        #expect(g.kind == .pill)
        #expect(g.notchRect.height == 24)
        #expect(g.notchRect.maxY == ultrawide.frame.maxY)
        #expect(abs(g.notchRect.midX - ultrawide.frame.midX) <= 0.5)
        // Menu bar hidden (height 0) → fallback height.
        #expect(NotchGeometry.pill(for: ultrawide, menuBarHeight: 0).notchRect.height == NotchGeometry.fallbackMenuBarHeight)
    }
}

@Suite("States and layout")
struct LayoutTests {
    @Test func statePrecedence() {
        #expect(SurfaceState.resolve(expanded: false, hovering: false, hasActivity: false, hasPeekEvent: false) == .idle)
        #expect(SurfaceState.resolve(expanded: false, hovering: false, hasActivity: true, hasPeekEvent: false) == .activity)
        #expect(SurfaceState.resolve(expanded: false, hovering: true, hasActivity: true, hasPeekEvent: false) == .peek)
        #expect(SurfaceState.resolve(expanded: false, hovering: true, hasActivity: true, hasPeekEvent: true) == .peekEvent)
        #expect(SurfaceState.resolve(expanded: true, hovering: true, hasActivity: true, hasPeekEvent: true) == .expanded)
    }

    @Test func idleIsExactlyTheNotch() {
        let l = SurfaceLayout.make(state: .idle, geometry: g14, wing: 0, peekEventContentWidth: 0)
        #expect(l.size == CGSize(width: 185, height: 32))
        #expect(l.topRadius == Theme.closedTopRadius && l.bottomRadius == Theme.closedBottomRadius)
        #expect(!l.shadow)
    }

    @Test func wingWidthIsClamped() {
        #expect(SurfaceLayout.wingWidth(left: 0, right: 0, geometry: g14) == 0)
        #expect(SurfaceLayout.wingWidth(left: 4, right: 2, geometry: g14) == 32)          // at least square
        #expect(SurfaceLayout.wingWidth(left: 20, right: 18, geometry: g14) == 42)        // 20 + 14 + 8
        #expect(SurfaceLayout.wingWidth(left: 400, right: 10, geometry: g14) == Theme.wingMaxWidth)
    }

    @Test func activityPeekAndEventSizes() {
        let a = SurfaceLayout.make(state: .activity, geometry: g14, wing: 42, peekEventContentWidth: 0)
        #expect(a.size == CGSize(width: 185 + 84, height: 32))
        let p = SurfaceLayout.make(state: .peek, geometry: g14, wing: 42, peekEventContentWidth: 0)
        #expect(p.size == CGSize(width: a.size.width + Theme.peekGrow.width, height: 32 + Theme.peekGrow.height))
        let e = SurfaceLayout.make(state: .peekEvent, geometry: g14, wing: 0, peekEventContentWidth: 300)
        #expect(e.size.height == 32 + Theme.peekEventDrop)
        let wanted: CGFloat = 300 + 2 * SurfaceLayout.peekEventPad + 2 * Theme.closedTopRadius
        #expect(e.size.width == wanted)
        let huge = SurfaceLayout.make(state: .peekEvent, geometry: g14, wing: 0, peekEventContentWidth: 2000)
        #expect(huge.size.width == SurfaceLayout.peekEventMaxWidth)
        let tiny = SurfaceLayout.make(state: .peekEvent, geometry: g14, wing: 0, peekEventContentWidth: 10)
        #expect(tiny.size.width >= 185 + 88)
    }

    @Test func expandedIsThePanel() {
        let l = SurfaceLayout.make(state: .expanded, geometry: g14, wing: 42, peekEventContentWidth: 0)
        #expect(l.size == Theme.expandedSize)
        #expect(l.topRadius == Theme.openTopRadius && l.bottomRadius == Theme.openBottomRadius)
        #expect(l.shadow && l.wing == 0)
    }

    @Test func windowFrameIsTheShapeFlushAndCentred() {
        let idle = SurfaceLayout.make(state: .idle, geometry: g14, wing: 0, peekEventContentWidth: 0).windowFrame(in: g14)
        // Collapsed: the visible shape plus the 4 pt hot zone, nothing larger.
        #expect(idle == CGRect(x: 665, y: 982 - 36, width: 185, height: 36))
        let open = SurfaceLayout.make(state: .expanded, geometry: g14, wing: 0, peekEventContentWidth: 0).windowFrame(in: g14)
        #expect(open.maxY == 982)
        #expect(open.width == Theme.expandedSize.width + 2 * SurfaceLayout.shadowInset.width)
        #expect(open.height == 210 + SurfaceLayout.shadowInset.height)
        #expect(abs(open.midX - g14.notchRect.midX) <= 0.5)
        // Pixel-aligned at 2×.
        #expect((open.minX * 2).rounded() == open.minX * 2)
    }

    @Test func transitionHoldsBothShapes() {
        let a = CGRect(x: 665, y: 946, width: 185, height: 36)
        let b = CGRect(x: 447.5, y: 744, width: 620, height: 238)
        #expect(transitionFrame(from: a, to: b) == b)
        #expect(transitionFrame(from: b, to: a) == b)
        #expect(transitionFrame(from: nil, to: a) == a)
    }
}

@Suite("Pointer and gestures")
struct GestureTests {
    @Test func slowArrivalOpensAfterDwell() {
        var h = HoverIntent()
        h.entered(at: CGPoint(x: 700, y: 960), time: 10)
        h.sample(at: CGPoint(x: 704, y: 962), time: 10.04)      // ~112 pt/s
        #expect(h.shouldOpen(stillInside: true))
        #expect(!h.shouldOpen(stillInside: false))
    }

    @Test func flickToTheTopEdgeDoesNotOpen() {
        var h = HoverIntent()
        h.entered(at: CGPoint(x: 700, y: 948), time: 10)
        h.sample(at: CGPoint(x: 720, y: 981), time: 10.04)     // ~960 pt/s
        #expect(!h.shouldOpen(stillInside: true))
        h.exited()
        #expect(!h.shouldOpen(stillInside: true))
    }

    @Test func oneTabPerSwipe() {
        var s = SwipeTracker()
        #expect(s.feed(deltaX: 0, deltaY: 0, phase: .began) == nil)
        #expect(s.feed(deltaX: -20, deltaY: 1, phase: .changed) == nil)
        #expect(s.feed(deltaX: -20, deltaY: 1, phase: .changed) == 1)
        #expect(s.feed(deltaX: -80, deltaY: 0, phase: .changed) == nil)   // same gesture: nothing more
        #expect(s.feed(deltaX: -80, deltaY: 0, phase: .momentum) == nil)
        #expect(s.feed(deltaX: 0, deltaY: 0, phase: .ended) == nil)
        _ = s.feed(deltaX: 0, deltaY: 0, phase: .began)
        #expect(s.feed(deltaX: 40, deltaY: 2, phase: .changed) == -1)
    }

    @Test func verticalScrollIsNotASwipe() {
        var s = SwipeTracker()
        _ = s.feed(deltaX: 0, deltaY: 0, phase: .began)
        #expect(s.feed(deltaX: 30, deltaY: 60, phase: .changed) == nil)
        #expect(s.feed(deltaX: 30, deltaY: 60, phase: .changed) == nil)
    }

    @Test func lastTabIsRememberedFor30Seconds() {
        let t0 = Date(timeIntervalSince1970: 1000)
        #expect(tabToOpen(last: .calendar, closedAt: t0, now: t0.addingTimeInterval(29), available: [.calendar]) == .calendar)
        #expect(tabToOpen(last: .calendar, closedAt: t0, now: t0.addingTimeInterval(31), available: [.calendar]) == nil)
        #expect(tabToOpen(last: .calendar, closedAt: t0, now: t0.addingTimeInterval(5), available: [.agents]) == nil)
        #expect(tabToOpen(last: nil, closedAt: t0, now: t0, available: [.agents]) == nil)
    }
}

@Suite("Displays")
struct DisplayTests {
    @Test func diffByUUID() {
        let other = NotchGeometry.pill(for: ultrawide, menuBarHeight: 24)
        let moved = NotchGeometry.pill(for: ScreenInfo(uuid: "ACER", frame: CGRect(x: 1512, y: 0, width: 3440, height: 1440),
                                                       visibleFrame: .zero, safeTop: 0, auxLeft: nil, auxRight: nil,
                                                       isBuiltin: false, scale: 1), menuBarHeight: 24)
        let d1 = ScreenDiff.between([:], ["A": g14, "B": other])
        #expect(d1.added == ["A", "B"] && d1.removed.isEmpty && d1.changed.isEmpty)
        let d2 = ScreenDiff.between(["A": g14, "B": other], ["A": g14, "B": moved])
        #expect(d2.changed == ["B"] && d2.added.isEmpty && d2.removed.isEmpty)
        let d3 = ScreenDiff.between(["A": g14, "B": other], ["A": g14])
        #expect(d3.removed == ["B"])
        #expect(ScreenDiff.between(["A": g14], ["A": g14]).isEmpty)
    }

    @Test func fullscreenSpacesFromManagedDisplaySpaces() {
        let displays: [[String: Any]] = [
            ["Display Identifier": "BUILTIN",
             "Current Space": ["ManagedSpaceID": 7],
             "Spaces": [["ManagedSpaceID": 3], ["ManagedSpaceID": 7, "TileLayoutManager": ["TileSpaces": []], "pid": 123]]],
            ["Display Identifier": "ACER",
             "Current Space": ["ManagedSpaceID": 4],
             "Spaces": [["ManagedSpaceID": 4], ["ManagedSpaceID": 9, "TileLayoutManager": [:]]]],
            ["Display Identifier": "BROKEN"],
        ]
        #expect(FullscreenSpaces.fullscreenDisplays(in: displays) == ["BUILTIN"])
    }
}

// MARK: - Model transitions

@MainActor
final class FrameRecorder: SurfaceModelDelegate {
    var frame: CGRect
    var grows: [CGRect] = []
    var settles = 0
    var stateChanges = 0
    init(_ initial: CGRect) { frame = initial }
    func surfaceLayoutWillChange(_ model: SurfaceModel, to layout: SurfaceLayout) {
        frame = transitionFrame(from: frame, to: layout.windowFrame(in: model.geometry))
        grows.append(frame)
    }
    func surfaceLayoutDidSettle(_ model: SurfaceModel) {
        settles += 1
        frame = model.layout.windowFrame(in: model.geometry)
    }
    func surfaceStateDidChange(_ model: SurfaceModel) { stateChanges += 1 }
}

@MainActor @Suite("Surface model")
struct ModelTests {
    func make() -> (SurfaceModel, FrameRecorder) {
        let m = SurfaceModel(geometry: g14)
        m.animates = false
        let r = FrameRecorder(m.layout.windowFrame(in: g14))
        m.delegate = r
        return (m, r)
    }

    @Test func hoverPeeksAndLeavingReturnsToIdle() {
        let (m, r) = make()
        #expect(m.state == .idle)
        m.setHovering(true)
        #expect(m.state == .peek)
        #expect(r.frame.size == CGSize(width: 197, height: 38 + Theme.hotZoneBelow))
        m.setHovering(false)
        #expect(m.state == .idle)
        #expect(r.frame == CGRect(x: 665, y: 946, width: 185, height: 36))
    }

    @Test func clickExpandsAndCollapseReturnsToTheVisibleShape() {
        let (m, r) = make()
        m.setHovering(true)
        m.expand(tab: .calendar)
        #expect(m.state == .expanded)
        #expect(m.visibility == .expanded(.calendar))
        #expect(r.frame.width == Theme.expandedSize.width + 2 * SurfaceLayout.shadowInset.width)
        m.collapse()
        #expect(m.state == .peek)               // the pointer is still on the notch
        #expect(m.lastTab == .calendar && m.closedAt != nil)
        m.setHovering(false)
        #expect(r.frame.height == 36)           // never a big transparent window left behind
    }

    @Test func tabsReportVisibility() {
        let (m, _) = make()
        m.expand(tab: nil)
        #expect(m.visibility == .expanded(nil))
        m.select(tab: .agents)
        #expect(m.visibility == .expanded(.agents))
        m.select(tab: nil)
        #expect(m.visibility == .expanded(nil))
        m.collapse()
        #expect(m.visibility == .collapsed)
    }

    @Test func wingsAppearWithActivityAndRetract() {
        let (m, r) = make()
        m.setActivity(present: true, left: 20, right: 18)
        #expect(m.state == .activity && m.wing == 42)
        let wide: CGFloat = 185 + 84
        #expect(r.frame.width == wide)
        m.setActivity(present: false, left: 20, right: 18)
        #expect(m.state == .idle && r.frame.width == 185)
    }

    @Test func peekEventDropsAndRetracts() {
        let (m, r) = make()
        let id = UUID()
        m.showPeek(id, contentWidth: 180)
        #expect(m.state == .peekEvent)
        #expect(r.frame.height == 32 + Theme.peekEventDrop + Theme.hotZoneBelow)
        m.showPeek(nil, contentWidth: 0)
        #expect(m.state == .idle)
    }

    @Test func hidingCollapsesAndPauses() {
        let (m, _) = make()
        m.expand(tab: nil)
        m.setHidden(true)
        #expect(!m.expanded && m.visibility == .hidden)
        m.expand(tab: nil)                       // ignored while hidden
        #expect(!m.expanded)
        m.setHidden(false)
        #expect(m.visibility == .collapsed)
    }
}

@MainActor @Suite("Settings and language")
struct SettingsTests {
    @Test func languageResolution() {
        #expect(L10n.resolve(.system, preferred: ["it-IT", "en"]) == "it")
        #expect(L10n.resolve(.system, preferred: ["en-GB"]) == "en")
        #expect(L10n.resolve(.it, preferred: ["en"]) == "it")
        #expect(L10n.resolve(.en, preferred: ["it"]) == "en")
    }

    @Test func settingsPersist() {
        let suite = "ai.glancy.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let s = AppSettings(defaults: d)
        #expect(s.openModel == .click && s.hideFromCapture && !s.externalPill)
        s.openModel = .hover
        s.hideFromCapture = false
        s.externalPill = true
        s.setEnabled(.media, false)
        s.language = .it
        #expect(L10n.tr("Settings") == "Impostazioni")
        let again = AppSettings(defaults: d)
        #expect(again.openModel == .hover && !again.hideFromCapture && again.externalPill)
        #expect(!again.isEnabled(.media) && again.isEnabled(.agents))
        #expect(again.language == .it)
        again.language = .en
        #expect(L10n.tr("Settings") == "Settings")
    }
}
