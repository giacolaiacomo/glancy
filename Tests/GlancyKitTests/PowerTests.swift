import Foundation
import SwiftUI
import Testing
@testable import GlancyKit

// IOPS description captured on a MacBook Pro (2026-10-05, 80 %, adapter attached,
// charging held by Optimised Charging); serial removed.
nonisolated(unsafe) private let iopsOnACHeld: [String: Any] = [
    "BatteryHealth": "Good", "Type": "InternalBattery", "LPM Active": 0, "Name": "InternalBattery-0",
    "Is Present": true, "Current": 0, "DesignCycleCount": 1000, "Current Capacity": 80, "Max Capacity": 100,
    "Transport Type": "Internal", "Is Charged": false, "Time to Full Charge": 0,
    "Battery Provides Time Remaining": true, "Power Source State": "AC Power", "Is Charging": false,
    "Power Source ID": 22675555, "Time to Empty": 0,
]

private func iops(_ changes: [String: Any]) -> [String: Any] {
    iopsOnACHeld.merging(changes) { _, new in new }
}

@Suite struct PowerParsingTests {
    @Test func realDescriptionOnACNotCharging() {
        let s = PowerState.parse([iopsOnACHeld])
        #expect(s == PowerState(hasBattery: true, percent: 80, onAC: true, isCharging: false, isCharged: false, minutesToFull: nil))
    }

    @Test func charging() {
        let s = PowerState.parse([iops(["Is Charging": true, "Current Capacity": 42, "Time to Full Charge": 95])])
        #expect(s.isCharging && s.onAC && s.percent == 42 && s.minutesToFull == 95)
    }

    @Test func stillEstimatingTimeToFull() {
        let s = PowerState.parse([iops(["Is Charging": true, "Time to Full Charge": -1])])
        #expect(s.minutesToFull == nil)
    }

    @Test func onBattery() {
        let s = PowerState.parse([iops(["Power Source State": "Battery Power", "Current Capacity": 9])], lowPowerMode: true)
        #expect(!s.onAC && !s.isCharging && s.percent == 9 && s.lowPowerMode)
    }

    @Test func percentFromNonHundredMaxCapacity() {
        // Older Macs report mAh-like capacities.
        let s = PowerState.parse([iops(["Current Capacity": 2500, "Max Capacity": 5000])])
        #expect(s.percent == 50)
    }

    @Test func macWithoutBattery() {
        #expect(PowerState.parse([]) == .noBattery)
        // A UPS is a power source, not the Mac's battery.
        let ups: [String: Any] = ["Type": "UPS", "Current Capacity": 100, "Max Capacity": 100, "Power Source State": "AC Power"]
        #expect(!PowerState.parse([ups]).hasBattery)
        #expect(PowerState.parse([], lowPowerMode: true).lowPowerMode)
    }

    @Test func absentBatteryIsNoBattery() {
        #expect(!PowerState.parse([iops(["Is Present": false])]).hasBattery)
    }
}

@Suite struct PowerTransitionTests {
    let ac = PowerState(hasBattery: true, percent: 50, onAC: true, isCharging: true)
    let battery = PowerState(hasBattery: true, percent: 50, onAC: false)

    @Test func launchIsSilent() {
        #expect(PowerLogic.transition(from: nil, to: ac, lowWarned: false).event == nil)
        #expect(PowerLogic.transition(from: nil, to: battery, lowWarned: false).event == nil)
    }

    @Test func plugAndUnplug() {
        #expect(PowerLogic.transition(from: battery, to: ac, lowWarned: false).event == .pluggedIn)
        #expect(PowerLogic.transition(from: ac, to: battery, lowWarned: false).event == .unplugged)
        #expect(PowerLogic.transition(from: ac, to: ac, lowWarned: false).event == nil)
    }

