import Darwin
import Foundation

/// Child processes Glancy spawned (the media adapter's perl, one-shot `system_profiler` / adapter
/// runs) must never outlive it. A normal quit stops every module, which stops its children; this
/// covers the rest:
/// - SIGTERM / SIGINT / SIGHUP (`kill`, `pkill`, a terminal closing): children get SIGTERM at
///   once, then the app quits through `NSApp.terminate` (modules stop cleanly); if the main thread
///   is stuck and can't, the process exits after a grace period anyway.
/// - A crash (SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE, SIGTRAP): the handler SIGTERMs every
///   registered child (async-signal-safe: a fixed table and `kill`), then re-raises with the default
///   action, so the crash report is unchanged.
/// - SIGKILL can't be caught: the next launch reaps the orphan (`AdapterStream.reapOrphan`).
public enum ChildProcesses {
    static let capacity = 32
    /// Fixed table read from the signal handler: no allocation, no lock there.
    nonisolated(unsafe) private static let slots: UnsafeMutablePointer<pid_t> = {
        let p = UnsafeMutablePointer<pid_t>.allocate(capacity: capacity)
        p.initialize(repeating: 0, count: capacity)
        return p
    }()
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []
    nonisolated(unsafe) private static var installed = false

    /// Records a live child. Silently ignored when the table is full (a bug, never seen).
    public static func register(_ pid: pid_t) {
        guard pid > 1 else { return }
        lock.withLock {
            for i in 0..<capacity where slots[i] == 0 {
                slots[i] = pid
                return
            }
        }
    }

    /// The child has exited (or was reaped).
    public static func unregister(_ pid: pid_t) {
        lock.withLock {
            for i in 0..<capacity where slots[i] == pid { slots[i] = 0 }
        }
    }

    /// Registered children, for diagnostics and tests.
    public static var current: [pid_t] {
        lock.withLock { (0..<capacity).map { slots[$0] }.filter { $0 > 1 } }
    }

    /// SIGTERM to every registered child. Async-signal-safe.
    static func terminateAll() {
        for i in 0..<capacity {
            let pid = slots[i]
            if pid > 1 { kill(pid, SIGTERM) }
        }
    }

    /// What SIGTERM / SIGINT / SIGHUP do, on the signal source's queue: children first, then a
    /// normal quit on main; if main is stuck, exit anyway after `grace` (nil = never, tests).
    nonisolated static func terminationHandler(grace: TimeInterval?,
                                               quit: @escaping @MainActor @Sendable () -> Void) -> @Sendable () -> Void {
        return {
            terminateAll()
            DispatchQueue.main.async { MainActor.assumeIsolated { quit() } }
            // A stuck main thread can't quit: don't stay around ignoring kill.
            if let grace { DispatchQueue.global().asyncAfter(deadline: .now() + grace) { _exit(0) } }
        }
    }

    /// Installs the handlers once. `quit` runs on the main queue on SIGTERM / SIGINT / SIGHUP.
    @MainActor public static func installSignalHandlers(grace: TimeInterval = 3, quit: @escaping @MainActor @Sendable () -> Void) {
        guard !installed else { return }
        installed = true
        _ = slots   // initialise the table now, never inside a signal handler

        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)   // the dispatch source takes over
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global(qos: .userInitiated))
            // Built outside this main-actor function: a closure written here would inherit the
            // main actor, and Swift 6 traps when the source calls it on its own queue.
            source.setEventHandler(handler: terminationHandler(grace: grace, quit: quit))
            source.resume()
            sources.append(source)
        }

        var action = sigaction()
        action.__sigaction_u.__sa_handler = { sig in
            ChildProcesses.terminateAll()
            // Back to the default action, then re-raise so the crash proceeds as before.
            // Explicitly: SA_RESETHAND does not reset SIGILL / SIGTRAP (a Swift trap on arm64
            // is SIGTRAP), which would re-enter this handler forever.
            signal(sig, SIG_DFL)
            raise(sig)
        }
        action.sa_flags = SA_RESETHAND
        sigemptyset(&action.sa_mask)
        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE, SIGTRAP] {
            sigaction(sig, &action, nil)
        }
    }
}
