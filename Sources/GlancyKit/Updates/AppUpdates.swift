import Foundation
import Observation

/// What the app asks of the updater. `SparkleDriver` is the real one; tests use a fake.
@MainActor
protocol UpdateDriver: AnyObject {
    /// A quiet check: a found update becomes the indicator (`AppUpdates.available`), no window.
    func checkInBackground()
    /// A check the user asked for, with Sparkle's standard UI. With an update already found it
    /// brings that update's window forward (install, later, skip).
    func checkNow()
}

/// In-app updates (Sparkle 2): the switch, the schedule, and the update a quiet check found.
///
/// Zero idle cost: Sparkle never schedules its own checks (SUEnableAutomaticChecks is false); the
/// updater itself is built on the first check, not at launch. Checks run once a few seconds after
/// launch and, at most once a day, when the panel opens (`UpdateSchedule`).
@MainActor @Observable
public final class AppUpdates {
    /// The running app's updater (nil in the renderer, tests and dev builds without a bundle).
    public private(set) static weak var current: AppUpdates?

    /// "Check for updates automatically" (Settings → General). On by default.
    public var automatic: Bool { didSet { schedule.automatic = automatic } }
    /// Display version of an update a check found and the user hasn't dealt with yet.
    public private(set) var available: String?
    /// When Glancy last asked the feed.
    public private(set) var lastCheck: Date?
    /// False when this copy can't update itself (not a signed Glancy.app with a feed).
    public let isSupported: Bool

    @ObservationIgnored var schedule: UpdateSchedule
    @ObservationIgnored private var driver: UpdateDriver?
    @ObservationIgnored private let makeDriver: @MainActor (AppUpdates) -> UpdateDriver?
    /// Every check this object started (tests and diagnostics).
    @ObservationIgnored private(set) var checks: [String] = []

    init(defaults: UserDefaults, now: @escaping () -> Date = { .now }, supported: Bool = true,
         makeDriver: @escaping @MainActor (AppUpdates) -> UpdateDriver?) {
        schedule = UpdateSchedule(defaults: defaults, now: now)
        automatic = schedule.automatic
        lastCheck = schedule.lastCheck
        isSupported = supported
        self.makeDriver = makeDriver
        L10n.addItalian(UpdatesText.italian)
    }

    /// The real updater for this process, or an inert one when Sparkle can't run here.
    public static func live(defaults: UserDefaults) -> AppUpdates {
        let usable = SparkleDriver.usable(bundle: .main)
        let updates = AppUpdates(defaults: defaults, supported: usable) { owner in
            usable ? SparkleDriver(owner: owner) : nil
        }
        current = updates
        return updates
    }

    /// The app is up (the surface is on screen): one quiet check if the switch is on.
    public func appLaunched() {
        guard schedule.dueAtLaunch() else { return }
        background("launch")
    }

    /// The panel opened: a quiet check if the switch is on and the last check is a day old.
    public func panelOpened() {
        guard schedule.dueOnPanelOpen() else { return }
        background("panel")
    }

    /// "Check now" (Settings, command bar): always, with Sparkle's window.
    public func checkNow() {
        guard let driver = loadDriver() else { return }
        record()
        checks.append("user")
        driver.checkNow()
    }

    /// The indicator or "Update to X.Y.Z": Sparkle's window for the found update (install there).
    public func install() { checkNow() }

    private func background(_ reason: String) {
        guard let driver = loadDriver() else { return }
        record()
        checks.append(reason)
        driver.checkInBackground()
    }

    private func record() {
        schedule.recordCheck()
        lastCheck = schedule.lastCheck
    }

    private func loadDriver() -> UpdateDriver? {
        guard isSupported else { return nil }
        if driver == nil { driver = makeDriver(self) }
        return driver
    }

    // MARK: From the driver

    func found(_ version: String) {
        if available != version { available = version }
    }

    func sessionFinished() {
        if available != nil { available = nil }
    }
}
