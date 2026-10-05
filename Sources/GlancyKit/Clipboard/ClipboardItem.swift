import Foundation

// Clipboard history: the stored item and the pure list logic (de-dup, limit, pins, search).

public enum ClipKind: String, Codable, Sendable, CaseIterable {
    case text, richText, url, image, files

    var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .richText: "textformat"
        case .url: "link"
        case .image: "photo"
        case .files: "doc"
        }
    }
}

/// One history entry. Text lives inline (up to `ClipLimits.inlineText`); larger text, RTF and
/// images live as blob files next to the index, named by `id`.
public struct ClipItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: ClipKind
    /// Plain text (text / rich text), the URL string (url), file paths joined by "\n" (files),
    /// empty for images. For a big text, only its head; the whole is in `textBlob`.
    public var text: String
    /// Stable content hash: equal signatures = same content (de-dup).
    public var signature: String
    public var date: Date
    public var pinned: Bool
    public var sourceBundleID: String?
    public var sourceName: String?
    public var textBlob: String?
    public var rtfBlob: String?
    public var imageBlob: String?
    public var imageSize: CGSize?
    public var fileURLs: [URL]

    public init(id: UUID = UUID(), kind: ClipKind, text: String, signature: String, date: Date = .now,
                pinned: Bool = false, sourceBundleID: String? = nil, sourceName: String? = nil,
                textBlob: String? = nil, rtfBlob: String? = nil, imageBlob: String? = nil,
                imageSize: CGSize? = nil, fileURLs: [URL] = []) {
        self.id = id; self.kind = kind; self.text = text; self.signature = signature; self.date = date
        self.pinned = pinned; self.sourceBundleID = sourceBundleID; self.sourceName = sourceName
        self.textBlob = textBlob; self.rtfBlob = rtfBlob; self.imageBlob = imageBlob
        self.imageSize = imageSize; self.fileURLs = fileURLs
    }

    /// Blob file names this item owns.
    var blobs: [String] { [textBlob, rtfBlob, imageBlob].compactMap { $0 } }

    /// What a row shows: whitespace collapsed, at most ~300 characters.
    var preview: String {
        switch kind {
        case .files:
            let names = fileURLs.map(\.lastPathComponent)
            return names.count <= 3 ? names.joined(separator: ", ")
                : names.prefix(2).joined(separator: ", ") + " +\(names.count - 2)"
        case .image:
            if let s = imageSize { return "\(Int(s.width)) × \(Int(s.height))" }
            return ""
        default:
            let head = text.prefix(400)
            return head.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
    }
}

public enum ClipLimits {
    /// Unpinned items kept; pinned ones are not counted.
    public static let maxItems = 60
    /// Text longer than this (UTF-8 bytes) goes to a blob; the index keeps the head.
    public static let inlineText = 16 * 1024
    /// Longest side of a stored image, in pixels.
    public static let imagePixels = 512
    /// Largest stored image file.
    public static let imageBytes = 2 * 1024 * 1024
    /// Largest RTF kept; beyond it the item is stored as plain text.
    public static let rtfBytes = 1024 * 1024
}

/// The list rules, free of I/O.
public enum ClipboardHistory {
    /// Inserts `item` on top. A same-content item is replaced (keeping its pin), so a re-copy
    /// moves it to the top. Returns the new list and the items dropped (their blobs can go).
    public static func insert(_ item: ClipItem, into list: [ClipItem], limit: Int = ClipLimits.maxItems)
        -> (list: [ClipItem], dropped: [ClipItem]) {
        var new = item
        var rest = list
        var dropped: [ClipItem] = []
        if let i = rest.firstIndex(where: { $0.signature == item.signature }) {
            let old = rest.remove(at: i)
            new.pinned = new.pinned || old.pinned
            if old.id != new.id { dropped.append(old) }
        }
        rest.insert(new, at: 0)
        let trimmed = trim(rest, limit: limit)
        return (trimmed.list, dropped + trimmed.dropped)
    }

    /// Keeps every pinned item and the newest `limit` unpinned ones, in order.
    public static func trim(_ list: [ClipItem], limit: Int = ClipLimits.maxItems) -> (list: [ClipItem], dropped: [ClipItem]) {
        var kept: [ClipItem] = []
        var dropped: [ClipItem] = []
        var unpinned = 0
        for item in list {
            if item.pinned { kept.append(item); continue }
            unpinned += 1
            if unpinned <= limit { kept.append(item) } else { dropped.append(item) }
        }
        return (kept, dropped)
    }

    /// Moves an existing item to the top with a fresh date (it was just copied back).
    public static func touch(_ id: UUID, in list: [ClipItem], now: Date = .now) -> [ClipItem] {
        guard let i = list.firstIndex(where: { $0.id == id }) else { return list }
        var rest = list
        var item = rest.remove(at: i)
        item.date = now
        rest.insert(item, at: 0)
        return rest
    }

    /// Items matching every word of `query` (case- and diacritic-insensitive) in their text,
    /// file names or source app. Empty query = everything.
    public static func filter(_ list: [ClipItem], query: String) -> [ClipItem] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return list }
        return list.filter { item in
            let hay = [item.text, item.sourceName ?? "", item.fileURLs.map(\.lastPathComponent).joined(separator: " ")]
                .joined(separator: " ")
            return words.allSatisfy { hay.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// Pinned first (in their order), then the rest: the order the list is drawn in.
    public static func sections(_ list: [ClipItem]) -> (pinned: [ClipItem], recent: [ClipItem]) {
        (list.filter(\.pinned), list.filter { !$0.pinned })
    }
}
