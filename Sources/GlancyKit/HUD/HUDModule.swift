import AppKit
import ApplicationServices
import SwiftUI

/// HUD preferences (Settings → HUD). All on by default.
@MainActor @Observable
public final class HUDSettings {
    public static let enabledKey = "glancy.hud.enabled"
    public static let kindsKey = "glancy.hud.keys"
    public var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: Self.enabledKey)
            onChange?()
        }
    }
    /// Which keys Glancy takes over; the others stay with the system and its own HUD.
    public var kinds: Set<HUDKind> {
        didSet {
            guard kinds != oldValue else { return }
            defaults.set(kinds.map(\.rawValue).sorted(), forKey: Self.kindsKey)
            onChange?()
        }
    }
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        kinds = (defaults.stringArray(forKey: Self.kindsKey)).map { Set($0.compactMap(HUDKind.init)) } ?? Set(HUDKind.allCases)
    }

    public func handles(_ kind: HUDKind) -> Bool { kinds.contains(kind) }

    public func set(_ kind: HUDKind, _ on: Bool) {
        if on { kinds.insert(kind) } else { kinds.remove(kind) }
    }
}

/// What the wings render. Fine-grained so a key repeat only touches the bar and the number.
@MainActor @Observable
public final class HUDModel {
    public internal(set) var reading = HUDReading(kind: .volume, level: 0)
    /// True when the HUD can't run because Glancy lacks Accessibility (the system HUD stays).
    public internal(set) var needsAccessibility = false
    /// True while our tap is installed and owns the keys.
    public internal(set) var active = false
    public init() {}
}

/// Volume, brightness and keyboard-backlight keys, applied by Glancy and shown in the wings.
/// Without Accessibility it does nothing and the system HUD stays.
@MainActor
public final class HUDModule: GlancyModule {
    public let id: ModuleID = .hud
    public let settings: HUDSettings
    public let model = HUDModel()

    static let priority = 75
    static let duration: TimeInterval = 1.5
    static let activityID = "hud"

    private var hub: ActivityHub?
    private var started = false
    private var tap: HUDEventTap?
    private var handler: HUDKeyHandler?
    private let audio = AudioOutput()
    private let display = DisplayBrightness()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var axRecheck: Task<Void, Never>?
    /// Start of the current on-screen HUD: kept while it stays up so repeated keys extend it
    /// without re-presenting the wings.
    private var shownSince: Date?
    private var shownUntil: Date = .distantPast
    private var surfaceHidden = false
    private lazy var feedbackSound: NSSound? = NSSound(
        contentsOfFile: "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff", byReference: true)

    /// false = never touch the event tap or CoreAudio (tests).
    private let usesHardware: Bool

    public convenience init() { self.init(settings: HUDSettings()) }
    public init(settings: HUDSettings) { self.settings = settings; usesHardware = true }
    init(settings: HUDSettings, usesHardware: Bool) { self.settings = settings; self.usesHardware = usesHardware }

    /// Glancy is trusted for Accessibility (needed for a tap that can swallow keys).
    public var needsAccessibility: Bool { model.needsAccessibility }

