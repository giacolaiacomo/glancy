import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import GlancyKit

// Lot I: the shortcut recorder's key logic, conflicts, the permission center's change reporting,
// module settings that became editable (HUD keys, clipboard hotkey, Pomodoro lengths), the
// settings navigation and the first-run flag.

private func defaults() -> (UserDefaults, () -> Void) {
    let suite = "ai.glancy.tests.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    return (d, { d.removePersistentDomain(forName: suite) })
}

@Suite("Shortcut recorder")
struct HotkeyRecorderTests {
    @Test func escapeCancelsDeleteClears() {
        #expect(HotkeyCapture.interpret(keyCode: UInt16(kVK_Escape), modifiers: []) == .cancel)
        #expect(HotkeyCapture.interpret(keyCode: UInt16(kVK_Delete), modifiers: []) == .clear)
        #expect(HotkeyCapture.interpret(keyCode: UInt16(kVK_ForwardDelete), modifiers: []) == .clear)
        // Caps Lock / Fn flags don't count as modifiers.
        #expect(HotkeyCapture.interpret(keyCode: UInt16(kVK_Escape), modifiers: [.capsLock, .function]) == .cancel)
    }

    @Test func needsControlOptionOrCommand() {
        #expect(HotkeyCapture.interpret(keyCode: UInt16(kVK_ANSI_A), modifiers: []) == .ignore)
        #expect(HotkeyCapture.interpret(keyCode: UInt16(kVK_ANSI_A), modifiers: [.shift]) == .ignore)
        let combo = HotkeyCapture.interpret(keyCode: UInt16(kVK_LeftArrow), modifiers: [.control, .option, .numericPad, .function])
        #expect(combo == .record(Hotkey(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(controlKey | optionKey))))
        let shifted = HotkeyCapture.interpret(keyCode: UInt16(kVK_ANSI_K), modifiers: [.command, .shift])
        #expect(shifted == .record(Hotkey(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | shiftKey))))
        // ⌥⌫ is a combination, not "clear".
        #expect(HotkeyCapture.interpret(keyCode: UInt16(kVK_Delete), modifiers: [.option])
                == .record(Hotkey(keyCode: UInt32(kVK_Delete), modifiers: UInt32(optionKey))))
    }

    @Test func conflicts() {
        let ctrlOpt = UInt32(controlKey | optionKey)
        let left = Hotkey(keyCode: UInt32(kVK_LeftArrow), modifiers: ctrlOpt)
        let space = Hotkey(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey))
        let v = Hotkey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | optionKey))
        let all = [HotkeyBinding(id: "windows.leftHalf", title: "Left half", hotkey: left),
                   HotkeyBinding(id: "clipboard", title: "Clipboard", hotkey: v)]
        // Another of Glancy's actions on the same keys.
        #expect(HotkeyConflict.find(HotkeyBinding(id: "windows.open", title: "Open", hotkey: left), among: all,
                                    system: [], failed: []) == .glancy("Left half"))
        // Its own binding is not a conflict.
        #expect(HotkeyConflict.find(all[0], among: all, system: [], failed: []) == nil)
        // A macOS shortcut (⌘Space = Spotlight), then one the system refused.
        #expect(HotkeyConflict.find(HotkeyBinding(id: "x", title: "X", hotkey: space), among: all,
                                    system: [space], failed: []) == .system)
        #expect(HotkeyConflict.find(all[1], among: all, system: [], failed: [v]) == .taken)
        // A cleared binding never conflicts, even with another cleared one.
        let none = Hotkey(keyCode: 0, modifiers: 0)
        #expect(HotkeyConflict.find(HotkeyBinding(id: "a", title: "A", hotkey: none),
                                    among: [HotkeyBinding(id: "b", title: "B", hotkey: none)], system: [], failed: []) == nil)
    }

    @Test func systemHotkeysAreReadable() {
        // CopySymbolicHotKeys works without any permission; every entry has a modifier or a key.
        let system = HotkeyConflict.systemHotkeys()
        #expect(system.allSatisfy { $0.keyCode < 0xFFFF })
    }
}

@MainActor @Suite("Hotkey suspension")
struct HotkeySuspensionTests {
    /// Raw Carbon registration of the same combination: refused while Glancy holds it.
    private func carbonFree(_ h: Hotkey) -> Bool {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(h.keyCode, h.modifiers, EventHotKeyID(signature: OSType(0x7465_7374), id: 99),
                                         GetApplicationEventTarget(), 0, &ref)
        if let ref { UnregisterEventHotKey(ref) }
        return status == noErr
    }

