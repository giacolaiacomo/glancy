import Foundation

/// Follows an append-only JSONL log that is rotated by rename (`events.jsonl` → `events.jsonl.1`,
/// then recreated by the next append). Event-driven only: a `DispatchSource` on the file (write /
/// extend / rename / delete) and, while the file does not exist, one on the nearest existing folder.
/// Parsing happens on the reader's private queue; batches are handed to the handler from there.
///
/// Rotation: the old inode keeps being followed ("retired") after the rename, so a hook that had it
/// open across the `mv` still gets its line read; the new file is followed from byte 0.
final class JSONLTailReader: @unchecked Sendable {
    typealias Handler = @Sendable (_ events: [AgentEvent], _ isRebuild: Bool) -> Void

    let url: URL
    let rebuildBytes: Int
    private let queue = DispatchQueue(label: "glancy.agents.tail", qos: .utility)

    // Everything below is touched only on `queue`.
    private var handler: Handler?
    private var current: Follower?
    private var retired: Follower?
    private var folderSource: DispatchSourceFileSystemObject?
    private var running = false

    init(url: URL, rebuildBytes: Int = 2 << 20) {
        self.url = url
        self.rebuildBytes = rebuildBytes
    }

    var rotatedURL: URL { URL(fileURLWithPath: url.path + ".1") }

    func start(_ handler: @escaping Handler) {
        queue.async { [self] in
            guard !running else { return }
            running = true
            self.handler = handler
            rebuild()
        }
    }

    func stop() {
        queue.sync { [self] in
            running = false
            handler = nil
            current?.cancel(); current = nil
            retired?.cancel(); retired = nil
            folderSource?.cancel(); folderSource = nil
        }
    }

    /// Runs `body` on the reader queue after everything queued so far (tests).
    func sync(_ body: () -> Void = {}) { queue.sync(execute: body) }

    // MARK: Rebuild

    private func rebuild() {
        guard let f = Follower(path: url.path) else {
            deliver([], rebuild: true)
            watchForCreation()
            return
        }
        let size = f.size
        var data = Data()
        // Right after a rotation the current file is short: borrow the tail of `.1` as well.
        if size < rebuildBytes {
            data = Self.readTail(of: rotatedURL, bytes: rebuildBytes - size)
            if let last = data.last, last != 0x0A { data.append(0x0A) }
        }
        let from = max(0, size - rebuildBytes)
        let raw = Self.pread(f.fd, from: off_t(from), count: size - from)
        f.offset = off_t(from + raw.count)
        data.append(from > 0 ? Self.dropFirstLine(raw) : raw)
        let events = AgentEventParser.drain(&data)
        f.partial = data
        deliver(events, rebuild: true)
        follow(f)
        read(f)                               // lines appended before the source existed
        // Rotated between open() and the source: catch up now rather than miss the new file.
        if pathInode() != f.inode { rotate() }
    }

    // MARK: Following

    private func follow(_ f: Follower) {
        current = f
        f.attach(queue: queue) { [weak self, weak f] flags in
            guard let self, let f, self.running else { return }
            if f === self.current {
                self.read(f)
                // Renamed or deleted, or a rename we did not see (coalesced): the path names another file.
                if flags.contains(.rename) || flags.contains(.delete) || self.pathInode() != f.inode {
                    self.rotate()
                }
            } else {
                self.read(f)                 // a late line on the rotated file
                if flags.contains(.delete) { self.flushAndRetire(f) }
            }
        }
    }

    private func read(_ f: Follower) {
        let events = f.readNew()
        if !events.isEmpty { deliver(events, rebuild: false) }
    }

    /// The file was renamed to `.1` (or deleted): drain the old inode (= the tail of `.1`), keep
    /// watching it for a late writer, and follow the new file from its first byte.
    private func rotate() {
        guard let old = current else { return }
        read(old)
        retired?.cancel()
        retired = old
        current = nil
        if let f = Follower(path: url.path) {
            follow(f)
            read(f)
        } else {
            watchForCreation()
        }
    }

    private func flushAndRetire(_ f: Follower) {
        var tail = f.partial
        if !tail.isEmpty {
            tail.append(0x0A)
            let events = AgentEventParser.drain(&tail)
            if !events.isEmpty { deliver(events, rebuild: false) }
        }
        f.cancel()
        if retired === f { retired = nil }
    }

