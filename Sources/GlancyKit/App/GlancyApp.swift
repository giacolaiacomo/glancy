import AppKit

/// Entry point: an AppKit lifecycle (no SwiftUI `App` scene), accessory policy, no Dock icon.
public enum GlancyApp {
    @MainActor private static var delegate: AppDelegate?
    @MainActor private static var wakeWatch: NSObjectProtocol?

    @MainActor public static func run() {
        let args = CommandLine.arguments
        // Agents → "Where it went": the log scan runs in this short-lived child, then exits.
        if args.contains("--usage-scan") { UsageLedger.runScanAndExit() }
        if args.contains("--self-test") { runSelfCheck() }
        if args.contains("--crashes") {
            // Summaries of Glancy's crash reports (App/CrashReports.swift), then exit.
            print(CrashReports.printAll(), terminator: "")
            exit(0)
        }
        if let i = args.firstIndex(of: "--login-item") { loginItem(args.dropFirst(i + 1).first) }
        Diagnostics.markLaunch()
        let diagnose = args.contains("--diagnose")
        // A debug build pointed at its own home (CFFIXED_USER_HOME) runs beside the installed app.
        let isolated = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil
        if diagnose, !isolated, let other = Diagnostics.otherInstance() {
            print(Diagnostics.reportOther(other))
            exit(0)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // kill / pkill / Ctrl-C: children first, then a normal quit (modules stop cleanly).
        ChildProcesses.installSignalHandlers { NSApp.terminate(nil) }
        // Debug: log the main thread's stack if launch (or a wake) blocks it for 2 s.
        MainThreadWatchdog.arm("launch")
        if MainThreadWatchdog.isEnabled {
            wakeWatch = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MainThreadWatchdog.arm("wake") }
            }
        }
        DispatchQueue.main.async { MainActor.assumeIsolated { Diagnostics.markRunLoopReached() } }
        if diagnose { Diagnostics.scheduleReport(after: 3, stay: args.contains("--stay")) }

        let d = AppDelegate(demo: args.contains("--demo"))
        delegate = d
        app.delegate = d
        app.run()
    }

    /// `--login-item on|off|status` (install.sh, uninstall.sh): the same login item as Settings →
    /// Open at login (`SMAppService.mainApp`), then exit. Only from inside Glancy.app.
    @MainActor private static func loginItem(_ arg: String?) -> Never {
        let item = LaunchAtLogin()
        switch arg {
        case "on": item.set(true)
        case "off": item.set(false)
        case "status", nil: break
        default:
            print("usage: Glancy --login-item on|off|status")
            exit(2)
        }
        let text: String = switch item.state {
        case .on: "on"
        case .off: "off"
        case .needsApproval: "needs approval in System Settings › General › Login Items"
        case .unavailable: "unavailable (only Glancy.app can register itself)"
        }
        print("open at login: \(text)")
        exit(item.state == .unavailable ? 1 : 0)
    }

    /// `--self-test`: headless checks (SelfCheck), then exit. No surface, no single-instance lock,
    /// so it also runs beside an installed Glancy.
    @MainActor private static func runSelfCheck() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in exit(await SelfCheck.run()) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            print("self-test: timed out after 60 s")
            exit(2)
        }
        app.run()
        exit(0)
    }
}
