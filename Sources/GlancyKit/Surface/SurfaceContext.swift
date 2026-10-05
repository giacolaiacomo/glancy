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

    public init(hub: ActivityHub, settings: AppSettings, launchAtLogin: LaunchAtLogin, modules: [any GlancyModule]) {
        self.hub = hub; self.settings = settings; self.launchAtLogin = launchAtLogin; self.modules = modules
    }

    /// Enabled modules, in the SPEC's tab order.
    public var enabledModules: [any GlancyModule] {
        modules.filter { settings.isEnabled($0.id) }.sorted { Self.order($0.id) < Self.order($1.id) }
    }

    /// The tabs of the panel, Home excluded, left to right.
    public var tabs: [PanelTab] { enabledModules.compactMap(\.tab) }

    /// Home first (nil), then each module tab.
    public var tabSequence: [ModuleID?] { [nil] + tabs.map(\.module) }

    static func order(_ id: ModuleID) -> Int {
        let order: [ModuleID] = [.agents, .calendar, .media, .timer, .notes, .shelf, .clipboard, .windows, .control, .notifications, .hud, .power, .command]
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
        }
    }

    static func symbol(_ id: ModuleID) -> String {
        switch id {
        case .agents: "sparkle"
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
        }
    }
}
