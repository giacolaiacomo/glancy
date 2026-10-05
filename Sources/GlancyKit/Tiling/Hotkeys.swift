// Tiling — global hotkeys through Carbon's RegisterEventHotKey (no Accessibility, no event tap).
// Ported from Tessera (Hotkeys.swift, MIT, same author), decoupled from any config: callers
// register closures and keep the returned token. The recorder *view* belongs to the UI lot; the
// key-name table and the NSEvent → Carbon modifier mapping it needs are here.

import AppKit
import Carbon.HIToolbox

/// A key combination: Carbon virtual key code + Carbon modifier mask.
public struct Hotkey: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = c.lenient(.keyCode, 0)
        modifiers = c.lenient(.modifiers, 0)
    }

    /// "⌃⌥←".
    public var description: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + Self.keyName(keyCode)
    }

    /// Carbon modifier mask for AppKit flags (what a recorder captures).
    public static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        return mask
    }

    static let names: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
        34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
        24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\", 43: ",", 44: "/", 47: ".",
        50: "`",
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 76: "⌤", 117: "⌦",
        115: "↖", 116: "⇞", 119: "↘", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    public static func keyName(_ keyCode: UInt32) -> String {
        if keyCode == 49 { return String(localized: "Space") }
        return names[keyCode] ?? "#\(keyCode)"
    }
}

@MainActor
public final class HotkeyManager {
    public static let shared = HotkeyManager()

    /// Returned by `register`; pass it to `unregister`.
    public struct Token: Hashable, Sendable { let id: UInt32 }

    nonisolated static let signature = OSType(0x6C_75_6E_74)   // 'lunt'

    private var actions: [UInt32: @MainActor () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    /// What each live token is bound to (re-registered after a suspension).
    private var combos: [UInt32: Hotkey] = [:]
    /// True while a shortcut recorder listens: every hotkey is released so the keys reach it.
    public private(set) var isSuspended = false
    private var nextID: UInt32 = 1
    private var handler: EventHandlerRef?

    private init() {}

    /// Registers a global hotkey. Nil when the combination has no modifier (it would hijack
    /// typing everywhere) or the system refuses it (already taken).
    @discardableResult
    public func register(_ hotkey: Hotkey, action: @escaping @MainActor () -> Void) -> Token? {
        guard hotkey.modifiers != 0 else { return nil }
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        if !isSuspended {
            guard let ref = Self.carbonRegister(hotkey, id: id) else { return nil }
            refs[id] = ref
        }
        actions[id] = action
        combos[id] = hotkey
        return Token(id: id)
    }

    public func unregister(_ token: Token) {
        if let ref = refs.removeValue(forKey: token.id) { UnregisterEventHotKey(ref) }
        actions[token.id] = nil
        combos[token.id] = nil
    }

    public func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
        actions.removeAll()
        combos.removeAll()
    }

    /// Releases every hotkey (a recorder is listening) or takes them back. Tokens stay valid.
    public func setSuspended(_ on: Bool) {
        guard on != isSuspended else { return }
        isSuspended = on
        if on {
            for ref in refs.values { UnregisterEventHotKey(ref) }
            refs.removeAll()
        } else {
            for (id, hotkey) in combos {
                if let ref = Self.carbonRegister(hotkey, id: id) { refs[id] = ref }
            }
        }
    }

    /// The combinations Glancy holds right now (suspended ones included).
    public var registered: Set<Hotkey> { Set(combos.values) }

    private static func carbonRegister(_ hotkey: Hotkey, id: UInt32) -> EventHotKeyRef? {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        return status == noErr ? ref : nil
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // A C function pointer carries no context: route back through the singleton.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            // Only ours: another handler's hot key (the surface's Esc) must pass on untouched.
            guard status == noErr, hotKeyID.signature == HotkeyManager.signature else { return OSStatus(eventNotHandledErr) }
            let id = hotKeyID.id
            // The application event target delivers on the main thread.
            MainActor.assumeIsolated { HotkeyManager.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    private func fire(_ id: UInt32) { actions[id]?() }

    /// Hot keys currently registered (diagnostics).
    public var registeredCount: Int { refs.count }
    /// Live tokens, suspended ones included (tests: a restarted module must not register twice).
    var tokenCount: Int { combos.count }
}
