import AppKit

/// One thing on the shelf: a bookmark to a file the user dropped, or to a file Glancy made for a
/// drop that wasn't a file (a promise, a text snippet, a link) — those it owns and deletes on remove.
public struct ShelfItem: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var bookmark: Data
    /// The bookmark carries a security scope (resolve and access with it).
    public var scoped: Bool
    /// Last resolved path: de-duplication, and the name if the file is renamed later.
    public var path: String
    /// Lives in `shelf-files/<id>/`: Glancy made it, Glancy deletes it.
    public var owned: Bool
    public var added: Date

    public init(id: UUID = UUID(), name: String, bookmark: Data, scoped: Bool, path: String, owned: Bool, added: Date = .now) {
        self.id = id; self.name = name; self.bookmark = bookmark; self.scoped = scoped
        self.path = path; self.owned = owned; self.added = added
    }
}

/// The shelf on disk: `<dir>/shelf.json` plus `<dir>/shelf-files/` for what Glancy staged itself.
/// Plain value logic + file I/O; the module calls it on the main actor (a few small files).
public struct ShelfStore: Sendable {
    public static let limit = 24
    public let dir: URL

    public init(dir: URL) { self.dir = dir }

    public static var `default`: ShelfStore {
        ShelfStore(dir: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Glancy", isDirectory: true))
    }

    public var indexURL: URL { dir.appendingPathComponent("shelf.json") }
    public var filesDir: URL { dir.appendingPathComponent("shelf-files", isDirectory: true) }

    // MARK: Index

    /// The saved items whose files still exist, with bookmarks refreshed when stale or moved.
    public func load() -> [ShelfItem] {
        guard let data = try? Data(contentsOf: indexURL),
              let saved = try? JSONDecoder().decode([ShelfItem].self, from: data) else { return [] }
        var out: [ShelfItem] = []
        var changed = false
        for var item in saved {
            guard let (url, stale) = Self.resolve(item), FileManager.default.fileExists(atPath: url.path) else {
                changed = true
                if item.owned { removeStaged(item) }
                continue
            }
            if stale || url.path != item.path {
                if let fresh = try? Self.item(for: url, owned: item.owned, id: item.id, added: item.added) { item = fresh }
                changed = true
            }
            out.append(item)
        }
        if changed { save(out) }
        return out
    }

    public func save(_ items: [ShelfItem]) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: indexURL, options: .atomic) }
    }

    // MARK: Bookmarks

    /// A security-scoped bookmark when the system grants one, a plain bookmark otherwise
    /// (Glancy is unsandboxed: both resolve; the scoped one also survives a future sandbox).
    public static func item(for url: URL, owned: Bool, id: UUID = UUID(), added: Date = .now) throws -> ShelfItem {
        let url = url.standardizedFileURL
        if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            return ShelfItem(id: id, name: url.lastPathComponent, bookmark: data, scoped: true, path: url.path, owned: owned, added: added)
        }
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        return ShelfItem(id: id, name: url.lastPathComponent, bookmark: data, scoped: false, path: url.path, owned: owned, added: added)
    }

    /// The bookmark's file now. A scoped bookmark belongs to the signature that made it: if a
    /// differently signed build can't open its scope, it is resolved plainly, and failing that the
    /// last known path still counts when the file is there (the caller then re-bookmarks it).
    public static func resolve(_ item: ShelfItem) -> (URL, stale: Bool)? {
        var stale = false
        if item.scoped, let url = try? URL(resolvingBookmarkData: item.bookmark, options: [.withSecurityScope, .withoutUI],
                                           relativeTo: nil, bookmarkDataIsStale: &stale) {
            return (url, stale)
        }
        if let url = try? URL(resolvingBookmarkData: item.bookmark, options: [.withoutUI], relativeTo: nil,
                              bookmarkDataIsStale: &stale) {
            return (url, stale || item.scoped)
        }
        if FileManager.default.fileExists(atPath: item.path) { return (URL(fileURLWithPath: item.path), true) }
        return nil
    }

    // MARK: Staging (files Glancy owns)

    /// A fresh `shelf-files/<uuid>/` folder for one staged item.
    public func stagingFolder(_ id: UUID = UUID()) throws -> URL {
        let folder = filesDir.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    public func removeStaged(_ item: ShelfItem) {
        guard item.owned else { return }
        let path = URL(fileURLWithPath: item.path).deletingLastPathComponent().standardizedFileURL.path
        // Only ever delete inside shelf-files.
        guard path.hasPrefix(filesDir.standardizedFileURL.path + "/") else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Text dropped on the shelf becomes a .txt named after its first words.
    public func stageText(_ text: String) throws -> URL {
        let url = try stagingFolder().appendingPathComponent(Self.fileName(for: text, fallback: "Text") + ".txt")
        try Data(text.utf8).write(to: url)
        return url
    }

    /// A link becomes a .webloc (what Safari and Finder make), named after its host.
    public func stageLink(_ link: URL) throws -> URL {
        let url = try stagingFolder().appendingPathComponent(Self.fileName(for: link.host() ?? link.absoluteString, fallback: "Link") + ".webloc")
        let data = try PropertyListSerialization.data(fromPropertyList: ["URL": link.absoluteString], format: .xml, options: 0)
        try data.write(to: url)
        return url
    }

    /// A file that lives only as long as the drag (a staged provider file, a temp copy) is
    /// copied into the shelf; everything else is bookmarked where it is.
    public func stageCopy(of file: URL) throws -> URL {
        let url = try stagingFolder().appendingPathComponent(file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: url)
        return url
    }

    public static func fileName(for text: String, fallback: String) -> String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let cleaned = first.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = String(cleaned.prefix(40)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty || name.hasPrefix(".") ? fallback : name
    }

    /// Paths that disappear after the drop: Foundation's NSItemProvider staging (boring.notch #1044)
    /// and the per-user temporary folders.
    public static func isTransient(_ url: URL) -> Bool {
        let p = url.resolvingSymlinksInPath().path
        let tmp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        return p.contains("/.com.apple.Foundation.NSItemProvider") || p.contains("/NSIRD_")
            || p.hasPrefix(tmp + "/") || p.hasPrefix("/private/var/folders/") || p.hasPrefix("/var/folders/")
    }
}

/// The shelf's list rules: newest first, one entry per file, at most `ShelfStore.limit`.
public enum ShelfList {
    public static func key(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Adds `new` in front. A file already on the shelf moves to the front instead of doubling
    /// (keeping its identity). Returns the new list and what left it: items past the limit and
    /// duplicates that were not kept (the caller deletes their staged files, if any).
    public static func adding(_ new: [ShelfItem], to items: [ShelfItem], limit: Int = ShelfStore.limit)
        -> (items: [ShelfItem], removed: [ShelfItem]) {
        var existing: [String: ShelfItem] = [:]
        for old in items where existing[key(old.path)] == nil { existing[key(old.path)] = old }
        var keys = Set<String>()
        var result: [ShelfItem] = []
        var removed: [ShelfItem] = []
        for item in new {
            let k = key(item.path)
            guard keys.insert(k).inserted else { removed.append(item); continue }
            if var old = existing[k] {
                old.added = item.added
                result.append(old)
                if old.id != item.id { removed.append(item) }
            } else {
                result.append(item)
            }
        }
        for old in items where keys.insert(key(old.path)).inserted { result.append(old) }
        return (Array(result.prefix(limit)), Array(result.dropFirst(limit)) + removed)
    }
}

/// What a drag carries, in the order the shelf prefers it.
public enum ShelfDropKind: Equatable, Sendable {
    case files([URL])
    case promises(Int)
    case link(URL)
    case text(String)
}

public enum ShelfDrop {
    /// The pasteboard types the notch accepts for the shelf.
    public static var types: [NSPasteboard.PasteboardType] {
        [.fileURL, .URL, .string] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    /// Real files first (when they exist), then file promises (Mail, Outlook, Photos), then a web
    /// link, then plain text.
    public static func classify(_ pb: NSPasteboard) -> ShelfDropKind? {
        let files = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if !files.isEmpty { return .files(files) }
        let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) ?? []
        if !promises.isEmpty { return .promises(promises.count) }
        if let link = (pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?
            .first(where: { ["http", "https", "mailto", "ftp"].contains($0.scheme?.lowercased() ?? "") }) {
            return .link(link)
        }
        if let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            if let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil,
               !text.contains(where: \.isWhitespace) {
                return .link(url)
            }
            return .text(text)
        }
        return nil
    }
}
