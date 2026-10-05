// Tiling — displays, usable rects and the one AX↔Cocoa conversion boundary.
//
// Cocoa coordinates: origin at the bottom-left of the primary display, y up (NSScreen).
// AX / CoreGraphics window coordinates: origin at the top-left of the primary display, y down.
// The primary display is always `NSScreen.screens[0]` (never `NSScreen.main`, which is the
// display with the key window). Stage Manager handling adapted from Rectangle's StageUtil
// (MIT, see NOTICE.md).

import AppKit
import CoreGraphics

/// A display as the tiling engine sees it. Keyed by UUID, which survives reconnects (the
/// CGDirectDisplayID can change).
public struct Display: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayID: CGDirectDisplayID
    public let name: String
    /// Cocoa coordinates.
    public let frame: CGRect
    public let visibleFrame: CGRect
    /// `visibleFrame` minus the Stage Manager strip when it is showing on this display.
    public let usableFrame: CGRect
    public let isBuiltIn: Bool

    public init(id: String, displayID: CGDirectDisplayID, name: String, frame: CGRect,
                visibleFrame: CGRect, usableFrame: CGRect, isBuiltIn: Bool) {
        self.id = id; self.displayID = displayID; self.name = name; self.frame = frame
        self.visibleFrame = visibleFrame; self.usableFrame = usableFrame; self.isBuiltIn = isBuiltIn
    }
}

public enum ScreenSpace {

    // MARK: Pure conversion

    /// Cocoa ↔ AX. The flip is its own inverse: y' = H − y − h, with H the primary display height.
    public static func flip(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The usable rect: `visibleFrame` minus a Stage Manager strip of `stripWidth` on one side.
    public static func usableRect(visibleFrame: CGRect, stripWidth: CGFloat, stripOnLeft: Bool) -> CGRect {
        guard stripWidth > 0, stripWidth < visibleFrame.width / 2 else { return visibleFrame }
        var r = visibleFrame
        if stripOnLeft { r.origin.x += stripWidth }
        r.size.width -= stripWidth
        return r
    }

    /// The display a window belongs to: full containment first, then largest overlap, then the
    /// display whose centre is nearest. Nil only when `frames` is empty.
    public static func bestIndex(for rect: CGRect, among frames: [CGRect]) -> Int? {
        guard !frames.isEmpty else { return nil }
        if let i = frames.firstIndex(where: { $0.contains(rect) }) { return i }
        var best: (index: Int, area: CGFloat)?
        for (i, f) in frames.enumerated() {
            let inter = f.intersection(rect)
            guard !inter.isNull else { continue }
            let area = inter.width * inter.height
            if area > (best?.area ?? 0) { best = (i, area) }
        }
        if let best { return best.index }
        let c = CGPoint(x: rect.midX, y: rect.midY)
        return frames.indices.min { a, b in
            hypot(frames[a].midX - c.x, frames[a].midY - c.y) < hypot(frames[b].midX - c.x, frames[b].midY - c.y)
        }
    }

    // MARK: Live

    /// Height of the primary display (`NSScreen.screens[0]`), the anchor AX measures from.
    @MainActor public static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    @MainActor public static func toAX(_ rect: CGRect) -> CGRect { flip(rect, primaryHeight: primaryHeight) }
    @MainActor public static func fromAX(_ rect: CGRect) -> CGRect { flip(rect, primaryHeight: primaryHeight) }

    /// Stable display key: `CGDisplayCreateUUIDFromDisplayID`, falling back to the display ID.
    public static func uuid(for displayID: CGDirectDisplayID) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let string = CFUUIDCreateString(nil, uuid) as String? else { return "display-\(displayID)" }
        return string
    }

    /// Every connected display, in `NSScreen.screens` order (the primary first).
    @MainActor public static func displays() -> [Display] {
        let stage = StageManager.current()
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            let strip = stage.stripWidth(on: screen.frame)
            return Display(id: uuid(for: id), displayID: id, name: screen.localizedName,
                           frame: screen.frame, visibleFrame: screen.visibleFrame,
                           usableFrame: usableRect(visibleFrame: screen.visibleFrame, stripWidth: strip,
                                                   stripOnLeft: stage.stripOnLeft),
                           isBuiltIn: CGDisplayIsBuiltin(id) != 0)
        }
    }

    /// The display a Cocoa rect belongs to.
    @MainActor public static func display(for rect: CGRect, in displays: [Display]) -> Display? {
        bestIndex(for: rect, among: displays.map(\.frame)).map { displays[$0] }
    }

    /// The display under the mouse pointer.
    @MainActor public static func displayUnderMouse(in displays: [Display]) -> Display? {
        let p = NSEvent.mouseLocation
        return displays.first { $0.frame.contains(p) } ?? displays.first
    }
}

/// Stage Manager state, read from the WindowManager and Dock defaults plus the strip's windows.
struct StageManager {
    var enabled: Bool
    var stripShown: Bool
    var stripOnLeft: Bool
    /// Strip windows (Cocoa frames) owned by the WindowManager process.
    var stripWindowFrames: [CGRect]
    /// Rectangle's default strip allowance.
    static let defaultStripWidth: CGFloat = 190

    func stripWidth(on screenFrame: CGRect) -> CGFloat {
        guard enabled, stripShown else { return 0 }
        // A single WindowManager window can be the one being dragged; the strip has several.
        let onThisScreen = stripWindowFrames.filter { screenFrame.intersects($0) }
        return onThisScreen.count >= 2 ? Self.defaultStripWidth : 0
    }

    @MainActor static func current() -> StageManager {
        let wm = UserDefaults(suiteName: "com.apple.WindowManager")
        let enabled = wm?.object(forKey: "GloballyEnabled") as? Bool ?? false
        guard enabled else { return StageManager(enabled: false, stripShown: false, stripOnLeft: true, stripWindowFrames: []) }
        let autoHide = wm?.object(forKey: "AutoHide") as? Bool ?? false
        let orientation = UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation")
        let onLeft: Bool
        switch orientation {
        case "left": onLeft = false
        case "right": onLeft = true
        default: onLeft = Locale.current.language.characterDirection != .rightToLeft
        }
        var frames: [CGRect] = []
        if !autoHide, let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                            kCGNullWindowID) as? [[String: Any]] {
            let h = ScreenSpace.primaryHeight
            for info in list where (info[kCGWindowOwnerName as String] as? String) == "WindowManager" {
                guard let dict = info[kCGWindowBounds as String] as? NSDictionary,
                      let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
                frames.append(ScreenSpace.flip(bounds, primaryHeight: h))
            }
        }
        return StageManager(enabled: true, stripShown: !autoHide, stripOnLeft: onLeft, stripWindowFrames: frames)
    }
}
