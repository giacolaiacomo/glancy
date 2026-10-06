import AppKit
import ApplicationServices

// Where the menu bar is busy, so the collapsed wings never sit on a menu title or a status item
// (SPEC §1.3 "Never covers menu-bar items by accident").
//
// - App menus: Accessibility (the menu-bar owner's AXMenuBar children), only when the process is
//   already trusted — never a prompt. Off the main thread, 0.25 s messaging timeout, cached per pid.
// - Status items / menu-bar extras: CGWindowList windows at the status level on the top band.
//   Their bounds need no Screen Recording permission (verified on macOS 26.6: names may be blank,
//   bounds are always there).
// - Without Accessibility the left side is assumed busy right up to the notch (see
//   `MenuBarClearance.unknownLeft`): menus can't be measured any other way, and a hidden left
//   wing costs less than a wing over "Help".
//
// Everything is recomputed on events only (app activated / launched / terminated, screens changed,
// Accessibility granted, an activity appearing). No timers.

/// What the menu bar looks like right now, in AppKit global coordinates (y up).
public struct MenuBarSnapshot: Equatable, Sendable {
    /// The frontmost app's menu titles (Apple menu excluded). nil = unknown (no Accessibility).
    public var menus: [CGRect]?
    /// Status items and menu-bar extras, every display.
    public var status: [CGRect]
    /// Whether Accessibility was available for the read.
    public var trusted: Bool

    public init(menus: [CGRect]?, status: [CGRect], trusted: Bool) {
        self.menus = menus; self.status = status; self.trusted = trusted
    }
}

/// The free room either side of one notch: from the last app menu on the left to `notch.minX`,
/// and from `notch.maxX` to the first status item (or overflowed menu) on the right.
public struct MenuBarClearance: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// Menus measured through Accessibility.
        case measured
        /// No Accessibility: the left side is an assumption (`unknownLeft`), the right side is measured.
        case estimated
    }

    public var left: CGFloat
    public var right: CGFloat
    public var source: Source

    public init(left: CGFloat, right: CGFloat, source: Source) {
        self.left = left; self.right = right; self.source = source
    }

    /// Kept free between a wing and the nearest menu-bar item. Equal to the hover growth per side
    /// (`Theme.peekGrow.width / 2`), so a peek never reaches the item either.
    public static let gap: CGFloat = 6
    /// Below this a wing can't hold even a dot or an icon: the side shows nothing.
    public static let minUsefulWing: CGFloat = 22
    /// Without Accessibility the app's menus can't be measured: assume they reach `notch.minX − 8`
    /// (macOS packs menus right up to the notch on any app with a full menu set — Chrome, Xcode,
    /// Office — and only then overflows them to the right). The left wing is then hidden; the right
    /// one still avoids the measured status items.
    public static let unknownLeft: CGFloat = 8
    /// Rects within this of the notch edge count as that side.
    static let tolerance: CGFloat = 1

    /// The clearance for one display. nil for a pill (a display without a notch keeps its own cap).
    /// `screens` are every display's frame, to place menus reported on another display.
    public static func compute(for g: NotchGeometry, screens: [CGRect], snapshot: MenuBarSnapshot) -> MenuBarClearance? {
        guard g.kind == .notch else { return nil }
        let notch = g.notchRect
        let screen = g.screenFrame
        var leftEdge = screen.minX, rightEdge = screen.maxX

        func onTopBand(_ r: CGRect) -> Bool {
            r.width > 0 && r.midX >= screen.minX && r.midX <= screen.maxX
                && r.maxY >= screen.maxY - 2 && r.minY < screen.maxY
        }

        for s in snapshot.status where onTopBand(s) && s.width < screen.width / 2 {
            if s.maxX <= notch.minX + tolerance { leftEdge = max(leftEdge, s.maxX) }
            else { rightEdge = min(rightEdge, max(s.minX, notch.maxX)) }   // straddling the notch: right side full
        }

        var source = Source.measured
        if let menus = snapshot.menus {
            for m in placed(menus, on: g, screens: screens) where m.width > 0 {
                if m.maxX <= notch.minX + tolerance { leftEdge = max(leftEdge, m.maxX) }
                else if m.minX >= notch.maxX - tolerance { rightEdge = min(rightEdge, m.minX) }
                else { leftEdge = max(leftEdge, notch.minX) }   // straddling: treat the left as full
            }
        } else {
            source = .estimated
            leftEdge = max(leftEdge, notch.minX - unknownLeft)
        }
        return MenuBarClearance(left: max(0, notch.minX - leftEdge), right: max(0, rightEdge - notch.maxX), source: source)
    }

    /// Menus as they sit on `g`'s display. AX reports them on the display whose menu bar is
    /// active; another display shows the same titles at the same offsets from its left edge,
    /// except that a notch pushes the titles that would cross it to its right (macOS overflow).
    static func placed(_ menus: [CGRect], on g: NotchGeometry, screens: [CGRect]) -> [CGRect] {
        let sorted = menus.sorted { $0.minX < $1.minX }
        guard let first = sorted.first else { return [] }
        let here = g.screenFrame
        let source = screens.first { $0.minX <= first.midX && first.midX <= $0.maxX && abs($0.maxY - first.maxY) < 40 }
        guard let source, source != here else { return sorted }
        let dx = here.minX - source.minX
        var shift: CGFloat = 0
        var out: [CGRect] = []
        for m in sorted {
            var r = m.offsetBy(dx: dx + shift, dy: here.maxY - source.maxY)
            if shift == 0, r.maxX > g.notchRect.minX {
                shift = g.notchRect.maxX - r.minX
                r = r.offsetBy(dx: shift, dy: 0)
            }
            out.append(r)
        }
        return out
    }

    /// The wings for content wanting `wing` on each side, where each side's own content needs
    /// `need` (content + padding): a side is narrowed to its room minus the gap, and dropped when
    /// that can't hold its content (a clipped half-icon reads as a glitch) or even a dot.
    public func clamp(_ wing: CGFloat, need: (left: CGFloat, right: CGFloat) = (0, 0)) -> (left: CGFloat, right: CGFloat) {
        func side(_ room: CGFloat, _ need: CGFloat) -> CGFloat {
            let w = min(wing, (room - Self.gap).rounded(.down))
            return w >= max(Self.minUsefulWing, min(need, wing)) ? w : 0
        }
        guard wing > 0 else { return (0, 0) }
        return (side(left, need.left), side(right, need.right))
    }
}

