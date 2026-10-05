import Foundation

// Persistence: `<dir>/index.json` + `<dir>/blobs/<id>.<ext>`. macOS has no NSFileProtection, so
// the directory is 0700 and every file 0600. All I/O happens on this actor, never on main.

public actor ClipboardDisk {
    public let directory: URL
    public nonisolated var blobs: URL { directory.appendingPathComponent("blobs", isDirectory: true) }
    var index: URL { directory.appendingPathComponent("index.json") }
    private var pendingSave: Task<Void, Never>?
    /// Saves and wipes carry the model's version; an older one arriving late is ignored.
    private var version = 0
    private let debounce: Duration

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Glancy/clipboard", isDirectory: true)
    }

    public init(directory: URL = ClipboardDisk.defaultDirectory, debounce: Duration = .milliseconds(800)) {
        self.directory = directory
        self.debounce = debounce
    }

    // MARK: Load / save

    public func load() -> [ClipItem] {
        guard let data = try? Data(contentsOf: index) else { return [] }
        let decoder = JSONDecoder()
        guard let items = try? decoder.decode([ClipItem].self, from: data) else { return [] }
        // Items whose image went missing are useless.
        return items.filter { item in
            item.imageBlob.map { FileManager.default.fileExists(atPath: blobs.appendingPathComponent($0).path) } ?? true
        }
    }

    /// Debounced: a burst of copies writes the index once.
    public func scheduleSave(_ items: [ClipItem], version: Int = .max) {
        guard accept(version) else { return }
        pendingSave?.cancel()
        let delay = debounce
        pendingSave = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self.save(items)
        }
    }

    /// Writes at once (tests, quit).
    public func save(_ items: [ClipItem]) {
        pendingSave?.cancel()
        pendingSave = nil
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(items), (try? prepare()) != nil else { return }
        try? writePrivate(data, to: index)
    }

    // MARK: Blobs

    /// Turns a draft into an item: downsamples the image, writes the blobs. Nil if the image is
    /// unreadable or nothing could be written.
    public func ingest(_ draft: ClipDraft, source: String?, sourceName: String?, now: Date = .now) -> ClipItem? {
        guard (try? prepare()) != nil else { return nil }
        let id = UUID()
        var item = ClipItem(id: id, kind: draft.kind, text: draft.text, signature: draft.signature, date: now,
                            sourceBundleID: source, sourceName: sourceName, fileURLs: draft.fileURLs)
        switch draft.kind {
        case .image:
            guard let raw = draft.image, let img = ClipImage.downsample(raw) else { return nil }
            let name = "\(id.uuidString).\(img.ext)"
            guard (try? writePrivate(img.data, to: blobs.appendingPathComponent(name))) != nil else { return nil }
            item.imageBlob = name
            item.imageSize = img.size
        case .text, .richText, .url:
            if draft.text.utf8.count > ClipLimits.inlineText {
                let name = "\(id.uuidString).txt"
                if (try? writePrivate(Data(draft.text.utf8), to: blobs.appendingPathComponent(name))) != nil {
                    item.textBlob = name
                    item.text = String(decoding: draft.text.utf8.prefix(ClipLimits.inlineText), as: UTF8.self)
                }
            }
            if let rtf = draft.rtf {
                let name = "\(id.uuidString).rtf"
                if (try? writePrivate(rtf, to: blobs.appendingPathComponent(name))) != nil {
                    item.rtfBlob = name
                } else {
                    item.kind = .text
                }
            }
        case .files:
            break
        }
        return item
    }

    public func remove(blobsOf items: [ClipItem]) {
        for name in items.flatMap(\.blobs) {
            try? FileManager.default.removeItem(at: blobs.appendingPathComponent(name))
        }
    }

    /// Clear all: the index and every blob.
    public func wipe(version: Int = .max) {
        guard accept(version) else { return }
        pendingSave?.cancel()
        pendingSave = nil
        try? FileManager.default.removeItem(at: blobs)
        try? FileManager.default.removeItem(at: index)
    }

    /// Deletes blob files no item references (a crash between ingest and save).
    public func sweep(keeping items: [ClipItem]) {
        let keep = Set(items.flatMap(\.blobs))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: blobs.path)) ?? []
        for name in names where !keep.contains(name) {
            try? FileManager.default.removeItem(at: blobs.appendingPathComponent(name))
        }
    }

    private func accept(_ v: Int) -> Bool {
        guard v == .max || v > version else { return false }
        if v != .max { version = v }
        return true
    }

    // MARK: Private files

    private func prepare() throws {
        let fm = FileManager.default
        for dir in [directory, blobs] {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
    }

    /// Writes to a 0600 temp file in the same (0700) directory, then renames over the target.
    private func writePrivate(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
