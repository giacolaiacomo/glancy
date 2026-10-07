import Observation
import SwiftUI

/// Where the settings page is: the index of sections, or one section (two levels, no deeper).
public enum SettingsRoute: Hashable, Sendable {
    case index
    case general
    case home
    case modules
    case permissions
    case module(ModuleID)
}

/// The settings page's place, kept across panel opens (one per app, on `AppSettings`).
@MainActor @Observable
public final class SettingsNavigation {
    public var route: SettingsRoute = .index
    /// The permissions page is showing as the first-run welcome.
    public var welcome = false

    public init() {}

    public func go(_ r: SettingsRoute, animated: Bool = true) {
        if r != .permissions { welcome = false }
        if animated { withAnimation(Theme.peek) { route = r } } else { route = r }
    }

    /// First run: the permission checklist, framed as a welcome.
    public func showWelcome() {
        welcome = true
        route = .permissions
    }
}
