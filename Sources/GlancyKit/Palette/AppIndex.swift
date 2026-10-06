import AppKit
import CoreServices

// The apps the command bar launches: /Applications (+ one level of folders), /System/Applications,
// ~/Applications, the Utilities folders and Finder. Indexed off main when the bar opens and the
// list is missing or stale; an FSEvents stream on those folders marks it stale. Never polls.

public struct AppEntry: Sendable, Equatable, Hashable {
    public let path: String
    /// The file name without ".app" ("Visual Studio Code").
    public let name: String
    /// The localised name Finder shows ("Calcolatrice"), when different.
    public let displayName: String

    public var url: URL { URL(fileURLWithPath: path) }
}

public enum AppScanner {
    public static var defaultFolders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                home.appendingPathComponent("Applications").path]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Apps outside those folders worth finding.
    public static let extras = ["/System/Library/CoreServices/Finder.app"]

    /// Every .app directly in each folder, and in plain sub-folders one level down
    /// ("/Applications/Microsoft Office/Word.app"). Duplicates (same path) once; sorted by name.
    public static func scan(_ folders: [URL], extras: [String] = AppScanner.extras) -> [AppEntry] {
        let fm = FileManager.default
        var seen = Set<String>()
        var out: [AppEntry] = []
        func add(_ url: URL) {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { return }
            let name = url.deletingPathExtension().lastPathComponent
            var display = fm.displayName(atPath: path)
            if display.hasSuffix(".app") { display = String(display.dropLast(4)) }
            out.append(AppEntry(path: path, name: name, displayName: display))
        }
        for folder in folders {
            // Not `.skipsHiddenFiles`: Safari in /Applications is a symlink into the cryptex flagged
            // hidden. Dot files are skipped by name.
            guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for item in items where !item.lastPathComponent.hasPrefix(".") {
                if item.pathExtension == "app" { add(item); continue }
                // One level into plain folders (not packages, not the Utilities folder scanned on its own).
                guard (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                if folders.contains(where: { $0.standardizedFileURL == item.standardizedFileURL }) { continue }
                guard let inner = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil) else { continue }
                for app in inner where app.pathExtension == "app" && !app.lastPathComponent.hasPrefix(".") { add(app) }
            }
        }
        for path in extras where fm.fileExists(atPath: path) { add(URL(fileURLWithPath: path)) }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// The cached list, its staleness, and the FSEvents stream that invalidates it.
@MainActor
public final class AppIndex {
    public private(set) var apps: [AppEntry] = []
    public private(set) var stale = true
    public private(set) var indexing = false
    /// Called on main when a new list lands.
    public var onUpdate: (() -> Void)?
    private let folders: [URL]
    private let extras: [String]
    private var stream: FSEventStreamRef?
    private var task: Task<Void, Never>?
    public private(set) var scanCount = 0

    public init(folders: [URL] = AppScanner.defaultFolders, extras: [String] = AppScanner.extras) {
        self.folders = folders
        self.extras = extras
    }

    /// The bar opened: re-index when needed (off main), and start watching after the first list.
    public func refreshIfNeeded() {
        guard stale, !indexing else { return }
        indexing = true
        scanCount += 1
        let folders = folders, extras = extras
        task = Task { [weak self] in
            let list = await Task.detached(priority: .userInitiated) { AppScanner.scan(folders, extras: extras) }.value
            guard !Task.isCancelled, let self else { return }
            self.task = nil
            self.apps = list
            self.stale = false
            self.indexing = false
            self.startWatching()
            self.onUpdate?()
        }
    }

    /// Synchronous index (renderer, tests).
    public func indexNow() {
        apps = AppScanner.scan(folders, extras: extras)
        stale = false
    }

    public func invalidate() { stale = true }

    /// The bar has been closed a while: drop the list and stop watching; the next open re-indexes
    /// (off main, as at the first open).
    public func release() {
        guard !indexing else { return }
        apps = []
        stale = true
        stopWatching()
    }

    /// Tests: a list without touching the disk.
    func setApps(_ list: [AppEntry]) {
        apps = list
        stale = false
    }

    public func stop() {
        task?.cancel(); task = nil
        indexing = false
        stopWatching()
    }

    /// Tests: wait for the scan in flight.
    func waitForIndex() async { await task?.value }

    // MARK: FSEvents

    private func startWatching() {
        guard stream == nil else { return }
        let paths = folders.map(\.path).filter { FileManager.default.fileExists(atPath: $0) } as CFArray
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let index = Unmanaged<AppIndex>.fromOpaque(info).takeUnretainedValue()
            // Delivered on the main queue (set below).
            MainActor.assumeIsolated { index.invalidate() }
        }
        guard let s = FSEventStreamCreate(nil, callback, &context, paths, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    private func stopWatching() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    var isWatching: Bool { stream != nil }
}

/// App icons, loaded when a row shows one, kept for the bar's session.
@MainActor
enum PaletteIcons {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 48
        return c
    }()

    static func icon(_ path: String) -> NSImage {
        if let i = cache.object(forKey: path as NSString) { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        i.size = NSSize(width: 32, height: 32)
        cache.setObject(i, forKey: path as NSString)
        return i
    }

    static func clear() { cache.removeAllObjects() }
}