    /// Shows the system's Accessibility prompt (for the onboarding checklist / settings page).
    public func requestAccessibility() {
        let key = "AXTrustedCheckOptionPrompt" as CFString   // kAXTrustedCheckOptionPrompt
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: Lifecycle

    public func start(hub: ActivityHub) {
        guard !started else { return }
        started = true
        self.hub = hub
        L10n.addItalian(hudItalian)
        settings.onChange = { [weak self] in self?.reconcile() }
        let ws = NSWorkspace.shared.notificationCenter
        observers = [
            (ws, ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.tap?.reenable() }
            }),
            // Posted when any app's Accessibility grant changes; the TCC write lands just after.
            (DistributedNotificationCenter.default(), DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.accessibilityMayHaveChanged() }
            }),
        ]
        reconcile()
    }

    public func stop() {
        started = false
        teardown()
        axRecheck?.cancel(); axRecheck = nil
        observers.forEach { $0.0.removeObserver($0.1) }
        observers = []
        settings.onChange = nil
        hub?.clear(Self.activityID)
        hub = nil
    }

    public func visibilityChanged(_ visibility: SurfaceVisibility) {
        // Hidden (fullscreen space, lock, screen off): our wings can't show, so the keys go back
        // to the system and its own HUD.
        surfaceHidden = visibility == .hidden
        handler?.setEnabled(!surfaceHidden)
        // Opening the panel is a cheap moment to notice a grant made in System Settings.
        if case .expanded = visibility, started, tap == nil { reconcile() }
    }

    /// A permission may have changed (System Settings, the onboarding checklist): take the keys
    /// as soon as Accessibility arrives, no relaunch.
    public func permissionsChanged() {
        guard started else { return }
        reconcile()
    }

    private func accessibilityMayHaveChanged() {
        axRecheck?.cancel()
        axRecheck = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.reconcile()
        }
    }

    /// Install or remove the tap to match the setting and the Accessibility grant.
    private func reconcile() {
        guard started, usesHardware else { return }
        let trusted = AXIsProcessTrusted()
        model.needsAccessibility = !trusted
        guard settings.enabled, !settings.kinds.isEmpty, trusted else { teardown(); return }
        handler?.setKinds(settings.kinds)
        guard tap == nil else { return }
        let handler = HUDKeyHandler(audio: audio, display: display) { reading, inverted in
            DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.applied(reading, feedbackInverted: inverted) } }
        }
        handler.setEnabled(!surfaceHidden)
        handler.setKinds(settings.kinds)
        guard let tap = HUDEventTap.start(handler: handler) else {
            model.needsAccessibility = true
            return
        }
        self.handler = handler
        self.tap = tap
        model.active = true
        audio.startListening { reading in
            DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.externalChange(reading) } }
        }
    }

    private func teardown() {
        handler?.setEnabled(false)
        tap?.stop()
        tap = nil
        handler = nil
        audio.stopListening()
        model.active = false
        hub?.clear(Self.activityID)
        shownSince = nil
    }

    // MARK: Showing

    private func applied(_ reading: HUDReading, feedbackInverted: Bool) {
        guard tap != nil else { return }
        show(reading)
        if reading.kind == .volume, !reading.muted, Self.feedbackEnabled() != feedbackInverted {
            feedbackSound?.stop()
            feedbackSound?.play()
        }
    }

    /// A volume change made elsewhere (menu-bar slider, AirPods, another app).
    private func externalChange(_ state: VolumeState) {
        guard tap != nil else { return }
        show(HUDReading(kind: .volume, level: state.volume, muted: state.muted))
    }

    func show(_ reading: HUDReading) {
        guard let hub else { return }
        let now = Date.now
        model.reading = reading
        // Same `updated` while the HUD stays up: the hub keeps the wings and only moves the expiry.
        let since = now < shownUntil ? (shownSince ?? now) : now
        shownSince = since
        shownUntil = now.addingTimeInterval(Self.duration)
        hub.post(LiveActivity(
            id: Self.activityID, module: .hud, priority: Self.priority, updated: since, expires: shownUntil,
            left: AnyView(HUDWingLeft(model: model)), right: AnyView(HUDWingRight(model: model))))
    }

    /// `com.apple.sound.beep.feedback` ("Play feedback when volume is changed").
    private static func feedbackEnabled() -> Bool {
        let v = CFPreferencesCopyAppValue("com.apple.sound.beep.feedback" as CFString, kCFPreferencesAnyApplication)
        return (v as? NSNumber)?.intValue == 1
    }

    /// For renders and previews: shows a sample HUD without touching any hardware.
    public func showSample(_ reading: HUDReading = HUDReading(kind: .volume, level: 0.625)) {
        show(reading)
    }
}

let hudItalian: [String: String] = [
    "Muted": "Muto",
]
