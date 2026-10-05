import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import GlancyKit

// The wave-4 bug-class audit, one regression per class that can be checked off the live app:
// callbacks the system makes off the main thread (the crash class of all five crash reports),
// hot-key defaults that collide, Italian strings whose placeholders don't match the English
// (a `String(format:)` crash or garbage), and AppleScript always running off main.

@MainActor
@Suite("Bug classes: isolation, hot keys, strings")
struct BugClassTests {
    // MARK: (a) Callbacks off the main thread

    /// IOBluetooth calls the connect / disconnect selectors on its coordinator queue. A main-actor
    /// `@objc` method trapped there (`_dispatch_assert_queue_fail` via `swift_task_checkIsolated`,
    /// four reports of 2026-10-05). Calling them from a background queue must simply return.
    /// (Outside an app bundle they return before touching IOBluetooth, which would kill the run.)
    @Test func bluetoothSelectorsAcceptAnyThread() async {
        let watcher = BluetoothWatcher()
        let done = await withCheckedContinuation { (k: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                watcher.perform(NSSelectorFromString("didConnect:device:"), with: NSObject(), with: NSObject())
                watcher.perform(NSSelectorFromString("didDisconnect:device:"), with: NSObject(), with: NSObject())
                k.resume(returning: !Thread.isMainThread)
            }
        }
        #expect(done)
        #expect(watcher.connected.isEmpty)
    }

    @Test func appleScriptRunsOnItsOwnQueue() async {
        let onMain = await withCheckedContinuation { (k: CheckedContinuation<Bool, Never>) in
            AppleScriptRunner.queue.async {
                // An empty script: no app is addressed, so no Automation prompt.
                _ = AppleScriptRunner.execute("")
                k.resume(returning: Thread.isMainThread)
            }
        }
        #expect(!onMain)
    }

    // MARK: (f) Hot keys

    static let ctrlOpt = UInt32(controlKey | optionKey)

    /// Every default Glancy registers, with who owns it. Workspace slots are the user's to set;
    /// ⌃⌥1…9 is where they go, so no default may sit there.
    static func defaults() -> [(owner: String, key: Hotkey)] {
        let w = WindowsHotkeys()
        var out: [(String, Hotkey)] = [("windows.autoArrange", w.autoArrange)]
        if let v = WindowsHotkeys.appVariant(w.autoArrange) { out.append(("windows.autoArrange⇧", v)) }
        for (action, key) in w.bindings { out.append(("windows.\(action.map { "\($0)" } ?? "open")", key)) }
        for (strategy, key) in w.arrangeBindings {
            out.append(("windows.arrange.\(strategy)", key))
            if let v = WindowsHotkeys.appVariant(key) { out.append(("windows.arrange.\(strategy)⇧", v)) }
        }
        out += [
            ("calendar.join", CalendarSettings.defaultJoinHotkey),
            ("notes.quick", NotesSettings.defaultHotkey),
            ("notes.voice", NotesSettings.defaultVoiceHotkey),
            ("command", CommandSettings.defaultHotkey),
            ("hud.mic", HUDSettings.defaultMicHotkey),
            ("clipboard", ClipboardSettings.defaultHotkey),
        ]
        return out
    }

    @Test func everyDefaultHotkeyIsUnique() {
        let all = Self.defaults()
        var seen: [Hotkey: String] = [:]
        for (owner, key) in all {
            #expect(key.modifiers != 0, "\(owner) has no modifier")
            if let other = seen[key] { Issue.record("\(owner) and \(other) both default to \(key.description)") }
            seen[key] = owner
        }
        // The ones the brief lists, so a silent change of any default shows up here.
        let expected = ["Space", "←", "→", "↑", "↓", "F", "Z", "B", "C", "R", "M", "G", "A", "J", "K", "N", "V", "0"]
            .map { "⌃⌥" + $0 } + ["⌃⌥⇧A", "⌃⌥⇧B", "⌃⌥⇧C", "⌃⌥⇧R", "⌃⌥⇧M", "⌃⌥⇧G", "⌥⌘V"]
        #expect(Set(all.map(\.key.description)) == Set(expected))
    }

    @Test func noDefaultTakesAWorkspaceSlot() {
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        let slots = Set(digits.map { Hotkey(keyCode: UInt32($0), modifiers: Self.ctrlOpt) })
        for (owner, key) in Self.defaults() { #expect(!slots.contains(key), "\(owner) takes workspace slot \(key.description)") }
    }

    // MARK: (b) Strings

    /// `%@`, `%d`, `%1$@`, `%.1f`…, positional indices folded (Italian may reorder them).
    static func placeholders(_ s: String) -> [String] {
        let regex = try? NSRegularExpression(pattern: #"%(?:(\d+)\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j)?([@dDiuUxXoOfeEgGcCsSpaA%])"#)
        let ns = s as NSString
        return (regex?.matches(in: s, range: NSRange(location: 0, length: ns.length)) ?? []).compactMap { m in
            let kind = ns.substring(with: m.range(at: 2))
            return kind == "%" ? nil : kind
        }.sorted()
    }

    /// Every module's Italian table, registered by starting each module once: a duplicate key in a
    /// table literal traps right there, and a placeholder mismatch is reported here.
    @Test func italianPlaceholdersMatchTheEnglish() {
        for m in ModuleLifecycleTests.makeAll() {
            m.start(hub: ActivityHub())
            m.stop()
        }
        let table = L10n.italianTable
        #expect(table.count > 500)
        for (en, it) in table where Self.placeholders(en) != Self.placeholders(it) {
            Issue.record("placeholders differ: \(en.debugDescription) → \(it.debugDescription)")
        }
    }

    @Test func placeholderParserSeesWhatFormatUses() {
        #expect(Self.placeholders("%d of %@") == ["@", "d"])
        #expect(Self.placeholders("%2$@ di %1$d") == ["@", "d"])
        #expect(Self.placeholders("100%% %.1f GB") == ["f"])
    }
}
