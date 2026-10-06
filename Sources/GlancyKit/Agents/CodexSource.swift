import CoreServices
import Foundation

/// Codex sessions from their rollout files (read-only; nothing under ~/.codex is ever written).
///
/// - Launch: the rollouts modified within `AgentSessionStore.forgetAfter`, newest first, at most
///   `maxFiles`. Each one: its first line (who, where, which app), the first user message (the
///   title), and the last `tailBytes` (the current state), folded line by line into a store.
/// - Then FSEvents on the sessions folder: a changed rollout is read from its last offset (only the
///   new bytes); a new one is followed from its first byte; an archived/deleted one ends its row.
/// Everything runs on the reader's private queue; batches go to the main actor in order.
final class CodexSessionsReader: @unchecked Sendable {
    typealias Deliver = @Sendable (AgentSourceUpdate) -> Void

    let root: URL
    let maxFiles: Int
    let tailBytes: Int
    let headBytes: Int
    let forgetAfter: TimeInterval
    private let queue = DispatchQueue(label: "glancy.agents.codex", qos: .utility)

    // Touched only on `queue`.
    private var deliver: Deliver?
    private var tracks: [String: Track] = [:]
    /// Subagent / reviewer rollouts seen live: not followed (bounded; cleared when full).
    private var ignored = Set<String>()
    private var watcher: FSEventsWatcher?
    private var appearance: FolderAppearanceWatcher?
    private var running = false
    /// The newest plan limits delivered (Codex's `rate_limits`).
    private var latestLimits: UsageReading?
    /// How many of the newest rollouts the launch fallback searches backwards for a reading.
    var limitsFallbackFiles = 10
    var now: @Sendable () -> Date = { .now }

    /// One followed rollout: offset, the line splitter's state and the session's parsing state.
    struct Track {
        var inode: ino_t
        var offset: off_t
        var splitter = CodexLineSplitter()
        var state = CodexRolloutState()
        var modified: Date
    }

    init(root: URL, maxFiles: Int = 12, tailBytes: Int = 1 << 20, headBytes: Int = 2 << 20,
         forgetAfter: TimeInterval = AgentSessionStore.forgetAfter) {
        self.root = root
        self.maxFiles = maxFiles
        self.tailBytes = tailBytes
        self.headBytes = headBytes
        self.forgetAfter = forgetAfter
    }

    func start(_ deliver: @escaping Deliver) {
        queue.async { [self] in
            guard !running else { return }
            running = true
            self.deliver = deliver
            // The stream starts before the scan: a file written meanwhile is reported after the
            // rebuild (same queue) and read from its offset, never missed.
            if FileManager.default.fileExists(atPath: root.path) {
                watch()
                rebuild()
            } else {
                // No sessions yet: an empty board, then wait for the folder (Codex installed later).
                deliver(.rebuilt(AgentSessionStore()))
                let a = FolderAppearanceWatcher(root, queue: queue) { [weak self] in
                    guard let self, self.running else { return }
                    self.appearance = nil
                    self.watch()
                    self.rebuild()
                }
                appearance = a
                a.start()
            }
        }
    }

    func stop() {
        queue.sync { [self] in
            running = false
            deliver = nil
            latestLimits = nil
            watcher?.cancel(); watcher = nil
            appearance?.cancel(); appearance = nil
            tracks = [:]
        }
    }

    /// Runs `body` on the reader queue after everything queued so far (tests).
    func sync(_ body: () -> Void = {}) { queue.sync(execute: body) }

    /// Followed rollouts (tests: the cap holds).
    var trackedCount: Int { queue.sync { tracks.count } }
    /// Tests: whether a rollout is being followed.
    func isTracking(_ url: URL) -> Bool {
        let want = url.resolvingSymlinksInPath().path   // /var vs /private/var
        return queue.sync { tracks.keys.contains { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == want } }
    }

    // MARK: Rebuild

    private func rebuild() {
        var store = AgentSessionStore()
        tracks = [:]
        ignored = []
        for (url, modified) in recentRollouts() {
            guard tracks.count < maxFiles else { break }
            guard var t = open(url, modified: modified) else { continue }
            catchUp(url, &t) { store.apply($0) }
            if t.state.isSubagent || t.state.sessionID == nil { continue }
            if let title = headTitle(url, upTo: t.offset), let sid = t.state.sessionID {
                store.setTitle(title, sessionID: sid)
            }
            tracks[url.path] = t
        }
        store.expire(now: now())
        deliver?(.rebuilt(store))
        var newest = tracks.values.compactMap(\.state.rateLimits).max { $0.updated < $1.updated }
        if newest == nil {
            // Codex last ran before the followed window: the newest rollouts, read backwards once.
            for (url, _) in recentRolloutsAll().prefix(limitsFallbackFiles) {
                if let r = autoreleasepool(invoking: { UsageParser.lastCodexReading(in: url) }) { newest = r; break }
            }
        }
        offerLimits(newest)
    }

