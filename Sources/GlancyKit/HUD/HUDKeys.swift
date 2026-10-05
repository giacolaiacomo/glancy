import Foundation

// Pure logic of the HUD: decoding NX_SYSDEFINED media keys, step maths, symbols, and the
// "is this external change worth a HUD" rule. No hardware here; everything is unit-tested.

/// The media keys the HUD owns (NX_KEYTYPE_* codes from IOKit's ev_keymap.h).
public enum MediaKey: Int, Sendable, CaseIterable {
    case volumeUp = 0          // NX_KEYTYPE_SOUND_UP
    case volumeDown = 1        // NX_KEYTYPE_SOUND_DOWN
    case brightnessUp = 2      // NX_KEYTYPE_BRIGHTNESS_UP
    case brightnessDown = 3    // NX_KEYTYPE_BRIGHTNESS_DOWN
    case mute = 7              // NX_KEYTYPE_MUTE
    case keyboardUp = 21       // NX_KEYTYPE_ILLUMINATION_UP
    case keyboardDown = 22     // NX_KEYTYPE_ILLUMINATION_DOWN

    var kind: HUDKind {
        switch self {
        case .volumeUp, .volumeDown, .mute: .volume
        case .brightnessUp, .brightnessDown: .brightness
        case .keyboardUp, .keyboardDown: .keyboard
        }
    }

    /// +1 up, −1 down, 0 for mute (a toggle).
    var direction: Int {
        switch self {
        case .volumeUp, .brightnessUp, .keyboardUp: 1
        case .volumeDown, .brightnessDown, .keyboardDown: -1
        case .mute: 0
        }
    }
}

/// One decoded media-key event.
public struct MediaKeyEvent: Equatable, Sendable {
    public let key: MediaKey
    public let isDown: Bool
    public let isRepeat: Bool

    /// NX_SYSDEFINED subtype 8 (NX_SUBTYPE_AUX_CONTROL_BUTTONS):
    /// data1 = keyCode << 16 | keyState << 8 | repeat, keyState 0xA = down, 0xB = up.
    /// Returns nil for any other subtype, an unknown key or an unknown state.
    public static func decode(subtype: Int, data1: Int) -> MediaKeyEvent? {
        guard subtype == 8 else { return nil }
        let code = (data1 & 0xFFFF_0000) >> 16
        let flags = data1 & 0xFFFF
        let state = (flags & 0xFF00) >> 8
        guard state == 0xA || state == 0xB, let key = MediaKey(rawValue: code) else { return nil }
        return MediaKeyEvent(key: key, isDown: state == 0xA, isRepeat: flags & 0x1 == 1)
    }

    /// The inverse of `decode`, for tests and fixtures.
    public static func data1(key: MediaKey, down: Bool, isRepeat: Bool = false) -> Int {
        (key.rawValue << 16) | ((down ? 0xA : 0xB) << 8) | (isRepeat ? 1 : 0)
    }
}

/// What the HUD is showing.
public enum HUDKind: String, Sendable, Equatable, CaseIterable {
    case volume, brightness, keyboard
}

/// Modifier handling, as macOS does it: ⌥⇧ = quarter steps; ⌥ alone = the system's "open the
/// settings pane" shortcut, passed through; ⇧ alone inverts the volume feedback sound.
public enum HUDModifiers: Sendable, Equatable {
    case none, fine, systemShortcut, shiftOnly

    public static func from(option: Bool, shift: Bool) -> HUDModifiers {
        switch (option, shift) {
        case (true, true): .fine
        case (true, false): .systemShortcut
        case (false, true): .shiftOnly
        case (false, false): .none
        }
    }
}

public enum HUDStep {
    /// macOS steps: 16 per full range, 64 with ⌥⇧.
    public static let coarse = 1.0 / 16
    public static let fine = 1.0 / 64

    /// The next level one step up or down, snapped to the step grid (a level between two grid
    /// points moves to the neighbouring one in that direction) and clamped to 0…1.
    public static func next(_ value: Float, up: Bool, fine: Bool) -> Float {
        let step = fine ? Self.fine : Self.coarse
        let n = Double(min(max(value, 0), 1)) / step
        let eps = 0.02   // float noise from devices that quantise (e.g. 0.5624 for 0.5625)
        let k = up ? (n + eps).rounded(.down) + 1 : (n - eps).rounded(.up) - 1
        return Float(min(max(k * step, 0), 1))
    }

    /// Whole-percent display value.
    public static func percent(_ value: Float) -> Int { Int((Double(min(max(value, 0), 1)) * 100).rounded()) }
}

/// A HUD reading: what to draw.
public struct HUDReading: Equatable, Sendable {
    public var kind: HUDKind
    public var level: Float
    public var muted: Bool
    public init(kind: HUDKind, level: Float, muted: Bool = false) {
        self.kind = kind; self.level = level; self.muted = muted
    }

    /// SF Symbol for the left wing.
    public var symbol: String {
        switch kind {
        case .volume:
            if muted || level <= 0.001 { return "speaker.slash.fill" }
            if level < 0.34 { return "speaker.wave.1.fill" }
            if level < 0.67 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        case .brightness:
            return level < 0.34 ? "sun.min.fill" : "sun.max.fill"
        case .keyboard:
            return level <= 0.001 ? "light.min" : "light.max"
        }
    }

    /// The level the bar shows: muted reads as an empty bar.
    public var shownLevel: Float { muted ? 0 : min(max(level, 0), 1) }
}

/// Output state compared by the CoreAudio listener to tell our own changes from other sources'.
public struct VolumeState: Equatable, Sendable {
    public var volume: Float
    public var muted: Bool
    public init(volume: Float, muted: Bool) { self.volume = volume; self.muted = muted }

    /// A listener read is worth a HUD only after launch, when it differs from the last state we
    /// know (our own writes update that state first, so they never count) by more than device
    /// quantisation noise.
    public static func isExternalChange(known: VolumeState?, now: VolumeState) -> Bool {
        guard let known else { return false }   // first read = launch or device switch: silent
        return known.muted != now.muted || abs(known.volume - now.volume) > 0.005
    }
}
