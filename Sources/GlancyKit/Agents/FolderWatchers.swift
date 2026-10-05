import CoreServices
import Foundation

/// File-level FSEvents on one folder tree: the paths that changed, coalesced by `latency`, on
/// `queue`. Event-driven only (fseventsd pushes; nothing is polled). Used where a source has many
/// files in nested folders (Codex rollouts by date) or a database that is rewritten in place.
final class FSEventsWatcher: @unchecked Sendable {
    typealias Handler = @Sendable (_ changes: [(path: String, flags: FSEventStreamEventFlags)]) -> Void

    private var stream: FSEventStreamRef?
    private let box: Box

    private final class Box: @unchecked Sendable {
        let handler: Handler
        init(_ h: @escaping Handler) { handler = h }
    }

    /// Starts watching `root` (which must exist). nil when the stream could not be created.
    init?(root: URL, latency: TimeInterval = 0.5, queue: DispatchQueue, _ handler: @escaping Handler) {
        box = Box(handler)
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            var out: [(String, FSEventStreamEventFlags)] = []
            out.reserveCapacity(count)
            for i in 0..<min(count, list.count) { out.append((list[i], flags[i])) }
            box.handler(out)
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &ctx, [root.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return nil }
        FSEventStreamSetDispatchQueue(s, queue)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s); FSEventStreamRelease(s)
            return nil
        }
        stream = s
    }

    /// Stops and releases the stream. Call on the watcher's queue (or before it ever fires).
    func cancel() {
        guard let s = stream else { return }
        stream = nil
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
    }

    var isRunning: Bool { stream != nil }

    deinit { cancel() }

    static func isRemoved(_ f: FSEventStreamEventFlags) -> Bool {
        f & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 || f & UInt32(kFSEventStreamEventFlagItemRenamed) != 0
    }
}

/// Waits for a folder that does not exist yet, watching the nearest existing ancestor with a
/// vnode dispatch source (it fires only when that folder's own entries change). Calls `ready`
/// once, on `queue`, when the folder exists.
final class FolderAppearanceWatcher: @unchecked Sendable {
    private let target: URL
    private let queue: DispatchQueue
    private let ready: @Sendable () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var done = false

    init(_ target: URL, queue: DispatchQueue, ready: @escaping @Sendable () -> Void) {
        self.target = target
        self.queue = queue
        self.ready = ready
    }

    /// Call on `queue`.
    func start() {
        guard !done else { return }
        if FileManager.default.fileExists(atPath: target.path) { finish(); return }
        var dir = target.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: dir.path), dir.path != "/" { dir = dir.deletingLastPathComponent() }
        source?.cancel(); source = nil
        let fd = open(dir.path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .link, .rename], queue: queue)
        src.setEventHandler { [weak self] in self?.start() }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
        // Created between the check and the watch.
        if FileManager.default.fileExists(atPath: target.path) { finish() }
    }

    private func finish() {
        guard !done else { return }
        done = true
        source?.cancel(); source = nil
        ready()
    }

    func cancel() {
        done = true
        source?.cancel(); source = nil
    }
}
