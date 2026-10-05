import SwiftUI

// Power surfaces: wings for plug / unplug / low / Low Power Mode, the Bluetooth peek and the
// Home card. Theme only.

extension PowerEvent {
    /// Charging = green, low = red, Low Power Mode = amber (as the menu-bar battery does).
    func tint(_ s: PowerState) -> Color {
        switch self {
        case .pluggedIn: s.isCharging || s.onAC ? Theme.done : Theme.primary
        case .low: Theme.failed
        case .lowPowerMode(let on): on ? Theme.waiting : Theme.primary
        case .unplugged: s.lowPowerMode ? Theme.waiting : Theme.primary
        }
    }
}

struct PowerWingLeft: View {
    let event: PowerEvent
    let state: PowerState
    var body: some View {
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

struct PowerWingRight: View {
    let event: PowerEvent
    let state: PowerState
    var body: some View {
        Text(verbatim: "\(state.percent)%")
            .font(Theme.font(.s, .medium).monospacedDigit())
            .foregroundStyle(event.tint(state))
            .lineLimit(1)
            .fixedSize()
    }
}

/// "AirPods Pro · 82 %": updates in place when the battery arrives from system_profiler.
struct BluetoothPeek: View {
    let model: PowerModel
    let address: String
    var body: some View {
        if let d = model.devices[address] {
            HStack(spacing: 8) {
                Image(systemName: d.symbol).font(.system(size: 14)).foregroundStyle(Theme.primary)
                Text(verbatim: d.name).font(Theme.font(.m, .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
                if let level = d.battery.headline {
                    BatteryLevel(percent: level)
                } else {
                    Text(verbatim: L10n.tr("Connected")).font(Theme.font(.m)).foregroundStyle(Theme.secondary)
                }
            }
            .fixedSize()
        }
    }
}

struct BatteryLevel: View {
    let percent: Int
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: PowerLogic.batterySymbol(percent)).font(.system(size: 12))
            Text(verbatim: "\(percent)%").font(Theme.font(.m)).monospacedDigit()
        }
        .foregroundStyle(percent <= PowerLogic.cardLowThreshold ? Theme.failed : Theme.done)
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
            if !state.isCharging { return L10n.tr("Low battery") }
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
                    HStack(spacing: 8) {
                        if let l = device.battery.left, let r = device.battery.right {
                            Text(verbatim: L10n.tr("L %d%%  R %d%%", l, r))
                        } else if let m = device.battery.main ?? device.battery.headline {
                            Text(verbatim: "\(m)%")
                        }
                        if let c = device.battery.case {
                            Text(verbatim: "\(L10n.tr("Case")) \(c)%")
                        }
                    }
                    .font(Theme.font(.s).monospacedDigit()).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
        }
    }
}

enum PowerText {
    /// "45m", "1h 20m".
    static func duration(minutes: Int) -> String {
        minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
    }
}