// MARK: - Reading the system

enum MenuBarReader {
    /// Height of the primary display (the one at the CG origin), to flip CG / AX rects (y down)
    /// into AppKit global coordinates (y up). Safe off the main thread.
    static var primaryHeight: CGFloat { CGDisplayBounds(CGMainDisplayID()).height }

    static func toAppKit(_ r: CGRect, primaryHeight h: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    /// The menu titles of `pid`'s menu bar, Apple menu excluded. nil when not trusted or the app
    /// didn't answer within the timeout. Never prompts.
    static func menus(pid: pid_t, primaryHeight h: CGFloat) -> [CGRect]? {
        guard Lab.accessibilityTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var barRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &barRef) == .success,
              let barRef, CFGetTypeID(barRef) == AXUIElementGetTypeID() else { return nil }
        let bar = barRef as! AXUIElement   // swiftlint:disable:this force_cast — type checked above
        AXUIElementSetMessagingTimeout(bar, 0.25)
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }
        var out: [CGRect] = []
        for (i, item) in children.enumerated() where i > 0 {   // 0 = the Apple menu
            var values: CFArray?
            let attrs = [kAXPositionAttribute, kAXSizeAttribute] as CFArray
            guard AXUIElementCopyMultipleAttributeValues(item, attrs, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
                  let list = values as? [AnyObject], list.count == 2,
                  CFGetTypeID(list[0]) == AXValueGetTypeID(), CFGetTypeID(list[1]) == AXValueGetTypeID() else { continue }
            var p = CGPoint.zero, s = CGSize.zero
            guard AXValueGetValue(list[0] as! AXValue, .cgPoint, &p),   // swiftlint:disable:this force_cast
                  AXValueGetValue(list[1] as! AXValue, .cgSize, &s), s.width > 0 else { continue }   // swiftlint:disable:this force_cast
            out.append(toAppKit(CGRect(origin: p, size: s), primaryHeight: h))
        }
        return out
    }

    /// Status items and menu-bar extras on every display: on-screen windows at the status level
    /// (25) or the main-menu level (24), excluding the menu-bar backdrop itself (full width) and
    /// our own windows. Bounds come without Screen Recording permission.
    static func statusItems(excluding own: pid_t, primaryHeight h: CGFloat) -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return statusItems(in: list, excluding: own, primaryHeight: h)
    }

    static func statusItems(in list: [[String: Any]], excluding own: pid_t, primaryHeight h: CGFloat) -> [CGRect] {
        var out: [CGRect] = []
        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 24 || layer == 25,
                  (w[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) }) != own,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: dict as CFDictionary),
                  b.width > 0, b.width < 600, b.height <= 60 else { continue }
            out.append(toAppKit(b, primaryHeight: h))
        }
        return out
    }
}

