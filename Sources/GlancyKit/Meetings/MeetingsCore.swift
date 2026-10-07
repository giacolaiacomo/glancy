import Foundation

// The meeting recorder's pure logic: who holds the microphone, which meeting that is, when a
// recording stops, folder names, the wing's minutes, how long audio is cut for speech recognition
// and how two tracks become one transcript. No clocks or I/O of its own: every function takes what
// it needs, so the module decides when to look and the tests drive everything.

/// Who speaks in a line of a transcript: your microphone, or what the Mac plays (everyone else).
public enum MeetingSpeaker: String, Codable, Sendable { case you, others }

/// A process whose microphone input is running (never Glancy itself).
public struct MicClient: Equatable, Sendable {
    public var pid: Int32
    public var bundleID: String?
    public var name: String?
    public init(pid: Int32, bundleID: String?, name: String?) { self.pid = pid; self.bundleID = bundleID; self.name = name }
}

/// What the microphone is doing, as the watcher last saw it.
public struct MicSnapshot: Equatable, Sendable {
    /// The default input runs somewhere (any process, Glancy included).
    public var running: Bool
    /// The processes whose input runs, Glancy left out; nil = unknown (no audio process objects).
    public var clients: [MicClient]?
    public init(running: Bool, clients: [MicClient]?) { self.running = running; self.clients = clients }
    public static let idle = MicSnapshot(running: false, clients: [])
}

/// The apps whose using the microphone means a call.
public struct MeetingApp: Equatable, Sendable {
    public let id: String
    public let name: String
    /// Bundle-identifier prefixes of the app and its helpers.
    public let bundles: [String]
    /// Processes without a bundle (FaceTime's calls run in `avconferenced`).
    public let processNames: [String]
    public let provider: MeetingLink.Provider?

    public static let known: [MeetingApp] = [
        MeetingApp(id: "zoom", name: "Zoom", bundles: ["us.zoom."], processNames: [], provider: .zoom),
        MeetingApp(id: "teams", name: "Microsoft Teams", bundles: ["com.microsoft.teams"], processNames: [], provider: .teams),
        MeetingApp(id: "webex", name: "Webex", bundles: ["Cisco-Systems.Spark", "com.webex.", "com.cisco.webex"], processNames: [],
                   provider: .webex),
        MeetingApp(id: "facetime", name: "FaceTime", bundles: ["com.apple.FaceTime"], processNames: ["avconferenced"], provider: .facetime),
        MeetingApp(id: "slack", name: "Slack", bundles: ["com.tinyspeck.slackmacgap"], processNames: [], provider: nil),
    ]

    /// Browsers and their helper processes (Safari's audio runs in the WebKit GPU process): a call
    /// there counts only while a calendar meeting with a link is on.
    public static let browsers: [(prefix: String, name: String)] = [
        ("com.google.Chrome", "Chrome"), ("com.apple.Safari", "Safari"), ("com.apple.WebKit", "Safari"),
        ("org.mozilla.firefox", "Firefox"), ("com.microsoft.edgemac", "Edge"), ("com.brave.Browser", "Brave"),
        ("company.thebrowser.", "Arc"), ("com.operasoftware.Opera", "Opera"), ("com.vivaldi.Vivaldi", "Vivaldi"),
        ("org.chromium.Chromium", "Chromium"), ("app.zen-browser.", "Zen"),
    ]

    func matches(_ c: MicClient) -> Bool { Self.matches(c, bundles: bundles, names: processNames) }

    static func matches(_ c: MicClient, bundles: [String], names: [String]) -> Bool {
        if let id = c.bundleID?.lowercased(), bundles.contains(where: { id.hasPrefix($0.lowercased()) }) { return true }
        if let n = c.name, names.contains(n) { return true }
        return false
    }

    /// The meeting app a process belongs to.
    public static func app(for c: MicClient) -> MeetingApp? { known.first { $0.matches(c) } }

    /// The browser a process belongs to (prefix, display name).
    public static func browser(for c: MicClient) -> (prefix: String, name: String)? {
        guard let id = c.bundleID?.lowercased() else { return nil }
        return browsers.first { id.hasPrefix($0.prefix.lowercased()) }
    }
}

