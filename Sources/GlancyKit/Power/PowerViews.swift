import SwiftUI

// Power surfaces: wings for plug / unplug / Low Power Mode, the low / full peeks, the headphones
// peek, the Devices tab and the Home card. Theme only.

extension PowerEvent {
    /// Charging = green, Low Power Mode = amber (as the menu-bar battery does), low level = red.
    func tint(_ s: PowerState) -> Color {
        switch self {
        case .pluggedIn: s.isCharging || s.onAC ? Theme.done : Theme.primary
        case .lowPowerMode(let on): on ? Theme.waiting : Theme.primary
        case .unplugged: s.lowPowerMode ? Theme.waiting : s.percent <= PowerLogic.cardLowThreshold ? Theme.failed : Theme.primary
        }
    }
}

struct PowerWingLeft: View {
    let event: PowerEvent
    let model: PowerModel
    var body: some View {
        let state = model.battery
        let symbol: String = switch event {
        case .pluggedIn: "bolt.fill"
        case .lowPowerMode(true): "leaf.fill"
        default: PowerLogic.batterySymbol(state.percent)
        }
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(event.tint(state))
            .frame(width: 20, alignment: .center)
            .fixedSize()
    }
}

/// "80%" plus, when macOS knows it, the time to full (plugged in) or to empty (unplugged). Bound
/// to the model: an estimate arriving while the wing is up shows in place.
struct PowerWingRight: View {
    let event: PowerEvent
    let model: PowerModel
    var body: some View {
        let state = model.battery
        HStack(spacing: 5) {
            Text(verbatim: "\(state.percent)%")
                .font(Theme.font(.s, .medium).monospacedDigit())
                .foregroundStyle(event.tint(state))
            if let m = minutes(state) {
                Text(verbatim: PowerText.duration(minutes: m))
                    .font(Theme.font(.s).monospacedDigit())
                    .foregroundStyle(Theme.secondary)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    private func minutes(_ s: PowerState) -> Int? {
        switch event {
        case .pluggedIn: s.isCharging ? s.minutesToFull : nil
        case .unplugged: s.minutesToEmpty
        case .lowPowerMode: s.minutesRemaining
        }
    }
}

/// Low: red battery, "Low battery · 20%", time left when known. Full: green, "Fully charged" or
/// "Charged to 80%" (the charge limit).
struct BatteryAlertPeek: View {
    let alert: BatteryAlert
    let model: PowerModel
    var body: some View {
        let s = model.battery
        HStack(spacing: 8) {
            switch alert {
            case .low:
                Image(systemName: PowerLogic.batterySymbol(s.percent)).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.failed)
                Text(verbatim: L10n.tr("Low battery")).font(Theme.font(.m, .semibold)).foregroundStyle(Theme.primary)
                Text(verbatim: "\(s.percent)%").font(Theme.font(.m, .semibold).monospacedDigit()).foregroundStyle(Theme.failed)
                if let m = s.minutesToEmpty {
                    Text(verbatim: L10n.tr("%@ left", PowerText.duration(minutes: m))).font(Theme.font(.m)).foregroundStyle(Theme.secondary)
                }
                if s.lowPowerMode { Image(systemName: "leaf.fill").font(.system(size: 11)).foregroundStyle(Theme.waiting) }
            case .full(let limit):
                Image(systemName: "battery.100percent.bolt").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.done)
                Text(verbatim: limit.map { L10n.tr("Charged to %d%%", $0) } ?? L10n.tr("Fully charged"))
                    .font(Theme.font(.m, .semibold)).foregroundStyle(Theme.primary)
                if limit != nil {
                    Text(verbatim: L10n.tr("Charge limit reached")).font(Theme.font(.m)).foregroundStyle(Theme.secondary)
                }
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// Alcove-style: the device's glyph and name, then each battery it reports (left, right, case or
/// its own) as a ring with the level. Updates in place as the levels arrive after the connection;
/// a level the device doesn't report is simply not shown.
struct BluetoothPeek: View {
    let model: PowerModel
    let address: String
    var body: some View {
        if let d = model.devices[address] {
            HStack(spacing: 10) {
                Image(systemName: d.symbol).font(.system(size: 17)).foregroundStyle(Theme.primary)
                Text(verbatim: d.name).font(Theme.font(.m, .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
                if d.battery.isEmpty {
                    Text(verbatim: L10n.tr("Connected")).font(Theme.font(.m)).foregroundStyle(Theme.secondary)
                } else {
                    BatteryGauges(battery: d.battery, size: 18)
                }
            }
            .fixedSize()
        }
    }
}

/// Rings for left / right / case (or the device's single level), each labelled.
struct BatteryGauges: View {
    let battery: BluetoothBattery
    var size: CGFloat = 18
    var body: some View {
        HStack(spacing: 8) {
            if let l = battery.left { BatteryRing(label: "L", percent: l, size: size) }
            if let r = battery.right { BatteryRing(label: "R", percent: r, size: size) }
            if battery.left == nil, battery.right == nil, let m = battery.main { BatteryRing(label: nil, percent: m, size: size) }
            if let c = battery.case { BatteryRing(label: nil, isCase: true, percent: c, size: size) }
        }
    }
}

struct BatteryRing: View {
    let label: String?
    var isCase = false
    let percent: Int
    var size: CGFloat = 18
    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                Circle().stroke(Theme.hairline, lineWidth: 2.5)
                Circle().trim(from: 0, to: CGFloat(percent) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if isCase {
                    RoundedRectangle(cornerRadius: 1.5).fill(Theme.secondary).frame(width: size * 0.36, height: size * 0.28)
                } else if let label {
                    Text(verbatim: L10n.tr(label)).font(.system(size: size * 0.42, weight: .bold)).foregroundStyle(Theme.secondary)
                }
            }
            .frame(width: size, height: size)
            Text(verbatim: "\(percent)%").font(Theme.font(.s, .medium).monospacedDigit()).foregroundStyle(Theme.primary)
        }
    }

    private var color: Color { percent <= PowerLogic.cardLowThreshold ? Theme.failed : Theme.done }
}

// MARK: Devices tab

/// The Devices tab: the Mac's battery and the headphones on the left, the microphone and the
/// sound output (from the HUD module) on the right.
struct DevicesTab: View {
    let model: PowerModel
    let sound: HUDModule?
    let connect: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                MacBatteryCard(state: model.battery)
                HeadphonesCard(model: model, connect: connect)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            if let sound, sound.audio.running {
                SoundControls(module: sound)
                    .frame(width: 290)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct MacBatteryCard: View {
    let state: PowerState
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state.hasBattery ? PowerLogic.batterySymbol(state.percent, charging: state.isCharging) : "powerplug.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: state.hasBattery ? "\(state.percent)%" : L10n.tr("This Mac"))
                        .font(Theme.font(.xl, .semibold).monospacedDigit()).foregroundStyle(Theme.primary)
                    if state.lowPowerMode {
                        HStack(spacing: 3) {
                            Image(systemName: "leaf.fill").font(.system(size: 9))
                            Text(verbatim: L10n.tr("Low Power Mode")).font(Theme.font(.xs, .medium))
                        }
                        .foregroundStyle(Theme.waiting)
                        .padding(.horizontal, 6).frame(height: 16)
                        .background(Capsule().fill(Theme.waiting.opacity(0.15)))
                    }
                }
                Text(verbatim: PowerText.status(state)).font(Theme.font(.s)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
    }

    private var tint: Color {
        guard state.hasBattery else { return Theme.secondary }
        if state.isCharging || (state.onAC && state.isCharged) { return Theme.done }
        if state.lowPowerMode { return Theme.waiting }
        return !state.onAC && state.percent <= PowerLogic.cardLowThreshold ? Theme.failed : Theme.primary
    }
}

private struct HeadphonesCard: View {
    let model: PowerModel
    let connect: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let connected = model.audioDevices
            if connected.isEmpty {
                let paired = Array(model.connectable.prefix(2))
                if paired.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "headphones").font(.system(size: 15)).foregroundStyle(Theme.tertiary).frame(width: 30)
                        Text(verbatim: L10n.tr("No headphones connected")).font(Theme.font(.m)).foregroundStyle(Theme.tertiary)
                    }
                } else {
                    ForEach(paired) { d in PairedRow(device: d, connecting: model.connecting.contains(d.address), connect: connect) }
                }
            } else {
                ForEach(Array(connected.prefix(2))) { d in ConnectedRow(device: d) }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
    }

    private struct ConnectedRow: View {
        let device: BluetoothDeviceInfo
        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: device.symbol).font(.system(size: 20)).foregroundStyle(Theme.primary).frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: device.name).font(Theme.font(.l, .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
                    if device.battery.isEmpty {
                        Text(verbatim: L10n.tr("Connected")).font(Theme.font(.s)).foregroundStyle(Theme.secondary)
                    } else {
                        BatteryGauges(battery: device.battery, size: 16)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private struct PairedRow: View {
        let device: BluetoothDeviceInfo
        let connecting: Bool
        let connect: (String) -> Void
        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: device.symbol).font(.system(size: 17)).foregroundStyle(Theme.secondary).frame(width: 30)
                Text(verbatim: device.name).font(Theme.font(.m, .medium)).foregroundStyle(Theme.secondary).lineLimit(1)
                Spacer(minLength: 4)
                if connecting {
                    Text(verbatim: L10n.tr("Connecting…")).font(Theme.font(.s)).foregroundStyle(Theme.tertiary)
                } else {
                    NotchTextButton(L10n.tr("Connect")) { connect(device.address) }
                }
            }
        }
    }
}

/// Home: the battery when charging or low, and the connected headphones with their battery.
struct PowerHomeCard: View {
    let model: PowerModel
    var body: some View {
        let b = model.battery
        HStack(spacing: 14) {
            if b.hasBattery, b.isCharging || (!b.onAC && b.percent <= PowerLogic.cardLowThreshold) {
                MacBattery(state: b)
            }
            if let h = model.headphones {
                Headphones(device: h)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private struct MacBattery: View {
        let state: PowerState
        var body: some View {
            let low = !state.isCharging
            HStack(spacing: 8) {
                Image(systemName: state.isCharging ? "bolt.fill" : PowerLogic.batterySymbol(state.percent))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(low ? Theme.failed : Theme.done)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "\(state.percent)%").font(Theme.font(.l, .semibold).monospacedDigit()).foregroundStyle(Theme.primary)
                    Text(verbatim: detail).font(Theme.font(.s)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
        }

        private var detail: String {
            if !state.isCharging {
                return state.minutesToEmpty.map { L10n.tr("%@ left", PowerText.duration(minutes: $0)) } ?? L10n.tr("Low battery")
            }
            if let m = state.minutesToFull { return L10n.tr("Full in %@", PowerText.duration(minutes: m)) }
            return L10n.tr("Charging")
        }
    }

    private struct Headphones: View {
        let device: BluetoothDeviceInfo
        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: device.symbol).font(.system(size: 15)).foregroundStyle(Theme.primary).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: device.name).font(Theme.font(.l, .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
                    Text(verbatim: PowerText.budsLine(device.battery) ?? "")
                        .font(Theme.font(.s).monospacedDigit()).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
        }
    }
}

@MainActor
enum PowerText {
    /// "45m", "1h 20m".
    nonisolated static func duration(minutes: Int) -> String {
        minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
    }

    /// "Charging · Full in 1h 20m", "On battery · 3h 10m left", "Charged", "Power adapter · Not charging".
    static func status(_ s: PowerState) -> String {
        guard s.hasBattery else { return L10n.tr("No battery") }
        if s.isCharging {
            return s.minutesToFull.map { "\(L10n.tr("Charging")) · \(L10n.tr("Full in %@", duration(minutes: $0)))" } ?? L10n.tr("Charging")
        }
        if s.onAC {
            if s.isCharged || s.percent >= 100 { return L10n.tr("Charged") }
            return "\(L10n.tr("Power adapter")) · \(L10n.tr("Not charging"))"
        }
        return s.minutesToEmpty.map { "\(L10n.tr("On battery")) · \(L10n.tr("%@ left", duration(minutes: $0)))" } ?? L10n.tr("On battery")
    }

    /// "L 82%  R 90%  Case 40%", "75%", nil when nothing is known.
    static func budsLine(_ b: BluetoothBattery) -> String? {
        var parts: [String] = []
        if let l = b.left, let r = b.right { parts.append(L10n.tr("L %d%%  R %d%%", l, r)) }
        else if let m = b.left ?? b.right ?? b.main { parts.append("\(m)%") }
        if let c = b.case { parts.append("\(L10n.tr("Case")) \(c)%") }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }
}
