import AppKit
import ApplicationServices
import Carbon.HIToolbox
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
    public static let micHotkeyKey = "glancy.hud.micHotkey"
    public static let inUseKey = "glancy.hud.showInUse"
    /// ⌃⌥0: free among Glancy's own (⌃⌥ Space/arrows/F/Z/A/B/C/R/M/G/J/K, ⌥⌘V) and macOS's.
    public static let defaultMicHotkey = Hotkey(keyCode: UInt32(kVK_ANSI_0), modifiers: UInt32(controlKey | optionKey))

    /// Mutes / unmutes the microphone from anywhere. No modifiers = none.
    public var micHotkey: Hotkey {
        didSet {
            guard micHotkey != oldValue else { return }
            if let data = try? JSONEncoder().encode(micHotkey) { defaults.set(data, forKey: Self.micHotkeyKey) }
            onHotkeyChange?()
        }
    }
    /// A red dot in the wings while an app records from the microphone or the camera.
    public var showInUse: Bool {
        didSet {
            guard showInUse != oldValue else { return }
            defaults.set(showInUse, forKey: Self.inUseKey)
            onInUseChange?()
        }
    }
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onHotkeyChange: (() -> Void)?
    @ObservationIgnored var onInUseChange: (() -> Void)?
    @ObservationIgnored let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        kinds = (defaults.stringArray(forKey: Self.kindsKey)).map { Set($0.compactMap(HUDKind.init)) } ?? Set(HUDKind.allCases)
        micHotkey = defaults.data(forKey: Self.micHotkeyKey).flatMap { try? JSONDecoder().decode(Hotkey.self, from: $0) } ?? Self.defaultMicHotkey
        showInUse = defaults.object(forKey: Self.inUseKey) as? Bool ?? true
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
/// Without Accessibility the keys stay with the system HUD. Also the microphone: a global mute
/// (hotkey, command bar, Devices tab) with a wing while muted, a red dot while an app records,
/// and the sound output list.
@MainActor
public final class HUDModule: GlancyModule {
    public let id: ModuleID = .hud
    public let settings: HUDSettings
    public let model = HUDModel()
    /// Microphone, camera-in-use and outputs (CoreAudio; a silent system in isolated runs).
    public let audio: AudioCenter

    static let priority = 75
    static let duration: TimeInterval = 1.5
    static let activityID = "hud"
    static let micID = "hud.mic"
    static let micFlashID = "hud.mic.flash"
    static let inUseID = "hud.inuse"
    /// Muted stays up until unmuted: above agents working (50), below charging (60).
    static let micPriority = 55
    /// Mic / camera in use: above now playing (30), below a running timer (40).
    static let inUsePriority = 35

    private var hub: ActivityHub?
    private var started = false
    private var tap: HUDEventTap?
    private var handler: HUDKeyHandler?
    private let volumeOutput = AudioOutput()
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

    /// false = never touch the event tap, CoreAudio or global hotkeys (tests, isolated runs).
    private let usesHardware: Bool
    private var micHotkeyToken: HotkeyManager.Token?
    /// The mic hotkey is set but the system refused it (taken by another app).
    public private(set) var micHotkeyFailed = false