    @Test func recorderReleasesAndRestoresHotkeys() throws {
        let h = Hotkey(keyCode: UInt32(kVK_F19), modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey))
        let manager = HotkeyManager.shared
        let token = try #require(manager.register(h) {})
        defer { manager.unregister(token); manager.setSuspended(false) }
        #expect(!carbonFree(h))                       // held by Glancy
        manager.setSuspended(true)
        #expect(carbonFree(h))                        // released while recording
        #expect(manager.registered.contains(h))       // but still known
        manager.setSuspended(false)
        #expect(!carbonFree(h))                       // taken back
    }
}

@MainActor @Suite("Permissions")
struct PermissionCenterTests {
    @Test func firstReadIsSilentThenChangesAreReported() {
        let (d, clean) = defaults()
        defer { clean() }
        let center = PermissionCenter(probe: .fixed([:]), defaults: d)
        var changes = 0
        center.onChange = { changes += 1 }
        center.apply([.calendar: .notDetermined, .accessibility: .notDetermined])
        #expect(changes == 0)                         // baseline
        center.apply([.calendar: .notDetermined, .accessibility: .notDetermined])
        #expect(changes == 0)                         // nothing moved
        center.apply([.calendar: .granted, .accessibility: .notDetermined])
        #expect(changes == 1)
        #expect(center.status(.calendar) == .granted)
        #expect(center.status(.bluetooth) == .notDetermined)   // unknown reads as "ask"
    }

    @Test func refreshReadsTheProbeOffMain() async {
        let (d, clean) = defaults()
        defer { clean() }
        let center = PermissionCenter(probe: .fixed([.fullDiskAccess: .denied]), defaults: d)
        center.refresh()
        for _ in 0..<50 where center.status.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(center.status(.fullDiskAccess) == .denied)
    }

    @Test(.disabled(if: CI.isCI, "reads the real TCC, EventKit and Automation state of this Mac"))
    func systemProbeReadsEveryStatusWithoutAsking() async {
        // Real reads only: AXIsProcessTrusted, EKEventStore status, an open() on the notification
        // database, AEDeterminePermissionToAutomateTarget with ask = false. No prompt can appear.
        let status = await PermissionProbe.system.read()
        #expect(Set(status.keys) == Set(PermissionKind.allCases))
        #expect(status[.notifications] == .unavailable)   // outside an app bundle
        #expect(status[.bluetooth] == .unavailable)       // no usage string in a test host
        print("system permission statuses:", status.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue)=\($0.value)" })
    }

    @Test func deepLinks() {
        #expect(PermissionCenter.settingsURL(.accessibility).absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        #expect(PermissionCenter.settingsURL(.calendar).absoluteString.hasSuffix("Privacy_Calendars"))
        #expect(PermissionCenter.settingsURL(.bluetooth).absoluteString.hasSuffix("Privacy_Bluetooth"))
        #expect(PermissionCenter.settingsURL(.fullDiskAccess).absoluteString.hasSuffix("Privacy_AllFiles"))
        #expect(PermissionCenter.settingsURL(.automation).absoluteString.hasSuffix("Privacy_Automation"))
    }

    @Test func fullDiskAccessIsDetectedByOpeningAFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let readable = dir.appendingPathComponent("db")
        try Data("x".utf8).write(to: readable)
        #expect(SystemPermissions.fullDiskAccess(path: readable.path) == .granted)
        let locked = dir.appendingPathComponent("locked")
        try Data("x".utf8).write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        #expect(SystemPermissions.fullDiskAccess(path: locked.path) == .denied)
        #expect(SystemPermissions.fullDiskAccess(path: dir.appendingPathComponent("missing").path) == .unavailable)
    }
}

@MainActor @Suite("Module settings")
struct ModuleSettingsTests {
    @Test func hudKeysPersist() {
        let (d, clean) = defaults()
        defer { clean() }
        let s = HUDSettings(defaults: d)
        #expect(s.kinds == Set(HUDKind.allCases))
        var changes = 0
        s.onChange = { changes += 1 }
        s.set(.keyboard, false)
        #expect(changes == 1 && !s.handles(.keyboard) && s.handles(.volume))
        s.set(.keyboard, false)
        #expect(changes == 1)                         // no change, no callback
        #expect(HUDSettings(defaults: d).kinds == [.volume, .brightness])
    }

