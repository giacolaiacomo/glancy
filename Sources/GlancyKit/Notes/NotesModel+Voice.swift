import Foundation

/// Voice notes in the notes list: a recording becomes a note (title + transcript + whatever is
/// typed), saved at once like any other edit.
extension NotesModel {
    /// A new voice note, selected and written now. `id` is the recording's (its file is `<id>.m4a`).
    @discardableResult
    func addVoiceNote(id: String, title: String, audio: NoteAudio) -> Note {
        let note = Note(id: id, text: title, modified: now(), audio: audio)
        notes.insert(note, at: 0)
        query = ""
        confirmingDelete = false
        selectedID = note.id
        scheduleSave(note.id, immediate: true)
        return note
    }

    /// Puts the transcript under the note's first line (the title), above anything typed since,
    /// and marks the recording as transcribed. An empty transcript only sets the mark.
    func fillTranscript(_ id: String, _ transcript: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }), notes[i].audio != nil else { return }
        let words = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty {
            notes[i].text = Self.inserting(words, into: notes[i].text)
        }
        notes[i].audio?.transcribed = true
        notes[i].modified = now()
        scheduleSave(id, immediate: true)
    }

    /// "Title\nmine" + "words" → "Title\nwords\nmine".
    nonisolated static func inserting(_ transcript: String, into text: String) -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return transcript }
        guard let br = text.firstIndex(of: "\n") else { return text + "\n" + transcript }
        let rest = text[text.index(after: br)...]
        return String(text[..<br]) + "\n" + transcript + (rest.isEmpty ? "" : "\n" + rest)
    }

    /// The recording of a note on disk.
    func audioURL(_ note: Note) -> URL? {
        note.audio.map { store.audioURL($0.file) }
    }
}