    public convenience init() { self.init(settings: HUDSettings()) }
    public init(settings: HUDSettings) {
        self.settings = settings; usesHardware = true
        audio = AudioCenter(system: CoreAudioSystem(), defaults: settings.defaults)
    }
    /// Isolated: no hardware at all, unless `audioSystem` (a fake) is given.
    init(settings: HUDSettings, usesHardware: Bool, audioSystem: AudioSystem? = nil) {
        self.settings = settings; self.usesHardware = usesHardware
        audio = AudioCenter(system: audioSystem ?? (usesHardware ? CoreAudioSystem() : SilentAudioSystem()), defaults: settings.defaults)
    }

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
        settings.onHotkeyChange = { [weak self] in self?.registerMicHotkey() }
        settings.onInUseChange = { [weak self] in self?.postInUse() }
        audio.onMicChange = { [weak self] muted, byUser in self?.micChanged(muted, byUser: byUser) }
        audio.onUseChange = { [weak self] _, _ in self?.postInUse() }
        audio.start()
        if audio.micMuted { postMicMuted() }
        postInUse()
        registerMicHotkey()
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
        if let micHotkeyToken { HotkeyManager.shared.unregister(micHotkeyToken) }
        micHotkeyToken = nil
        audio.onMicChange = nil; audio.onUseChange = nil
        audio.stop(restore: true)
        settings.onHotkeyChange = nil; settings.onInUseChange = nil
        hub?.clearAll(from: .hud)
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
        let trusted = Lab.accessibilityTrusted()
        model.needsAccessibility = !trusted
        guard settings.enabled, !settings.kinds.isEmpty, trusted else { teardown(); return }
        handler?.setKinds(settings.kinds)
        guard tap == nil else { return }
        let handler = HUDKeyHandler(audio: volumeOutput, display: display) { reading, inverted in
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
        volumeOutput.startListening { reading in
            DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.externalChange(reading) } }
        }
    }

    private func teardown() {
        handler?.setEnabled(false)
        tap?.stop()
        tap = nil
        handler = nil
        volumeOutput.stopListening()
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

    // MARK: Microphone

    private func registerMicHotkey() {
        if let micHotkeyToken { HotkeyManager.shared.unregister(micHotkeyToken) }
        micHotkeyToken = nil
        micHotkeyFailed = false
        guard started, usesHardware, settings.micHotkey.modifiers != 0 else { return }
        micHotkeyToken = HotkeyManager.shared.register(settings.micHotkey) { [weak self] in self?.toggleMic() }
        micHotkeyFailed = micHotkeyToken == nil
    }

    /// Mutes or unmutes the microphone (hotkey, command bar, Devices tab). Nothing to mute or a
    /// refusal flashes "No microphone" / leaves the state as it is.
    public func toggleMic() {
        guard started else { return }
        if audio.toggleMic() == nil { flashMic(nil) }
    }

    /// Changes the mic hotkey (Settings → HUD); a combination without modifiers clears it.
    public func setMicHotkey(_ combo: Hotkey) { settings.micHotkey = combo }

    private func micChanged(_ muted: Bool, byUser: Bool) {
        if muted { postMicMuted() } else { hub?.clear(Self.micID) }
        if byUser { flashMic(muted) }
        postInUse()
    }

    private func postMicMuted() {
        guard let hub else { return }
        hub.post(LiveActivity(id: Self.micID, module: .hud, priority: Self.micPriority, updated: .now,
                              left: AnyView(MicWingLeft(muted: true)), right: AnyView(MicWingRight(audio: audio, showInUse: settings.showInUse))))
    }

    /// A 1.5 s confirmation at HUD priority: "Mic muted" / "Mic on" / "No microphone" (nil).
    private func flashMic(_ muted: Bool?) {
        guard let hub else { return }
        let now = Date.now
        hub.post(LiveActivity(id: Self.micFlashID, module: .hud, priority: Self.priority, updated: now,
                              expires: now.addingTimeInterval(Self.duration),
                              left: AnyView(MicWingLeft(muted: muted ?? true)),
                              right: AnyView(MicFlashRight(muted: muted))))
    }

    /// The in-use dot: shown while an app records and the mic is not muted (the muted wing has its own dot).
    private func postInUse() {
        guard let hub else { return }
        if settings.showInUse, !audio.micMuted, audio.micUse.inUse || audio.cameraInUse {
            hub.post(LiveActivity(id: Self.inUseID, module: .hud, priority: Self.inUsePriority, updated: .now,
                                  left: AnyView(InUseWingLeft(audio: audio)), right: AnyView(InUseWingRight())))
        } else {
            hub.clear(Self.inUseID)
        }
        if audio.micMuted { postMicMuted() }
    }

    /// For renders: the muted wing, the in-use dot or the toggle flash, without touching CoreAudio.
    public enum MicSample { case muted, mutedInUse, inUse, cameraInUse, flashOn }
    public func showMicSample(_ sample: MicSample) {
        guard let hub else { return }
        switch sample {
        case .muted, .mutedInUse:
            audio.setSample(muted: true, micInUse: sample == .mutedInUse, apps: sample == .mutedInUse ? ["Zoom"] : [])
            postMicMuted()
        case .inUse, .cameraInUse:
            audio.setSample(muted: false, micInUse: sample == .inUse, camera: sample == .cameraInUse, apps: ["FaceTime"])
            hub.post(LiveActivity(id: Self.inUseID, module: .hud, priority: Self.inUsePriority, updated: .now,
                                  left: AnyView(InUseWingLeft(audio: audio)), right: AnyView(InUseWingRight())))
        case .flashOn:
            flashMic(false)
        }
    }

    // MARK: Command bar

    public func commands() -> [GlancyCommand] {
        guard audio.running else { return [] }
        var out: [GlancyCommand] = []
        if let mic = micCommand(rank: 0) { out.append(mic) }
        out += audio.outputs.filter { $0.id != audio.defaultOutputID }.map { outputCommand($0, rank: 0) }
        return out
    }

    public func results(for query: String) -> [GlancyCommand] {
        guard audio.running else { return [] }
        let q = PowerCommands.normalise(query)
        guard q.count >= 2 else { return [] }
        var out: [GlancyCommand] = []
        if PowerCommands.matches(q, HUDCommands.micWords), let mic = micCommand(rank: 75) { out.append(mic) }
        let outputWord = PowerCommands.matches(q, HUDCommands.outputWords)
        for d in audio.outputs where d.id != audio.defaultOutputID && (outputWord || PowerCommands.nameMatches(q, d.name)) {
            out.append(outputCommand(d, rank: PowerCommands.nameMatches(q, d.name) ? 85 : 55))
        }
        return out
    }

    private func micCommand(rank: Int) -> GlancyCommand? {
        guard audio.micMutable else { return nil }
        let muted = audio.micMuted
        let key = settings.micHotkey.modifiers == 0 ? nil : settings.micHotkey.description
        let subtitle = [audio.defaultInput?.name, key].compactMap { $0 }.joined(separator: " · ")
        return GlancyCommand(id: "hud.mic.toggle", module: .hud,
                             title: muted ? L10n.tr("Unmute microphone") : L10n.tr("Mute microphone"),
                             subtitle: subtitle.isEmpty ? nil : subtitle,
                             symbol: muted ? "mic.fill" : "mic.slash.fill", keywords: HUDCommands.micWords,
                             rank: rank, closesPanel: false) { [weak self] in self?.toggleMic() }
    }

    private func outputCommand(_ d: AudioDevice, rank: Int) -> GlancyCommand {
        GlancyCommand(id: "hud.output.\(d.uid)", module: .hud, title: L10n.tr("Play sound on %@", d.name),
                      subtitle: audio.defaultOutput.map { L10n.tr("Now: %@", $0.name) }, symbol: d.symbol,
                      keywords: HUDCommands.outputWords, rank: rank, closesPanel: false) { [weak self] in
            self?.audio.selectOutput(d.id)
        }
    }
}

/// Command-bar words (EN + IT).
enum HUDCommands {
    static let micWords = ["microphone", "mic", "microfono", "mute", "unmute", "muto", "silenzia", "riattiva"]
    static let outputWords = ["output", "uscita", "sound", "suono", "audio", "speakers", "altoparlanti", "headphones", "cuffie"]
}

let hudItalian: [String: String] = [
    "Muted": "Muto",
    "Mic muted": "Mic muto",
    "Mic on": "Mic attivo",
    "No microphone": "Nessun microfono",
    "Mute microphone": "Silenzia microfono",
    "Unmute microphone": "Riattiva microfono",
    "Microphone": "Microfono",
    "Muted by Glancy": "Silenziato da Glancy",
    "In use by %@": "In uso da %@",
    "In use": "In uso",
    "Camera in use": "Fotocamera in uso",
    "Output": "Uscita",
    "Play sound on %@": "Riproduci audio su %@",
    "Now: %@": "Ora: %@",
    "Mute": "Silenzia",
    "Unmute": "Riattiva",
    "Can't be muted": "Non silenziabile",
]
