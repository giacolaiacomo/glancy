import Foundation

// Command bar matching: fuzzy (prefix, word start, acronym, substring, subsequence), case and
// diacritics insensitive. Pure and fast: candidates are normalised once per open, a query once per
// keystroke, and scoring works on UTF-16 arrays.

/// A string prepared for matching: folded, lowercased, split into words.
public struct MatchText: Sendable, Equatable {
    /// Words joined by single spaces ("visual studio code").
    public let text: [UInt16]
    /// The words without spaces ("visualstudiocode").
    public let compact: [UInt16]
    /// The first letter of every word ("vsc").
    public let initials: [UInt16]
    /// Where each word starts in `text`.
    public let wordStarts: [Int]

    public init(_ raw: String) {
        let norm = PaletteMatcher.normalize(raw, splitCamelCase: true)
        text = Array(norm.utf16)
        var compact: [UInt16] = [], initials: [UInt16] = [], starts: [Int] = []
        var atStart = true
        for (i, c) in text.enumerated() {
            if c == 32 { atStart = true; continue }
            compact.append(c)
            if atStart { initials.append(c); starts.append(i); atStart = false }
        }
        self.compact = compact
        self.initials = initials
        wordStarts = starts
    }

    public var isEmpty: Bool { text.isEmpty }
}

public enum PaletteMatcher {
    /// Folded (case, diacritics, width), punctuation to spaces, single spaces, trimmed.
    /// `splitCamelCase` also breaks "TextEdit" into "text edit" (candidates only, not queries).
    public static func normalize(_ s: String, splitCamelCase: Bool = false) -> String {
        // One pass on the original (case is needed for camel case), one fold of the whole string.
        var out = ""
        out.reserveCapacity(s.utf8.count)
        var prevLower = false
        var lastSpace = true
        for ch in s {
            if splitCamelCase, ch.isUppercase, prevLower, !lastSpace { out.append(" "); lastSpace = true }
            prevLower = ch.isLowercase
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastSpace = false
            } else if !lastSpace {
                out.append(" ")
                lastSpace = true
            }
        }
        if out.hasSuffix(" ") { out.removeLast() }
        return out.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
    }

    /// The query, prepared: its words (normalised).
    public struct Query: Sendable, Equatable {
        public let raw: String
        public let text: [UInt16]
        public let compact: [UInt16]
        public let words: [[UInt16]]
        public init(_ raw: String) {
            self.raw = raw
            let n = PaletteMatcher.normalize(raw)
            text = Array(n.utf16)
            words = n.split(separator: " ").map { Array($0.utf16) }
            compact = words.flatMap { $0 }
        }
        public var isEmpty: Bool { compact.isEmpty }
    }

    // Score bands (higher is better). The bar adds rank, frecency and learning on top.
    public static let exact = 1000, prefix = 900, compactPrefix = 870, wordPrefix = 800, allWords = 760,
                      acronym = 700, substring = 600, subsequenceMax = 590

    /// nil = no match.
    public static func score(_ q: Query, _ t: MatchText) -> Int? {
        guard !q.isEmpty, !t.isEmpty else { return nil }
        let qt = q.text, tt = t.text
        if qt == tt || q.compact == t.compact { return exact }
        if hasPrefix(tt, qt) { return prefix - min(tt.count - qt.count, 60) }
        if hasPrefix(t.compact, q.compact) { return compactPrefix - min(t.compact.count - q.compact.count, 60) }
        if q.words.count == 1 {
            for (n, s) in t.wordStarts.enumerated() where n > 0 && hasPrefix(tt, qt, at: s) {
                return wordPrefix - n * 4
            }
        } else if wordsInOrder(q.words, t) {
            return allWords
        }
        if q.compact.count >= 2, hasPrefix(t.initials, q.compact) {
            return acronym - (t.initials.count - q.compact.count) * 2
        }
        if q.compact.count >= 2, let i = find(qt, in: tt) { return substring - min(i, 40) }
        if q.compact.count >= 2, let s = subsequence(q.compact, t) { return s }
        return nil
    }

    /// Best score over a title and its keywords (keywords count a little less).
    public static func best(_ q: Query, title: MatchText, keywords: [MatchText]) -> Int? {
        var best = score(q, title)
        for k in keywords {
            if let s = score(q, k).map({ $0 - 40 }), s > (best ?? .min) { best = s }
        }
        return best
    }

    // MARK: Pieces

    static func hasPrefix(_ a: [UInt16], _ p: [UInt16], at start: Int = 0) -> Bool {
        guard start + p.count <= a.count else { return false }
        for i in 0..<p.count where a[start + i] != p[i] { return false }
        return true
    }

    static func find(_ p: [UInt16], in a: [UInt16]) -> Int? {
        guard p.count <= a.count else { return nil }
        for i in 0...(a.count - p.count) where hasPrefix(a, p, at: i) { return i }
        return nil
    }

    /// Every query word is the prefix of a distinct word of the target, in order.
    static func wordsInOrder(_ words: [[UInt16]], _ t: MatchText) -> Bool {
        var w = 0
        for s in t.wordStarts {
            guard w < words.count else { break }
            if hasPrefix(t.text, words[w], at: s) { w += 1 }
        }
        return w == words.count
    }

    /// Characters in order over the compact target, rewarding word starts and runs; nil when the
    /// match is too scattered to be useful.
    static func subsequence(_ q: [UInt16], _ t: MatchText) -> Int? {
        let starts = Set(t.wordStarts)
        let tt = t.text
        var qi = 0, bonus = 0, last = -2, gaps = 0, first = -1
        for (i, c) in tt.enumerated() where c != 32 {
            guard qi < q.count else { break }
            if c == q[qi] {
                if first < 0 { first = i }
                bonus += 10
                if starts.contains(i) { bonus += 14 }
                if i == last + 1 { bonus += 9 } else if last >= 0 { gaps += i - last - 1 }
                last = i
                qi += 1
            }
        }
        guard qi == q.count else { return nil }
        // Too scattered: more skipped than matched, several times over.
        if gaps > q.count * 4 { return nil }
        let s = 260 + bonus - gaps * 3 - min(first, 20) * 2
        return min(max(s, 100), subsequenceMax)
    }
}
