import AppKit
import CoreWLAN
import IOKit.pwr_mgt

// Every system side effect of the Control module goes through `SystemActions`. The live
// implementation talks to macOS; tests and renders use fakes, so no automated run ever changes the
// user's appearance, Wi-Fi, Finder, sleep, lock or Trash.

/// The answer of a scripted action (System Events, Finder).
public enum ScriptOutcome: Error, Equatable, Sendable {
    case ok
    /// Automation for the target app was refused (or not yet allowed and the prompt dismissed).
    case needsPermission
    case failed(String)
}

/// The Finder preferences the Control tab flips (both need a Finder restart to apply).
public enum FinderFlag: String, Sendable {
    case desktopIcons = "CreateDesktop"
    case hiddenFiles = "AppleShowAllFiles"
}

public struct TrashSummary: Equatable, Sendable {
    public var items: Int
    /// nil when the size can't be read (no Full Disk Access): the count comes from Finder.
    public var bytes: Int64?
    public init(items: Int, bytes: Int64?) { self.items = items; self.bytes = bytes }
}

public enum ScreenshotTarget: Sendable { case clipboard, desktop }

public enum CameraAccess: Sendable, Equatable {
    case granted, denied, notDetermined
    /// No usage string in Info.plist (tests, `swift run`): asking would crash the process.
    case unavailable
}

/// System calls of the Control module. Main-actor; anything that can block is async and runs off
/// the main thread inside the live implementation.
@MainActor
public protocol SystemActions: AnyObject {
    // Keep awake
    /// Takes (true) or releases (false) the no-idle-sleep assertion. Returns false on failure.
    func holdAwake(_ on: Bool) -> Bool

    // Toggle states (cheap reads)
    func darkMode() -> Bool
    /// nil = no Wi-Fi interface.
    func wifiPower() -> Bool?
    func finderFlag(_ flag: FinderFlag) -> Bool

    // Toggles
    func setDarkMode(_ on: Bool) async -> ScriptOutcome
    func setWiFiPower(_ on: Bool) -> Bool
    /// Writes the Finder preference and restarts Finder.
    func setFinderFlag(_ flag: FinderFlag, _ on: Bool) async -> Bool

    // Tools
    func lockScreen()
    func sleepDisplay()
    func startScreenSaver()
    func screenshot(_ target: ScreenshotTarget)
    func trashSummary() async -> Result<TrashSummary, ScriptOutcome>
    func emptyTrash() async -> ScriptOutcome
    /// Names of the volumes "Eject all" would eject.
    func ejectableVolumes() -> [String]
    /// Returns how many were ejected and how many refused (in use).
    func ejectAll() async -> (ejected: Int, failed: Int)
    /// Shows the system colour loupe; `done` gets nil when cancelled.
    func sampleColor(_ done: @escaping @MainActor (RGB?) -> Void)
    func copy(_ text: String)
    func cameraAccess() -> CameraAccess
    func requestCamera() async -> Bool
    func openAutomationSettings()
    func openCameraSettings()
}

// MARK: - Live

@MainActor
public final class LiveSystemActions: SystemActions {
    private var assertion: IOPMAssertionID = 0
    private var sampler: NSColorSampler?
    private static let scriptQueue = DispatchQueue(label: "ai.glancy.control.script", qos: .userInitiated)

    public init() {}

    // MARK: Keep awake

