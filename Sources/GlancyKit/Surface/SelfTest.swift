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
}