/// A meeting found on the microphone (and the calendar).
public struct MeetingDetection: Equatable, Sendable {
    /// Stable per meeting ("event:<id>" with a calendar meeting, else "app:zoom"): "Not now" holds
    /// for it until it ends.
    public var key: String
    /// The calendar meeting in progress, when there is one.
    public var event: CalendarEvent?
    /// The app on the call ("Zoom", "Chrome"), when known.
    public var app: String?
    /// The processes whose input ending means the meeting ended (bundle prefixes and bare names);
    /// both empty = unknown (Glancy can't tell who holds the microphone).
    public var holderBundles: [String]
    public var holderNames: [String]

    public init(key: String, event: CalendarEvent? = nil, app: String? = nil, holderBundles: [String] = [], holderNames: [String] = []) {
        self.key = key; self.event = event; self.app = app; self.holderBundles = holderBundles; self.holderNames = holderNames
    }

    public var knowsHolder: Bool { !holderBundles.isEmpty || !holderNames.isEmpty }
}

public enum MeetingDetector {
    /// A calendar meeting counts from this long before its start (people join early).
    public static let earlyJoin: TimeInterval = 5 * 60

    /// Calendar meetings with a call link on at `now` (from 5 minutes before the start to the end),
    /// the one that started last first.
    public static func inProgress(_ events: [CalendarEvent], now: Date) -> [CalendarEvent] {
        events.filter { e in
            !e.isAllDay && !e.isDeclined && e.link != nil && e.end > e.start
                && e.start.addingTimeInterval(-earlyJoin) <= now && now < e.end
        }
        .sorted { ($0.start, $0.id) > ($1.start, $1.id) }
    }

    /// The meeting on the microphone right now, or nil.
    /// - A meeting app (Zoom, Teams, Webex, FaceTime, Slack) using the microphone is a meeting,
    ///   named after the calendar meeting on at the time when there is one.
    /// - Anything else using it (a browser on Meet, an unknown app) counts only while a calendar
    ///   meeting with a link is on.
    /// - When Glancy can't tell who uses it (no audio process objects), the microphone running
    ///   during a calendar meeting with a link counts.
    public static func detect(mic: MicSnapshot, events: [CalendarEvent], now: Date) -> MeetingDetection? {
        let meetings = inProgress(events, now: now)
        guard let clients = mic.clients else {
            guard mic.running, let e = meetings.first else { return nil }
            return MeetingDetection(key: "event:\(e.id)", event: e)
        }
        for app in MeetingApp.known {
            guard clients.contains(where: app.matches) else { continue }
            let event = meetings.first { $0.link?.provider == app.provider && app.provider != nil } ?? meetings.first
            return MeetingDetection(key: event.map { "event:\($0.id)" } ?? "app:\(app.id)", event: event, app: app.name,
                                    holderBundles: app.bundles, holderNames: app.processNames)
        }
        guard let e = meetings.first, let client = clients.first else { return nil }
        if let browser = clients.lazy.compactMap({ MeetingApp.browser(for: $0) }).first {
            return MeetingDetection(key: "event:\(e.id)", event: e, app: browser.name, holderBundles: [browser.prefix])
        }
        if let id = client.bundleID {
            return MeetingDetection(key: "event:\(e.id)", event: e, app: client.name, holderBundles: [id])
        }
        return MeetingDetection(key: "event:\(e.id)", event: e, app: client.name, holderNames: client.name.map { [$0] } ?? [])
    }

    /// The meeting's app still uses the microphone: true / false, nil when that can't be told.
    public static func stillHeld(_ d: MeetingDetection, mic: MicSnapshot) -> Bool? {
        guard d.knowsHolder, let clients = mic.clients else { return nil }
        return clients.contains { MeetingApp.matches($0, bundles: d.holderBundles, names: d.holderNames) }
    }

    /// The next instant a calendar meeting with a link comes into the window or leaves it.
    public static func nextBoundary(_ events: [CalendarEvent], after now: Date) -> Date? {
        events.filter { !$0.isAllDay && !$0.isDeclined && $0.link != nil }
            .flatMap { [$0.start.addingTimeInterval(-earlyJoin), $0.end] }
            .filter { $0 > now }
            .min()
    }
}

/// When a recording ends by itself.
public enum MeetingStopRules {
    /// The meeting's app let go of the microphone this long ago.
    public static let releaseGrace: TimeInterval = 30
    /// After a calendar meeting's end, the recording keeps going this long…
    public static let overrun: TimeInterval = 10 * 60
    /// …then stops once both tracks have been quiet this long; checked again this often.
    public static let silentFor: TimeInterval = 60
    public static let recheck: TimeInterval = 2 * 60
    /// Nothing records longer than this.
    public static let maxLength: TimeInterval = 4 * 3600
    /// Shorter recordings are thrown away (a Record pressed by mistake).
    public static let minLength: TimeInterval = 2

