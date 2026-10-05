import AppKit
import CoreGraphics
import os

/// Applies media keys on the event-tap thread. Decides synchronously whether a key is ours
/// (applied → swallowed) or not (passed through untouched). Everything it touches is either
/// thread-safe (CoreAudio, DisplayServices) or used only on the tap thread (keyboard backlight).
final class HUDKeyHandler: @unchecked Sendable {
    let audio: AudioOutput
    private let display: DisplayBrightness
    private var keyboard: KeyboardBacklight?
    private var keyboardLoaded = false
    /// Keys whose key-down we swallowed: their key-up is swallowed too, nothing else.
    private var swallowedDown: Set<MediaKey> = []
    private let enabled = OSAllocatedUnfairLock(initialState: true)
    /// Main-thread delivery of what to show.
    private let onApplied: @Sendable (HUDReading, _ feedbackInverted: Bool) -> Void

    init(audio: AudioOutput, display: DisplayBrightness, onApplied: @escaping @Sendable (HUDReading, Bool) -> Void) {
        self.audio = audio
        self.display = display
        self.onApplied = onApplied
    }

    func setEnabled(_ on: Bool) { enabled.withLock { $0 = on } }

    /// The kinds of key this handler takes over (Settings → HUD); others pass through.
    private let kinds = OSAllocatedUnfairLock(initialState: Set(HUDKind.allCases))
    func setKinds(_ k: Set<HUDKind>) { kinds.withLock { $0 = k } }

    /// True = swallow the event.
    func handle(_ event: MediaKeyEvent, modifiers: HUDModifiers) -> Bool {
        guard event.isDown else { return swallowedDown.remove(event.key) != nil }
        swallowedDown.remove(event.key)
        guard enabled.withLock({ $0 }), modifiers != .systemShortcut else { return false }
        guard kinds.withLock({ $0.contains(event.key.kind) }) else { return false }
        if event.key == .mute && event.isRepeat { return false }
        guard let reading = apply(event.key, fine: modifiers == .fine) else { return false }
        swallowedDown.insert(event.key)
        onApplied(reading, modifiers == .shiftOnly)
        return true
    }

    private func apply(_ key: MediaKey, fine: Bool) -> HUDReading? {
        switch key.kind {
        case .volume:
            guard let state = audio.apply(direction: key.direction, fine: fine) else { return nil }
            return HUDReading(kind: .volume, level: state.volume, muted: state.muted)
        case .brightness:
            guard let id = DisplayBrightness.builtInDisplayUnderCursor(), let current = display.get(id) else { return nil }
            let target = HUDStep.next(current, up: key.direction > 0, fine: fine)
            guard display.set(id, target) else { return nil }
            return HUDReading(kind: .brightness, level: display.get(id) ?? target)
        case .keyboard:
            if !keyboardLoaded { keyboard = KeyboardBacklight(); keyboardLoaded = true }
            guard let keyboard else { return nil }
            let target = HUDStep.next(keyboard.get(), up: key.direction > 0, fine: fine)
            guard keyboard.set(target) else { return nil }
            return HUDReading(kind: .keyboard, level: target)
        }
    }
}

/// A `CGEventTap` on NX_SYSDEFINED at the HID level, run on its own thread's run loop so a busy
/// main thread can never time it out. Idle cost: a thread blocked in its run loop. One-shot:
/// `stop()` ends it for good; a restart makes a new one.
final class HUDEventTap: @unchecked Sendable {
    private let handler: HUDKeyHandler
    private let port: CFMachPort
    private var runLoop: CFRunLoop?
    private var stopped = false

    private init(handler: HUDKeyHandler, port: CFMachPort) {
        self.handler = handler
        self.port = port
    }

    /// nil when the tap can't be created (no Accessibility).
    static func start(handler: HUDKeyHandler) -> HUDEventTap? {
        guard !Lab.isActive else { return nil }
        let mask = CGEventMask(1 << 14)   // NX_SYSDEFINED
        // The tap object is the callback's context, so it must exist before the port: a box first.
        let slot = TapSlot()
        guard let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: hudTapCallback,
                                           userInfo: Unmanaged.passUnretained(slot).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else { return nil }
        let tap = HUDEventTap(handler: handler, port: port)
        slot.tap = tap
        let ready = DispatchSemaphore(value: 0)
        let box = TapBox(source: source, slot: slot)
        let thread = Thread {
            let rl = CFRunLoopGetCurrent()!
            box.slot.tap?.runLoop = rl
            CFRunLoopAddSource(rl, box.source, .commonModes)
            ready.signal()
            CFRunLoopRun()
            // The slot (and so the tap and its handler) lives until the run loop has stopped.
            withExtendedLifetime(box) {}
        }
        thread.name = "ai.glancy.hud.tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        CGEvent.tapEnable(tap: port, enable: true)
        return tap
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        if let runLoop { CFRunLoopStop(runLoop) }
    }

    /// After sleep, or when the system disabled the tap.
    func reenable() {
        if !stopped, !CGEvent.tapIsEnabled(tap: port) { CGEvent.tapEnable(tap: port, enable: true) }
    }

    fileprivate func callback(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            CGEvent.tapEnable(tap: port, enable: true)
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == 14, let ns = NSEvent(cgEvent: event),
              let key = MediaKeyEvent.decode(subtype: Int(ns.subtype.rawValue), data1: ns.data1) else {
            return Unmanaged.passUnretained(event)
        }
        let flags = event.flags
        let modifiers = HUDModifiers.from(option: flags.contains(.maskAlternate), shift: flags.contains(.maskShift))
        return handler.handle(key, modifiers: modifiers) ? nil : Unmanaged.passUnretained(event)
    }
}

/// The callback's context: set once before the tap thread starts, read only on that thread.
private final class TapSlot: @unchecked Sendable {
    var tap: HUDEventTap?
}

private final class TapBox: @unchecked Sendable {
    let source: CFRunLoopSource
    let slot: TapSlot
    init(source: CFRunLoopSource, slot: TapSlot) { self.source = source; self.slot = slot }
}

private func hudTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    guard let tap = Unmanaged<TapSlot>.fromOpaque(userInfo).takeUnretainedValue().tap else { return Unmanaged.passUnretained(event) }
    return tap.callback(type: type, event: event)
}
