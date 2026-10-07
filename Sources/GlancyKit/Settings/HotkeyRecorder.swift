import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

// The shortcut recorder of Settings: click a field, press a combination, Esc cancels, ⌫ clears.
// While it listens the panel takes the keyboard (`SurfaceKeyFocus`), Glancy's own hotkeys are
// released (so pressing one records it instead of firing it), and the surface's Esc goes to it.

/// What one key press means to a recorder. Pure, unit-tested.
public enum HotkeyCapture: Equatable, Sendable {
    case cancel
    case clear
    case record(Hotkey)
    /// Not usable as a global shortcut (no ⌃, ⌥ or ⌘): keep listening.
    case ignore

    public static func interpret(keyCode: UInt16, modifiers flags: NSEvent.ModifierFlags) -> HotkeyCapture {
        let mods = flags.intersection([.control, .option, .shift, .command])
        if mods.isEmpty {
            switch Int(keyCode) {
            case kVK_Escape: return .cancel
            case kVK_Delete, kVK_ForwardDelete: return .clear
            default: return .ignore
            }
        }
        // ⇧ alone would hijack capitals everywhere.
        guard !mods.intersection([.control, .option, .command]).isEmpty else { return .ignore }
        return .record(Hotkey(keyCode: UInt32(keyCode), modifiers: Hotkey.carbonModifiers(mods)))
    }
}

/// One of Glancy's bindings, for conflict checks.
public struct HotkeyBinding: Equatable, Sendable {
    public var id: String
    public var title: String
    public var hotkey: Hotkey
    public init(id: String, title: String, hotkey: Hotkey) { self.id = id; self.title = title; self.hotkey = hotkey }
}

public enum HotkeyConflict: Equatable, Sendable {
    /// Another Glancy action uses it (its title).
    case glancy(String)
    /// A macOS shortcut (System Settings → Keyboard → Keyboard Shortcuts).
    case system
    /// The system refused to register it: another app holds it.
    case taken

    public static func find(_ binding: HotkeyBinding, among all: [HotkeyBinding], system: Set<Hotkey>,
                            failed: Set<Hotkey>) -> HotkeyConflict? {
        let h = binding.hotkey
        guard h.modifiers != 0 else { return nil }
        if let other = all.first(where: { $0.id != binding.id && $0.hotkey == h }) { return .glancy(other.title) }
        if system.contains(h) { return .system }
        if failed.contains(h) { return .taken }
        return nil
    }

    /// The enabled macOS symbolic hotkeys (Mission Control, Spotlight, screenshots…).
    public static func systemHotkeys() -> Set<Hotkey> {
        var array: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&array) == noErr,
              let list = array?.takeRetainedValue() as? [[String: Any]] else { return [] }
        var out: Set<Hotkey> = []
        for entry in list {
            guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = entry[kHISymbolicHotKeyCode as String] as? Int, code >= 0, code < 0xFFFF,
                  let mods = entry[kHISymbolicHotKeyModifiers as String] as? Int else { continue }
            out.insert(Hotkey(keyCode: UInt32(code), modifiers: UInt32(mods) & UInt32(cmdKey | optionKey | controlKey | shiftKey)))
        }
        return out
    }
}

/// The one recorder listening right now, if any.
@MainActor @Observable
final class HotkeyRecorder {
    static let shared = HotkeyRecorder()

    private(set) var recording: String?
    /// The last press was refused (no ⌃ ⌥ ⌘): the field says so.
    private(set) var refused = false
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var commit: ((Hotkey) -> Void)?
    private static let focusOwner = "settings.hotkeyRecorder"

    func begin(_ id: String, commit: @escaping (Hotkey) -> Void) {
        end()
        recording = id
        refused = false
        self.commit = commit
        HotkeyManager.shared.setSuspended(true)
        SurfaceKeyFocus.request(true, owner: Self.focusOwner)
        SurfaceKeyFocus.escapeInterceptor = { [weak self] in
            guard let self, self.recording != nil else { return false }
            self.end()
            return true
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let used = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return used ? nil : event
        }
    }

    /// True = the event was ours.
    private func handle(_ event: NSEvent) -> Bool {
        guard recording != nil else { return false }
        switch HotkeyCapture.interpret(keyCode: event.keyCode, modifiers: event.modifierFlags) {
        case .cancel:
            end()
        case .clear:
            finish(Hotkey(keyCode: 0, modifiers: 0))
        case .record(let h):
            finish(h)
        case .ignore:
            refused = true
        }
        return true
    }