/// Keeps a `MenuBarSnapshot` current, from events only. One per `SurfaceManager`.
@MainActor
final class MenuBarWatcher {
    /// The reads, off the main thread: menus of a pid (nil pid or untrusted → nil) and status items.
    struct Reader: Sendable {
        var menus: @Sendable (pid_t) -> [CGRect]?
        var status: @Sendable () -> [CGRect]
        var trusted: @Sendable () -> Bool
        var owner: @MainActor () -> pid_t?

        static let system = Reader(
            menus: { MenuBarReader.menus(pid: $0, primaryHeight: MenuBarReader.primaryHeight) },
            status: { MenuBarReader.statusItems(excluding: getpid(), primaryHeight: MenuBarReader.primaryHeight) },
            trusted: { Lab.accessibilityTrusted() },
            owner: { NSWorkspace.shared.menuBarOwningApplication?.processIdentifier })
    }

    private(set) var snapshot: MenuBarSnapshot?
    var onChange: (() -> Void)?
    /// Whether the wings would avoid the menus better with Accessibility (Settings / Permissions).
    var needsAccessibility: Bool { snapshot.map { !$0.trusted } ?? false }

    private let reader: Reader?
    private let observes: Bool
    private var cache: [pid_t: [CGRect]] = [:]
    private var generation = 0
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var axRetry: Task<Void, Never>?
    private(set) var reads = 0

    /// `reader` nil: inert (tests that don't care); `observes` false: no system notifications.
    init(reader: Reader? = .system, observes: Bool = true) {
        self.reader = reader; self.observes = observes
    }

    func start() {
        guard observes, tokens.isEmpty else { refresh(); return }
        let ws = NSWorkspace.shared.notificationCenter
        add(ws, NSWorkspace.didActivateApplicationNotification) { me, _ in me.refresh() }
        add(ws, NSWorkspace.didLaunchApplicationNotification) { me, _ in me.refresh() }
        add(ws, NSWorkspace.didTerminateApplicationNotification) { me, note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let pid = app?.processIdentifier { me.cache[pid] = nil }
            me.refresh()
        }
        add(.default, NSApplication.didChangeScreenParametersNotification) { me, _ in
            // Overflow depends on the screen's width: every cached layout is stale.
            me.cache.removeAll()
            me.refresh()
        }
        // Accessibility granted or revoked: the TCC write lands just after this notification.
        add(DistributedNotificationCenter.default(), Notification.Name("com.apple.accessibility.api")) { me, _ in
            me.axRetry?.cancel()
            me.axRetry = Task { [weak me] in
                try? await Delay.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                me?.cache.removeAll()
                me?.refresh()
            }
        }
        refresh()
    }

    func stop() {
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
        axRetry?.cancel(); axRetry = nil
        generation += 1
    }

    var observerCount: Int { tokens.count }

    /// Reads the menu bar again. A cached menu layout for the owner is applied at once (no wing
    /// flicker on app switches), then refreshed off the main thread.
    func refresh() {
        guard let reader else { return }
        generation += 1
        let gen = generation
        let pid = reader.owner()
        let trusted = reader.trusted()
        if let pid, trusted, let cached = cache[pid] {
            apply(MenuBarSnapshot(menus: cached, status: snapshot?.status ?? [], trusted: true))
        }
        reads += 1
        Task.detached(priority: .utility) {
            let menus = trusted ? pid.flatMap { reader.menus($0) } : nil
            let status = reader.status()
            let snap = MenuBarSnapshot(menus: menus, status: status, trusted: trusted)
            await MainActor.run { [weak self] in
                guard let self, self.generation == gen else { return }
                // An app still launching has no menus yet: don't cache that.
                if let pid, let menus, !menus.isEmpty { self.cache[pid] = menus }
                self.apply(snap)
            }
        }
    }

    /// Installs a snapshot (tests call this directly).
    func apply(_ s: MenuBarSnapshot) {
        guard s != snapshot else { return }
        snapshot = s
        onChange?()
    }

    private func add(_ center: NotificationCenter, _ name: Notification.Name,
                     _ body: @escaping @MainActor (MenuBarWatcher, Notification) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            nonisolated(unsafe) let note = note
            MainActor.assumeIsolated {
                guard let self else { return }
                body(self, note)
            }
        }
        tokens.append((center, token))
    }
}