    /// Watches the nearest existing folder on the way to the log until the log exists.
    private func watchForCreation() {
        folderSource?.cancel(); folderSource = nil
        let dir = nearestExistingFolder()
        let dfd = open(dir.path, O_EVTONLY | O_CLOEXEC)
        guard dfd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: dfd, eventMask: [.write, .link, .rename], queue: queue)
        src.setEventHandler { [weak self] in self?.checkCreation(watching: dir) }
        src.setCancelHandler { close(dfd) }
        folderSource = src
        src.resume()
        // The file (or a folder on the way) may have appeared before the watch existed.
        checkCreation(watching: dir)
    }

    private func checkCreation(watching dir: URL) {
        guard running, current == nil else { return }
        if let f = Follower(path: url.path) {
            folderSource?.cancel(); folderSource = nil
            follow(f)
            read(f)
        } else if nearestExistingFolder() != dir {
            watchForCreation()                // a folder on the way appeared or vanished: move the watch
        }
    }

    private func nearestExistingFolder() -> URL {
        var dir = url.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: dir.path), dir.path != "/" {
            dir = dir.deletingLastPathComponent()
        }
        return dir
    }

    private func pathInode() -> ino_t {
        var st = stat()
        return stat(url.path, &st) == 0 ? st.st_ino : 0
    }

    private func deliver(_ events: [AgentEvent], rebuild: Bool) {
        handler?(events, rebuild)
    }

    // MARK: File helpers (also used by the debug snapshot)

    static func pread(_ fd: Int32, from: off_t, count: Int) -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        let n = data.withUnsafeMutableBytes { Darwin.pread(fd, $0.baseAddress, count, from) }
        if n <= 0 { return Data() }
        if n < count { data.removeSubrange(n...) }
        return data
    }

    /// The last `bytes` bytes of a file, starting at a line boundary.
    static func readTail(of url: URL, bytes: Int) -> Data {
        guard bytes > 0 else { return Data() }
        let f = open(url.path, O_RDONLY | O_CLOEXEC)
        guard f >= 0 else { return Data() }
        defer { close(f) }
        var st = stat()
        fstat(f, &st)
        let size = Int(st.st_size)
        let from = max(0, size - bytes)
        let chunk = pread(f, from: off_t(from), count: size - from)
        return from > 0 ? dropFirstLine(chunk) : chunk
    }

    /// Drops everything up to and including the first newline (a line cut by the seek).
    static func dropFirstLine(_ d: Data) -> Data {
        guard let nl = d.firstIndex(of: 0x0A) else { return Data() }
        return Data(d[d.index(after: nl)...])
    }
}

/// One open inode being followed: fd, byte offset, the partial last line, its dispatch source.
/// Used only on the reader's queue.
private final class Follower {
    let fd: Int32
    let inode: ino_t
    var offset: off_t = 0
    var partial = Data()
    private var source: DispatchSourceFileSystemObject?

    init?(path: String) {
        let f = open(path, O_RDONLY | O_CLOEXEC)
        guard f >= 0 else { return nil }
        var st = stat()
        fstat(f, &st)
        fd = f
        inode = st.st_ino
    }

    var size: Int {
        var st = stat()
        return fstat(fd, &st) == 0 ? Int(st.st_size) : 0
    }

    func attach(queue: DispatchQueue, _ onEvent: @escaping (DispatchSource.FileSystemEvent) -> Void) {
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: queue)
        // Appends are coalesced: hooks write a line per tool call across every session, and one
        // read per 300 ms is plenty for a glance surface (fewer wake-ups, same information).
        // Rename/delete (rotation) are handled at once.
        let coalesce = Coalescer(onEvent)
        src.setEventHandler { [unowned src] in
            let ev = src.data
            if !ev.isDisjoint(with: [.rename, .delete]) { coalesce.onEvent(ev); return }
            guard !coalesce.pending else { return }
            coalesce.pending = true
            queue.asyncAfter(deadline: .now() + 0.3) { coalesce.pending = false; coalesce.onEvent(.write) }
        }
        let fd = fd
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
    }

    /// Reads everything appended since the last read; returns the complete lines parsed.
    func readNew() -> [AgentEvent] {
        let size = off_t(size)
        if size < offset {                   // truncated in place: start over
            offset = 0
            partial = Data()
        }
        guard size > offset else { return [] }
        let chunk = JSONLTailReader.pread(fd, from: offset, count: Int(size - offset))
        offset += off_t(chunk.count)
        partial.append(chunk)
        return AgentEventParser.drain(&partial)
    }

    func cancel() {
        if let s = source { s.cancel(); source = nil } else { close(fd) }
    }
}

/// State for coalescing appends. Touched only on the reader's serial queue.
private final class Coalescer: @unchecked Sendable {
    let onEvent: (DispatchSource.FileSystemEvent) -> Void
    var pending = false
    init(_ onEvent: @escaping (DispatchSource.FileSystemEvent) -> Void) { self.onEvent = onEvent }
}