    @Test func lowOncePerDischarge() {
        var s = battery
        var warned = false
        var lows = 0
        for p in stride(from: 15, through: 3, by: -1) {
            let old = s
            s.percent = p
            let r = PowerLogic.transition(from: old, to: s, lowWarned: warned)
            warned = r.lowWarned
            if r.event == .low { lows += 1; #expect(p == 10) }
        }
        #expect(lows == 1)
        // Plugging in re-arms it; the next discharge warns again.
        let plugged = PowerState(hasBattery: true, percent: 5, onAC: true, isCharging: true)
        let r1 = PowerLogic.transition(from: s, to: plugged, lowWarned: warned)
        #expect(r1.event == .pluggedIn && r1.lowWarned == false)
        let unplugged = PowerState(hasBattery: true, percent: 6, onAC: false)
        let r2 = PowerLogic.transition(from: plugged, to: unplugged, lowWarned: r1.lowWarned)
        #expect(r2.event == .low && r2.lowWarned)
    }

    @Test func lowAtLaunchWarnsOnce() {
        let low = PowerState(hasBattery: true, percent: 7, onAC: false)
        let r = PowerLogic.transition(from: nil, to: low, lowWarned: false)
        #expect(r.event == .low && r.lowWarned)
        #expect(PowerLogic.transition(from: low, to: low, lowWarned: r.lowWarned).event == nil)
    }

    @Test func lowPowerMode() {
        var on = battery; on.lowPowerMode = true
        #expect(PowerLogic.transition(from: battery, to: on, lowWarned: false).event == .lowPowerMode(true))
        #expect(PowerLogic.transition(from: on, to: battery, lowWarned: false).event == .lowPowerMode(false))
    }

    @Test func noBatteryNeverShows() {
        let r = PowerLogic.transition(from: .noBattery, to: .noBattery, lowWarned: false)
        #expect(r.event == nil)
    }

    @Test func homeCardOnlyWhenNotable() {
        #expect(PowerLogic.isNotable(ac, headphonesWithBattery: false))                                   // charging
        #expect(!PowerLogic.isNotable(PowerState(hasBattery: true, percent: 80, onAC: true), headphonesWithBattery: false)) // held
        #expect(!PowerLogic.isNotable(battery, headphonesWithBattery: false))                             // 50 % on battery
        #expect(PowerLogic.isNotable(PowerState(hasBattery: true, percent: 18, onAC: false), headphonesWithBattery: false))
        #expect(PowerLogic.isNotable(battery, headphonesWithBattery: true))
        #expect(!PowerLogic.isNotable(.noBattery, headphonesWithBattery: false))
        #expect(PowerLogic.isNotable(.noBattery, headphonesWithBattery: true))
    }

    @Test func batterySymbols() {
        #expect(PowerLogic.batterySymbol(5) == "battery.0percent")
        #expect(PowerLogic.batterySymbol(25) == "battery.25percent")
        #expect(PowerLogic.batterySymbol(50) == "battery.50percent")
        #expect(PowerLogic.batterySymbol(80) == "battery.75percent")
        #expect(PowerLogic.batterySymbol(95) == "battery.100percent")
        #expect(PowerLogic.batterySymbol(40, charging: true) == "battery.100percent.bolt")
    }
}

@Suite @MainActor struct PowerActivityTests {
    @Test func plugActivityAtPriority60For3Seconds() throws {
        let hub = ActivityHub()
        let module = PowerModule(settings: PowerSettings(defaults: UserDefaults(suiteName: "ai.glancy.tests.power")!))
        // Started for real (IOPS is read-only; Bluetooth stays off without the Info.plist key).
        module.start(hub: hub)
        defer { module.stop() }
        module.showSample(.pluggedIn)
        let top = try #require(hub.top)
        #expect(top.id == "power" && top.priority == 60 && top.module == .power)
        #expect(abs(try #require(top.expires).timeIntervalSince(top.updated) - 3) < 0.05)
        // The HUD (75) outranks it.
        hub.post(LiveActivity(id: "hud", module: .hud, priority: 75, left: AnyView(EmptyView()), right: AnyView(EmptyView())))
        #expect(hub.top?.id == "hud")
    }

