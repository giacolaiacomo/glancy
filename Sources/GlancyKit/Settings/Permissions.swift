import AppKit
import AVFoundation
import Speech
import ApplicationServices
import CoreBluetooth
import EventKit
import Observation
import UserNotifications

/// The permissions Glancy can use (SPEC §4 onboarding checklist).
public enum PermissionKind: String, CaseIterable, Sendable {
    case calendar, accessibility, bluetooth, notifications, automation, fullDiskAccess, microphone, camera, speech
}

public enum PermissionStatus: Sendable, Equatable {
    case granted
    case denied
    case notDetermined
    /// Can't be asked here (no Info.plist key outside the app bundle, no player running…).
    case unavailable
}

/// A module that must notice a grant made while it runs (no relaunch).
@MainActor
public protocol PermissionAware: AnyObject {
    func permissionsChanged()
}

/// How statuses are read. `system` asks macOS without ever showing a prompt; renders and tests
/// use `fixed`.
public struct PermissionProbe: Sendable {
    public var read: @Sendable () async -> [PermissionKind: PermissionStatus]

    public init(read: @escaping @Sendable () async -> [PermissionKind: PermissionStatus]) { self.read = read }

    public static func fixed(_ s: [PermissionKind: PermissionStatus]) -> PermissionProbe { PermissionProbe { s } }

    public static let system = PermissionProbe {
        var out: [PermissionKind: PermissionStatus] = [:]
        out[.calendar] = SystemPermissions.calendar()
        out[.accessibility] = Lab.accessibilityTrusted() ? .granted : .notDetermined
        out[.bluetooth] = SystemPermissions.bluetooth()
        out[.fullDiskAccess] = SystemPermissions.fullDiskAccess()
        out[.notifications] = await SystemPermissions.notifications()
        out[.automation] = await SystemPermissions.automation()
        out[.microphone] = SystemPermissions.capture(.audio, usage: "NSMicrophoneUsageDescription")
        out[.camera] = SystemPermissions.capture(.video, usage: "NSCameraUsageDescription")
        out[.speech] = SystemPermissions.speech()
        return out
    }
}

/// Live permission statuses for the checklist, refreshed only on events: the page appearing,
/// Glancy becoming active, System Settings losing focus, the Accessibility distributed
/// notification, calendar store changes, and the answer to a request. Never polls.
@MainActor @Observable
public final class PermissionCenter {
    public private(set) var status: [PermissionKind: PermissionStatus] = [:]
    /// A request is waiting for the user's answer.
    public private(set) var asking: PermissionKind?

    /// Called when any status changed after the first read: modules re-check (AppDelegate).
    @ObservationIgnored public var onChange: (() -> Void)?
    @ObservationIgnored public var probe: PermissionProbe
    /// Asks for calendar access on the Calendar module's own store, so it sees the grant at once.
    @ObservationIgnored public var calendarRequester: (@MainActor () async -> Void)?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var axRecheck: Task<Void, Never>?
    @ObservationIgnored private var bluetoothAsker: BluetoothAsker?
    @ObservationIgnored private let defaults: UserDefaults

    static let axPromptedKey = "glancy.permissions.axPrompted"

    public init(probe: PermissionProbe = .system, defaults: UserDefaults = .standard) {
        self.probe = probe
        self.defaults = defaults
    }

    public func status(_ p: PermissionKind) -> PermissionStatus { status[p] ?? .notDetermined }

    // MARK: Observation (event-driven only)