    private func finish(_ h: Hotkey) {
        let commit = commit
        end()            // Glancy's hotkeys come back first…
        commit?(h)       // …then the owner re-registers with the new one.
    }

    func cancel(_ id: String) { if recording == id { end() } }

    func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        commit = nil
        guard recording != nil else { return }
        recording = nil
        refused = false
        SurfaceKeyFocus.escapeInterceptor = nil
        HotkeyManager.shared.setSuspended(false)
        SurfaceKeyFocus.request(false, owner: Self.focusOwner)
    }
}

extension SurfaceKeyFocus {
    /// Gets the surface's Esc first (a recorder cancels instead of the panel closing). Returns
    /// true when it consumed the key.
    static var escapeInterceptor: (() -> Bool)?
}

/// A shortcut field: shows the combination, records a new one on click.
struct HotkeyField: View {
    let id: String
    let hotkey: Hotkey
    let conflict: HotkeyConflict?
    let onChange: (Hotkey) -> Void
    @State private var hover = false
    @Environment(\.settingsChrome) private var chrome

    var body: some View {
        let recorder = HotkeyRecorder.shared
        let recording = recorder.recording == id
        VStack(alignment: .trailing, spacing: chrome == .window ? 3 : 1.ui) {
            Button {
                if recording { recorder.end() } else { recorder.begin(id, commit: onChange) }
            } label: {
                if chrome == .window { windowField(recording: recording) } else { notchField(recording: recording) }
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .help(tr("Click, then press the new shortcut. Esc cancels, ⌫ clears."))
            if let note = note(recording: recording, refused: recorder.refused) {
                Text(verbatim: note)
                    .font(chrome == .window ? SettingsStyle.font(.xs) : .system(size: 9.5.ui))
                    .foregroundStyle(recording ? (chrome == .window ? SettingsStyle.tertiary : Theme.tertiary)
                                     : (chrome == .window ? SettingsStyle.waiting : Theme.waiting))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .onDisappear { recorder.cancel(id) }
    }

    private func notchField(recording: Bool) -> some View {
        Text(verbatim: label(recording: recording))
            .font(Theme.font(.s, recording ? .regular : .medium).monospacedDigit())
            .foregroundStyle(recording ? Theme.secondary : hotkey.modifiers == 0 ? Theme.tertiary : Theme.primary)
            .lineLimit(1)
            .padding(.horizontal, 8.ui)
            .frame(minWidth: 64.ui)
            .frame(height: 20.ui)
            .background(Capsule().fill(recording || hover ? Color.white.opacity(0.12) : Theme.card))
            .overlay(Capsule().strokeBorder(recording ? Theme.secondary : conflict != nil ? Theme.waiting.opacity(0.7) : .clear,
                                            lineWidth: 1.ui))
            .contentShape(Capsule())
    }

    /// A recorder field like a text field: the focus ring while it listens.
    private func windowField(recording: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return Text(verbatim: label(recording: recording))
            .font(.system(size: 12, weight: recording ? .regular : .medium).monospacedDigit())
            .foregroundStyle(recording ? SettingsStyle.secondary : hotkey.modifiers == 0 ? SettingsStyle.faint : SettingsStyle.primary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(minWidth: 88)
            .frame(height: 22)
            .background(shape.fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(shape.strokeBorder(recording ? Color.accentColor
                                        : conflict != nil ? SettingsStyle.waiting
                                        : hover ? Color.primary.opacity(0.25) : Color.primary.opacity(0.14),
                                        lineWidth: recording ? 2 : 1))
            .contentShape(shape)
    }

    private func label(recording: Bool) -> String {
        if recording { return tr("Press keys…") }
        return hotkey.modifiers == 0 ? tr("None") : hotkey.description
    }

    private func note(recording: Bool, refused: Bool) -> String? {
        if recording { return refused ? tr("Add ⌃, ⌥ or ⌘") : tr("Esc cancels · ⌫ clears") }
        switch conflict {
        case .glancy(let other): return L10n.tr("Also %@", other)
        case .system: return tr("Used by macOS")
        case .taken: return tr("Taken by another app")
        case nil: return nil
        }
    }
}
