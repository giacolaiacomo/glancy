import Observation
import SwiftUI

/// A page of the Settings window: the sidebar's selection.
public enum SettingsRoute: Hashable, Sendable {
    case general
    case home
    case permissions
    case module(ModuleID)
    case about
}

/// The Settings window's place, kept across opens (one per app, on `AppSettings`).
@MainActor @Observable
public final class SettingsNavigation {
    public var route: SettingsRoute = .general
    /// The permissions page is showing as the first-run welcome.
    public var welcome = false

    public init() {}

    public func go(_ r: SettingsRoute) {
        if r != .permissions { welcome = false }
        if route != r { route = r }
    }

    /// First run: the permission checklist, framed as a welcome.
    public func showWelcome() {
        welcome = true
        route = .permissions
    }
}

/// What the sidebar lists and how a page is called. Generic over `ModuleID.allCases`: a module
/// registered in `Modules.make()` gets its row (name and symbol from `SurfaceContext`, tint and
/// search words from `SettingsCatalog`) with no work here.
@MainActor
public enum SettingsSidebar {
    /// The registered modules in the panel's tab order (unknown ones after, in `allCases` order).
    static func modules(registered: Set<ModuleID>) -> [ModuleID] {
        ModuleID.allCases.enumerated()
            .filter { registered.contains($0.element) }
            .sorted { (SurfaceContext.order($0.element), $0.offset) < (SurfaceContext.order($1.element), $1.offset) }
            .map(\.element)
    }

    /// Every page, top to bottom: General, Home, Permissions, each module, About.
    public static func routes(registered: Set<ModuleID>) -> [SettingsRoute] {
        [.general, .home, .permissions] + modules(registered: registered).map { .module($0) } + [.about]
    }

    /// A route the sidebar can show: none, or a module that isn't registered, is General.
    static func resolve(_ route: SettingsRoute?, registered: Set<ModuleID>) -> SettingsRoute {
        switch route {
        case .module(let id)? where !registered.contains(id): .general
        case let r?: r
        case nil: .general
        }
    }

    static func title(_ route: SettingsRoute) -> String {
        switch route {
        case .general: tr("General")
        case .home: tr("Home")
        case .permissions: tr("Permissions")
        case .module(let id): tr(SurfaceContext.name(id))
        case .about: tr("About")
        }
    }

    static func symbol(_ route: SettingsRoute) -> String {
        switch route {
        case .general: "gearshape.fill"
        case .home: "house.fill"
        case .permissions: "hand.raised.fill"
        case .module(let id): SurfaceContext.symbol(id)
        case .about: "info.circle.fill"
        }
    }

    static func tint(_ route: SettingsRoute) -> Color {
        switch route {
        case .general: Color(nsColor: .systemGray)
        case .home: Color(nsColor: .systemBlue)
        case .permissions: Color(nsColor: .systemBlue)
        case .module(let id): SettingsCatalog.tint(id)
        case .about: Color(nsColor: .systemGray)
        }
    }

    /// Whether a page matches the sidebar's search: its title, and the names of what it holds
    /// (a module's purpose and `SettingsCatalog.keywords`), in the language shown.
    static func matches(_ route: SettingsRoute, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        var words = [title(route)]
        switch route {
        case .general:
            words += [tr("Open with"), tr("Click"), tr("Hover"), tr("Size"), tr("Language"), tr("Launch at login"),
                      tr("Hidden from screen recordings"), tr("Pill on external displays")]
        case .home:
            words += HomeWidget.allCases.map { tr($0.title) } + [tr("Always"), tr("Only when needed")]
        case .permissions:
            words += PermissionKind.allCases.map(PermissionRows.title)
        case .module(let id):
            words += [tr(SettingsCatalog.purpose(id))] + SettingsCatalog.keywords(id)
        case .about:
            words += [tr("Updates"), tr("Version"), tr("Crash reports"), "GitHub", tr("Quit Glancy")]
        }
        return words.contains { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}
