import Foundation

// Synced lyrics: the LRC format, the line on screen at a given playback position, and when the
// next line starts. Pure values, unit-tested; the controller turns `delayToNextLine` into one
// scheduled wake per line.

/// One timed line. `text` is empty for an instrumental break.
public struct LyricLine: Equatable, Sendable {
    public var time: TimeInterval
    public var text: String
    public init(time: TimeInterval, text: String) { self.time = time; self.text = text }
}

/// What LRCLIB (or the cache) knows about a track.
public enum LyricsContent: Equatable, Sendable {
    /// Timed lines, sorted by time.
    case synced([LyricLine])
    /// Words without timing.
    case plain(String)
    case instrumental
    case notFound
}

public enum LRC {
    /// Parses LRC text: `[mm:ss.xx]`, `[mm:ss.xxx]`, `[mm:ss]`, `[mm:ss:xx]`, several stamps on one
    /// line (a repeated chorus), `[offset:±ms]` (positive = lyrics earlier), metadata tags
    /// (`[ar:…]`, `[ti:…]`) ignored, word-level `<mm:ss.xx>` stamps stripped. Lines are sorted by time;
    /// a stamp with no words is an instrumental break (empty text).
    public static func parse(_ source: String) -> [LyricLine] {
        var offset: TimeInterval = 0
        var out: [LyricLine] = []
        for raw in source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var rest = Substring(raw).drop { $0 == " " || $0 == "\t" }
            var stamps: [TimeInterval] = []
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if let t = time(tag) {
                    stamps.append(t)
                } else if tag.lowercased().hasPrefix("offset:") {
                    let v = tag.dropFirst("offset:".count).trimmingCharacters(in: .whitespaces)
                    if let ms = Double(v) { offset = ms / 1000 }
                }
                // Anything else is a metadata tag ([ar:…], [length:…]): skipped.
                rest = rest[rest.index(after: close)...]
            }
            guard !stamps.isEmpty else { continue }
            let text = stripWordStamps(String(rest)).trimmingCharacters(in: .whitespaces)
            for t in stamps { out.append(LyricLine(time: t, text: text)) }
        }
        if offset != 0 { out = out.map { LyricLine(time: max(0, $0.time - offset), text: $0.text) } }
        // Stable: lines sharing a stamp keep their order.
        return out.enumerated().sorted { a, b in
            a.element.time != b.element.time ? a.element.time < b.element.time : a.offset < b.offset
        }.map(\.element)
    }

    /// "03:07.25" / "3:07.250" / "03:07" / "03:07:25" → seconds. Nil for anything else.
    static func time(_ tag: Substring) -> TimeInterval? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3, let m = Int(parts[0]), m >= 0 else { return nil }
        var secPart = Substring(parts[1])
        var frac: Substring = ""
        if parts.count == 3 {
            frac = parts[2]
        } else if let dot = secPart.firstIndex(of: ".") {
            frac = secPart[secPart.index(after: dot)...]
            secPart = secPart[..<dot]
        }
        guard secPart.count <= 2, let s = Int(secPart), (0..<60).contains(s) else { return nil }
        var f: TimeInterval = 0
        if !frac.isEmpty {
            guard frac.count <= 3, frac.allSatisfy(\.isNumber), let n = Double(frac) else { return nil }
            f = n / pow(10, Double(frac.count))
        }
        return TimeInterval(m * 60 + s) + f
    }

    private static func stripWordStamps(_ s: String) -> String {
        guard s.contains("<") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "<", let close = s[i...].firstIndex(of: ">"), time(s[s.index(after: i)..<close]) != nil {
                i = s.index(after: close)
                continue
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out.replacingOccurrences(of: "  ", with: " ")
    }
}

/// Lookups over sorted lines.
public enum LyricsTimeline {
    /// The line being sung at `position`: the last one whose time is ≤ position. Nil before the first.
    public static func index(in lines: [LyricLine], at position: TimeInterval) -> Int? {
        var lo = 0, hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= position { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }

    /// When the next line starts (seconds of track time), strictly after `position`.
    public static func nextTime(in lines: [LyricLine], after position: TimeInterval) -> TimeInterval? {
        let next = (index(in: lines, at: position) ?? -1) + 1
        // Lines sharing a stamp: skip to the first one that is really later.
        var i = next
        while i < lines.count, lines[i].time <= position { i += 1 }
        return i < lines.count ? lines[i].time : nil
    }

    /// Wall-clock seconds until the line changes, or nil when nothing will change on its own
    /// (paused, no timing, past the last line).
    public static func delayToNextLine(_ lines: [LyricLine], info: NowPlayingInfo, now: Date) -> TimeInterval? {
        let rate = info.effectiveRate
        guard rate > 0, let position = info.position(at: now),
              let next = nextTime(in: lines, after: position) else { return nil }
        if let d = info.duration, next > d { return nil }
        return max(0, (next - position) / rate)
    }
}
