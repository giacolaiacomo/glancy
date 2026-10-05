import AppKit
import Foundation
import Testing
@testable import GlancyKit

// Lot M: the wings never cover a menu title or a status item. Synthetic menu bars on the 14"
// MacBook Pro (notch x 665…850, 32 pt) and the ultrawide above it; one opt-in live reading.

private let mbp = ScreenInfo(
    uuid: "BUILTIN", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    visibleFrame: CGRect(x: 0, y: 57, width: 1512, height: 892), safeTop: 32,
    auxLeft: CGRect(x: 0, y: 950, width: 665, height: 32), auxRight: CGRect(x: 850, y: 950, width: 662, height: 32),
    isBuiltin: true, scale: 2)

private let wide = ScreenInfo(
    uuid: "ACER", frame: CGRect(x: -928, y: 982, width: 3440, height: 1440),
    visibleFrame: CGRect(x: -928, y: 982, width: 3440, height: 1416), safeTop: 0,
    auxLeft: nil, auxRight: nil, isBuiltin: false, scale: 1)

private var g: NotchGeometry { NotchGeometry.notch(for: mbp)! }
private let frames = [mbp.frame, wide.frame]

/// A menu title / status item on the built-in menu bar (AppKit, y up): x from…to.
private func bar(_ x0: CGFloat, _ x1: CGFloat, top: CGFloat = 982, height: CGFloat = 33) -> CGRect {
    CGRect(x: x0, y: top - height, width: x1 - x0, height: height)
}

/// Chrome on the 14": titles packed up to 657 ("Help" ends 8 pt before the notch).
private let chromeMenus = [bar(62, 160), bar(176, 206), bar(222, 252), bar(268, 312), bar(328, 395), bar(411, 488),
                           bar(504, 572), bar(588, 614), bar(620, 640), bar(640, 657)]
/// The status items measured on this Mac via CGWindowList (leftmost at 942).
private let statusItems = [bar(942, 986), bar(986, 1056), bar(1056, 1094), bar(1381, 1514)]

