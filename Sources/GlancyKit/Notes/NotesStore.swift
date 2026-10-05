import Foundation

/// Notes on disk: one UTF-8 `.md` file per note in `Application Support/Glancy/notes/`, the file's
/// modification date is the note's. Writes are atomic (a 0600 temp file in the same folder, then
/// `rename(2)` over the old one), so a crash mid-write leaves the previous version intact and at
/// worst a stray `.tmp` file, swept on the next load. All I/O on this actor, never on main.
public actor NotesStore {
    public nonisolated let directory: URL
    /// Files written since launch (tests check the debounce with it).
    public private(set) var writes = 0

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Glancy/notes", isDirectory: true)
    }

    public init(directory: URL = NotesStore.defaultDirectory) {
        self.directory = directory
    }

    nonisolated func url(_ id: String) -> URL { directory.appendingPathComponent("\(id).md") }

    /// Every note, newest first. Leftover temp files from an interrupted write are removed.
    public func loadAll() -> [Note] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return [] }
        var out: [Note] = []
        for file in files {
            let name = file.lastPathComponent
            if name.hasPrefix("."), name.hasSuffix(".tmp") {
                try? fm.removeItem(at: file)
                continue
            }
            guard file.pathExtension == "md", !name.hasPrefix("."),
                  let data = try? Data(contentsOf: file) else { continue }
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            out.append(Note(id: file.deletingPathExtension().lastPathComponent, fileText: String(decoding: data, as: UTF8.self),
                            modified: date))
        }
        return out.sorted { $0.modified > $1.modified }
    }

    /// Writes one note atomically and stamps the file with the note's date.
    @discardableResult
    public func write(_ note: Note) -> Bool {
        guard Self.atomicWrite(note, in: directory) else { return false }
        writes += 1
        return true
    }

    /// The write itself, callable synchronously at quit (`NotesModel.flushNow`).
    nonisolated static func atomicWrite(_ note: Note, in directory: URL) -> Bool {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            guard (try? fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                           attributes: [.posixPermissions: 0o700])) != nil else { return false }
        }
        let target = directory.appendingPathComponent("\(note.id).md")
        let tmp = directory.appendingPathComponent(".\(note.id).\(UUID().uuidString.prefix(8)).tmp")
        guard fm.createFile(atPath: tmp.path, contents: Data(note.fileText.utf8), attributes: [.posixPermissions: 0o600]) else {
            return false
        }
        // rename(2) replaces the old file in one step: readers see the old or the new text, never half.
        guard rename(tmp.path, target.path) == 0 else {
            try? fm.removeItem(at: tmp)
            return false
        }
        try? fm.setAttributes([.modificationDate: note.modified], ofItemAtPath: target.path)
        return true
    }

    /// Removes the note and its recording, if any.
    public func delete(_ id: String) {
        try? FileManager.default.removeItem(at: url(id))
        try? FileManager.default.removeItem(at: audioURL(id: id))
    }

    /// A voice note's recording (`file` from its metadata).
    public nonisolated func audioURL(_ file: String) -> URL { directory.appendingPathComponent(file) }
    nonisolated func audioURL(id: String) -> URL { directory.appendingPathComponent("\(id).m4a") }
}
