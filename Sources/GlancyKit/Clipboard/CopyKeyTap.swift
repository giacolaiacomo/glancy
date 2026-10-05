import AppKit
import ApplicationServices

/// A listen-only `CGEventTap` on keyDown that reports ⌘C / ⌘X (SPEC §3 Clipboard: no polling).
/// The tap's source runs on the main run loop; its callback is O(1) and allocation-free for every
/// other key. Needs Input Monitoring (or Accessibility); without it `install()` returns false and
/// the module falls back to app switches and panel opens.
@MainActor
final class CopyKeyTap {
    var onCopyKey: (() -> Void)?
    private(set) var installed = false
    fileprivate var port: CFMachPort?
    private var source: CFRunLoopSource?

    /// Whether the system lets us see key events (never prompts).
    static var permitted: Bool { CGPreflightListenEventAccess() || AXIsProcessTrusted() }

    /// Asks for Input Monitoring (the system prompt / Settings pane). User-initiated only.
    static func requestPermission() {
        if !CGRequestListenEventAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    @discardableResult
    func install() -> Bool {
        guard !installed else { return true }
        guard Self.permitted else { return false }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                           eventsOfInterest: mask, callback: copyKeyCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.source = source
        installed = true
        return true
    }

    func uninstall() {
        if let port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        port = nil
        source = nil
        installed = false
    }

    fileprivate func reenable() {
        if let port { CGEvent.tapEnable(tap: port, enable: true) }
    }

    /// Pure: is this keyDown a copy or cut? `char` is the layout's character for the key (0 if
    /// unknown), so ⌘C works on non-QWERTY layouts too.
    nonisolated static func isCopyKey(keyCode: Int64, flags: CGEventFlags, char: UniChar) -> Bool {
        guard flags.contains(.maskCommand), !flags.contains(.maskControl), !flags.contains(.maskAlternate) else { return false }
        if keyCode == 8 || keyCode == 7 { return true }                          // kVK_ANSI_C / kVK_ANSI_X
        return char == 0x63 || char == 0x78 || char == 0x43 || char == 0x58      // c x C X
    }
}

/// The tap callback. Runs on the main thread (its source is on the main run loop).
private let copyKeyCallback: CGEventTapCallBack = { _, type, event, refcon in
    switch type {
    case .keyDown:
        let flags = event.flags
        // The common case — a key without ⌘ — leaves here, touching nothing.
        guard flags.contains(.maskCommand) else { return Unmanaged.passUnretained(event) }
        var length = 0
        var buffer: (UniChar, UniChar) = (0, 0)
        withUnsafeMutablePointer(to: &buffer) { p in
            p.withMemoryRebound(to: UniChar.self, capacity: 2) {
                event.keyboardGetUnicodeString(maxStringLength: 2, actualStringLength: &length, unicodeString: $0)
            }
        }
        let char = length > 0 ? buffer.0 : 0
        guard CopyKeyTap.isCopyKey(keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: flags, char: char),
              let refcon else { return Unmanaged.passUnretained(event) }
        let tap = Unmanaged<CopyKeyTap>.fromOpaque(refcon).takeUnretainedValue()
        MainActor.assumeIsolated { tap.onCopyKey?() }
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let refcon {
            let tap = Unmanaged<CopyKeyTap>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { tap.reenable() }
        }
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}
