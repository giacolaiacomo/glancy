import Foundation

/// Which new names in a watched folder are worth announcing.
public enum ShelfFolderRules {
    /// Suffixes browsers use while a download is still being written (Chrome, Safari, Firefox,
    /// Edge, Opera, generic). The final name appears when the browser renames the file.
    public static let partialSuffixes = ["crdownload", "download", "part", "partial", "opdownload"]

    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "pdf", "bmp"]

    /// macOS names screenshots "<prefix> <date> at <time>.png"; the prefix follows the system
    /// language ("Screenshot", "Screen Shot" before macOS 10.14 → Ventura, Italian "Istantanea",
    /// older Italian "Schermata") or the user's own (`defaults write com.apple.screencapture name`).
    public static let screenshotPrefixes = ["Screenshot", "Screen Shot", "Istantanea", "Schermata"]

    /// Never announced: hidden files (screenshots are first written as ".Screenshot …" and renamed),
    /// Finder's own files, browser partials.
    public static func isNoise(_ name: String) -> Bool {
        if name.hasPrefix(".") || name == "Icon\r" || name.isEmpty { return true }
        return isPartial(name)
    }

    public static func isPartial(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return partialSuffixes.contains(ext)
    }

    /// A finished download candidate (the stability check happens later).
    public static func isDownload(_ name: String) -> Bool { !isNoise(name) }

    /// A screenshot file name, with the system prefixes plus a custom one.
    public static func isScreenshot(_ name: String, customPrefix: String? = nil) -> Bool {
        guard !isNoise(name), imageExtensions.contains((name as NSString).pathExtension.lowercased()) else { return false }
        var prefixes = screenshotPrefixes
        if let customPrefix, !customPrefix.isEmpty { prefixes.append(customPrefix) }
        return prefixes.contains { prefix in
            guard name.hasPrefix(prefix + " ") else { return false }
            return name.dropFirst(prefix.count + 1).first?.isNumber == true
        }
    }

    /// Firefox creates the final name empty at once and writes "<name>.part" beside it; other
    /// browsers write "<name>.<suffix>". While a sibling like that exists the file is unfinished.
    public static func hasPartialSibling(_ name: String, among names: Set<String>) -> Bool {
        partialSuffixes.contains { names.contains(name + "." + $0) }
    }

    /// Where screenshots land: `com.apple.screencapture location`, or the Desktop.
    public static func screenshotFolder(defaults: UserDefaults? = UserDefaults(suiteName: "com.apple.screencapture"),
                                        home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        guard let raw = defaults?.string(forKey: "location")?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return desktop }
        let path = raw.hasPrefix("~") ? home.path + raw.dropFirst() : raw
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return desktop }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    public static func screenshotPrefix(defaults: UserDefaults? = UserDefaults(suiteName: "com.apple.screencapture")) -> String? {
        defaults?.string(forKey: "name")
    }
}

public enum ShelfFolderStatus: Equatable, Sendable { case off, watching, denied, missing }

/// Watches one folder for new files, event-driven: a `DispatchSource` on the folder fires when
/// its entries change (create, rename, delete); the listing is diffed against what was there.
/// A new name that passes `accepts` waits until it is stable — no partial sibling, not empty, and
/// the same size and date `settle` after the last folder event — then it is reported, together with
/// everything else that settled in the same burst. Nothing runs between folder events except the
/// single settle wait (re-armed only while a file is still visibly growing).
@MainActor
final class ShelfFolderWatcher {
    typealias Status = ShelfFolderStatus

    let folder: URL
    let settle: Duration
    private let accepts: (String) -> Bool
    /// Settled new files, one call per burst.
    var onFiles: (([URL]) -> Void)?
    private(set) var status: Status = .off

    private var source: DispatchSourceFileSystemObject?
    private var known: Set<String> = []
    private var pending: [String: Fingerprint] = [:]
    private var reported: Set<String> = []
    private var settleTask: Task<Void, Never>?
    private var starting = false
    private var generation = 0

    struct Fingerprint: Equatable {
        var size: Int
        var modified: Date?
        let firstSeen: Date
        static func == (a: Fingerprint, b: Fingerprint) -> Bool { a.size == b.size && a.modified == b.modified }
    }

    init(folder: URL, settle: Duration = .seconds(1), accepts: @escaping (String) -> Bool) {
        self.folder = folder
        self.settle = settle
        self.accepts = accepts
    }