@Suite("Menu-bar clearance: math")
struct MenuBarClearanceMathTests {
    @Test func chromeMenusAndStatusItems() throws {
        let c = try #require(MenuBarClearance.compute(for: g, screens: frames,
                                                      snapshot: .init(menus: chromeMenus, status: statusItems, trusted: true)))
        #expect(c == MenuBarClearance(left: 8, right: 92, source: .measured))
    }

    @Test func menusOverflowedRightOfTheNotch() throws {
        // Too many menus: macOS moves the last ones right of the notch, before the status items.
        let menus = chromeMenus + [bar(858, 900), bar(916, 930)]
        let c = try #require(MenuBarClearance.compute(for: g, screens: frames,
                                                      snapshot: .init(menus: menus, status: statusItems, trusted: true)))
        #expect(c.left == 8 && c.right == 8)
    }

    @Test func fewMenusAndNoStatusItems() throws {
        let c = try #require(MenuBarClearance.compute(for: g, screens: frames,
                                                      snapshot: .init(menus: [bar(62, 120), bar(136, 170)], status: [], trusted: true)))
        #expect(c.left == 495)          // 665 − 170
        #expect(c.right == 662)         // 1512 − 850
    }

    @Test func noMenusAtAllLeavesTheWholeSide() throws {
        let c = try #require(MenuBarClearance.compute(for: g, screens: frames, snapshot: .init(menus: [], status: [], trusted: true)))
        #expect(c.left == 665 && c.right == 662)
    }

    @Test func statusItemsOnAnotherDisplayDontCount() throws {
        // The ultrawide's own status items (its top edge is y 2422) sit at x 1940… — not ours.
        let theirs = [CGRect(x: 1940, y: 2392, width: 44, height: 30), CGRect(x: 900, y: 2392, width: 44, height: 30)]
        let c = try #require(MenuBarClearance.compute(for: g, screens: frames,
                                                      snapshot: .init(menus: [], status: theirs, trusted: true)))
        #expect(c.right == 662)
    }

    @Test func theMenuBarBackdropIsNotAnItem() throws {
        let c = try #require(MenuBarClearance.compute(for: g, screens: frames,
                                                      snapshot: .init(menus: [], status: [bar(0, 1512)], trusted: true)))
        #expect(c.left == 665 && c.right == 662)
    }

    @Test func aStraddlingItemFillsItsSide() throws {
        let c = try #require(MenuBarClearance.compute(for: g, screens: frames,
                                                      snapshot: .init(menus: [bar(640, 700)], status: [bar(840, 880)], trusted: true)))
        #expect(c.left == 0 && c.right == 0)
    }

    @Test func withoutAccessibilityTheLeftIsAssumedFull() throws {
        let c = try #require(MenuBarClearance.compute(for: g, screens: frames,
                                                      snapshot: .init(menus: nil, status: statusItems, trusted: false)))
        #expect(c == MenuBarClearance(left: MenuBarClearance.unknownLeft, right: 92, source: .estimated))
        // The left wing goes, the right one still clears the first status item.
        #expect(c.clamp(71) == (left: 0, right: 71))
    }

    @Test func externalDisplayPillIsUnaffected() {
        let pill = NotchGeometry.pill(for: wide, menuBarHeight: 24)
        #expect(MenuBarClearance.compute(for: pill, screens: frames,
                                         snapshot: .init(menus: chromeMenus, status: statusItems, trusted: true)) == nil)
        let blocked = MenuBarClearance(left: 0, right: 0, source: .measured)
        let w = SurfaceLayout.wings(left: 40, right: 40, geometry: pill, clearance: blocked)
        #expect(w.left == w.right && w.left > 0)
    }

    @Test func menusReadOnAnotherDisplayAreReplacedWithOverflow() {
        // The ultrawide's menu bar was active: titles from its left edge (x −928), crossing where
        // the built-in notch would be. On the built-in they restart at x 0 and overflow past it.
        let src = [CGRect(x: -928 + 60, y: 2392, width: 500, height: 30), CGRect(x: -928 + 580, y: 2392, width: 120, height: 30)]
        let placed = MenuBarClearance.placed(src, on: g, screens: frames)
        #expect(placed[0].minX == 60 && placed[0].maxY == 982)
        #expect(placed[1].minX == 850)                       // 580…700 crosses 665: moved right of the notch
        let c = MenuBarClearance.compute(for: g, screens: frames, snapshot: .init(menus: src, status: [], trusted: true))
        #expect(c?.left == 105 && c?.right == 0)
    }
}

@Suite("Menu-bar clearance: wings")
struct MenuBarWingTests {
    @Test func clampPerSide() {
        let c = MenuBarClearance(left: 60, right: 300, source: .measured)
        #expect(c.clamp(71) == (left: 54, right: 71))                   // narrowed to room − gap
        #expect(c.clamp(71, need: (40, 40)) == (left: 54, right: 71))
        #expect(c.clamp(71, need: (60, 40)) == (left: 0, right: 71))     // content wouldn't fit: none
        #expect(c.clamp(0) == (left: 0, right: 0))
        let tight = MenuBarClearance(left: 6 + 21, right: 6 + 22, source: .measured)
        #expect(tight.clamp(71) == (left: 0, right: 22))                 // below a dot: nothing
    }

