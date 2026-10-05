// Tiling — thin, synchronous Accessibility helpers. Every call here is an IPC round trip to
// another app: call them only from that app's `AppHandle` thread, never from the main thread.

import ApplicationServices
import CoreGraphics
import Foundation

/// Private but stable since 10.x; used by Rectangle, Loop, AeroSpace and yabai.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

enum AXAttr {
    static let windows = kAXWindowsAttribute as String
    static let focusedWindow = kAXFocusedWindowAttribute as String
    static let mainWindow = kAXMainWindowAttribute as String
    static let position = kAXPositionAttribute as String
    static let size = kAXSizeAttribute as String
    static let title = kAXTitleAttribute as String
    static let role = kAXRoleAttribute as String
    static let subrole = kAXSubroleAttribute as String
    static let identifier = kAXIdentifierAttribute as String
    static let minimized = kAXMinimizedAttribute as String
    static let focused = kAXFocusedAttribute as String
    static let main = kAXMainAttribute as String
    static let enabled = kAXEnabledAttribute as String
    static let closeButton = kAXCloseButtonAttribute as String
    static let minimizeButton = kAXMinimizeButtonAttribute as String
    static let zoomButton = kAXZoomButtonAttribute as String
    static let fullscreenButton = kAXFullScreenButtonAttribute as String
    static let fullscreen = "AXFullScreen"
    static let minSize = "AXMinSize"
    static let minimumSize = "AXMinimumSize"
    static let enhancedUserInterface = "AXEnhancedUserInterface"
    static let focusedUIElement = kAXFocusedUIElementAttribute as String
    static let window = kAXWindowAttribute as String
    static let parent = kAXParentAttribute as String
}

extension AXUIElement {
    func raw(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    func string(_ attribute: String) -> String? { raw(attribute) as? String }

    func bool(_ attribute: String) -> Bool? {
        guard let v = raw(attribute) else { return nil }
        if CFGetTypeID(v) == CFBooleanGetTypeID() { return CFBooleanGetValue((v as! CFBoolean)) }
        return (v as? NSNumber)?.boolValue
    }

    func element(_ attribute: String) -> AXUIElement? {
        guard let v = raw(attribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    func elements(_ attribute: String) -> [AXUIElement] {
        guard let array = raw(attribute) as? [AnyObject] else { return [] }
        return array.compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? (item as! AXUIElement) : nil
        }
    }

    func point(_ attribute: String) -> CGPoint? {
        guard let v = raw(attribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var out = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &out) ? out : nil
    }

    func size(_ attribute: String) -> CGSize? {
        guard let v = raw(attribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var out = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &out) ? out : nil
    }

    /// Frame in AX coordinates (top-left origin).
    var axFrame: CGRect? {
        guard let p = point(AXAttr.position), let s = size(AXAttr.size) else { return nil }
        return CGRect(origin: p, size: s)
    }

    @discardableResult
    func setPosition(_ point: CGPoint) -> AXError {
        var p = point
        guard let value = AXValueCreate(.cgPoint, &p) else { return .failure }
        return AXUIElementSetAttributeValue(self, AXAttr.position as CFString, value)
    }

    @discardableResult
    func setSize(_ size: CGSize) -> AXError {
        var s = size
        guard let value = AXValueCreate(.cgSize, &s) else { return .failure }
        return AXUIElementSetAttributeValue(self, AXAttr.size as CFString, value)
    }

    @discardableResult
    func setBool(_ attribute: String, _ value: Bool) -> AXError {
        AXUIElementSetAttributeValue(self, attribute as CFString, (value ? kCFBooleanTrue : kCFBooleanFalse))
    }

    func isSettable(_ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(self, attribute as CFString, &settable) == .success else { return false }
        return settable.boolValue
    }

    /// The CGWindowID behind this window element, when the private call answers.
    var windowID: CGWindowID? {
        var id = CGWindowID(0)
        return _AXUIElementGetWindow(self, &id) == .success && id != 0 ? id : nil
    }

    var pid: pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(self, &pid) == .success ? pid : nil
    }

    /// AXMinSize, or the older AXMinimumSize.
    var minimumSize: CGSize? { size(AXAttr.minSize) ?? size(AXAttr.minimumSize) }
}

/// What CGWindowList says about one window. Bounds are in AX (top-left) coordinates.
public struct CGWindowInfo: Sendable, Equatable {
    public let id: CGWindowID
    public let pid: pid_t
    public let layer: Int
    public let alpha: Double
    public let bounds: CGRect
    public let ownerName: String

    /// On-screen windows of the current Space, front to back.
    public static func onScreen() -> [CGWindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let number = info[kCGWindowNumber as String] as? NSNumber,
                  let pid = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return nil }
            return CGWindowInfo(id: CGWindowID(number.uint32Value), pid: pid.int32Value,
                                layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                                alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                                bounds: bounds,
                                ownerName: info[kCGWindowOwnerName as String] as? String ?? "")
        }
    }
}