    /// Delivers a reading newer than the last one delivered.
    private func offerLimits(_ r: UsageReading?) {
        guard let r, r.updated > (latestLimits?.updated ?? .distantPast) else { return }
        latestLimits = r
        deliver?(.limits(r))
    }

    /// Rollouts modified within `forgetAfter`, newest first (subagent ones are skipped by the caller).
    func recentRollouts() -> [(URL, Date)] { rollouts(since: now().addingTimeInterval(-forgetAfter)) }

    /// Every rollout, newest first (debug).
    func recentRolloutsAll() -> [(URL, Date)] { rollouts(since: .distantPast) }

    private func rollouts(since cutoff: Date) -> [(URL, Date)] {
        var found: [(URL, Date)] = []
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles]) else { return [] }
        for case let url as URL in e where url.pathExtension == "jsonl" {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  let m = v.contentModificationDate, m >= cutoff else { continue }
            found.append((url, m))
        }
        return found.sorted { $0.1 > $1.1 }
    }

    // MARK: Following

    private func watch() {
        watcher = FSEventsWatcher(root: root, queue: queue) { [weak self] changes in
            self?.changed(changes)
        }
    }

    private func changed(_ changes: [(path: String, flags: FSEventStreamEventFlags)]) {
        guard running else { return }
        var live: [AgentEvent] = []
        var quiet: [AgentEvent] = []
        var seen = Set<String>()
        for c in changes where c.path.hasSuffix(".jsonl") && !ignored.contains(c.path) && seen.insert(c.path).inserted {
            let url = URL(fileURLWithPath: c.path)
            guard FileManager.default.fileExists(atPath: c.path) else {
                // Archived (moved to archived_sessions) or deleted: the session is over.
                if let t = tracks.removeValue(forKey: c.path), let sid = t.state.sessionID, !t.state.isSubagent {
                    live.append(AgentEvent(ts: now(), kind: .sessionEnd, sessionID: sid, cwd: t.state.cwd,
                                           reason: "archived", agent: .codex))
                }
                continue
            }
            if var t = tracks[c.path] {
                if inode(c.path) != t.inode {                // replaced: start over
                    guard let fresh = open(url, modified: now()) else { continue }
                    t = fresh
                    catchUp(url, &t) { quiet.append($0) }
                } else {
                    readNew(url, &t) { live.append($0) }
                }
                t.modified = now()
                tracks[c.path] = t
            } else {
                // A new rollout (a session just started), or an old one resumed. A file not written
                // within the forget window is neither: FSEvents can report writes from before the
                // stream started (late, on busy machines), and those must not revive an old session.
                if let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                   m < now().addingTimeInterval(-forgetAfter) { continue }
                guard var t = open(url, modified: now()) else { continue }
                catchUp(url, &t) { quiet.append($0) }
                if t.state.isSubagent || t.state.sessionID == nil {
                    if ignored.count >= 256 { ignored = [] }
                    if t.state.isSubagent { ignored.insert(c.path) }
                    continue
                }
                if let title = headTitle(url, upTo: t.offset), let sid = t.state.sessionID {
                    quiet.append(AgentEvent(ts: now(), kind: .sessionStart, sessionID: sid, cwd: t.state.cwd,
                                            agent: .codex, host: t.state.host, title: title))
                }
                tracks[c.path] = t
                trimTracks()
            }
        }
        if !quiet.isEmpty { deliver?(.events(quiet, quiet: true)) }
        offerLimits(tracks.values.compactMap(\.state.rateLimits).max { $0.updated < $1.updated })
        // Rows of files let go of stay in the store until they go stale; nothing else is held.
        if !live.isEmpty { deliver?(.events(live, quiet: false)) }
    }

    /// Keeps at most `maxFiles` rollouts followed: the least recently written ones are let go.
    private func trimTracks() {
        guard tracks.count > maxFiles else { return }
        for (path, _) in tracks.sorted(by: { $0.value.modified < $1.value.modified }).prefix(tracks.count - maxFiles) {
            tracks[path] = nil
        }
    }

    private func open(_ url: URL, modified: Date) -> Track? {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return nil }
        return Track(inode: st.st_ino, offset: 0, modified: modified)
    }

    /// First reading of a rollout: the first line (session_meta) whole, then the last `tailBytes`.
    private func catchUp(_ url: URL, _ t: inout Track, _ each: (AgentEvent) -> Void) {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var st = stat()
        fstat(fd, &st)
        let size = off_t(st.st_size)
        // The first line, in chunks, until its newline (base instructions make it ~50 KB).
        var offset: off_t = 0
        var splitter = CodexLineSplitter()
        var state = t.state
        var firstDone = false
        while !firstDone, offset < size {
            let chunk = JSONLTailReader.pread(fd, from: offset, count: Int(min(64 << 10, size - offset)))
            guard !chunk.isEmpty else { break }
            let nl = chunk.firstIndex(of: 0x0A)
            let part = nl.map { chunk[chunk.startIndex...$0] } ?? chunk[...]
            offset += off_t(part.count)
            autoreleasepool {
                splitter.feed(Data(part)) { line, d in
                    CodexRollout.events(line: line, decision: d, state: &state).forEach(each)
                }
            }
            firstDone = nl != nil
        }
        t.state = state
        // A subagent's rollout, or not a rollout at all: nothing more to read.
        guard !state.isSubagent, state.sessionID != nil else { t.offset = offset; return }
        // Then the tail, from a line boundary.
        let tailStart = max(offset, size - off_t(tailBytes))
        if tailStart > offset {
            offset = tailStart
            splitter = CodexLineSplitter()
            // Skip the line the cut fell in.
            var found = false
            while !found, offset < size {
                let probe = JSONLTailReader.pread(fd, from: offset, count: Int(min(64 << 10, size - offset)))
                guard !probe.isEmpty else { break }
                if let nl = probe.firstIndex(of: 0x0A) {
                    offset += off_t(nl - probe.startIndex + 1); found = true
                } else {
                    offset += off_t(probe.count)
                }
            }
        }
        t.state = state
        t.splitter = splitter
        t.offset = offset
        read(fd, size: size, &t, each)
    }

    private func readNew(_ url: URL, _ t: inout Track, _ each: (AgentEvent) -> Void) {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var st = stat()
        fstat(fd, &st)
        let size = off_t(st.st_size)
        if size < t.offset {                        // truncated: start over
            t.offset = 0
            t.splitter = CodexLineSplitter()
        }
        read(fd, size: size, &t, each)
    }

    /// Reads `[t.offset, size)` in 256 KB chunks through the splitter, folding line by line.
    private func read(_ fd: Int32, size: off_t, _ t: inout Track, _ each: (AgentEvent) -> Void) {
        var state = t.state
        var splitter = t.splitter
        while t.offset < size {
            let chunk = JSONLTailReader.pread(fd, from: t.offset, count: Int(min(256 << 10, size - t.offset)))
            guard !chunk.isEmpty else { break }
            t.offset += off_t(chunk.count)
            autoreleasepool {
                splitter.feed(chunk) { line, d in
                    CodexRollout.events(line: line, decision: d, state: &state).forEach(each)
                }
            }
        }
        t.state = state
        t.splitter = splitter
    }

    /// The first user message, searched in the first `headBytes` (stops at the first one found).
    /// Only when the tail did not start at the top of the file (otherwise the store already has it).
    private func headTitle(_ url: URL, upTo end: off_t) -> String? {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var splitter = CodexLineSplitter()
        var state = CodexRolloutState()
        var offset: off_t = 0
        var title: String?
        let limit = min(end, off_t(headBytes))
        while title == nil, offset < limit {
            let chunk = JSONLTailReader.pread(fd, from: offset, count: Int(min(256 << 10, limit - offset)))
            guard !chunk.isEmpty else { break }
            offset += off_t(chunk.count)
            autoreleasepool {
                splitter.feed(chunk) { line, d in
                    guard title == nil else { return }
                    for e in CodexRollout.events(line: line, decision: d, state: &state) where e.kind == .userPromptSubmit {
                        if let p = e.prompt { title = p; break }
                    }
                }
            }
        }
        return title
    }

    private func inode(_ path: String) -> ino_t {
        var st = stat()
        return stat(path, &st) == 0 ? st.st_ino : 0
    }
}

/// The Codex source: rollouts under ~/.codex/sessions.
@MainActor
final class CodexSource: AgentSource {
    nonisolated static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions", isDirectory: true)

    let kind = AgentKind.codex
    let reader: CodexSessionsReader

    init(root: URL = CodexSource.defaultRoot) {
        reader = CodexSessionsReader(root: root)
    }

    func start(_ sink: @escaping @MainActor (AgentKind, AgentSourceUpdate) -> Void) {
        reader.start { update in
            DispatchQueue.main.async { MainActor.assumeIsolated { sink(.codex, update) } }
        }
    }

    func stop() { reader.stop() }

    func status() -> AgentSourceStatus {
        let path = (reader.root.path as NSString).abbreviatingWithTildeInPath
        return FileManager.default.fileExists(atPath: reader.root.path)
            ? AgentSourceStatus(.ok, AgentsText.reading(path))
            : AgentSourceStatus(.missing, AgentsText.t("Not found: Codex has not run on this Mac yet"))
    }
}
