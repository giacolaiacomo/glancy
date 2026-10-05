// Windows — "apply when this display setup connects". Listens to the screen-parameters
// notification (posted on every CGDisplay reconfiguration), waits until the changes stop for
// 1.5 s (a dock brings several displays up one by one, and macOS gathers windows meanwhile), and
// reports the new setup once — only when a display came or went, not when the Dock resized.
// Idle cost: one notification observer; a single sleeping task only during a burst.

import AppKit

@MainActor
final class DisplaySetupWatcher {
    var debounce: Duration = .milliseconds(1500)
    /// The connected displays (injected by tests).
    var displays: () -> [Display] = { ScreenSpace.displays() }
    /// The setup changed and settled.
    var onSetupChange: (([Display]) -> Void)?
    private var observer: NSObjectProtocol?
    private var pending: Task<Void, Never>?
    private(set) var lastKey: String?

    func start() {
        guard observer == nil else { return }
        lastKey = WorkspacePlanner.setupKey(displays())
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.noteChange() }
            }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        pending?.cancel()
        pending = nil
    }

    /// A reconfiguration happened: (re)start the quiet period.
    func noteChange() {
        if lastKey == nil { lastKey = WorkspacePlanner.setupKey(displays()) }
        pending?.cancel()
        let wait = debounce
        pending = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            self.settled()
        }
    }

    private func settled() {
        let now = displays()
        let key = WorkspacePlanner.setupKey(now)
        guard key != lastKey else { return }
        lastKey = key
        onSetupChange?(now)
    }

    /// Tests: whether a quiet period is running.
    var isWaiting: Bool { pending != nil }
}
