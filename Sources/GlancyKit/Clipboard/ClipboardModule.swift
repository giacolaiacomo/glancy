import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Clipboard history (SPEC §3). On demand: no Home card, no live activity, no peek.
/// Capture triggers, never polling: ⌘C/⌘X (listen-only event tap, checks at +150 and +600 ms),
/// app activation, panel open.
@MainActor
public final class ClipboardModule: GlancyModule {
    public let id: ModuleID = .clipboard
    public let model: ClipboardModel
    /// Synthetic history, no observers (the renderer; never shows the user's real clipboard).
    let sample: Bool

    private let tap = CopyKeyTap()
    private var hub: ActivityHub?
    private var activation: NSObjectProtocol?
    private var hotkey: HotkeyManager.Token?
    private var pending: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var pasteTask: Task<Void, Never>?
    /// The last app that was frontmost and not us: the source of a copy, the target of a paste.
    private var lastFrontmost: NSRunningApplication?
    private var panelOpen = false
    private var started = false

    /// The hotkey is set but the system refused it (taken by another app).
    public private(set) var hotkeyFailed = false

    public convenience init() {
        let env = ProcessInfo.processInfo
        let sample = env.processName == "glancy-render" || env.environment["GLANCY_CLIPBOARD_SAMPLE"] == "1"
        if sample {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glancy-clipboard-sample", isDirectory: true)
            self.init(disk: ClipboardDisk(directory: dir), settings: ClipboardSettings(defaults: UserDefaults(suiteName: "ai.glancy.clipboard.sample")!),
                      pasteboard: NSPasteboard(name: .init("ai.glancy.clipboard.sample")), sample: true)
        } else {
            self.init(disk: ClipboardDisk(), settings: ClipboardSettings(), pasteboard: .general, sample: false)
        }
    }

    public init(disk: ClipboardDisk, settings: ClipboardSettings, pasteboard: NSPasteboard, sample: Bool = false) {
        self.model = ClipboardModel(disk: disk, settings: settings, pasteboard: pasteboard)
        self.sample = sample
    }

    // MARK: Lifecycle

    public func start(hub: ActivityHub) {
        guard !started else { return }
        started = true
        self.hub = hub
        L10n.addItalian(ClipText.italian)
        model.onChosen = { [weak self] item in self?.chosen(item) }
        if sample {
            model.items = ClipboardSample.items(blobs: model.disk.blobs)
            model.loaded = true
            model.copyKeysSeen = true
            return
        }
        // What is on the pasteboard at launch is not recorded: we cannot tell where it came from.
        model.lastChangeCount = model.pasteboard.changeCount
        loadTask = Task { [weak self] in await self?.model.load() }
        lastFrontmost = Self.notUs(NSWorkspace.shared.frontmostApplication)
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.appActivated(app) }
        }
        tap.onCopyKey = { [weak self] in self?.copyKeyPressed() }
        model.copyKeysSeen = tap.install()
        registerHotkey()
    }

    private func registerHotkey() {
        if let hotkey { HotkeyManager.shared.unregister(hotkey) }
        hotkey = nil
        let combo = model.settings.hotkey
        guard combo.modifiers != 0 else { hotkeyFailed = false; return }
        hotkey = HotkeyManager.shared.register(combo) { [weak self] in
            self?.hub?.requestOpen(.clipboard)
        }
        hotkeyFailed = hotkey == nil
    }

    /// Changes the hotkey (Settings → Clipboard); a combination without modifiers clears it.
    public func setHotkey(_ combo: Hotkey) {
        guard combo != model.settings.hotkey else { return }
        model.settings.hotkey = combo
        if started, !sample { registerHotkey() }
    }

    /// A permission may have changed: catch ⌘C at once when the tap can now be installed.
    public func permissionsChanged() {
        guard started, !sample, !tap.installed else { return }
        model.copyKeysSeen = tap.install()
    }

    public func stop() {
        guard started else { return }
        started = false
        pending?.cancel(); loadTask?.cancel(); pasteTask?.cancel()
        pending = nil; loadTask = nil; pasteTask = nil
        tap.uninstall()
        tap.onCopyKey = nil
        model.copyKeysSeen = false
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil
        if let hotkey { HotkeyManager.shared.unregister(hotkey) }
        hotkey = nil
        model.setVisible(false)
        model.onChosen = nil
        if !sample {
            let items = model.items
            let disk = model.disk
            Task { await disk.save(items) }
        }
        hub = nil
        panelOpen = false
    }

    public func visibilityChanged(_ visibility: SurfaceVisibility) {
        guard started else { return }
        if case .expanded(let tab) = visibility {
            if !panelOpen, !sample {
                panelOpen = true
                // A copy made from a menu with the mouse is caught here at the latest.
                model.check(source: lastFrontmost)
                // Input Monitoring may have been granted since launch.
                if !tap.installed { model.copyKeysSeen = tap.install() }
            }
            model.setVisible(tab == .clipboard)
        } else {
            panelOpen = false
            model.setVisible(false)
        }
    }

    // MARK: Triggers

    private func copyKeyPressed() {
        // The source app writes the pasteboard after the key: look shortly after, and once more.
        pending?.cancel()
        let source = NSWorkspace.shared.frontmostApplication
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.model.check(source: Self.notUs(source))
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.model.check(source: Self.notUs(source))
        }
    }

    private func appActivated(_ app: NSRunningApplication?) {
        // A copy not seen yet came from the app being left.
        if !sample { model.check(source: lastFrontmost) }
        if let app = Self.notUs(app) { lastFrontmost = app }
    }

    private static func notUs(_ app: NSRunningApplication?) -> NSRunningApplication? {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return app
    }

    // MARK: Copy back

    private func chosen(_ item: ClipItem) {
        hub?.requestClose()
        guard model.settings.pasteAfterChoosing, Lab.accessibilityTrusted(), !sample else { return }
        let target = lastFrontmost
        pasteTask?.cancel()
        pasteTask = Task {
            // Let the panel close (and the target take focus back) before the keystroke.
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            if let target, !target.isActive {
                target.activate()
                try? await Task.sleep(for: .milliseconds(120))
            }
            Self.postPaste()
        }
    }

    /// ⌘V into whatever is frontmost.
    private static func postPaste() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Asks for Accessibility when "Paste after choosing" is turned on without it.
    public func pasteSettingChanged(_ on: Bool) {
        guard on, !Lab.accessibilityTrusted() else { return }
        // kAXTrustedCheckOptionPrompt, spelled out (the global is not concurrency-safe).
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    // MARK: Surface

    public var tab: PanelTab? {
        PanelTab(module: .clipboard, symbol: "doc.on.clipboard", title: "Clipboard") { [model, weak self] in
            AnyView(ClipboardTabView(model: model, onPasteSetting: { self?.pasteSettingChanged($0) }))
        }
    }
}
