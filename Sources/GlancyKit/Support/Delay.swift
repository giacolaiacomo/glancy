import Foundation

/// `Task.sleep` that lets go when cancelled. A cancelled `Task.sleep` resumes at once, but the
/// runtime keeps its wake-up job — and with it the task — until the original deadline: every
/// re-armed wait (an hour to the next meeting, a minute to the next tick, a hover dwell) left a
/// task behind for as long as it would have slept (~50 per walk through the panel). Here the wait
/// is a dispatch timer that is cancelled, and freed, with the task.
public enum Delay {
    /// Suspends for `duration`; throws `CancellationError` as soon as the task is cancelled.
    public static func sleep(for duration: Duration) async throws {
        let wait = Wait()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                wait.start(c, after: duration)
            }
        } onCancel: {
            wait.finish(throwing: CancellationError())
        }
    }

    /// One wait: the continuation and its timer, finished exactly once (timer or cancellation).
    private final class Wait: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, any Error>?
        private var timer: DispatchSourceTimer?
        private var cancelled = false

        func start(_ c: CheckedContinuation<Void, any Error>, after duration: Duration) {
            lock.lock()
            if cancelled {
                lock.unlock()
                c.resume(throwing: CancellationError())
                return
            }
            continuation = c
            let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            t.schedule(deadline: .now() + Delay.interval(duration), repeating: .never, leeway: Delay.leeway(duration))
            t.setEventHandler { @Sendable [weak self] in self?.finish(throwing: nil) }
            timer = t
            lock.unlock()
            t.resume()
        }

        func finish(throwing error: (any Error)?) {
            lock.lock()
            if error != nil { cancelled = true }
            let c = continuation, t = timer
            continuation = nil; timer = nil
            lock.unlock()
            t?.cancel()
            if let c {
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }

    static func interval(_ d: Duration) -> DispatchTimeInterval {
        let (s, atto) = d.components
        let ns = max(0, s) > Int64.max / 1_000_000_000 ? Int64.max : max(0, s) * 1_000_000_000 + max(0, atto) / 1_000_000_000
        return .nanoseconds(Int(clamping: ns))
    }

    /// Short waits are exact (a hover dwell); long ones may be coalesced by up to a second.
    static func leeway(_ d: Duration) -> DispatchTimeInterval {
        d < .seconds(1) ? .milliseconds(1) : d < .seconds(60) ? .milliseconds(50) : .seconds(1)
    }
}