    /// Starts watching; returns the resulting status. `.denied` = macOS refused the folder
    /// (Files and Folders privacy for Desktop / Downloads). The first access happens off the main
    /// thread: while macOS shows its privacy prompt the calling thread is blocked until the user
    /// answers, and that must never be Glancy's main thread.
    @discardableResult
    func start() async -> Status {
        guard source == nil, !starting else { return status }
        starting = true
        let generation = self.generation
        let path = folder.path
        let opened = await Task.detached(priority: .utility) { Self.open(path) }.value
        starting = false
        guard generation == self.generation else {
            // Stopped while macOS was asking: let the descriptor go.
            if case .ok(_, let fd) = opened { close(fd) }
            return status
        }
        switch opened {
        case .failed(let s):
            status = s
        case .ok(let names, let fd):
            known = names
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .link],
                                                                queue: .main)
            // On the main queue; @Sendable so the handler itself carries no actor (see lint.sh).
            src.setEventHandler { @Sendable [weak self] in
                MainActor.assumeIsolated { self?.folderChanged() }
            }
            src.setCancelHandler { @Sendable in close(fd) }
            src.resume()
            source = src
            status = .watching
        }
        return status
    }

    private enum Opened: Sendable {
        case ok(Set<String>, Int32)
        case failed(ShelfFolderStatus)
    }

    /// The listing and an event-only descriptor. Blocking (privacy prompt): off main only.
    private nonisolated static func open(_ path: String) -> Opened {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: path)
        } catch {
            return .failed(isPermission(error) ? .denied : .missing)
        }
        let fd = Darwin.open(path, O_EVTONLY)
        guard fd >= 0 else { return .failed((errno == EPERM || errno == EACCES) ? .denied : .missing) }
        return .ok(Set(names), fd)
    }

    func stop() {
        generation += 1
        starting = false
        source?.cancel()
        source = nil
        settleTask?.cancel(); settleTask = nil
        pending.removeAll()
        if status == .watching { status = .off }
    }

    /// Tests and diagnostics.
    var pendingNames: [String] { pending.keys.sorted() }

    // MARK: Events

    func folderChanged() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        let current = Set(names)
        for name in current.subtracting(known) where accepts(name) && !reported.contains(name) {
            pending[name] = fingerprint(name, firstSeen: .now)
        }
        known = current
        pending = pending.filter { current.contains($0.key) }
        reported.formIntersection(current)
        armSettle()
    }

    private func armSettle() {
        settleTask?.cancel()
        guard !pending.isEmpty else { settleTask = nil; return }
        let wait = settle
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.settleNow()
        }
    }

    /// One look at every pending name: ready ones are reported together.
    func settleNow() {
        settleTask = nil
        var ready: [URL] = []
        var growing = false
        let now = Date.now
        for (name, last) in pending {
            let url = folder.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { pending[name] = nil; continue }
            // Waiting for the browser to finish (a later folder event re-arms the check). Given
            // up after ten minutes so a stray empty file can't stay pending forever.
            if ShelfFolderRules.hasPartialSibling(name, among: known) || last.size == 0 && !isDirectory(url) {
                if now.timeIntervalSince(last.firstSeen) > 600 { pending[name] = nil; continue }
                let fresh = fingerprint(name, firstSeen: last.firstSeen)
                if fresh != last { pending[name] = fresh; growing = true }
                continue
            }
            let fresh = fingerprint(name, firstSeen: last.firstSeen)
            if fresh != last {
                pending[name] = fresh
                growing = true
            } else {
                pending[name] = nil
                reported.insert(name)
                ready.append(url)
            }
        }
        if growing { armSettle() }
        if !ready.isEmpty {
            onFiles?(ready.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
        }
    }

    private func fingerprint(_ name: String, firstSeen: Date) -> Fingerprint {
        let url = folder.appendingPathComponent(name)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        return Fingerprint(size: isDirectory(url) ? max(size, 1) : size, modified: attrs?[.modificationDate] as? Date, firstSeen: firstSeen)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    nonisolated static func isPermission(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && (ns.code == NSFileReadNoPermissionError || ns.code == 257) { return true }
        if let posix = ns.userInfo[NSUnderlyingErrorKey] as? NSError, posix.domain == NSPOSIXErrorDomain {
            return posix.code == Int(EPERM) || posix.code == Int(EACCES)
        }
        return ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EPERM) || ns.code == Int(EACCES))
    }
}