    public func start() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        let ws = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()
        observers = [
            (nc, nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }),
            // Calendar access granted or revoked reaches every store as a change.
            (nc, nc.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }),
            // Coming back from System Settings (Bluetooth, Full Disk Access, Automation have no
            // notification of their own).
            (ws, ws.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == "com.apple.systempreferences" else { return }
                MainActor.assumeIsolated { self?.refresh() }
            }),
            // Any app's Accessibility grant changed; the TCC write lands just after the post.
            (dnc, dnc.addObserver(forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.accessibilityMayHaveChanged() }
            }),
        ]
        refresh()
    }

    public func stop() {
        observers.forEach { $0.0.removeObserver($0.1) }
        observers = []
        refreshTask?.cancel(); refreshTask = nil
        axRecheck?.cancel(); axRecheck = nil
        bluetoothAsker = nil
    }

    private func accessibilityMayHaveChanged() {
        axRecheck?.cancel()
        axRecheck = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    /// Re-reads every status (off the main thread for the slow ones) and reports a change.
    public func refresh() {
        refreshTask?.cancel()
        let probe = probe
        refreshTask = Task { [weak self] in
            let fresh = await Task.detached(priority: .userInitiated) { await probe.read() }.value
            guard !Task.isCancelled, let self else { return }
            self.apply(fresh)
        }
    }

    /// Adopts statuses read elsewhere (the refresh, renders).
    public func apply(_ fresh: [PermissionKind: PermissionStatus]) {
        guard fresh != status else { return }
        let first = status.isEmpty
        status = fresh
        if !first { onChange?() }
    }

    // MARK: Requests (only ever from a button the user pressed)

    /// Asks for `p` the way macOS allows: the system prompt when it has not been answered yet,
    /// otherwise the right pane of System Settings.
    public func request(_ p: PermissionKind) {
        switch p {
        case .calendar:
            guard status(.calendar) == .notDetermined else { return openSettings(p) }
            asking = .calendar
            let requester = calendarRequester
            Task { [weak self] in
                if let requester { await requester() } else if EventKitSource.usable { _ = try? await EKEventStore().requestFullAccessToEvents() }
                self?.asking = nil
                self?.refresh()
            }
        case .accessibility:
            // The system prompt shows once; after that it is the pane or nothing.
            if defaults.bool(forKey: Self.axPromptedKey) { return openSettings(p) }
            defaults.set(true, forKey: Self.axPromptedKey)
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .bluetooth:
            guard status(.bluetooth) == .notDetermined, SystemPermissions.bluetoothUsable else { return openSettings(p) }
            asking = .bluetooth
            bluetoothAsker = BluetoothAsker { [weak self] in
                self?.asking = nil
                self?.bluetoothAsker = nil
                self?.refresh()
            }
        case .notifications:
            guard status(.notifications) == .notDetermined, SystemPermissions.inBundle else { return openSettings(p) }
            asking = .notifications
            Task { [weak self] in
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                self?.asking = nil
                self?.refresh()
            }
        case .automation:
            guard status(.automation) == .notDetermined, let target = SystemPermissions.runningPlayer() else { return openSettings(p) }
            asking = .automation
            Task { [weak self] in
                // Blocks until the user answers the prompt: off the main thread.
                _ = await Task.detached { SystemPermissions.automate(target, ask: true) }.value
                self?.asking = nil
                self?.refresh()
            }
        case .fullDiskAccess:
            openSettings(p)
        case .microphone, .camera:
            guard status(p) == .notDetermined else { return openSettings(p) }
            asking = p
            let media: AVMediaType = p == .microphone ? .audio : .video
            Task { [weak self] in
                _ = await AVCaptureDevice.requestAccess(for: media)
                self?.asking = nil
                self?.refresh()
            }
        case .speech:
            guard status(.speech) == .notDetermined else { return openSettings(p) }
            asking = .speech
            Task { [weak self] in
                _ = await SystemTranscriber.askSpeech()
                self?.asking = nil
                self?.refresh()
            }
        }
    }

    public func openSettings(_ p: PermissionKind) {
        NSWorkspace.shared.open(Self.settingsURL(p))
    }

    public static func settingsURL(_ p: PermissionKind) -> URL {
        let pane: String
        switch p {
        case .calendar: pane = "com.apple.preference.security?Privacy_Calendars"
        case .accessibility: pane = "com.apple.preference.security?Privacy_Accessibility"
        case .bluetooth: pane = "com.apple.preference.security?Privacy_Bluetooth"
        case .automation: pane = "com.apple.preference.security?Privacy_Automation"
        case .fullDiskAccess: pane = "com.apple.preference.security?Privacy_AllFiles"
        case .notifications: pane = "com.apple.preference.notifications"
        case .microphone: pane = "com.apple.preference.security?Privacy_Microphone"
        case .camera: pane = "com.apple.preference.security?Privacy_Camera"
        case .speech: pane = "com.apple.preference.security?Privacy_SpeechRecognition"
        }
        return URL(string: "x-apple.systempreferences:" + pane)!
    }
}

