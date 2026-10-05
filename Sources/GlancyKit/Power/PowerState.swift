import Foundation

// Pure logic of the Power module: IOPS description → state, state transitions → activities,
// system_profiler JSON → Bluetooth batteries, device icons. No IOKit here; all unit-tested.

/// The Mac's battery as the wings and the Home card need it.
public struct PowerState: Equatable, Sendable {
    public var hasBattery: Bool
    public var percent: Int
    public var onAC: Bool
    public var isCharging: Bool
    public var isCharged: Bool
    /// Minutes to full while charging; nil while macOS is still estimating (or not charging).
    public var minutesToFull: Int?
    public var lowPowerMode: Bool

    public init(hasBattery: Bool, percent: Int = 0, onAC: Bool = true, isCharging: Bool = false,
                isCharged: Bool = false, minutesToFull: Int? = nil, lowPowerMode: Bool = false) {
        self.hasBattery = hasBattery; self.percent = percent; self.onAC = onAC; self.isCharging = isCharging
        self.isCharged = isCharged; self.minutesToFull = minutesToFull; self.lowPowerMode = lowPowerMode
    }

    public static let noBattery = PowerState(hasBattery: false)

    /// From `IOPSGetPowerSourceDescription` dictionaries (one per source). Uses the internal
    /// battery; a Mac without one (mini, Studio, iMac) gets `noBattery`.
    public static func parse(_ sources: [[String: Any]], lowPowerMode: Bool = false) -> PowerState {
        guard let d = sources.first(where: { ($0["Type"] as? String) == "InternalBattery" && (($0["Is Present"] as? Bool) ?? true) })
        else { var s = noBattery; s.lowPowerMode = lowPowerMode; return s }
        let current = (d["Current Capacity"] as? Int) ?? 0
        let max = (d["Max Capacity"] as? Int) ?? 100
        let percent = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current
        let charging = (d["Is Charging"] as? Bool) ?? false
        let toFull = (d["Time to Full Charge"] as? Int).flatMap { $0 > 0 ? $0 : nil }
        return PowerState(hasBattery: true, percent: Swift.min(Swift.max(percent, 0), 100),
                          onAC: (d["Power Source State"] as? String) == "AC Power",
                          isCharging: charging, isCharged: (d["Is Charged"] as? Bool) ?? false,
                          minutesToFull: charging ? toFull : nil, lowPowerMode: lowPowerMode)
    }
}

/// What a power change is worth showing in the wings.
public enum PowerEvent: Equatable, Sendable {
    case pluggedIn, unplugged, low, lowPowerMode(Bool)
}

public enum PowerLogic {
    public static let lowThreshold = 10
    public static let cardLowThreshold = 20
    public static let activityPriority = 60
    public static let activityDuration: TimeInterval = 3

    /// The activity a state change deserves, and the updated "already warned this discharge" flag.
    /// - Plug / unplug: on every AC change (never at launch: `old == nil`).
    /// - Low: at ≤ 10 % on battery, once per discharge (re-armed by plugging in).
    /// - Low Power Mode on/off.
    public static func transition(from old: PowerState?, to new: PowerState, lowWarned: Bool) -> (event: PowerEvent?, lowWarned: Bool) {
        guard new.hasBattery else { return (nil, false) }
        var warned = new.onAC ? false : lowWarned
        var event: PowerEvent?
        if let old, old.hasBattery {
            if !old.onAC && new.onAC { event = .pluggedIn }
            else if old.onAC && !new.onAC { event = .unplugged }
            else if old.lowPowerMode != new.lowPowerMode { event = .lowPowerMode(new.lowPowerMode) }
        }
        if event == nil || event == .unplugged, !new.onAC, new.percent <= lowThreshold, !warned {
            event = .low
            warned = true
        }
        return (event, warned)
    }

    /// The Home card has something to say: charging, low, or headphones with a known battery.
    public static func isNotable(_ s: PowerState, headphonesWithBattery: Bool) -> Bool {
        (s.hasBattery && (s.isCharging || (!s.onAC && s.percent <= cardLowThreshold))) || headphonesWithBattery
    }

    /// The battery glyph for a level (SF Symbols has 0/25/50/75/100).
    public static func batterySymbol(_ percent: Int, charging: Bool = false) -> String {
        if charging { return "battery.100percent.bolt" }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

// MARK: Bluetooth

/// Battery levels of a Bluetooth device, as far as known (percent).
public struct BluetoothBattery: Equatable, Sendable {
    public var left: Int?
    public var right: Int?
    public var `case`: Int?
    public var main: Int?
    public init(left: Int? = nil, right: Int? = nil, case c: Int? = nil, main: Int? = nil) {
        self.left = left; self.right = right; self.case = c; self.main = main
    }
    public var isEmpty: Bool { left == nil && right == nil && main == nil && self.case == nil }
    /// The one number to show: the emptier bud, or the device's own level.
    public var headline: Int? {
        let buds = [left, right].compactMap { $0 }
        return buds.min() ?? main ?? self.case
    }
}

/// One device from `system_profiler SPBluetoothDataType -json`.
public struct ProfiledBluetoothDevice: Equatable, Sendable {
    public var name: String
    public var address: String         // normalised: upper-case, colon-separated
    public var connected: Bool
    public var minorType: String?
    public var battery: BluetoothBattery
}

public enum BluetoothProfiler {
    /// Parses the JSON; unknown shapes yield [] rather than an error.
    public static func parse(_ data: Data) -> [ProfiledBluetoothDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var out: [ProfiledBluetoothDevice] = []
        for c in controllers {
            for (key, connected) in [("device_connected", true), ("device_not_connected", false)] {
                for entry in (c[key] as? [[String: Any]]) ?? [] {
                    for (name, value) in entry {
                        guard let p = value as? [String: Any], let address = p["device_address"] as? String else { continue }
                        out.append(ProfiledBluetoothDevice(
                            name: name, address: normaliseAddress(address), connected: connected,
                            minorType: p["device_minorType"] as? String,
                            battery: BluetoothBattery(left: percent(p["device_batteryLevelLeft"]),
                                                      right: percent(p["device_batteryLevelRight"]),
                                                      case: percent(p["device_batteryLevelCase"]),
                                                      main: percent(p["device_batteryLevelMain"]))))
                    }
                }
            }
        }
        return out
    }

    /// "85%" / "85 %" / 85 → 85.
    static func percent(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        guard let s = v as? String else { return nil }
        return Int(s.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
    }

    /// IOBluetooth says "a0-b1-c2-d3-e4-f5", system_profiler "A0:B1:C2:D3:E4:F5".
    public static func normaliseAddress(_ s: String) -> String {
        s.uppercased().replacingOccurrences(of: "-", with: ":")
    }
}

public enum BluetoothIcon {
    /// SF Symbol for a device, from its name and (when known) its kind.
    public static func symbol(name: String, minorType: String? = nil, isAudio: Bool = true) -> String {
        let n = name.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("beats") { return "beats.headphones" }
        let m = minorType?.lowercased() ?? ""
        if m.contains("speaker") || n.contains("speaker") || n.contains("homepod") { return "hifispeaker" }
        if m.contains("keyboard") || n.contains("keyboard") { return "keyboard" }
        if m.contains("mouse") || n.contains("mouse") { return "magicmouse" }
        if n.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        return isAudio ? "headphones" : "dot.radiowaves.left.and.right"
    }
}
