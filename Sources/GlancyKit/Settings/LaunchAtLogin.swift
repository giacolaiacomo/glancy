import Foundation
import Observation
import ServiceManagement

/// Launch at login through `SMAppService.mainApp` (no helper, no dependency). The state lives in the
/// system, not in UserDefaults: we read it back every time the settings page appears.
@MainActor @Observable
public final class LaunchAtLogin {
    public enum State: Equatable { case on, off, needsApproval, unavailable }
    public private(set) var state: State = .off

    public init() { refresh() }

    /// Only a real `.app` bundle can register itself.
    private var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    public func refresh() {
        guard isBundled else { state = .unavailable; return }
        switch SMAppService.mainApp.status {
        case .enabled: state = .on
        case .requiresApproval: state = .needsApproval
        case .notRegistered, .notFound: state = .off
        @unknown default: state = .off
        }
    }

    public func set(_ on: Bool) {
        guard isBundled else { state = .unavailable; return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLogGlancy("launch at login: \(error.localizedDescription)")
        }
        refresh()
        if state == .needsApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}

func NSLogGlancy(_ message: String) {
    #if DEBUG
    print("[glancy] \(message)")
    #endif
}
