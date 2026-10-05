import AppKit

/// `--selftest`: drives the live surface through every state with the real springs and logs the
/// panel frame after each step, so an automated run can check the window always ends as the
/// visible shape. Writes to stdout and ~/Library/Logs/Glancy/selftest.log.
extension SurfaceManager {
    func runSelfTest() {
        Task { @MainActor in
            var lines: [String] = []
            @MainActor func log(_ step: String) {
                for s in self.surfacesForTest {
                    let f = s.panelFrame
                    let line = String(format: "%-22@ state=%-10@ frame=(%.1f, %.1f, %.1f×%.1f) visible=%@",
                                      step as NSString, "\(s.model.state)" as NSString,
                                      f.minX, f.minY, f.width, f.height, s.panelVisible ? "yes" : "no")
                    print(line); lines.append(line)
                }
            }
            func pause(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
            guard let s = self.surfacesForTest.first else {
                print("selftest: no notched display")
                if CommandLine.arguments.contains("--exit") { NSApp.terminate(nil) }
                return
            }
            await pause(1.0); log("start")
            s.model.setHovering(true); await pause(0.15); log("hover +150ms")
            await pause(0.6); log("hover settled")
            self.open(s); await pause(0.12); log("open +120ms")
            await pause(0.8); log("open settled")
            s.model.select(tab: self.contextForTest.tabs.first?.module); await pause(0.4); log("first tab")
            s.model.toggleSettings(); await pause(0.4); log("settings")
            self.close(s); await pause(0.12); log("close +120ms")
            await pause(0.9); log("close settled")
            s.model.setHovering(false); await pause(0.8); log("leave settled")
            let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Logs/Glancy", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? lines.joined(separator: "\n").appending("\n")
                .write(to: dir.appendingPathComponent("selftest.log"), atomically: true, encoding: .utf8)
            // `--selftest --exit` (scripts/leaks.sh): quit normally so `leaks --atExit` can look.
            if CommandLine.arguments.contains("--exit") { NSApp.terminate(nil) }
        }
    }

    /// `--tour [home|tabs|all|<module>] [rounds]` (scripts/footprint.sh --tour): after `delay`
    /// seconds, opens the panel on Home, then (tabs, all) every tab, then (all) every settings page,
    /// and closes it, `rounds` times — the views a user builds by hand, so the footprint after
    /// collapse can be compared with idle. `<module>` opens that tab and stays (inspection). Logs
    /// the footprint and the malloc bytes in use after each step; a panel closed by the pointer
    /// mid-way is reported as "interrupted".
    func runTour(after delay: Double, scope: String, rounds: Int = 1) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard let s = self.surfacesForTest.first else { return }
            func pause(_ t: Double = 0.7) async { try? await Task.sleep(for: .seconds(t)) }
            @MainActor func log(_ step: String) {
                let (now, peak) = Self.footprint()
                var stats = malloc_statistics_t()
                malloc_zone_statistics(nil, &stats)
                print(String(format: "tour: %-22@ %6.1f MB (peak %5.1f), malloc in use %5.1f MB", step as NSString, now, peak,
                             Double(stats.size_in_use) / 1_048_576))
                fflush(stdout)
            }
            var interrupted = false
            @MainActor func step(_ name: String) {
                if !s.model.expanded, !interrupted { interrupted = true; print("tour: interrupted at \(name)") }
                log(name)
            }
            log("start")
            if let id = ModuleID(rawValue: scope) {
                self.open(s); s.model.select(tab: id); await pause(2); step("holding \(id.rawValue)")
                print("tour: done"); fflush(stdout)
                return
            }
            for round in 1...max(1, rounds) {
                if round > 1 { await pause(3) }
                self.open(s); await pause(); step("home")
                if scope != "home" {
                    for tab in self.contextForTest.tabs {
                        s.model.select(tab: tab.module); await pause(); step("tab \(tab.module.rawValue)")
                    }
                    s.model.select(tab: nil); await pause()
                }
                if scope == "all" {
                    let nav = self.contextForTest.settings.navigation
                    s.model.toggleSettings()
                    var routes: [SettingsRoute] = [.index, .general, .modules, .permissions]
                    routes += self.contextForTest.modules.map { .module($0.id) }
                    for r in routes {
                        nav.go(r, animated: false); await pause(0.5)
                        if case let .module(id) = r { step("settings \(id.rawValue)") } else { step("settings \(r)") }
                    }
                    nav.go(.index, animated: false)
                    s.model.toggleSettings()
                }
                self.close(s)
                await pause(1); log("closed \(round)")
            }
            await pause(5); log("closed +5s")
            print(interrupted ? "tour: done (interrupted)" : "tour: done")
            fflush(stdout)
        }
    }

    /// This process's phys_footprint and its lifetime peak, in MB.
    nonisolated static func footprint() -> (Double, Double) {
        var usage = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &usage) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        guard ok == 0 else { return (0, 0) }
        return (Double(usage.ri_phys_footprint) / 1_048_576, Double(usage.ri_lifetime_max_phys_footprint) / 1_048_576)
    }
}
