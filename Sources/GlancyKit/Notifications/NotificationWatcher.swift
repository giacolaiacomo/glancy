import Foundation

/// Follows the Notification Center store. Event-driven only: `DispatchSource` file-system sources on
/// `db`, `db-wal` (write / extend / rename / delete) and on their folder (a WAL file created later).
/// Events are coalesced (one query per `coalesce` window), and only rows past the last one seen are
/// read. A rename or delete of either file reopens the connection. No polling: when the store cannot
/// be read, nothing runs until `retry()` (panel open, app activation).
///
/// Everything below runs on the watcher's private serial queue; events reach the handler from there.
final class NotificationWatcher: @unchecked Sendable {
    enum Event: Sendable {
        case unavailable(NotificationSourceError)
        /// The newest notifications at (re)connection, oldest first: shown, never announced.
        case initial([SystemNotification])
        /// Delivered since the last event, oldest first.
        case new([SystemNotification])
    }
    typealias Handler = @Sendable (Event) -> Void

    let url: URL
    let coalesce: DispatchTimeInterval
    let keep: Int
    private let queue = DispatchQueue(label: "glancy.notifications.watch", qos: .utility)

    // Queue-confined state.
    private var handler: Handler?
    private var running = false
    private var db: NotificationDatabase?
    private var sources: [DispatchSourceFileSystemObject] = []
    private var cursor: Cursor?
    private var pending: Need?
    /// Batch size cap for a single catch-up query (a flood shows its newest rows only).
    private let batch = 50

    /// The last row handed out: its id and uuid (ids can be reused, see `NotificationDatabase.rows`).
    struct Cursor: Equatable {
        var recID: Int64
        var uuid: Data?

        /// Rows not seen yet: past the cursor, or at the cursor's id with another uuid.
        func unseen(_ rows: [NotificationRow]) -> [NotificationRow] {
            rows.filter { $0.recID > recID || ($0.recID == recID && $0.uuid != nil && uuid != nil && $0.uuid != uuid) }
        }
    }

    private enum Need: Int, Comparable {
        case query, rewatch, reopen
        static func < (a: Need, b: Need) -> Bool { a.rawValue < b.rawValue }
    }

    init(url: URL, coalesce: DispatchTimeInterval = .milliseconds(300), keep: Int = 20) {
        self.url = url
        self.coalesce = coalesce
        self.keep = keep
    }

    var walURL: URL { URL(fileURLWithPath: url.path + "-wal") }

    func start(_ handler: @escaping Handler) {
        queue.async { [self] in
            guard !running else { return }
            running = true
            self.handler = handler
            connect()
        }
    }

    func stop() {
        queue.sync { [self] in
            running = false
            handler = nil
            cancelSources()
            db?.close(); db = nil
            cursor = nil
            pending = nil
        }
    }

    /// Tries again when the store could not be read (Full Disk Access granted since, store back).
    func retry() {
        queue.async { [self] in
            guard running, db == nil else { return }
            connect()
        }
    }

    /// Runs `body` on the watcher queue after everything queued so far (tests).
    func sync(_ body: () -> Void = {}) { queue.sync(execute: body) }

    // MARK: Connection

    private func connect() {
        let database = NotificationDatabase(url: url)
        do {
            try database.open()
        } catch {
            disconnect(error)
            return
        }
        db = database
        if cursor != nil {
            // Reconnected after a rename/delete or a retry: catch up from where we were.
            fetchNew()
        } else {
            do {
                let rows = try database.latest(limit: keep)
                cursor = rows.last.map { Cursor(recID: $0.recID, uuid: $0.uuid) } ?? Cursor(recID: 0, uuid: nil)
                emit(.initial(Self.decode(rows)))
            } catch {
                // Not even busy is retried here: without a cursor nothing would follow.
                disconnect(error)
                return
            }
        }
        if db != nil { watch() }
    }

    private func fail(_ error: Error) {
        let e = error as? NotificationSourceError ?? .sqlite(-1, "\(error)")
        switch e {
        case .sqlite(let rc, _) where rc & 0xFF == 5 || rc & 0xFF == 6:
            return                                   // SQLITE_BUSY / LOCKED: the next event reads it
        default:
            disconnect(e)
        }
    }

    /// Closes everything and reports why. Unless access was refused, the folder stays watched: the
    /// store or its WAL coming back (usernoted reopening it after a swap) triggers a new attempt.
    /// Otherwise only `retry()` tries again.
    private func disconnect(_ error: Error) {
        let e = error as? NotificationSourceError ?? .sqlite(-1, "\(error)")
        db?.close(); db = nil
        cancelSources()
        if e != .needsFullDiskAccess {
            addSource(url.deletingLastPathComponent().path, mask: [.write], isFolder: true)
        }
        emit(.unavailable(e))
    }

    // MARK: File events

    private func watch() {
        cancelSources()
        addSource(url.path, mask: [.write, .extend, .rename, .delete], isFolder: false)
        addSource(walURL.path, mask: [.write, .extend, .rename, .delete], isFolder: false)
        addSource(url.deletingLastPathComponent().path, mask: [.write], isFolder: true)
    }

    private func addSource(_ path: String, mask: DispatchSource.FileSystemEvent, isFolder: Bool) {
        let fd = Darwin.open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source, self.running else { return }
            let flags = source.data
            if isFolder {
                // A file appeared or went away (WAL created, store swapped): re-arm, or reconnect.
                self.schedule(self.db == nil ? .reopen : .rewatch)
            } else if flags.contains(.rename) || flags.contains(.delete) {
                self.schedule(.reopen)
            } else {
                self.schedule(.query)
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        sources.append(source)
    }

    private func cancelSources() {
        for s in sources { s.cancel() }
        sources = []
    }

    /// Coalesces a burst of file events into one action after `coalesce`.
    private func schedule(_ need: Need) {
        if let pending {
            self.pending = max(pending, need)
            return
        }
        pending = need
        queue.asyncAfter(deadline: .now() + coalesce) { [weak self] in
            guard let self, self.running, let need = self.pending else { return }
            self.pending = nil
            switch need {
            case .query:
                self.fetchNew()
            case .rewatch:
                self.fetchNew()
                if self.db != nil { self.watch() }
            case .reopen:
                self.db?.close(); self.db = nil
                self.cancelSources()
                self.connect()
            }
        }
    }

    private func fetchNew() {
        guard let db, let cursor else { return }
        do {
            let fresh = cursor.unseen(try db.rows(from: cursor.recID, limit: batch))
            guard let last = fresh.last else { return }
            self.cursor = Cursor(recID: last.recID, uuid: last.uuid)
            let decoded = Self.decode(fresh)
            if !decoded.isEmpty { emit(.new(decoded)) }
        } catch {
            fail(error)
        }
    }

    private func emit(_ event: Event) { handler?(event) }

    static func decode(_ rows: [NotificationRow]) -> [SystemNotification] {
        rows.compactMap {
            NotificationDecoder.decode(recID: $0.recID, identifier: $0.identifier, data: $0.data, deliveredDate: $0.delivered)
        }
    }
}
