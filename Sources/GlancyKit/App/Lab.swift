import AppKit
import Foundation

/// `Glancy --lab` (or `GLANCY_LAB=1`): the memory lab (scripts/ram-lab.sh). Every module on demo
/// data under a scratch root, settings in their own suite, no single-instance lock, no global hot
/// keys, event taps, mouse monitors, Accessibility, permission prompts, Bluetooth, EventKit,
/// CoreAudio or AppleScript. The surface is real (it renders, so graphics memory counts) but sits
/// 20 000 pt left of every display, so it never shows on anyone's screen and never sees the pointer.
/// It runs beside an installed Glancy without touching it.
///
/// SIGUSR1 runs the tour (`GLANCY_LAB_ROUNDS`, default 1); SIGUSR2 prints the process's memory as
/// one `lab:` line. Both are dispatch sources: nothing wakes while the lab idles.
public enum Lab {
    public nonisolated static let isActive: Bool =
        CommandLine.arguments.contains("--lab") || ProcessInfo.processInfo.environment["GLANCY_LAB"] == "1"

    /// How far left of every display the lab's surface lives.
    static let offset: CGFloat = -20_000

    /// `GLANCY_LAB_HOME`, else a fresh folder in the temporary directory.
    static let root: URL = {
        if let p = ProcessInfo.processInfo.environment["GLANCY_LAB_HOME"], !p.isEmpty {
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("glancy-lab-\(getpid())", isDirectory: true)
    }()

    static let defaultsSuite = "ai.glancy.lab"

    /// Accessibility, but never in the lab (it would act on the user's real windows).
    nonisolated static func accessibilityTrusted() -> Bool {
        !isActive && AXIsProcessTrusted()
    }

    /// The built-in display (or the main one), moved far off-screen; a 14" notch when there is no
    /// notched display to copy.
    @MainActor static func screen() -> ScreenInfo {
        let real = NSScreen.screens.compactMap(\.info)
        var s = real.first(where: \.hasNotch) ?? real.first ?? ScreenInfo(
            uuid: "lab", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944), safeTop: 32,
            auxLeft: nil, auxRight: nil, isBuiltin: true, scale: 2)
        let dx = offset - s.frame.minX
        s.uuid = "lab"
        s.frame = s.frame.offsetBy(dx: dx, dy: 0)
        s.visibleFrame = s.visibleFrame.offsetBy(dx: dx, dy: 0)
        if !s.hasNotch {
            let w: CGFloat = 185
            s.safeTop = 32
            s.auxLeft = CGRect(x: s.frame.minX, y: s.frame.maxY - 32, width: (s.frame.width - w) / 2, height: 32)
            s.auxRight = CGRect(x: s.frame.midX + w / 2, y: s.frame.maxY - 32, width: (s.frame.width - w) / 2, height: 32)
        } else {
            s.auxLeft = s.auxLeft?.offsetBy(dx: dx, dy: 0)
            s.auxRight = s.auxRight?.offsetBy(dx: dx, dy: 0)
        }
        return s
    }

    /// Every status as granted: the settings pages look like a set-up Mac; nothing is asked.
    static let permissions = PermissionProbe.fixed(Dictionary(uniqueKeysWithValues: PermissionKind.allCases.map { ($0, .granted) }))

    /// One line with this process's memory, for scripts/ram-lab.sh.
    nonisolated static func report(_ label: String) -> String {
        let (now, peak) = SurfaceManager.footprint()
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return String(format: "lab: %@ footprint=%.1f peak=%.1f malloc_in_use=%.1f malloc_allocated=%.1f",
                      label, now, peak, Double(stats.size_in_use) / 1_048_576, Double(stats.size_allocated) / 1_048_576)
    }

    // MARK: Signals

    nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []

    @MainActor static func installSignals(tour: @escaping @MainActor () -> Void) {
        for sig in [SIGUSR1, SIGUSR2] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { @Sendable in
                MainActor.assumeIsolated {
                    if sig == SIGUSR1 { tour() } else { print(report("now")); fflush(stdout) }
                }
            }
            source.resume()
            sources.append(source)
        }
    }

    static var rounds: Int {
        ProcessInfo.processInfo.environment["GLANCY_LAB_ROUNDS"].flatMap(Int.init) ?? 1
    }
}
