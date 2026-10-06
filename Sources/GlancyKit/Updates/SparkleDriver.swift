import AppKit
import OSLog
import Sparkle

/// Sparkle 2 behind `UpdateDriver`. Built on the first check (never at launch), lives for the rest
/// of the run. Sparkle's own scheduler stays off: `automaticallyChecksForUpdates` is false, so it
/// never arms a timer; Glancy decides when to look (`UpdateSchedule`).
///
/// An LSUIElement app has no Dock icon to draw the eye, so a quiet check that finds an update
/// opens no window (gentle reminders): Glancy shows a dot on the settings gear and "Update to
/// X.Y.Z" in Settings; clicking it brings Sparkle's standard window forward.
///
/// Environment, read only when set:
///   GLANCY_UPDATE_FEED=<url>     another appcast (a local test feed); the lab needs it to update.
///   GLANCY_UPDATE_UNATTENDED=1   install whatever a check finds and relaunch, no window. Ignored
///                                in the real app (bundle id ai.glancy.app): scripts/update-e2e.sh.
@MainActor
final class SparkleDriver: NSObject, UpdateDriver {
    static let releaseBundleID = "ai.glancy.app"

    private weak var owner: AppUpdates?
    private var updater: SPUUpdater?
    private var userDriver: (any SPUUserDriver)?

    /// A Glancy.app carrying a public key, outside the lab (or in the lab with a test feed).
    static func usable(bundle: Bundle) -> Bool {
        guard bundle.bundleURL.pathExtension == "app",
              bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String != nil else { return false }
        return !Lab.isActive || feedOverride != nil
    }

    static var feedOverride: String? {
        ProcessInfo.processInfo.environment["GLANCY_UPDATE_FEED"].flatMap { $0.isEmpty ? nil : $0 }
    }

    static var unattended: Bool {
        ProcessInfo.processInfo.environment["GLANCY_UPDATE_UNATTENDED"] == "1"
            && Bundle.main.bundleIdentifier != releaseBundleID
    }

    init(owner: AppUpdates) {
        self.owner = owner
        super.init()
        let bundle = Bundle.main
        let driver: any SPUUserDriver = Self.unattended
            ? UnattendedUserDriver()
            : SPUStandardUserDriver(hostBundle: bundle, delegate: self)
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: self)
        // Belt and braces with SUEnableAutomaticChecks=false: Sparkle's scheduler never runs.
        updater.automaticallyChecksForUpdates = false
        updater.automaticallyDownloadsUpdates = false
        do {
            try updater.start()
            self.updater = updater
            userDriver = driver
        } catch {
            NSLog("Glancy updates: Sparkle did not start: %@", error.localizedDescription)
        }
    }

    func checkInBackground() {
        guard let updater, !updater.sessionInProgress else { return }
        updater.checkForUpdatesInBackground()
    }

    func checkNow() {
        // While a session is open (an update already found) this brings its window forward.
        updater?.checkForUpdates()
    }
}

extension SparkleDriver: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? { Self.feedOverride }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        owner?.found(item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        owner?.sessionFinished()
    }
}

extension SparkleDriver: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// A quiet check never pops a window: the dot and the Settings button take it from here.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        owner?.found(update.displayVersionString)
    }

    func standardUserDriverWillFinishUpdateSession() {
        owner?.sessionFinished()
    }

    /// Sparkle's windows come up over other apps (Glancy is an accessory app with no window of
    /// its own to activate).
    func standardUserDriverWillShowModalAlert() {
        NSApp.activate()
    }
}

/// Test-only user driver (GLANCY_UPDATE_UNATTENDED, never the real app): every answer is "install",
/// so scripts/update-e2e.sh exercises download, EdDSA check, install and relaunch with no window.
@MainActor
final class UnattendedUserDriver: NSObject, SPUUserDriver {
    override init() {
        super.init()
        let info = Bundle.main.infoDictionary ?? [:]
        log("unattended updater in \(Bundle.main.bundleIdentifier ?? "?") \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?")), pid \(getpid())")
    }

    /// Unified log (an app opened by Launch Services has no stdout):
    /// `log show --predicate 'subsystem == "ai.glancy.updates"'`.
    private static let logger = Logger(subsystem: "ai.glancy.updates", category: "unattended")
    private func log(_ s: String) { Self.logger.notice("\(s, privacy: .public)") }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        log("found \(appcastItem.displayVersionString) (\(appcastItem.versionString)), installing")
        reply(.install)
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}
    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        log("no update: \(error.localizedDescription)")
        acknowledgement()
    }
    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        log("error: \(error.localizedDescription)")
        acknowledgement()
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { log("downloading") }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() { log("extracting") }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        log("ready, install and relaunch")
        reply(.install)
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        log("installing (terminated: \(applicationTerminated))")
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        log("installed, relaunched: \(relaunched)")
        acknowledgement()
    }
    func showUpdateInFocus() {}
    func dismissUpdateInstallation() {}
}