    @Test func gapNeverCoveredEvenWhenPeeking() {
        // Peek grows by half its growth on each side: no more than the gap.
        #expect(Theme.peekGrow.width / 2 <= MenuBarClearance.gap)
        let c = MenuBarClearance(left: 8, right: 92, source: .measured)
        let w = c.clamp(71, need: (50, 71))
        for state in [SurfaceState.activity, .peek] {
            let l = SurfaceLayout.make(state: state, geometry: g, wingLeft: w.left, wingRight: w.right, peekEventContentWidth: 0)
            let f = l.windowFrame(in: g)
            let shapeMinX = f.midX - l.size.width / 2, shapeMaxX = f.midX + l.size.width / 2
            #expect(shapeMinX >= g.notchRect.minX - c.left + MenuBarClearance.gap - Theme.peekGrow.width / 2)
            #expect(shapeMaxX <= g.notchRect.maxX + c.right)
            #expect(shapeMaxX <= 942)                                     // the first status item
        }
    }

    @Test func asymmetricLayoutAndWindow() {
        let l = SurfaceLayout.make(state: .activity, geometry: g, wingLeft: 0, wingRight: 71, peekEventContentWidth: 0)
        #expect(l.size.width == 256)                                 // notch + right wing
        #expect(l.shift == 35.5)
        let f = l.windowFrame(in: g)
        #expect(f.minX == 665 && f.maxX == 921)                   // nothing left of the notch
        #expect(l.slots(notchWidth: 185) == (left: 0, right: 71))
        // The SwiftUI root is centred on the notch and covers the window.
        let h = SurfaceLayout.hostFrame(in: g, window: f)
        #expect(h.midX == g.notchRect.midX && h.minX <= f.minX && h.maxX >= f.maxX)
        // Symmetric wings: unchanged from before.
        let s = SurfaceLayout.make(state: .activity, geometry: g, wing: 42, peekEventContentWidth: 0)
        #expect(s.shift == 0 && s.size.width == 269 && s.wing == 42)
        #expect(SurfaceLayout.hostFrame(in: g, window: s.windowFrame(in: g)) == s.windowFrame(in: g))
    }

    @Test func expandedAndPeekEventStayCentred() {
        for state in [SurfaceState.expanded, .peekEvent] {
            let l = SurfaceLayout.make(state: state, geometry: g, wingLeft: 0, wingRight: 71, peekEventContentWidth: 200)
            #expect(l.shift == 0)
            #expect(abs(l.windowFrame(in: g).midX - g.notchRect.midX) <= 0.5)
        }
    }

    @MainActor @Test func modelReclampsWhenTheMenuBarChanges() {
        let m = SurfaceModel(geometry: g)
        m.animates = false
        let r = FrameRecorder(m.layout.windowFrame(in: g))
        m.delegate = r
        m.setActivity(present: true, left: 30, right: 49)          // wing 71 both sides
        #expect(r.frame.width == 327)                              // 185 + 2 × 71
        m.setClearance(MenuBarClearance(left: 8, right: 92, source: .measured))   // Chrome came forward
        #expect(m.wings == (left: 0, right: 71))
        #expect(r.frame == CGRect(x: 665, y: 946, width: 256, height: 36))
        m.setClearance(MenuBarClearance(left: 8, right: 10, source: .measured))   // both sides full
        #expect(m.state == .activity && m.wing == 0)
        #expect(r.frame.width == 185)                               // just the notch
        m.setClearance(nil)
        #expect(m.wings == (left: 71, right: 71))
    }
}

@Suite("Menu-bar clearance: reading")
struct MenuBarReadingTests {
    @Test func statusItemsFromTheWindowList() {
        let own: pid_t = 777
        func w(_ layer: Int, _ pid: Int, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ h: CGFloat) -> [String: Any] {
            [kCGWindowLayer as String: layer, kCGWindowOwnerPID as String: pid,
             kCGWindowBounds as String: CGRect(x: x, y: y, width: width, height: h).dictionaryRepresentation]
        }
        let list = [
            w(25, 652, 942, 0, 44, 33),          // a status item (CG: y down from the primary's top)
            w(25, 652, 1940, -1440, 44, 30),     // one on the ultrawide above
            w(24, 405, 0, 0, 1512, 33),          // the menu-bar backdrop
            w(27, 777, 594, 0, 327, 36),         // our own panel
            w(25, 777, 600, 0, 40, 33),          // ours again, at the status level
            w(20, 651, 0, 0, 1512, 982),         // the Dock
            w(0, 99, 100, 100, 400, 300),        // an app window
        ]
        let items = MenuBarReader.statusItems(in: list, excluding: own, primaryHeight: 982)
        #expect(items == [CGRect(x: 942, y: 949, width: 44, height: 33), CGRect(x: 1940, y: 2392, width: 44, height: 30)])
    }

