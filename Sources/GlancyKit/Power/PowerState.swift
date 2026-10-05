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
    /// Minutes left on battery; nil on AC or while macOS is still estimating.
    public var minutesToEmpty: Int?

    public init(hasBattery: Bool, percent: Int = 0, onAC: Bool = true, isCharging: Bool = false,
                isCharged: Bool = false, minutesToFull: Int? = nil, lowPowerMode: Bool = false, minutesToEmpty: Int? = nil) {
        self.hasBattery = hasBattery; self.percent = percent; self.onAC = onAC; self.isCharging = isCharging
        self.isCharged = isCharged; self.minutesToFull = minutesToFull; self.lowPowerMode = lowPowerMode
        self.minutesToEmpty = minutesToEmpty
    }

    /// The time worth showing next to the level: to full while charging, to empty on battery.
    public var minutesRemaining: Int? { isCharging ? minutesToFull : onAC ? nil : minutesToEmpty }

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
        // 0 and -1 mean "still estimating"; a day or more is not an estimate either.
        func minutes(_ key: String) -> Int? { (d[key] as? Int).flatMap { $0 > 0 && $0 < 24 * 60 ? $0 : nil } }
        let onAC = (d["Power Source State"] as? String) == "AC Power"
        return PowerState(hasBattery: true, percent: Swift.min(Swift.max(percent, 0), 100),
                          onAC: onAC,
                          isCharging: charging, isCharged: (d["Is Charged"] as? Bool) ?? false,
                          minutesToFull: charging ? minutes("Time to Full Charge") : nil, lowPowerMode: lowPowerMode,
                          minutesToEmpty: onAC ? nil : minutes("Time to Empty"))
    }
}

/// What a power change is worth showing in the wings.
public enum PowerEvent: Equatable, Sendable {
    case pluggedIn, unplugged, lowPowerMode(Bool)
}

public enum PowerLogic {
    public static let cardLowThreshold = 20
    public static let activityPriority = 60
    public static let activityDuration: TimeInterval = 3