    public func holdAwake(_ on: Bool) -> Bool {
        if on {
            guard assertion == 0 else { return true }
            var id: IOPMAssertionID = 0
            let r = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                "Glancy: keep awake" as CFString, &id)
            guard r == kIOReturnSuccess else { return false }
            assertion = id
            return true
        }
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
        return true
    }

    // MARK: States

    public func darkMode() -> Bool {
        // The global domain is in the standard search list (a suite named NSGlobalDomain is nil).
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    public func wifiPower() -> Bool? {
        CWWiFiClient.shared().interface()?.powerOn()
    }

    public func finderFlag(_ flag: FinderFlag) -> Bool {
        let v = CFPreferencesCopyAppValue(flag.rawValue as CFString, "com.apple.finder" as CFString)
        let on: Bool? = (v as? Bool) ?? (v as? NSNumber)?.boolValue
            ?? (v as? String).map { ["1", "true", "yes"].contains($0.lowercased()) }
        switch flag {
        case .desktopIcons: return !(on ?? true)       // "hidden" when CreateDesktop is false
        case .hiddenFiles: return on ?? false
        }
    }

    // MARK: Toggles

    public func setDarkMode(_ on: Bool) async -> ScriptOutcome {
        await Self.run("tell application \"System Events\" to tell appearance preferences to set dark mode to \(on)")
    }

    public func setWiFiPower(_ on: Bool) -> Bool {
        guard let iface = CWWiFiClient.shared().interface() else { return false }
        do { try iface.setPower(on); return true } catch { return false }
    }

    public func setFinderFlag(_ flag: FinderFlag, _ on: Bool) async -> Bool {
        let value: Bool = switch flag {
        case .desktopIcons: !on       // on = icons hidden → CreateDesktop false
        case .hiddenFiles: on
        }
        CFPreferencesSetAppValue(flag.rawValue as CFString, value as CFBoolean, "com.apple.finder" as CFString)
        guard CFPreferencesAppSynchronize("com.apple.finder" as CFString) else { return false }
        // launchd starts Finder again at once.
        return await Self.process("/usr/bin/killall", ["Finder"]) == 0
    }

    // MARK: Tools

    public func lockScreen() {
        // The lock the system menu uses (login.framework, loaded at call time); without it, the
        // display goes to sleep, which locks when a password is required after sleep.
        typealias Lock = @convention(c) () -> Int32
        if let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
           let sym = dlsym(h, "SACLockScreenImmediate") {
            _ = unsafeBitCast(sym, to: Lock.self)()
            return
        }
        sleepDisplay()
    }

    public func sleepDisplay() {
        Task { _ = await Self.process("/usr/bin/pmset", ["displaysleepnow"]) }
    }

    public func startScreenSaver() {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    public func screenshot(_ target: ScreenshotTarget) {
        let args: [String]
        switch target {
        case .clipboard: args = ["-i", "-c"]
        case .desktop:
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
            args = ["-i", desktop.appendingPathComponent("Screenshot \(f.string(from: .now)).png").path]
        }
        Task { _ = await Self.process("/usr/sbin/screencapture", args) }
    }

    public func trashSummary() async -> Result<TrashSummary, ScriptOutcome> {
        // Direct read first (works with Full Disk Access); otherwise ask Finder for the count.
        if let s = await Task.detached(priority: .userInitiated, operation: { Self.readTrash() }).value { return .success(s) }
        let (outcome, text) = await Self.runReturning("tell application \"Finder\" to count items of trash")
        guard outcome == .ok else { return .failure(outcome) }
        return .success(TrashSummary(items: Int(text ?? "") ?? 0, bytes: nil))
    }

    public func emptyTrash() async -> ScriptOutcome {
        await Self.run("tell application \"Finder\" to empty trash")
    }

    public func ejectableVolumes() -> [String] {
        Self.ejectable().map { (try? $0.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? $0.lastPathComponent }
    }

    public func ejectAll() async -> (ejected: Int, failed: Int) {
        let urls = Self.ejectable()
        return await Task.detached(priority: .userInitiated) {
            var ok = 0, bad = 0
            for url in urls {
                do { try NSWorkspace.shared.unmountAndEjectDevice(at: url); ok += 1 } catch { bad += 1 }
            }
            return (ok, bad)
        }.value
    }

    public func sampleColor(_ done: @escaping @MainActor (RGB?) -> Void) {
        let s = NSColorSampler()
        sampler = s
        s.show { [weak self] color in
            MainActor.assumeIsolated {
                self?.sampler = nil
                guard let c = color?.usingColorSpace(.sRGB) else { done(nil); return }
                done(RGB(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent)))
            }
        }
    }

    public func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    public func cameraAccess() -> CameraAccess { CameraPermission.status() }
    public func requestCamera() async -> Bool { await CameraPermission.request() }

    public func openAutomationSettings() { NSWorkspace.shared.open(PermissionCenter.settingsURL(.automation)) }
    public func openCameraSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
    }

    // MARK: Helpers

    nonisolated static func ejectable() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey, .volumeIsRootFileSystemKey, .volumeNameKey]
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return vols.filter { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsRootFileSystem != true else { return false }
            return v.volumeIsEjectable == true || v.volumeIsRemovable == true || v.volumeIsInternal == false
        }.filter { $0.path.hasPrefix("/Volumes/") }
    }

    nonisolated static func readTrash() -> TrashSummary? {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        guard let top = try? FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil, options: []) else { return nil }
        var bytes: Int64 = 0
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        if let e = FileManager.default.enumerator(at: trash, includingPropertiesForKeys: Array(keys)) {
            for case let url as URL in e {
                if let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true { bytes += Int64(v.totalFileAllocatedSize ?? 0) }
            }
        }
        return TrashSummary(items: top.filter { $0.lastPathComponent != ".DS_Store" }.count, bytes: bytes)
    }

    /// Runs AppleScript off the main thread (the first run may show the Automation prompt and block
    /// until it is answered).
    static func run(_ source: String) async -> ScriptOutcome { await runReturning(source).0 }

    static func runReturning(_ source: String) async -> (ScriptOutcome, String?) {
        await withCheckedContinuation { (k: CheckedContinuation<(ScriptOutcome, String?), Never>) in
            scriptQueue.async {
                var err: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
                if let err {
                    let code = (err[NSAppleScript.errorNumber] as? Int) ?? 0
                    // -1743 not authorised; -1744 would require consent (prompt dismissed).
                    if code == -1743 || code == -1744 { k.resume(returning: (.needsPermission, nil)); return }
                    k.resume(returning: (.failed((err[NSAppleScript.errorMessage] as? String) ?? "AppleScript \(code)"), nil))
                    return
                }
                k.resume(returning: (.ok, result?.stringValue ?? result.map { String($0.int32Value) }))
            }
        }
    }

    /// Runs a short system tool and returns its exit status (registered as a child meanwhile).
    static func process(_ path: String, _ args: [String]) async -> Int32 {
        await withCheckedContinuation { (k: CheckedContinuation<Int32, Never>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { proc in
                ChildProcesses.unregister(proc.processIdentifier)
                k.resume(returning: proc.terminationStatus)
            }
            do {
                try p.run()
                ChildProcesses.register(p.processIdentifier)
            } catch {
                k.resume(returning: -1)
            }
        }
    }
}
