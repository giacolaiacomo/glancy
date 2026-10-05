import Foundation

/// One note: a plain-text (light Markdown) file in `Application Support/Glancy/notes/<id>.md`.
/// A voice note also has `<id>.m4a` beside it, described in a front-matter block at the top of
/// the file (see `NoteFile`); its `text` is the title, the transcript and anything typed.
public struct Note: Identifiable, Equatable, Sendable {
    /// The file name without `.md` ("2026-10-05 143210"): readable in Finder, unique per second.
    public let id: String
    public var text: String
    public var modified: Date
    /// The recording, for a voice note.
    public var audio: NoteAudio?

    public init(id: String, text: String, modified: Date, audio: NoteAudio? = nil) {
        self.id = id; self.text = text; self.modified = modified; self.audio = audio
    }

    /// No words and no recording: never written, dropped when left.
    public var isBlank: Bool { audio == nil && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The first line with words, without Markdown marks; nil for a blank note.
    public var title: String? {
        lines.first.map { String($0.prefix(80)) }
    }

    /// The lines after the title, without Markdown marks (for list previews and the Home card).
    public var bodyLines: [String] { Array(lines.dropFirst()) }

    private var lines: [String] {
        text.split(whereSeparator: \.isNewline).map { Self.plain(String($0)) }.filter { !$0.isEmpty }
    }

    /// "- [x] milk" → "milk", "## Plan" → "Plan", "- item" → "item".
    static func plain(_ line: String) -> String {
        var s = Substring(line).drop { $0 == " " || $0 == "\t" }
        if let m = Checklist.item(String(s)) { return String(m.text) }
        while s.first == "#" { s = s.dropFirst() }
        if s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("+ ") { s = s.dropFirst(2) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// A new id from a date, avoiding `taken` ones.
    static func newID(at date: Date, taken: Set<String>) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmmss"
        let base = f.string(from: date)
        var id = base, n = 2
        while taken.contains(id) { id = "\(base)-\(n)"; n += 1 }
        return id
    }
}

/// Checklist lines (`- [ ] milk`, `* [x] done`), the only "rich" thing notes have. Ranges are
/// UTF-16 (NSString / NSTextView), so a click maps straight onto them.
public enum Checklist {
    public struct Marker: Equatable, Sendable {
        /// From the dash to the closing bracket: "- [ ]".
        public var prefix: NSRange
        /// The brackets: "[ ]".
        public var box: NSRange
        /// The whole line, without its line break.
        public var line: NSRange
        public var checked: Bool
    }

    private static let pattern = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+]) \[([ xX])\](?= |$)"#, options: [.anchorsMatchLines])

    /// Every checklist marker in `text`.
    public static func markers(in text: String) -> [Marker] {
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            let dash = m.range(at: 2)
            let box = NSRange(location: m.range(at: 3).location - 1, length: 3)
            let prefix = NSRange(location: dash.location, length: NSMaxRange(box) - dash.location)
            var line = ns.lineRange(for: NSRange(location: m.range.location, length: 0))
            // Drop the line break.
            while line.length > 0, let c = Unicode.Scalar(ns.character(at: NSMaxRange(line) - 1)),
                  CharacterSet.newlines.contains(c) { line.length -= 1 }
            let mark = ns.substring(with: m.range(at: 3))
            return Marker(prefix: prefix, box: box, line: line, checked: mark != " ")
        }
    }

    /// One line as a checklist item, or nil.
    static func item(_ line: String) -> (checked: Bool, text: Substring)? {
        let s = Substring(line).drop { $0 == " " || $0 == "\t" }
        guard s.count >= 5, "-*+".contains(s.first!), s.dropFirst().hasPrefix(" ["),
              let mark = s.dropFirst(3).first, " xX".contains(mark), s.dropFirst(4).first == "]" else { return nil }
        let rest = s.dropFirst(5)
        guard rest.isEmpty || rest.first == " " else { return nil }
        return (mark != " ", rest.drop { $0 == " " })
    }

    /// The text with the box at `offset` flipped, when `offset` (UTF-16) falls on a marker's
    /// "- [ ]"; nil otherwise. `box` says which range changed (for an undoable replace).
    public static func toggle(_ text: String, at offset: Int) -> (text: String, box: NSRange, replacement: String)? {
        guard let m = markers(in: text).first(where: { offset >= $0.prefix.location && offset < NSMaxRange($0.prefix) }) else {
            return nil
        }
        let replacement = m.checked ? "[ ]" : "[x]"
        let new = (text as NSString).replacingCharacters(in: m.box, with: replacement)
        return (new, m.box, replacement)
    }

    /// What Return does at the end of a list line.
    public enum Continuation: Equatable, Sendable {
        /// Insert this (a line break plus the next item's marker).
        case insert(String)
        /// The item is empty: remove its marker (ends the list), this range.
        case endList(NSRange)
    }

    /// Return pressed with the caret at `caret` (UTF-16). nil = a plain line break.
    public static func continuation(in text: String, caret: Int) -> Continuation? {
        let ns = text as NSString
        guard caret <= ns.length else { return nil }
        var lineStart = caret
        while lineStart > 0, !isBreak(ns, lineStart - 1) { lineStart -= 1 }
        let line = ns.substring(with: NSRange(location: lineStart, length: caret - lineStart))
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        if let item = Checklist.item(line) {
            if item.text.trimmingCharacters(in: .whitespaces).isEmpty {
                return .endList(NSRange(location: lineStart, length: caret - lineStart))
            }
            let bullet = line.dropFirst(indent.count).first.map(String.init) ?? "-"
            return .insert("\n\(indent)\(bullet) [ ] ")
        }
        let body = line.dropFirst(indent.count)
        if let bullet = body.first, "-*+".contains(bullet), body.dropFirst().first == " " {
            if body.dropFirst(2).trimmingCharacters(in: .whitespaces).isEmpty {
                return .endList(NSRange(location: lineStart, length: caret - lineStart))
            }
            return .insert("\n\(indent)\(bullet) ")
        }
        return nil
    }

    private static func isBreak(_ ns: NSString, _ i: Int) -> Bool {
        guard let c = Unicode.Scalar(ns.character(at: i)) else { return false }
        return CharacterSet.newlines.contains(c)
    }
}
