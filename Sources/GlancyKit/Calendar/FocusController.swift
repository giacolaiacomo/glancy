import AppKit
import Foundation
import Observation

// Focus (Do Not Disturb) on and off for meetings and Pomodoro focus rounds.
//
// macOS has no public API to set a Focus. The supported route is Shortcuts: its "Set Focus"
// action turns any Focus on or off, and `/usr/bin/shortcuts run <name>` runs a shortcut from any
// process without Accessibility or Automation prompts. Glancy cannot create shortcuts, so the user
// makes two once ("Glancy Focus On", "Glancy Focus Off"; Settings shows how) and Glancy runs them.
// Everything else (UI scripting Control Center, `defaults write com.apple.ncprefs`, the private
// DoNotDisturb framework) is either broken on current macOS, needs Accessibility, or needs Apple's
// private entitlements.
//
// Owners (the calendar, the timer) *claim* Focus; it is on while any claim stands. Glancy turns it
// off only when it turned it on itself (`isOn`, persisted across relaunches).

/// Runs the Shortcuts command line. Off main; tests inject a recorder.
public protocol ShortcutRunning: Sendable {
    /// The names of the user's shortcuts; nil when the list could not be read.
    func list() async -> [String]?
    /// Runs one shortcut by name; false when it failed (missing, error, timed out).
    func run(_ name: String) async -> Bool
}

/// `/usr/bin/shortcuts`, one child process per call, killed after `timeout`.
public struct ShortcutsCLI: ShortcutRunning {
    public static let path = "/usr/bin/shortcuts"
    public var timeout: TimeInterval = 20
    public init() {}

    public static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: path) }

    public func list() async -> [String]? {
        guard let (status, out) = await Self.exec(["list"], timeout: timeout), status == 0 else { return nil }
        return out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public func run(_ name: String) async -> Bool {
        guard let (status, _) = await Self.exec(["run", name], timeout: timeout) else { return false }
        return status == 0
    }

    static func exec(_ args: [String], timeout: TimeInterval) async -> (Int32, String)? {
        guard isAvailable else { return nil }
        return await withCheckedContinuation { (done: CheckedContinuation<(Int32, String)?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { done.resume(returning: nil); return }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                done.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }
}

@MainActor @Observable
public final class FocusController {
    /// The real one (the app's modules). Tests and isolated runs make their own or pass none.
    public static let shared = FocusController(runner: ShortcutsCLI(), defaults: .standard)

    public nonisolated static let onShortcut = "Glancy Focus On"
    public nonisolated static let offShortcut = "Glancy Focus Off"
    nonisolated static let isOnKey = "glancy.focus.glancyOn"

    public enum Setup: Equatable, Sendable {
        case unknown, checking, ready
        /// The shortcuts not found (by name).
        case missing([String])
        /// No Shortcuts command line (or its list failed).
        case unavailable
    }

    public private(set) var setup: Setup = .unknown
    /// Glancy turned Focus on and has not turned it off yet.
    public private(set) var isOn: Bool
    /// The last run failed: Settings says so.
    public private(set) var lastRunFailed = false

    @ObservationIgnored private let runner: ShortcutRunning
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var registered: [String: () -> Void] = [:]
    @ObservationIgnored private var claims: [String: Bool] = [:]
    @ObservationIgnored private var queue: Task<Void, Never>?
    @ObservationIgnored private var checking: Task<Void, Never>?
    /// "On" failed: don't retry at every refresh; wait until nobody wants Focus, or the setup
    /// check finds the shortcuts.
    @ObservationIgnored private var blocked = false
    /// Renders and previews: never run anything.
    @ObservationIgnored public var frozen = false

    public init(runner: ShortcutRunning, defaults: UserDefaults) {
        self.runner = runner
        self.defaults = defaults
        isOn = defaults.bool(forKey: Self.isOnKey)
    }

    // MARK: Owners

    /// An owner (e.g. "calendar", "timer") takes part. Until every registered owner has claimed
    /// once, nothing is turned off (a relaunch mid-meeting must not flap). `onOverride` is called
    /// when the user turns Focus off by hand: the owner stops claiming for what is running now.
    public func register(_ owner: String, onOverride: @escaping () -> Void) {
        registered[owner] = onOverride
    }

    /// The owner leaves (module stopped): its claim goes, and Focus with it if it was the last.
    public func unregister(_ owner: String) {
        registered[owner] = nil
        claims[owner] = nil
        evaluate()
    }

    public func claim(_ owner: String, _ wants: Bool) {
        guard registered[owner] != nil else { return }
        claims[owner] = wants
        evaluate()
    }

    /// Whether some owner wants Focus right now.
    public var isWanted: Bool { claims.values.contains(true) }

    /// "Turn Focus off" by hand: every owner lets go of what is running now, then Focus goes off.
    public func turnOffNow() {
        for (_, onOverride) in registered { onOverride() }
        evaluate()
        if isOn { setOn(false) }
    }

    private func evaluate() {
        let want = isWanted
        if !want { blocked = false }
        if want, !isOn, !blocked { setOn(true); return }
        // Off only once every owner has spoken (a persisted `isOn` from before a relaunch waits).
        if !want, isOn, registered.keys.allSatisfy({ claims[$0] != nil }) { setOn(false) }
    }

    private func setOn(_ on: Bool) {
        isOn = on
        guard !frozen else { return }
        defaults.set(on, forKey: Self.isOnKey)
        let name = on ? Self.onShortcut : Self.offShortcut
        let previous = queue
        queue = Task { [runner, weak self] in
            await previous?.value
            let ok = await runner.run(name)
            await MainActor.run { self?.ran(on: on, ok: ok) }
        }
    }

    private func ran(on: Bool, ok: Bool) {
        lastRunFailed = !ok
        if ok {
            if setup != .ready { setup = .ready }
            return
        }
        // It did not turn on: don't claim we own it (and don't try to turn it off later).
        if on, isOn { isOn = false; defaults.set(false, forKey: Self.isOnKey); blocked = true }
        checkSetup()
    }

    /// Waits for the runs queued so far (tests).
    public func settle() async {
        await queue?.value
        await checking?.value
    }

    // MARK: Setup

    /// Looks for the two shortcuts (`shortcuts list`, off main). Called when Settings shows the
    /// Focus options, on "Check again", and after a failed run; never periodically.
    public func checkSetup() {
        guard !frozen, setup != .checking else { return }
        setup = .checking
        checking = Task { [runner, weak self] in
            let names = await runner.list()
            await MainActor.run { self?.checked(Self.setup(from: names)) }
        }
    }

    private func checked(_ s: Setup) {
        setup = s
        // The shortcuts are there now: a meeting in progress gets its Focus.
        if s == .ready, blocked { blocked = false; evaluate() }
    }

    public static func setup(from names: [String]?) -> Setup {
        guard let names else { return .unavailable }
        let have = Set(names.map { $0.lowercased() })
        let missing = [onShortcut, offShortcut].filter { !have.contains($0.lowercased()) }
        return missing.isEmpty ? .ready : .missing(missing)
    }

    /// Renders: a fixed setup state, nothing run.
    public func prepareForRender(_ s: Setup) {
        frozen = true
        setup = s
    }

    /// Opens a new, empty shortcut in Shortcuts (the setup card).
    public static func openShortcutsEditor() {
        if let url = URL(string: "shortcuts://create-shortcut"), NSWorkspace.shared.open(url) { return }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