    @MainActor @Test func watcherFallsBackWithoutAccessibility() async throws {
        let w = MenuBarWatcher(reader: .init(menus: { _ in Issue.record("AX read while untrusted"); return [] },
                                             status: { statusItems }, trusted: { false }, owner: { 42 }),
                               observes: false)
        var changes = 0
        w.onChange = { changes += 1 }
        w.refresh()
        for _ in 0..<200 where w.snapshot == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(w.snapshot == MenuBarSnapshot(menus: nil, status: statusItems, trusted: false))
        #expect(w.needsAccessibility && changes == 1)
    }

    @MainActor @Test func watcherCachesMenusPerApp() async throws {
        final class Count: @unchecked Sendable { var n = 0 }
        let count = Count()
        let w = MenuBarWatcher(reader: .init(menus: { _ in count.n += 1; return chromeMenus },
                                             status: { statusItems }, trusted: { true }, owner: { 42 }),
                               observes: false)
        w.refresh()
        for _ in 0..<200 where w.snapshot == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(w.snapshot?.menus == chromeMenus && !w.needsAccessibility)
        // Another app was in front meanwhile; coming back applies the cached menus at once.
        w.apply(MenuBarSnapshot(menus: [bar(62, 100)], status: statusItems, trusted: true))
        w.refresh()
        #expect(w.snapshot?.menus == chromeMenus)                  // synchronously, before the re-read
        for _ in 0..<200 where count.n < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(count.n == 2)
    }

    @MainActor @Test func managerAppliesClearanceToNotchesOnly() throws {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "glancy.test.menubar.\(UUID().uuidString)")!)
        settings.externalPill = true
        let context = SurfaceContext(hub: ActivityHub(), settings: settings, launchAtLogin: LaunchAtLogin(), modules: [])
        let watcher = MenuBarWatcher(reader: nil, observes: false)
        let manager = SurfaceManager(context: context, screens: { [mbp, wide] }, fullscreenSpaces: { [] },
                                     events: SystemEvents(workspace: NotificationCenter(), distributed: NotificationCenter(),
                                                          app: NotificationCenter(), observesDock: false),
                                     menuBar: watcher, presents: false)
        manager.start()
        defer { manager.stop() }
        watcher.apply(MenuBarSnapshot(menus: nil, status: statusItems, trusted: false))
        let notch = try #require(manager.surface("BUILTIN"))
        let pill = try #require(manager.surface("ACER"))
        #expect(notch.model.clearance == MenuBarClearance(left: 8, right: 92, source: .estimated))
        #expect(pill.model.clearance == nil)
        #expect(manager.menuBarNeedsAccessibility)
        notch.displayForTest()      // the wings view's first pass (no activity in the hub) is behind us
        notch.model.setActivity(present: true, left: 30, right: 49)
        #expect(notch.model.wings == (left: 0, right: 71))
        #expect(notch.panelFrame.minX == 665)                       // nothing over the menus
        #expect(notch.panelFrame.maxX == 921)
        // The host stays centred on the notch inside the off-centre window.
        #expect(notch.hostBoundsForTest.width == 327)              // 2 × 163.5
    }

    /// Opt-in live reading of this Mac's menu bar (read only): GLANCY_LIVE_MENUBAR=1 swift test --filter liveReading
    @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["GLANCY_LIVE_MENUBAR"] == "1"))
    func liveReading() async throws {
        let w = MenuBarWatcher(observes: false)
        w.refresh()
        for _ in 0..<400 where w.snapshot == nil { try await Task.sleep(for: .milliseconds(5)) }
        let snap = try #require(w.snapshot)
        let owner = NSWorkspace.shared.menuBarOwningApplication
        print("LIVE owner=\(owner?.localizedName ?? "nil") pid=\(owner?.processIdentifier ?? 0) AXtrusted=\(snap.trusted)")
        print("LIVE menus=\(snap.menus.map { $0.map { "\(Int($0.minX))…\(Int($0.maxX))" }.joined(separator: " ") } ?? "unknown (no AX)")")
        print("LIVE status=\(snap.status.sorted { $0.minX < $1.minX }.map { "\(Int($0.minX))…\(Int($0.maxX))@y\(Int($0.minY))" }.joined(separator: " "))")
        let screens = NSScreen.screens.compactMap(\.info)
        for s in screens {
            guard let g = NotchGeometry.notch(for: s) else { print("LIVE screen \(s.frame): no notch → pill, unaffected"); continue }
            let c = MenuBarClearance.compute(for: g, screens: screens.map(\.frame), snapshot: snap)
            let wings = SurfaceLayout.wings(left: 49, right: 49, geometry: g, clearance: c)
            print("LIVE notch \(g.notchRect) clearance=\(String(describing: c)) → wings for a 71 pt activity: \(wings)")
        }
    }
}

