import AppKit
import Foundation
import Testing
@testable import GlancyKit

// Settings → General → Size. Nothing here changes `UIScale.shared` (the factor every view in this
// process reads, other suites included): managers get their own `UIScale`, layout gets its factor
// through the geometry.

private let mbp14 = ScreenInfo(
    uuid: "BUILTIN", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    visibleFrame: CGRect(x: 0, y: 57, width: 1512, height: 892), safeTop: 32,
    auxLeft: CGRect(x: 0, y: 950, width: 665, height: 32), auxRight: CGRect(x: 850, y: 950, width: 662, height: 32),
    isBuiltin: true, scale: 2)

private let display27 = ScreenInfo(
    uuid: "LG27", frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
    visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1416), safeTop: 0,
    auxLeft: nil, auxRight: nil, isBuiltin: false, scale: 2)

/// A short display: the expanded panel at 1.3 (273 pt + 28 pt of shadow) does not fit 290 pt.
private let short = ScreenInfo(
    uuid: "SHORT", frame: CGRect(x: 0, y: 0, width: 1024, height: 320),
    visibleFrame: CGRect(x: 0, y: 0, width: 1024, height: 290), safeTop: 0,
    auxLeft: nil, auxRight: nil, isBuiltin: false, scale: 2)

@MainActor
@Suite("Size setting")
struct SizeTests {
    @Test func factorsAndTheHalfPointGrid() {
        #expect(UISize.normal.factor == 1 && UISize.large.factor == 1.15 && UISize.extraLarge.factor == 1.3)
        #expect(UIScale.scaled(13, by: 1) == 13)
        #expect(UIScale.scaled(9.5, by: 1) == 9.5)
        #expect(UIScale.scaled(10, by: 1.15) == 11.5)
        #expect(UIScale.scaled(13, by: 1.3) == 17)          // 16.9 → 17
        #expect(UIScale.scaled(680, by: 1.3) == 884)
        #expect(UIScale.scaled(210, by: 1.15) == 241.5)
        // Every scaled value lands on whole pixels at 2×.
        for v in stride(from: CGFloat(1), through: 40, by: 0.5) {
            for f in UISize.allCases.map(\.factor) {
                let s = UIScale.scaled(v, by: f)
                #expect((s * 2).rounded() == s * 2)
            }
        }
    }

    @Test func normalIsTheDefaultAndChangesNothing() {
        let suite = "ai.glancy.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        #expect(AppSettings(defaults: d).size == .normal)
        // The process-wide scale starts normal: Theme reads exactly the normal metrics.
        #expect(UIScale.shared.factor == 1)
        #expect(Theme.expandedSize == Theme.Base.expandedSize)
        #expect(Theme.openTopRadius == Theme.Base.openTopRadius)
        #expect(12.ui == 12 && 9.5.ui == 9.5)
        // Layout at factor 1 is the layout of before the setting existed.
        let g = NotchGeometry.notch(for: mbp14)!
        #expect(g.uiScale == 1)
        let open = SurfaceLayout.make(state: .expanded, geometry: g, wing: 0, peekEventContentWidth: 0)
        #expect(open.size == CGSize(width: 680, height: 210))
    }

    @Test func theSettingIsPersisted() {
        let suite = "ai.glancy.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let s = AppSettings(defaults: d)
        s.size = .extraLarge
        #expect(AppSettings(defaults: d).size == .extraLarge)
        s.size = .large
        #expect(AppSettings(defaults: d).size == .large)
        #expect(d.string(forKey: "uiSize") == "large")
    }

    @Test func theNotchKeepsItsHardwareSizeThePanelAndDropDownsGrow() {
        let g = NotchGeometry.notch(for: mbp14, uiScale: 1.3)!
        #expect(g.notchRect.size == CGSize(width: 185, height: 32))
        let idle = SurfaceLayout.make(state: .idle, geometry: g, wing: 0, peekEventContentWidth: 0)
        #expect(idle.size == CGSize(width: 185, height: 32))
        #expect(idle.topRadius == Theme.Base.closedTopRadius && idle.bottomRadius == Theme.Base.closedBottomRadius)
        let peek = SurfaceLayout.make(state: .peek, geometry: g, wing: 0, peekEventContentWidth: 0)
        #expect(peek.size.height == 32 + Theme.Base.peekGrow.height)   // the hover grow stays inside the menu-bar gap
        let open = SurfaceLayout.make(state: .expanded, geometry: g, wing: 0, peekEventContentWidth: 0)
        #expect(open.size == CGSize(width: 884, height: 273))
        #expect(open.topRadius == UIScale.scaled(Theme.Base.openTopRadius, by: 1.3))
        let drop = SurfaceLayout.make(state: .peekEvent, geometry: g, wing: 0, peekEventContentWidth: 400)
        #expect(drop.size.height == 32 + UIScale.scaled(Theme.Base.peekEventDrop, by: 1.3))
        #expect(drop.size.width == (400 + 2 * UIScale.scaled(SurfaceLayout.peekEventPad, by: 1.3) + 2 * Theme.Base.closedTopRadius).rounded(.up))
        #expect(g.wingCap == UIScale.scaled(Theme.Base.wingMaxWidth, by: 1.3))
    }