    /// The wing a state change deserves: plug / unplug on every AC change (never at launch:
    /// `old == nil`), Low Power Mode on/off. Low and full are peeks (`BatteryAlerts`).
    public static func transition(from old: PowerState?, to new: PowerState) -> PowerEvent? {
        guard new.hasBattery, let old, old.hasBattery else { return nil }
        if !old.onAC && new.onAC { return .pluggedIn }
        if old.onAC && !new.onAC { return .unplugged }
        if old.lowPowerMode != new.lowPowerMode { return .lowPowerMode(new.lowPowerMode) }
        return nil
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

/// A battery peek: low (the threshold crossed) or full (`limit` = the level charging stopped at
/// when below 100: the charge limit or Optimised Charging).
public enum BatteryAlert: Equatable, Sendable {
    case low(Int)
    case full(limit: Int?)
}

/// Low / full peeks, each once: a low threshold fires when the level reaches it on battery and
/// is re-armed only by AC power or by climbing `hysteresis` points above it (so 20→19→20→19 warns
/// once); a big drop past several thresholds warns once, for the lowest. Full fires once per
/// charge: on "Is Charged", at 100 %, or when charging stops on AC at ≥ 80 % (the charge-limit
/// range) — a pause below that is heat or calibration, not a limit. Unplugging re-arms it.
public struct BatteryAlerts: Equatable, Sendable {
    public var thresholds: [Int]
    public var hysteresis: Int
    public var fullEnabled: Bool
    /// Thresholds that may still fire.
    public private(set) var armed: Set<Int>
    /// The level the last "full" fired at during this charge (nil = not yet).
    public private(set) var fullAt: Int?

    public static let limitFloor = 80

    public init(thresholds: [Int] = [20, 10], hysteresis: Int = 3, fullEnabled: Bool = true) {
        self.thresholds = thresholds.filter { $0 > 0 && $0 < 100 }
        self.hysteresis = hysteresis
        self.fullEnabled = fullEnabled
        armed = Set(self.thresholds)
    }

    /// New settings keep what already fired for thresholds that stay.
    public mutating func configure(thresholds: [Int], fullEnabled: Bool) {
        let t = thresholds.filter { $0 > 0 && $0 < 100 }
        armed = armed.intersection(t).union(Set(t).subtracting(self.thresholds))
        self.thresholds = t
        self.fullEnabled = fullEnabled
    }

    public mutating func update(from old: PowerState?, to new: PowerState) -> BatteryAlert? {
        guard new.hasBattery else { return nil }
        // Re-arm: AC, or far enough above.
        for t in thresholds where new.onAC || new.percent >= t + hysteresis { armed.insert(t) }
        if !new.onAC { fullAt = nil }

        if !new.onAC {
            let crossed = thresholds.filter { new.percent <= $0 && armed.contains($0) }
            guard let lowest = crossed.min() else { return nil }
            // Everything at or above the level is spent, fired or not.
            for t in thresholds where new.percent <= t { armed.remove(t) }
            return .low(lowest)
        }

        let full = new.isCharged || new.percent >= 100
        let held = !new.isCharging && new.percent >= Self.limitFloor && (old?.isCharging ?? false)
        guard full || held else { return nil }
        // At launch (no old state) a full battery is known silently.
        guard let old, old.hasBattery else { fullAt = new.percent; return nil }
        if let at = fullAt, at >= new.percent { return nil }
        // Already reported at a limit and now topped up to 100 (Optimised Charging finishing): report again.
        fullAt = new.percent
        guard fullEnabled else { return nil }
        return .full(limit: new.percent >= 100 ? nil : new.percent)
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

    /// From IOBluetoothDevice's battery properties (`batteryPercentLeft` …, 0 = unknown).
    public static func fromDevice(_ values: [String: Int]) -> BluetoothBattery {
        func p(_ k: String) -> Int? { values[k].flatMap { $0 > 0 && $0 <= 100 ? $0 : nil } }
        let left = p("batteryPercentLeft"), right = p("batteryPercentRight")
        // "Combined" stands in only when the buds are not reported apart.
        let main = p("batteryPercentSingle") ?? (left == nil && right == nil ? p("batteryPercentCombined") : nil)
        return BluetoothBattery(left: left, right: right, case: p("batteryPercentCase"), main: main)
    }

    /// From an IORegistry entry (`BatteryPercent`, `BatteryPercentLeft/Right/Case/Single`).
    public static func fromRegistry(_ props: [String: Any]) -> BluetoothBattery {
        func p(_ k: String) -> Int? { (props[k] as? Int).flatMap { $0 > 0 && $0 <= 100 ? $0 : nil } }
        return BluetoothBattery(left: p("BatteryPercentLeft"), right: p("BatteryPercentRight"), case: p("BatteryPercentCase"),
                                main: p("BatteryPercentSingle") ?? p("BatteryPercent"))
    }

    /// Known values of `other` fill the gaps of `self`.
    public func merged(with other: BluetoothBattery) -> BluetoothBattery {
        BluetoothBattery(left: left ?? other.left, right: right ?? other.right, case: self.case ?? other.case, main: main ?? other.main)
    }
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
        if n.contains("beats") || n.contains("powerbeats") {
            if n.contains("studio buds") { return "beats.studiobuds" }
            if n.contains("fit pro") { return "beats.fitpro" }
            if n.contains("powerbeats pro") { return "beats.powerbeatspro" }
            if n.contains("powerbeats") || n.contains("flex") || n.contains("buds") { return "beats.earphones" }
            return "beats.headphones"
        }
        let m = minorType?.lowercased() ?? ""
        if m.contains("speaker") || n.contains("speaker") || n.contains("homepod") { return "hifispeaker" }
        if m.contains("keyboard") || n.contains("keyboard") { return "keyboard" }
        if m.contains("mouse") || n.contains("mouse") { return "magicmouse" }
        if n.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        return isAudio ? "headphones" : "dot.radiowaves.left.and.right"
    }
}
