import Darwin
import Foundation
import os

/// Debug builds: if the main thread doesn't get back to its run loop within `timeout` of launch
/// (or of a wake), log where it is stuck — the launch freeze of wave 2 (IOBluetooth blocking main
/// before authorization) looked "light and idle" from outside. One check per arm, no polling.
///
/// How the stack is taken: the watchdog thread signals the main thread (SIGUSR2); its handler
/// records `backtrace()` into a fixed buffer; the watchdog symbolises and logs it (os_log,
/// subsystem `ai.glancy.app`, category `watchdog`, and stderr).
public enum MainThreadWatchdog {
    static let log = Logger(subsystem: "ai.glancy.app", category: "watchdog")
    static let maxFrames: Int32 = 128
    nonisolated(unsafe) private static let frames: UnsafeMutablePointer<UnsafeMutableRawPointer?> = {
        let p = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: Int(maxFrames))
        p.initialize(repeating: nil, count: Int(maxFrames))
        return p
    }()
    nonisolated(unsafe) private static var frameCount: Int32 = 0
    nonisolated(unsafe) private static var captured: Int32 = 0
    nonisolated(unsafe) private static var mainThread: pthread_t?
    nonisolated(unsafe) private static var handlerInstalled = false

    /// The last report (tests, `--diagnose`).
    nonisolated(unsafe) public private(set) static var lastReport: String?

    /// Whether arming does anything: debug builds only, unless `force` (tests).
    public static var isEnabled: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    /// Call on the main thread before it gets busy (before `app.run()`, in a wake handler).
    /// `onStuck` (tests) receives the report on the watchdog thread.
    @MainActor public static func arm(_ reason: String, timeout: TimeInterval = 2, force: Bool = false,
                                      onStuck: (@Sendable (String) -> Void)? = nil) {
        guard isEnabled || force else { return }
        mainThread = pthread_self()
        installHandler()
        let reached = Flag()
        // Runs as soon as the main run loop services its queue again.
        DispatchQueue.main.async { reached.set() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            guard !reached.isSet else { return }
            let report = "main thread did not reach the run loop within \(timeout) s of \(reason)\n" + sampleMain()
            lastReport = report
            log.fault("\(report, privacy: .public)")
            FileHandle.standardError.write(Data(("glancy watchdog: " + report + "\n").utf8))
            onStuck?(report)
        }
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        _ = frames
        var action = sigaction()
        action.__sigaction_u.__sa_handler = { _ in
            MainThreadWatchdog.frameCount = backtrace(MainThreadWatchdog.frames, MainThreadWatchdog.maxFrames)
            MainThreadWatchdog.captured = 1
        }
        action.sa_flags = SA_RESTART
        sigemptyset(&action.sa_mask)
        sigaction(SIGUSR2, &action, nil)
    }

    /// The main thread's stack, symbolised. Called off the main thread.
    private static func sampleMain() -> String {
        guard let main = mainThread else { return "(main thread unknown)" }
        captured = 0
        pthread_kill(main, SIGUSR2)
        var waited = 0
        while captured == 0, waited < 100 {   // up to 1 s for the handler to run
            Thread.sleep(forTimeInterval: 0.01)
            waited += 1
        }
        guard captured != 0 else { return "(main thread did not answer the sampling signal)" }
        let n = frameCount
        guard n > 0, let symbols = backtrace_symbols(frames, n) else { return "(empty stack)" }
        defer { free(symbols) }
        // Frame 0-1 are the handler and the signal trampoline.
        return (0..<Int(n)).compactMap { symbols[$0].map { String(cString: $0) } }.joined(separator: "\n")
    }
}