    @Test func thePillGrowsWithEverythingElse() {
        let normal = NotchGeometry.pill(for: display27, menuBarHeight: 24)
        let xl = NotchGeometry.pill(for: display27, menuBarHeight: 24, uiScale: 1.3)
        #expect(normal.notchRect.size == CGSize(width: 186, height: 24))
        #expect(xl.notchRect.size == CGSize(width: 242, height: 31))
        #expect(xl.notchRect.maxY == display27.frame.maxY)
        #expect(abs(xl.notchRect.midX - display27.frame.midX) <= 0.5)
        let idle = SurfaceLayout.make(state: .idle, geometry: xl, wing: 0, peekEventContentWidth: 0)
        #expect(idle.size == xl.notchRect.size)
        #expect(idle.bottomRadius == UIScale.scaled(Theme.Base.closedBottomRadius, by: 1.3))
        // Wings: content measured at the larger size, pads grown with it.
        #expect(SurfaceLayout.wingWidth(left: 40, right: 0, geometry: xl)
                == (40 + UIScale.scaled(SurfaceLayout.wingOuterPad, by: 1.3) + UIScale.scaled(SurfaceLayout.wingInnerGap, by: 1.3)).rounded(.up))
    }

    @Test func aSizeThatDoesNotFitFallsToTheLargestThatDoes() {
        #expect(UISize.extraLarge.fitting([mbp14]) == .extraLarge)
        #expect(UISize.extraLarge.fitting([mbp14, display27]) == .extraLarge)
        #expect(UISize.extraLarge.fitting([short]) == .large)
        #expect(UISize.large.fitting([short]) == .large)
        // Too narrow for anything larger: normal is the floor.
        let narrow = ScreenInfo(uuid: "N", frame: CGRect(x: 0, y: 0, width: 760, height: 600),
                                visibleFrame: CGRect(x: 0, y: 0, width: 760, height: 576), safeTop: 0,
                                auxLeft: nil, auxRight: nil, isBuiltin: false, scale: 2)
        #expect(UISize.extraLarge.fitting([narrow]) == .normal)
        // Only displays that show a surface count: the short one without the pill has none.
        #expect(SurfaceManager.effectiveSize(.extraLarge, [mbp14, short], externalPill: false) == .extraLarge)
        #expect(SurfaceManager.effectiveSize(.extraLarge, [mbp14, short], externalPill: true) == .large)
        // No notch anywhere: the main display gets the pill, and it is the one measured.
        #expect(SurfaceManager.effectiveSize(.extraLarge, [short, mbp14.withoutNotch], externalPill: false) == .large)
    }

    @Test func changingTheSizeRelaysOutLiveAndOnlyOnce() async throws {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "glancy.test.size.\(UUID().uuidString)")!)
        let scale = UIScale()
        let context = SurfaceContext(hub: ActivityHub(), settings: settings, launchAtLogin: LaunchAtLogin(), modules: [])
        let ws = NotificationCenter(), dn = NotificationCenter(), app = NotificationCenter()
        let manager = SurfaceManager(context: context, screens: { [mbp14] }, fullscreenSpaces: { [] },
                                     events: SystemEvents(workspace: ws, distributed: dn, app: app, observesDock: false),
                                     presents: false, uiScale: scale)
        manager.start()
        defer { manager.stop() }
        let surface = try #require(manager.surface("BUILTIN"))
        manager.open(surface)
        #expect(surface.panelFrame.width == 680 + 2 * SurfaceLayout.shadowInset.width)

        settings.size = .extraLarge
        try await waitUntil { scale.size == .extraLarge }
        #expect(scale.requested == .extraLarge && scale.factor == 1.3 && !scale.isLimited)
        #expect(surface.model.geometry.uiScale == 1.3)
        #expect(surface.model.expanded)   // re-laid out in place, not closed and reopened
        #expect(surface.panelFrame.width == 884 + 2 * SurfaceLayout.shadowInset.width)
        #expect(surface.panelFrame.height == 273 + SurfaceLayout.shadowInset.height)
        #expect(surface.panelFrame.maxY == mbp14.frame.maxY)

        settings.size = .normal
        try await waitUntil { scale.size == .normal }
        #expect(surface.panelFrame.width == 680 + 2 * SurfaceLayout.shadowInset.width)
        // The process-wide factor was never touched.
        #expect(UIScale.shared.factor == 1)
    }

    @Test func sizeCommandsInTheCommandBar() {
        let suite = "ai.glancy.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let s = AppSettings(defaults: d)
        let items = BuiltinCommands.sizeItems(tag: "Glancy", settings: s)
        #expect(items.map(\.id) == ["glancy.size.normal", "glancy.size.large", "glancy.size.extraLarge"])
        #expect(items.allSatisfy { !$0.closesPanel })
        items[1].run?()
        #expect(s.size == .large)
        #expect(BuiltinCommands.sizeItems(tag: "Glancy", settings: nil).isEmpty)
    }

    @Test func stringsHaveItalian() {
        for key in ["Size", "Normal", "Large", "Extra large", "Doesn't fit the screen: %@ in use", "Size: %@"] {
            #expect(L10n.italianTable[key] != nil, "\(key)")
        }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }
}

private extension ScreenInfo {
    var withoutNotch: ScreenInfo {
        ScreenInfo(uuid: uuid, frame: frame, visibleFrame: visibleFrame, safeTop: 0, auxLeft: nil, auxRight: nil,
                   isBuiltin: isBuiltin, scale: scale)
    }
}
