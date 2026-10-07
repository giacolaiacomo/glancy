import SwiftUI

/// What every surface view needs besides its own model: the hub, the modules, the settings and a
/// few app-level actions. One per app, shared by all displays.
@MainActor
public final class SurfaceContext {
    public let hub: ActivityHub
    public let settings: AppSettings
    public let launchAtLogin: LaunchAtLogin
    public private(set) var modules: [any GlancyModule]
    /// App-level actions, wired by the AppDelegate (no-ops in the renderer).
    public var setModuleEnabled: (ModuleID, Bool) -> Void = { _, _ in }
    public var quit: () -> Void = {}
    /// In-app updates (Sparkle); nil in the renderer, tests and dev builds that can't update.
    public var updates: AppUpdates?

    public init(hub: ActivityHub, settings: AppSettings, launchAtLogin: LaunchAtLogin, modules: [any GlancyModule]) {
        self.hub = hub; self.settings = settings; self.launchAtLogin = launchAtLogin; self.modules = modules
        for case let m as SurfaceContextAware in modules { m.attach(self) }
    }

    /// Enabled modules, in the SPEC's tab order.
    public var enabledModules: [any GlancyModule] {
        modules.filter { settings.isEnabled($0.id) }.sorted { Self.order($0.id) < Self.order($1.id) }
    }

    /// The tabs of the panel, Home excluded, left to right (the command bar's included).
    public var tabs: [PanelTab] { enabledModules.compactMap(\.tab) }

    /// Pages that open only on request (a hotkey) and have no icon in the strip.
    public static let hiddenFromStrip: Set<ModuleID> = [.command]

    /// The tabs with an icon in the strip, left to right.
    public var stripTabs: [PanelTab] { tabs.filter { !Self.hiddenFromStrip.contains($0.module) } }

    /// Home first (nil), then each strip tab (what a swipe walks through).
    public var tabSequence: [ModuleID?] { [nil] + stripTabs.map(\.module) }

    static func order(_ id: ModuleID) -> Int {
        let order: [ModuleID] = [.agents, .calendar, .meetings, .media, .timer, .notes, .shelf, .clipboard, .windows, .control, .monitor, .notifications, .hud, .power, .command]
        return order.firstIndex(of: id) ?? order.count
    }

    static func name(_ id: ModuleID) -> String {
        switch id {
        case .agents: "Agents"
        case .calendar: "Calendar"
        case .media: "Media"
        case .hud: "HUD"
        case .power: "Power"
        case .timer: "Timer"
        case .shelf: "Shelf"
        case .clipboard: "Clipboard"
        case .windows: "Windows"
        case .notifications: "Notifications"
        case .command: "Command bar"
        case .control: "Control"
        case .notes: "Notes"
        case .monitor: "Monitor"
        case .meetings: "Meetings"
        }
    }

    static func symbol(_ id: ModuleID) -> String {
        switch id {
        case .agents: AgentsModule.symbol
        case .calendar: "calendar"
        case .media: "music.note"
        case .hud: "speaker.wave.2"
        case .power: "battery.75percent"
        case .timer: "timer"
        case .shelf: "tray"
        case .clipboard: "doc.on.clipboard"
        case .windows: "rectangle.split.2x2"
        case .notifications: "bell"
        case .command: "command"
        case .control: "switch.2"
        case .notes: "note.text"
        case .monitor: "gauge.with.dots.needle.67percent"
        case .meetings: MeetingsModule.symbol
        }
    }
}

/// A module that needs the app's context (enabled modules, settings) gets it when the context is
/// built. Called once per context; the renderer builds several.
@MainActor
public protocol SurfaceContextAware: AnyObject {
    func attach(_ context: SurfaceContext)
}

/// Routes that only the surface can take. Wired by `SurfaceManager`; nil before.
@MainActor
public enum SurfaceRoute {
    /// Closes the panel and opens the Settings window on a page (nil = the page it was on).
    public static var openSettings: ((SettingsRoute?) -> Void)?
}
