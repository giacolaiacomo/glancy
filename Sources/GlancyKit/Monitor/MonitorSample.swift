import Foundation

/// Made-up figures for renders: a busy afternoon on a 10-core Mac with 16 GB. No process is read.
enum MonitorSample {
    static func make() -> (MonitorSnapshot, [MonitorIndicator: [Double]]) {
        var s = MonitorSnapshot()
        s.cpu = 0.34; s.cpuUser = 0.22; s.cpuSystem = 0.12
        s.cores = [0.82, 0.64, 0.71, 0.55, 0.31, 0.12, 0.18, 0.09, 0.22, 0.05]
        s.memory = MemoryReading(used: 12_240_000_000, total: 17_179_869_184, pressure: 1)
        s.swap = SwapReading(used: 1_420_000_000, total: 3_221_225_472)
        s.gpu = 0.27
        s.disk = DiskReading(free: 212_000_000_000, total: 494_000_000_000)
        s.diskRead = 3_400_000; s.diskWrite = 820_000
        s.down = 1_240_000; s.up = 86_000
        s.power = PowerReading(watts: 13.7, onBattery: false)
        s.thermal = 0
        s.uptime = 3 * 86400 + 4 * 3600

        func app(_ name: String, _ bundle: String?, cpu: Double, mem: Double, disk: Double = 0, energy: Double = 0, gpu: Double = 0,
                 pids: [pid_t]) -> MonitorRow {
            var r = MonitorRow(id: bundle ?? "pid:\(pids[0])", name: name, bundlePath: bundle, path: bundle, pids: pids)
            r.cpu = cpu; r.memory = UInt64(mem * 1_000_000); r.disk = disk; r.energy = energy; r.gpu = gpu
            return r
        }
        let apps = [
            app("Google Chrome", "/Applications/Google Chrome.app", cpu: 1.43, mem: 2_310, disk: 420_000, energy: 2.1, gpu: 0.08, pids: Array(901...918)),
            app("Xcode", "/Applications/Xcode.app", cpu: 0.92, mem: 1_840, disk: 2_100_000, energy: 1.4, pids: [1201, 1202, 1210]),
            app("Safari", "/Applications/Safari.app", cpu: 0.28, mem: 980, disk: 64_000, energy: 0.45, gpu: 0.05, pids: [700, 702, 705]),
            app("Music", "/System/Applications/Music.app", cpu: 0.06, mem: 310, disk: 12_000, energy: 0.09, pids: [640]),
            app("Mail", "/System/Applications/Mail.app", cpu: 0.04, mem: 420, disk: 380_000, energy: 0.05, pids: [615]),
            app("Terminal", "/System/Applications/Utilities/Terminal.app", cpu: 0.61, mem: 1_120, disk: 220_000, energy: 0.8, pids: [500, 1500, 1501]),
            app("Finder", "/System/Library/CoreServices/Finder.app", cpu: 0.02, mem: 160, disk: 4_000, energy: 0.01, gpu: 0.01, pids: [480]),
        ]
        var rest = MonitorRow(id: "system.remainder", name: "System processes")
        rest.cpu = 0.38; rest.isRemainder = true
        s.apps = apps + [rest]
        s.processes = [
            app("Google Chrome Helper (Renderer)", "/Applications/Google Chrome.app", cpu: 0.88, mem: 690, disk: 120_000, energy: 1.2, gpu: 0.06, pids: [912]),
            app("swift-frontend", nil, cpu: 0.57, mem: 940, disk: 200_000, energy: 0.7, pids: [1501]),
            app("Xcode", "/Applications/Xcode.app", cpu: 0.51, mem: 1_210, disk: 1_800_000, energy: 0.8, pids: [1201]),
            app("Google Chrome", "/Applications/Google Chrome.app", cpu: 0.34, mem: 520, disk: 300_000, energy: 0.6, gpu: 0.02, pids: [901]),
            app("com.apple.WebKit.WebContent", "/Applications/Safari.app", cpu: 0.21, mem: 610, disk: 40_000, energy: 0.33, gpu: 0.04, pids: [705]),
            app("SourceKitService", "/Applications/Xcode.app", cpu: 0.18, mem: 460, disk: 90_000, energy: 0.3, pids: [1210]),
        ] + [rest]
        s.processCount = 562
        func wave(_ base: Double, _ amp: Double, _ k: Double) -> [Double] {
            (0..<60).map { (i: Int) -> Double in
                let x = Double(i)
                let a: Double = amp * sin(x / k)
                let b: Double = amp * 0.4 * sin(x / (k / 3.1))
                return max(0, base + a + b)
            }
        }
        let h: [MonitorIndicator: [Double]] = [
            .cpu: wave(0.3, 0.12, 6), .memory: wave(0.7, 0.02, 14), .gpu: wave(0.22, 0.1, 4),
            .disk: wave(2_000_000, 1_600_000, 3), .network: wave(900_000, 600_000, 5), .energy: wave(12, 3, 7),
        ]
        return (s, h)
    }
}