@Suite("Menu-bar clearance: drop-downs")
struct MenuBarClearanceDropDownTests {
    private let chrome = MenuBarClearance(left: 8, right: 92, source: .measured)

    @Test func aWideDropDownKeepsToTheFreeRoomInTheMenuBar() {
        let l = SurfaceLayout.make(state: .peekEvent, geometry: g, wingLeft: 0, wingRight: 0,
                                   peekEventContentWidth: 380, clearance: chrome)
        let notch = g.notchRect.width
        // The top edge on each side ends where the free room ends (room − gap from the notch).
        #expect(l.size.width / 2 - l.bandInsetLeft <= notch / 2 + max(0, 8 - MenuBarClearance.gap))
        #expect(l.size.width / 2 - l.bandInsetRight <= notch / 2 + 92 - MenuBarClearance.gap)
        #expect(l.bandInsetLeft > 0 && l.bandInsetRight > 0)
        #expect(l.bandHeight == g.notchRect.height)

        let shape = NotchShape(topRadius: l.topRadius, bottomRadius: l.bottomRadius, bandInsetLeft: l.bandInsetLeft,
                               bandInsetRight: l.bandInsetRight, bandHeight: l.bandHeight)
        let path = shape.path(in: CGRect(origin: .zero, size: l.size))   // y down, like SwiftUI
        // Over "Help", just left of the notch: free. Below the menu bar, same x: the drop-down.
        let overHelp = CGPoint(x: l.size.width / 2 - notch / 2 - 12, y: 10)
        #expect(!path.contains(overHelp))
        #expect(path.contains(CGPoint(x: overHelp.x, y: l.bandHeight + 16)))
        // Wide at the bottom: the full width is used below the band.
        #expect(path.contains(CGPoint(x: 20, y: l.bandHeight + 16)))
    }

    @Test func noClearanceOrAPillKeepsThePlainShape() {
        let l = SurfaceLayout.make(state: .peekEvent, geometry: g, wingLeft: 0, wingRight: 0, peekEventContentWidth: 380)
        #expect(l.bandInsetLeft == 0 && l.bandInsetRight == 0)
        let roomy = MenuBarClearance(left: 600, right: 600, source: .measured)
        let r = SurfaceLayout.make(state: .peekEvent, geometry: g, wingLeft: 0, wingRight: 0,
                                   peekEventContentWidth: 380, clearance: roomy)
        #expect(r.bandInsetLeft == 0 && r.bandInsetRight == 0)
    }
}
