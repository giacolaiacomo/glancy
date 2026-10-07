import Foundation
import Observation

/// How the expanded panel opens (SPEC §2 "Open model").
public enum OpenModel: String, CaseIterable, Codable, Sendable {
    case click   // hover → peek, click → expanded (default)
    case hover   // dwell 300 ms with a velocity gate, then expanded
}

/// The app-wide preferences, persisted in UserDefaults. Fine-grained `@Observable` properties so a
/// view only re-renders for what it reads.
@MainActor @Observable
public final class AppSettings {
    public var openModel: OpenModel { didSet { save(openModel.rawValue, Key.openModel) } }
    public var language: AppLanguage {
        didSet { save(language.rawValue, Key.language); L10n.apply(language) }
    }
    public var hideFromCapture: Bool { didSet { save(hideFromCapture, Key.hideFromCapture) } }
    public var externalPill: Bool { didSet { save(externalPill, Key.externalPill) } }
    /// Settings → General → Size: text, symbols and the panel together. Normal by default.
    public var size: UISize { didSet { save(size.rawValue, Key.size) } }
    public var disabledModules: Set<ModuleID> {
        didSet { save(disabledModules.map(\.rawValue).sorted(), Key.disabledModules) }
    }
    /// Settings → Home: the widgets in the user's order (every widget once).
    public private(set) var homeOrder: [HomeWidget] {
        didSet { save(homeOrder.map(\.rawValue), Key.homeOrder) }
    }
    /// Settings → Home: the widgets turned off.
    public private(set) var homeHidden: Set<HomeWidget> {
        didSet { save(homeHidden.map(\.rawValue).sorted(), Key.homeHidden) }
    }
    /// Settings → Home: the widgets whose Always / Only when needed the user chose; the others
    /// follow `HomeWidget.defaultMode` (a save from before the choice existed has none).
    public private(set) var homeModes: [HomeWidget: HomeWidgetMode] {
        didSet { save(Dictionary(uniqueKeysWithValues: homeModes.map { ($0.key.rawValue, $0.value.rawValue) }), Key.homeModes) }
    }

    /// The settings page's place (index or a section). Not persisted.
    @ObservationIgnored public let navigation = SettingsNavigation()
    /// Live permission statuses for the checklist (observers start with the app, not here).
    @ObservationIgnored public let permissions: PermissionCenter

    @ObservationIgnored private let defaults: UserDefaults

    enum Key {
        static let openModel = "openModel"
        static let language = "language"
        static let hideFromCapture = "hideFromCapture"
        static let externalPill = "externalPill"
        static let size = "uiSize"
        static let disabledModules = "disabledModules"
        static let optedIn = "optedInModules"
        static let onboarded = "onboardingShown"
        static let homeOrder = "homeWidgetOrder"
        static let homeHidden = "homeWidgetsHidden"
        static let homeModes = "homeWidgetModes"
    }

    /// Opt-in modules (a large permission): off until the user turns them on, existing settings included.
    public static let defaultDisabled: Set<ModuleID> = [.notifications, .meetings]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        permissions = PermissionCenter(defaults: defaults)
        openModel = defaults.string(forKey: Key.openModel).flatMap(OpenModel.init) ?? .click
        language = defaults.string(forKey: Key.language).flatMap(AppLanguage.init) ?? .system
        hideFromCapture = defaults.object(forKey: Key.hideFromCapture) as? Bool ?? true
        externalPill = defaults.object(forKey: Key.externalPill) as? Bool ?? false
        size = defaults.string(forKey: Key.size).flatMap(UISize.init) ?? .normal
        let off = defaults.stringArray(forKey: Key.disabledModules) ?? []
        let optedIn = Set((defaults.stringArray(forKey: Key.optedIn) ?? []).compactMap(ModuleID.init))
        disabledModules = Set(off.compactMap(ModuleID.init)).union(Self.defaultDisabled.subtracting(optedIn))
        homeOrder = HomeLayout.normalized((defaults.stringArray(forKey: Key.homeOrder) ?? []).compactMap(HomeWidget.init))
        homeHidden = Set((defaults.stringArray(forKey: Key.homeHidden) ?? []).compactMap(HomeWidget.init))
        let modes = (defaults.dictionary(forKey: Key.homeModes) as? [String: String]) ?? [:]
        homeModes = Dictionary(uniqueKeysWithValues: modes.compactMap { k, v in
            HomeWidget(rawValue: k).flatMap { w in HomeWidgetMode(rawValue: v).map { (w, $0) } }
        })
        L10n.apply(language)
    }

    // MARK: Home widgets

    public func isShownOnHome(_ w: HomeWidget) -> Bool { !homeHidden.contains(w) }

    public func setShownOnHome(_ w: HomeWidget, _ on: Bool) {
        if on { homeHidden.remove(w) } else { homeHidden.insert(w) }
    }

    /// Always (shown at rest too) or Only when needed (only when it has something).
    public func homeMode(_ w: HomeWidget) -> HomeWidgetMode { homeModes[w] ?? w.defaultMode }

    public func setHomeMode(_ w: HomeWidget, _ mode: HomeWidgetMode) {
        homeModes[w] = mode
    }

    /// Moves a widget one place up (-1) or down (+1) in Home's order.
    public func moveOnHome(_ w: HomeWidget, by step: Int) {
        guard let i = homeOrder.firstIndex(of: w) else { return }
        let j = i + step
        guard homeOrder.indices.contains(j) else { return }
        homeOrder.swapAt(i, j)
    }

    /// Back to the default Home: every widget on, the default order and modes.
    public func resetHome() {
        homeOrder = HomeWidget.defaultOrder
        homeHidden = []
        homeModes = [:]
    }

    /// Anything in Settings → Home differs from the defaults (Reset is offered).
    public var homeIsCustomized: Bool {
        homeOrder != HomeWidget.defaultOrder || !homeHidden.isEmpty || homeModes.contains { $0.value != $0.key.defaultMode }
    }

    public func isEnabled(_ module: ModuleID) -> Bool {
        !disabledModules.contains(module) && Self.onlyModules?.contains(module) != false
    }

    /// Diagnostics (footprint bisection): `GLANCY_ONLY_MODULES=agents,media` runs just those, as if
    /// the others were off, without touching the saved choice.
    nonisolated static let onlyModules: Set<ModuleID>? = ProcessInfo.processInfo.environment["GLANCY_ONLY_MODULES"].map {
        Set($0.split(separator: ",").compactMap { ModuleID(rawValue: String($0)) })
    }

    public func setEnabled(_ module: ModuleID, _ on: Bool) {
        if on { disabledModules.remove(module) } else { disabledModules.insert(module) }
        if Self.defaultDisabled.contains(module) {
            var optedIn = Set(defaults.stringArray(forKey: Key.optedIn) ?? [])
            if on { optedIn.insert(module.rawValue) } else { optedIn.remove(module.rawValue) }
            save(optedIn.sorted(), Key.optedIn)
        }
    }

    /// True until the first-run welcome has been shown once.
    public var needsOnboarding: Bool { !defaults.bool(forKey: Key.onboarded) }
    public func markOnboarded() { defaults.set(true, forKey: Key.onboarded) }

    private func save(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }
}