    @Test func clipboardHotkeyPersistsAndClears() {
        let (d, clean) = defaults()
        defer { clean() }
        let s = ClipboardSettings(defaults: d)
        #expect(s.hotkey == ClipboardSettings.defaultHotkey)
        s.hotkey = Hotkey(keyCode: 0, modifiers: 0)
        #expect(ClipboardSettings(defaults: d).hotkey.modifiers == 0)   // cleared stays cleared
        let shiftV = Hotkey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey))
        s.hotkey = shiftV
        #expect(ClipboardSettings(defaults: d).hotkey == shiftV)
    }

    @Test func pomodoroLengths() throws {
        let (d, clean) = defaults()
        defer { clean() }
        #expect(PomodoroLengths.load(d) == PomodoroLengths())
        let l = PomodoroLengths(focus: 50, shortBreak: 10, longBreak: 500)
        #expect(l.longBreak == PomodoroLengths.range.upperBound)    // clamped
        l.save(d)
        #expect(PomodoroLengths.load(d) == l)
        #expect(Pomodoro.duration(of: 0, lengths: l) == 50 * 60)
        #expect(Pomodoro.duration(of: 1, lengths: l) == 10 * 60)
        #expect(Pomodoro.duration(of: Pomodoro.lastPhase, lengths: l) == 120 * 60)
        // A partial or older value decodes leniently.
        let partial = try JSONDecoder().decode(PomodoroLengths.self, from: Data(#"{"focus": 40}"#.utf8))
        #expect(partial == PomodoroLengths(focus: 40))
    }

    @Test func windowsClearedBindingDecodes() throws {
        var h = WindowsHotkeys()
        h.undo = Hotkey(keyCode: 0, modifiers: 0)
        let back = try JSONDecoder().decode(WindowsHotkeys.self, from: JSONEncoder().encode(h))
        #expect(back.undo.modifiers == 0 && back.leftHalf == WindowsHotkeys().leftHalf)
    }
}

@MainActor @Suite("Settings page")
struct SettingsPageTests {
    @Test func navigationAndWelcome() {
        let nav = SettingsNavigation()
        #expect(nav.route == .index && !nav.welcome)
        nav.showWelcome()
        #expect(nav.route == .permissions && nav.welcome)
        nav.go(.module(.calendar), animated: false)
        #expect(nav.route == .module(.calendar) && !nav.welcome)
    }

    @Test func firstRunFlag() {
        let (d, clean) = defaults()
        defer { clean() }
        let s = AppSettings(defaults: d)
        #expect(s.needsOnboarding)
        s.markOnboarded()
        #expect(!AppSettings(defaults: d).needsOnboarding)
    }

    @Test func checklistShowsOnlyWhatModulesUse() {
        let (d, clean) = defaults()
        defer { clean() }
        let settings = AppSettings(defaults: d)
        let none = SurfaceContext(hub: ActivityHub(), settings: settings, launchAtLogin: LaunchAtLogin(), modules: [])
        #expect(PermissionRows.visible(none).isEmpty)
        let media = MediaModule()
        let ctx = SurfaceContext(hub: ActivityHub(), settings: settings, launchAtLogin: LaunchAtLogin(),
                                 modules: [CalendarModule(), media, TimerModule(store: TimerStore(url: URL(fileURLWithPath: "/dev/null")), alerts: NoAlerts())])
        #expect(PermissionRows.visible(ctx) == [.calendar, .notifications])
        media.model.source = .scripts                  // the media fallback needs Automation
        #expect(PermissionRows.visible(ctx) == [.calendar, .notifications, .automation])
        settings.permissions.apply([.calendar: .granted, .notifications: .denied, .automation: .unavailable])
        #expect(PermissionRows.missing(ctx) == 1)
    }

    @Test func everySettingsStringHasItalian() throws {
        // Every literal the settings files pass to tr(...) has an Italian entry.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("Sources/GlancyKit/Settings")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "SettingsText.swift" }
        let pattern = try NSRegularExpression(pattern: #"\btr\("((?:[^"\\]|\\.)*)""#)
        var missing: [String] = []
        L10n.apply(.it)
        defer { L10n.apply(.en) }
        for f in files {
            let s = try String(contentsOf: f, encoding: .utf8)
            for m in pattern.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                let key = String(s[Range(m.range(at: 1), in: s)!])
                if L10n.tr(key) == key, !["Bluetooth", "Volume", "%d / %d / %d min", "%d min", "HUD", "Timer", "Home"].contains(key) { missing.append(key) }
            }
        }
        #expect(missing.isEmpty, "untranslated: \(missing)")
    }
}

@MainActor
private final class NoAlerts: TimerAlerting {
    func schedule(at date: Date, title: String, body: String) {}
    func cancel() {}
}
