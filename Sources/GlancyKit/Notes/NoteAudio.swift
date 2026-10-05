import Foundation

/// The recording of a voice note: `<id>.m4a` next to the `.md`, its length and a small waveform
/// (computed once after recording).
public struct NoteAudio: Equatable, Sendable {
    /// The file name inside the notes folder ("2026-10-05 143210.m4a").
    public var file: String
    public var duration: TimeInterval
    /// Peaks, 0…255, a few dozen bars: drawn as is, never recomputed.
    public var waveform: [UInt8]
    /// The transcript has been put in the note (or there was nothing to transcribe).
    public var transcribed: Bool

    public init(file: String, duration: TimeInterval, waveform: [UInt8] = [], transcribed: Bool = false) {
        self.file = file; self.duration = duration; self.waveform = waveform; self.transcribed = transcribed
    }
}

/// How a note sits on disk. A plain note is its text, byte for byte (every note written before
/// voice notes loads unchanged). A voice note starts with a front-matter block that Markdown
/// editors (Obsidian, iA Writer…) show as properties:
///
///     ---
///     audio: 2026-10-05 143210.m4a
///     duration: 42.3
///     waveform: <base64 peaks>
///     transcribed: true
///     ---
///     Voice note 14:32
///     …
///
/// A file that merely starts with `---` (a rule) and has no `audio:` key is left as text.
public enum NoteFile {
    public static func decode(_ raw: String) -> (text: String, audio: NoteAudio?) {
        guard raw.hasPrefix("---\n") else { return (raw, nil) }
        let afterOpen = raw.index(raw.startIndex, offsetBy: 4)
        guard let close = raw.range(of: "\n---\n", range: afterOpen..<raw.endIndex) else { return (raw, nil) }
        var fields: [String: String] = [:]
        for line in raw[afterOpen..<close.lowerBound].split(separator: "\n", omittingEmptySubsequences: false) {
            guard let colon = line.firstIndex(of: ":") else { return (raw, nil) }
            let key = line[..<colon]
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0 == "_" }) else { return (raw, nil) }
            fields[String(key)] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let file = fields["audio"], !file.isEmpty, !file.contains("/") else { return (raw, nil) }
        let audio = NoteAudio(file: file,
                              duration: fields["duration"].flatMap(Double.init) ?? 0,
                              waveform: fields["waveform"].flatMap { Data(base64Encoded: $0) }.map { [UInt8]($0) } ?? [],
                              transcribed: fields["transcribed"] == "true")
        return (String(raw[close.upperBound...]), audio)
    }

    public static func encode(_ text: String, audio: NoteAudio?) -> String {
        guard let audio else { return text }
        let duration = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), audio.duration)
        var head = "---\naudio: \(audio.file)\nduration: \(duration)\n"
        if !audio.waveform.isEmpty { head += "waveform: \(Data(audio.waveform).base64EncodedString())\n" }
        head += "transcribed: \(audio.transcribed)\n---\n"
        return head + text
    }
}

public extension Note {
    /// What goes in the `.md` file.
    var fileText: String { NoteFile.encode(text, audio: audio) }

    /// The note as read from its file.
    init(id: String, fileText: String, modified: Date) {
        let (text, audio) = NoteFile.decode(fileText)
        self.init(id: id, text: text, modified: modified, audio: audio)
    }
}

/// "0:42", "12:05", "1:02:03".
public enum VoiceTime {
    public static func format(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded(.down)))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