    /// The first silence check of a calendar meeting.
    public static func endCheck(eventEnd: Date) -> Date { eventEnd.addingTimeInterval(overrun) }

    /// Past the end check: stop when nothing has been heard for a minute (unknown = quiet).
    public static func quietEnough(_ silence: TimeInterval?) -> Bool { (silence ?? .infinity) >= silentFor }
}

/// The wing's minutes and the clocks the views show.
public enum MeetingClock {
    /// Whole minutes recorded.
    public static func minutes(_ elapsed: TimeInterval) -> Int { max(0, Int((elapsed / 60).rounded(.down))) }

    /// The instant the shown minutes change next.
    public static func nextMinute(start: Date, now: Date) -> Date {
        let m = minutes(now.timeIntervalSince(start))
        return start.addingTimeInterval(TimeInterval(m + 1) * 60)
    }

    /// "4:07", "1:04:07".
    public static func clock(_ t: TimeInterval) -> String {
        let total = max(0, Int(t.rounded(.down)))
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// A transcript timestamp: "04:07", "1:04:07".
    public static func stamp(_ t: TimeInterval) -> String {
        let total = max(0, Int(t.rounded(.down)))
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

/// Recording folders: "2026-10-07 1000 Design review".
public enum MeetingFolder {
    public static let maxTitle = 60

    public static func name(start: Date, title: String, taken: Set<String>, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd HHmm"
        let clean = sanitize(title)
        let base = clean.isEmpty ? f.string(from: start) : "\(f.string(from: start)) \(clean)"
        var name = base, n = 2
        while taken.contains(name) { name = "\(base) \(n)"; n += 1 }
        return name
    }

    /// No path separators, colons, control characters or leading dots; spaces collapsed; at most
    /// `maxTitle` characters.
    public static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        let mapped = s.unicodeScalars.map { bad.contains($0) ? " " : String($0) }.joined()
        var out = mapped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while out.hasPrefix(".") { out.removeFirst() }
        out = String(out.prefix(maxTitle)).trimmingCharacters(in: .whitespaces)
        return out
    }
}

// MARK: Speech chunks

/// Long audio is recognised in pieces of at most 55 s (on-device recognition of one request is
/// meant for short audio), each cut at the quietest tenth of a second between 40 and 55 s so a
/// word is rarely split; pieces with nothing above the noise floor are skipped.
public enum SpeechChunks {
    /// One energy value per this many seconds.
    public static let frame: TimeInterval = 0.1
    public static let longest: TimeInterval = 55
    public static let shortest: TimeInterval = 40
    /// RMS below this is silence (about −50 dBFS).
    public static let floor: Float = 0.003

    public struct Chunk: Equatable, Sendable {
        public var frames: Range<Int>
        public var silent: Bool
        public var start: TimeInterval { TimeInterval(frames.lowerBound) * SpeechChunks.frame }
    }

    /// `energy`: RMS per `frame` of the whole track.
    public static func plan(energy: [Float]) -> [Chunk] {
        let longestFrames = Int(longest / frame), shortestFrames = Int(shortest / frame)
        var out: [Chunk] = []
        var start = 0
        while start < energy.count {
            var end = min(energy.count, start + longestFrames)
            if end < energy.count {
                // The quietest frame in the window (the latest one on a tie: longer pieces).
                let window = (start + shortestFrames)..<end
                var best = window.lowerBound
                for i in window where energy[i] <= energy[best] { best = i }
                end = best + 1
            }
            let silent = energy[start..<end].allSatisfy { $0 < floor }
            out.append(Chunk(frames: start..<end, silent: silent))
            start = end
        }
        return out
    }
}

// MARK: Transcript

/// One line of a transcript: who, from when to when (seconds from the recording's start), what.
public struct SpokenLine: Codable, Equatable, Sendable {
    public var speaker: MeetingSpeaker
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    public init(speaker: MeetingSpeaker, start: TimeInterval, end: TimeInterval, text: String) {
        self.speaker = speaker; self.start = start; self.end = end; self.text = text
    }
}

/// A recognised word with its time in the audio.
public struct SpokenWord: Equatable, Sendable {
    public var text: String
    public var start: TimeInterval
    public var duration: TimeInterval
    public init(text: String, start: TimeInterval, duration: TimeInterval) { self.text = text; self.start = start; self.duration = duration }
}

public enum TranscriptBuilder {
    /// A pause this long starts a new line…
    public static let pause: TimeInterval = 1.0
    /// …and a shorter one does after a sentence's end; no line runs longer than `longest`.
    public static let sentencePause: TimeInterval = 0.5
    public static let longest: TimeInterval = 30
    /// Lines of one speaker this close are joined.
    public static let joinGap: TimeInterval = 1.5

    /// Words (as a recogniser gives them) → lines.
    public static func lines(from words: [SpokenWord], speaker: MeetingSpeaker) -> [SpokenLine] {
        var out: [SpokenLine] = []
        var current: SpokenLine?
        for w in words.sorted(by: { $0.start < $1.start }) {
            let text = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if var c = current {
                let gap = w.start - c.end
                let sentenceEnd = c.text.last.map { ".?!…".contains($0) } ?? false
                if gap >= pause || (sentenceEnd && gap >= sentencePause) || w.start + w.duration - c.start > longest {
                    out.append(c)
                    current = SpokenLine(speaker: speaker, start: w.start, end: w.start + w.duration, text: text)
                } else {
                    c.text += " " + text
                    c.end = max(c.end, w.start + w.duration)
                    current = c
                }
            } else {
                current = SpokenLine(speaker: speaker, start: w.start, end: w.start + w.duration, text: text)
            }
        }
        if let current { out.append(current) }
        return out
    }

    /// Both tracks in time order. A "You" line that repeats an "Others" line said at the same time
    /// (the other people heard by your microphone through the speakers) is dropped; lines of one
    /// speaker less than 1.5 s apart are joined.
    public static func merge(you: [SpokenLine], others: [SpokenLine]) -> [SpokenLine] {
        let kept = you.filter { !isEcho($0, of: others) }
        let all = (kept + others).sorted { ($0.start, $0.speaker == .others ? 0 : 1) < ($1.start, $1.speaker == .others ? 0 : 1) }
        var out: [SpokenLine] = []
        for line in all {
            if var last = out.last, last.speaker == line.speaker, line.start - last.end < joinGap,
               line.end - last.start <= longest * 2 {
                last.text += " " + line.text
                last.end = max(last.end, line.end)
                out[out.count - 1] = last
            } else {
                out.append(line)
            }
        }
        return out
    }

    /// Most of the line's words appear in an "Others" line overlapping it in time (±3 s).
    static func isEcho(_ line: SpokenLine, of others: [SpokenLine]) -> Bool {
        let words = Set(normalized(line.text))
        guard words.count >= 2 else {
            // One word: an echo only when it is exactly what someone else said then.
            return others.contains { overlaps($0, line) && normalized($0.text) == normalized(line.text) }
        }
        return others.contains { o in
            guard overlaps(o, line) else { return false }
            let theirs = Set(normalized(o.text))
            return Double(words.intersection(theirs).count) / Double(words.count) >= 0.6
        }
    }

    private static func overlaps(_ a: SpokenLine, _ b: SpokenLine) -> Bool {
        a.start - 3 <= b.end && b.start <= a.end + 3
    }

    static func normalized(_ s: String) -> [String] {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// transcript.md: a title, one line about the recording, then "**04:07 You** text" lines.
    public static func markdown(title: String, about: String, lines: [SpokenLine], you: String, others: String, empty: String) -> String {
        var out = "# \(title)\n\n\(about)\n\n"
        if lines.isEmpty { return out + "_\(empty)_\n" }
        for l in lines {
            out += "**\(MeetingClock.stamp(l.start)) \(l.speaker == .you ? you : others):** \(l.text)\n\n"
        }
        return out
    }

    /// The note in Notes: the title, the line about it, then plain "04:07 You: text" lines.
    public static func note(title: String, about: String, lines: [SpokenLine], you: String, others: String, empty: String) -> String {
        var out = "\(title)\n\(about)\n"
        if lines.isEmpty { return out + "\n\(empty)" }
        for l in lines {
            out += "\n\(MeetingClock.stamp(l.start)) \(l.speaker == .you ? you : others): \(l.text)"
        }
        return out
    }
}
