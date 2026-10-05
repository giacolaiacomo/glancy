import Foundation
import Observation

// State and settings of the Control module.

/// A question or a note shown in the tab's bar (in place of the tools row while it lasts).
public enum ControlPrompt: Equatable, Sendable {
    /// "Finder restarts to apply" before flipping desktop icons / hidden files.
    case confirmFinder(FinderFlag, on: Bool)
    case confirmTrash(TrashSummary)
    /// Automation for an app (System Events, Finder) was refused.
    case needsAutomation(String)
    case needsCamera
    /// A short result line ("Ejected 2 disks", "Trash is already empty").
    case note(String, symbol: String)
}

public enum MirrorState: Equatable, Sendable {
    case off
    case live
    /// Drawn without a camera (renderer).
    case placeholder
}

/// What the Control views render from.
@MainActor @Observable
public final class ControlModel {
    public internal(set) var awake = AwakeState()
    public internal(set) var darkMode = false
    public internal(set) var wifi: Bool?
    public internal(set) var desktopIconsHidden = false
    public internal(set) var hiddenFilesShown = false
    public internal(set) var ejectable: [String] = []
    /// Tiles whose action is running (spinner on the tile).
    public internal(set) var busy: Set<ControlTile> = []
    public internal(set) var prompt: ControlPrompt?
    public internal(set) var mirror: MirrorState = .off
    public internal(set) var recent = RecentColors()
    /// The colour just picked, shown large until the tab closes.
    public internal(set) var picked: RGB?
    public init() {}

    func isOn(_ tile: ControlTile) -> Bool {
        switch tile {
        case .keepAwake: awake.isOn
        case .darkMode: darkMode
        case .wifi: wifi == true
        case .desktopIcons: desktopIconsHidden
        case .hiddenFiles: hiddenFilesShown
        case .mirror: mirror != .off
        default: false
        }
    }
}

/// Settings → Control, persisted in UserDefaults.
@MainActor @Observable
public final class ControlSettings {
    public var layout: ControlLayout { didSet { save() } }
    public var awakeDefault: AwakeDuration { didSet { save() } }
    public var showStats: Bool { didSet { save() } }
    public var awakeInWings: Bool { didSet { save() } }
    public var screenshotTarget: ScreenshotTargetSetting { didSet { save() } }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var loading = true
    static let key = "glancy.control.settings"
    static let recentKey = "glancy.control.recentColors"

    public enum ScreenshotTargetSetting: String, Codable, Sendable { case clipboard, desktop }

    private struct Stored: Codable {
        var layout: ControlLayout
        var awakeDefault: AwakeDuration
        var showStats: Bool
        var awakeInWings: Bool
        var screenshotTarget: ScreenshotTargetSetting
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let s = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        var layout = s?.layout ?? ControlLayout()
        layout.normalize()
        self.layout = layout
        awakeDefault = s?.awakeDefault ?? .h1
        showStats = s?.showStats ?? true
        awakeInWings = s?.awakeInWings ?? true
        screenshotTarget = s?.screenshotTarget ?? .clipboard
        loading = false
    }

    private func save() {
        guard !loading else { return }
        let s = Stored(layout: layout, awakeDefault: awakeDefault, showStats: showStats, awakeInWings: awakeInWings,
                       screenshotTarget: screenshotTarget)
        if let d = try? JSONEncoder().encode(s) { defaults.set(d, forKey: Self.key) }
    }

    func loadRecent() -> RecentColors {
        defaults.data(forKey: Self.recentKey).flatMap { try? JSONDecoder().decode(RecentColors.self, from: $0) } ?? RecentColors()
    }

    func saveRecent(_ r: RecentColors) {
        if let d = try? JSONEncoder().encode(r) { defaults.set(d, forKey: Self.recentKey) }
    }

    public func reset() {
        layout = ControlLayout()
        awakeDefault = .h1
        showStats = true
        awakeInWings = true
        screenshotTarget = .clipboard
    }
}

// MARK: - One wake-up at a date

/// Schedules a single wake-up (keep-awake expiry). Never a repeating timer.
@MainActor
public protocol WakeScheduling: AnyObject {
    func schedule(at date: Date, _ fire: @escaping @MainActor () -> Void) -> WakeToken
}

public final class WakeToken {
    private let onCancel: () -> Void
    public init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    public func cancel() { onCancel() }
}

@MainActor
public final class TaskWakeScheduler: WakeScheduling {
    public init() {}
    public func schedule(at date: Date, _ fire: @escaping @MainActor () -> Void) -> WakeToken {
        let task = Task { @MainActor in
            // +50 ms so the deadline has strictly passed when the handler looks.
            try? await Task.sleep(for: .seconds(max(0.05, date.timeIntervalSinceNow + 0.05)))
            guard !Task.isCancelled else { return }
            fire()
        }
        return WakeToken { task.cancel() }
    }
}