/// Reads permission statuses without prompting. Everything here is safe off the main thread.
enum SystemPermissions {
    static var inBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

    /// Microphone / camera. Without the usage string macOS kills the process on a request, so a
    /// run outside the app bundle reports `unavailable`.
    static func capture(_ media: AVMediaType, usage key: String) -> PermissionStatus {
        guard inBundle, Bundle.main.object(forInfoDictionaryKey: key) != nil else { return .unavailable }
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    static func speech() -> PermissionStatus {
        guard inBundle, Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else { return .unavailable }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    /// IOBluetooth / CoreBluetooth kill a process that lacks the usage string (tests, renders).
    static var bluetoothUsable: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil
    }

    static func calendar() -> PermissionStatus {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    static func bluetooth() -> PermissionStatus {
        guard bluetoothUsable else { return .unavailable }
        switch CBManager.authorization {
        case .allowedAlways: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    static func notifications() async -> PermissionStatus {
        guard inBundle else { return .unavailable }
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    /// Full Disk Access, detected the only way there is: try to open a file it protects (the
    /// notification database the Notifications module reads), read-only.
    static let notificationDB = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db").path

    static func fullDiskAccess(path: String = notificationDB) -> PermissionStatus {
        let fd = open(path, O_RDONLY)
        if fd >= 0 { close(fd); return .granted }
        return errno == ENOENT ? .unavailable : .denied
    }

    static let players = ["com.apple.Music", "com.spotify.client"]

    @MainActor static func runningPlayer() -> String? {
        players.first { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
    }

    /// Music / Spotify scripting (the media fallback). Unknown while neither player runs.
    static func automation() async -> PermissionStatus {
        let running = await MainActor.run { players.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty } }
        var best: PermissionStatus = .unavailable
        for id in running {
            switch automate(id, ask: false) {
            case .granted: return .granted
            case .notDetermined: best = .notDetermined
            case .denied: if best == .unavailable { best = .denied }
            case .unavailable: break
            }
        }
        return best
    }

    /// `AEDeterminePermissionToAutomateTarget`; with `ask` it shows the prompt and blocks.
    static func automate(_ bundleID: String, ask: Bool) -> PermissionStatus {
        var desc = AEAddressDesc()
        guard let data = bundleID.data(using: .utf8) else { return .unavailable }
        let made = data.withUnsafeBytes { raw in
            AECreateDesc(DescType(typeApplicationBundleID), raw.baseAddress, raw.count, &desc)
        }
        guard made == noErr else { return .unavailable }
        defer { AEDisposeDesc(&desc) }
        let status = AEDeterminePermissionToAutomateTarget(&desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return .unavailable   // procNotFound: the player quit
        }
    }
}

/// Shows the Bluetooth prompt through CoreBluetooth (never blocks) and reports the answer.
@MainActor
private final class BluetoothAsker: NSObject, CBCentralManagerDelegate {
    private var central: CBCentralManager?
    private let done: @MainActor () -> Void

    init(done: @escaping @MainActor () -> Void) {
        self.done = done
        super.init()
        central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            guard CBManager.authorization != .notDetermined else { return }
            self.central = nil
            done()
        }
    }
}