    @Test func peekForHeadphones() {
        let hub = ActivityHub()
        let module = PowerModule(settings: PowerSettings(defaults: UserDefaults(suiteName: "ai.glancy.tests.power")!))
        module.start(hub: hub)
        defer { module.stop() }
        module.showSamplePeek()
        #expect(hub.peek?.module == .power)
        #expect(module.model.headphones?.battery.headline == 82)
    }
}

// `system_profiler SPBluetoothDataType -json` captured on a Mac (2026-10-05), names,
// addresses and serials anonymised. No AirPods were connected at capture time, so the one
// connected pair's battery keys (device_batteryLevel*) were added in the format system_profiler
// uses for connected AirPods ("85%").
private let profilerFixture = #"""
{
  "SPBluetoothDataType" : [
    {
      "controller_properties" : {
        "controller_address" : "00:00:00:00:00:AA",
        "controller_chipset" : "BCM_4388C2",
        "controller_discoverable" : "attrib_off",
        "controller_firmwareVersion" : "23.5.224.1481",
        "controller_productID" : "0x4A43",
        "controller_state" : "attrib_on",
        "controller_supportedServices" : "0x392039 < HFP AVRCP A2DP HID Braille LEA AACP GATT SerialPort >",
        "controller_transport" : "PCIe",
        "controller_vendorID" : "0x004C (Apple)"
      },
      "device_connected" : [
        {
          "MX Master 3S" : {
            "device_address" : "00:00:00:00:00:01",
            "device_firmwareVersion" : "RBM22.01_0006",
            "device_minorType" : "Mouse",
            "device_productID" : "0xB034",
            "device_services" : "0x400000 < BLE >",
            "device_vendorID" : "0x046D"
          }
        },
        {
          "AirPods Pro di Test" : {
            "device_address" : "00:00:00:00:00:02",
            "device_batteryLevelCase" : "18%",
            "device_batteryLevelLeft" : "100%",
            "device_batteryLevelRight" : "96%",
            "device_caseVersion" : "1.4.1",
            "device_firmwareVersion" : "6F21",
            "device_minorType" : "Headphones",
            "device_productID" : "0x200E",
            "device_serialNumber" : "XXXXXXXXXXXX",
            "device_vendorID" : "0x004C"
          }
        }
      ],
      "device_not_connected" : [
        {
          "AirPods di Altro - Find My" : {
            "device_address" : "00:00:00:00:00:03",
            "device_caseVersion" : "8B21",
            "device_firmwareVersion" : "8B39",
            "device_minorType" : "Headphones",
            "device_productID" : "0x201B",
            "device_vendorID" : "0x004C"
          }
        },
        {
          "Apple Watch di Test" : {
            "device_address" : "00:00:00:00:00:04"
          }
        },
        {
          "CAMEO 4-000000A" : {
            "device_address" : "00:00:00:00:00:05",
            "device_minorType" : "Desktop Computer"
          }
        },
        {
          "MX Anywhere 3S" : {
            "device_address" : "00:00:00:00:00:06",
            "device_minorType" : "Mouse"
          }
        }
      ]
    }
  ]
}
"""#

@Suite struct BluetoothParsingTests {
    let devices = BluetoothProfiler.parse(Data(profilerFixture.utf8))

    @Test func readsConnectedAndPairedDevices() {
        #expect(devices.count == 6)
        #expect(devices.filter(\.connected).map(\.name).sorted() == ["AirPods Pro di Test", "MX Master 3S"])
    }

    @Test func airPodsBattery() throws {
        let pods = try #require(devices.first { $0.name == "AirPods Pro di Test" })
        #expect(pods.address == "00:00:00:00:00:02")
        #expect(pods.minorType == "Headphones")
        #expect(pods.battery == BluetoothBattery(left: 100, right: 96, case: 18))
        #expect(pods.battery.headline == 96)
    }

    @Test func devicesWithoutBatteryHaveNone() {
        let mouse = devices.first { $0.name == "MX Master 3S" }
        #expect(mouse?.battery.isEmpty == true)
        #expect(mouse?.battery.headline == nil)
    }

    @Test func malformedInputIsEmpty() {
        #expect(BluetoothProfiler.parse(Data("not json".utf8)).isEmpty)
        #expect(BluetoothProfiler.parse(Data(#"{"SPBluetoothDataType":[{}]}"#.utf8)).isEmpty)
    }

    @Test func percentStrings() {
        #expect(BluetoothProfiler.percent("85%") == 85)
        #expect(BluetoothProfiler.percent("85 %") == 85)
        #expect(BluetoothProfiler.percent(85) == 85)
        #expect(BluetoothProfiler.percent("n/a") == nil)
        #expect(BluetoothProfiler.percent(nil) == nil)
    }

    @Test func addressNormalisation() {
        #expect(BluetoothProfiler.normaliseAddress("a0-b1-c2-d3-e4-f5") == "A0:B1:C2:D3:E4:F5")
        #expect(BluetoothProfiler.normaliseAddress("A0:B1:C2:D3:E4:F5") == "A0:B1:C2:D3:E4:F5")
    }

    @Test func mainBatteryForSingleUnitDevices() {
        #expect(BluetoothBattery(main: 64).headline == 64)
        #expect(BluetoothBattery(case: 30).headline == 30)
    }

    @Test func icons() {
        #expect(BluetoothIcon.symbol(name: "AirPods Pro di Test") == "airpodspro")
        #expect(BluetoothIcon.symbol(name: "AirPods Max") == "airpodsmax")
        #expect(BluetoothIcon.symbol(name: "AirPods di Altro - Find My") == "airpods")
        #expect(BluetoothIcon.symbol(name: "Beats Studio Pro") == "beats.headphones")
        #expect(BluetoothIcon.symbol(name: "WH-1000XM5") == "headphones")
        #expect(BluetoothIcon.symbol(name: "Magic Keyboard", isAudio: false) == "keyboard")
        #expect(BluetoothIcon.symbol(name: "MX Master 3S", minorType: "Mouse", isAudio: false) == "magicmouse")
    }

    @Test func durations() {
        #expect(PowerText.duration(minutes: 45) == "45m")
        #expect(PowerText.duration(minutes: 80) == "1h 20m")
        #expect(PowerText.duration(minutes: 125) == "2h 05m")
    }
}
