import CoreGraphics
import Foundation
import ObjectiveC

/// Built-in display brightness through the private DisplayServices framework (dlsym), the way
/// the system's own brightness keys do it. Every call reports failure instead of guessing.
final class DisplayBrightness: @unchecked Sendable {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private let getFn: GetFn?
    private let setFn: SetFn?

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        getFn = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: GetFn.self) }
        setFn = handle.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: SetFn.self) }
    }

    var isAvailable: Bool { getFn != nil && setFn != nil }

    func get(_ display: CGDirectDisplayID) -> Float? {
        guard let getFn else { return nil }
        var value: Float = 0
        return getFn(display, &value) == 0 ? value : nil
    }

    func set(_ display: CGDirectDisplayID, _ value: Float) -> Bool {
        guard let setFn else { return false }
        return setFn(display, value) == 0
    }

    /// The built-in display under the mouse cursor, or nil when the cursor is on another display
    /// (brightness keys then belong to whatever drives that display: pass through).
    static func builtInDisplayUnderCursor() -> CGDirectDisplayID? {
        guard let cursor = CGEvent(source: nil)?.location else { return nil }
        var id = CGDirectDisplayID(0)
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(cursor, 1, &id, &count) == .success, count == 1 else { return nil }
        return CGDisplayIsBuiltin(id) != 0 ? id : nil
    }
}

/// Keyboard backlight through the private CoreBrightness `KeyboardBrightnessClient`.
/// Created lazily and used only on the event-tap thread.
final class KeyboardBacklight {
    private typealias GetFn = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias SetFn = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
    private let client: NSObject
    private let keyboard: UInt64
    private let getFn: GetFn
    private let setFn: SetFn
    private static let getSel = NSSelectorFromString("brightnessForKeyboard:")
    private static let setSel = NSSelectorFromString("setBrightness:forKeyboard:")

    init?() {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil,
              let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
        let client = cls.init()
        guard client.responds(to: Self.getSel), client.responds(to: Self.setSel),
              let getImp = client.method(for: Self.getSel), let setImp = client.method(for: Self.setSel) else { return nil }
        self.client = client
        getFn = unsafeBitCast(getImp, to: GetFn.self)
        setFn = unsafeBitCast(setImp, to: SetFn.self)
        // The built-in keyboard's backlight id; 1 on every MacBook so far.
        var id: UInt64 = 1
        let copyIDs = NSSelectorFromString("copyKeyboardBacklightIDs")
        if client.responds(to: copyIDs), let ids = client.perform(copyIDs)?.takeRetainedValue() as? [NSNumber], let first = ids.first {
            id = first.uint64Value
        }
        keyboard = id
    }

    func get() -> Float { getFn(client, Self.getSel, keyboard) }
    func set(_ value: Float) -> Bool { setFn(client, Self.setSel, value, keyboard) }
}
