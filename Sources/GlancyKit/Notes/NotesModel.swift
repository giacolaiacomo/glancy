import Foundation
import Observation

/// The notes in memory and everything the tab does with them. Edits save on their own, debounced
/// per note (a pause in typing writes once); leaving the tab or quitting flushes at once. Blank
/// notes never reach the disk, and one left blank is removed when you leave it.
@MainActor @Observable
public final class NotesModel {
    public internal(set) var notes: [Note] = []
    public internal(set) var loaded = false
    public var selectedID: String? {
        didSet {
            guard selectedID != oldValue else { return }
            if let old = oldValue { dropIfBlank(old) }
            if let selectedID { settings.lastID = selectedID }
            confirmingDelete = false
        }
    }
    /// The list's search.
    public var query = ""
    /// Bumped to put the keyboard in the editor (quick note, new note, tab shown).
    public internal(set) var focusToken = 0
    /// Delete asks once: the first click arms it.
    public var confirmingDelete = false

    @ObservationIgnored public let store: NotesStore
    @ObservationIgnored public let settings: NotesSettings
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored let now: () -> Date
    @ObservationIgnored private var pending: [String: Task<Void, Never>] = [:]
    /// Notes changed since their last write.
    @ObservationIgnored private var dirty: Set<String> = []
    @ObservationIgnored private(set) var visible = false
    /// Told before a note goes (voice notes stop playing it).
    @ObservationIgnored var willDelete: ((String) -> Void)?

    /// A quick note reopens the last note edited within this long; otherwise it starts a new one.
    static let quickReuse: TimeInterval = 15 * 60

    public init(store: NotesStore, settings: NotesSettings, debounce: Duration = .milliseconds(700),
                now: @escaping () -> Date = { .now }) {
        self.store = store
        self.settings = settings
        self.debounce = debounce
        self.now = now
    }

    // MARK: Loading

    public func load() async {
        let all = await store.loadAll()
        // Edits made before the load finished win.
        let local = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        notes = all.filter { local[$0.id] == nil } + notes
        notes.sort { $0.modified > $1.modified }
        loaded = true
        if settings.pinnedID.map({ id in !notes.contains { $0.id == id } }) == true { settings.pinnedID = nil }
        if selectedID == nil { selectedID = settings.lastID.flatMap { id in notes.first { $0.id == id }?.id } ?? notes.first?.id }
        if visible, notes.isEmpty { create() }
    }

    // MARK: Reading

    public var selected: Note? { selectedID.flatMap { id in notes.first { $0.id == id } } }
    public var pinned: Note? { settings.pinnedID.flatMap { id in notes.first { $0.id == id } } }

    /// The list: newest first, filtered by the search.
    public var listed: [Note] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let sorted = notes.sorted { $0.modified > $1.modified }
        return q.isEmpty ? sorted : search(q)
    }

    /// Notes whose text contains every word of `query` (case and accent blind), title hits first.
    public func search(_ query: String, limit: Int = .max) -> [Note] {
        let words = NLQuery.fold(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        var hits: [(Note, Int)] = []
        for n in notes {
            let body = NLQuery.fold(n.text)
            guard words.allSatisfy({ body.contains($0) }) else { continue }
            let title = NLQuery.fold(n.title ?? "")
            hits.append((n, words.allSatisfy { title.contains($0) } ? 1 : 0))
        }
        return hits.sorted { a, b in a.1 != b.1 ? a.1 > b.1 : a.0.modified > b.0.modified }.prefix(limit).map(\.0)
    }

    // MARK: Editing

    /// A new empty note, selected. Nothing is written until it has words.
    @discardableResult
    public func create(text: String = "") -> Note {
        let note = Note(id: Note.newID(at: now(), taken: Set(notes.map(\.id))), text: text, modified: now())
        notes.insert(note, at: 0)
        query = ""
        selectedID = note.id
        if !note.isBlank { scheduleSave(note.id, immediate: true) }
        focusToken &+= 1
        return note
    }

    public func edit(_ id: String, text: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }), notes[i].text != text else { return }
        notes[i].text = text
        notes[i].modified = now()
        scheduleSave(id)
    }

    public func select(_ id: String) {
        guard notes.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    public func delete(_ id: String) {
        willDelete?(id)
        // A save already writing this note must land before the delete, or the file comes back.
        let inFlight = pending.removeValue(forKey: id)
        inFlight?.cancel()
        dirty.remove(id)
        notes.removeAll { $0.id == id }
        if settings.pinnedID == id { settings.pinnedID = nil }
        if settings.inboxID == id { settings.inboxID = nil }
        if selectedID == id { selectedID = listed.first?.id }
        confirmingDelete = false
        let store = store
        Task { _ = await inFlight?.value; await store.delete(id) }
    }

    public func togglePin(_ id: String) {
        settings.pinnedID = settings.pinnedID == id ? nil : id
    }

    /// Flips the checklist box under `offset` in the selected note (the editor uses the same
    /// helper; this one serves clicks from the Home card and tests).
    public func toggleCheck(_ id: String, at offset: Int) {
        guard let n = notes.first(where: { $0.id == id }), let r = Checklist.toggle(n.text, at: offset) else { return }
        edit(id, text: r.text)
    }

    /// The command bar's "note buy milk": one line at the end of the Quick notes note (made on
    /// first use). Written at once: the panel is about to close.
    public func appendToInbox(_ line: String, title: String) {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let id = settings.inboxID, let i = notes.firstIndex(where: { $0.id == id }) {
            var body = notes[i].text
            if !body.isEmpty, !body.hasSuffix("\n") { body += "\n" }
            notes[i].text = body + text
            notes[i].modified = now()
            scheduleSave(id, immediate: true)
        } else {
            let note = Note(id: Note.newID(at: now(), taken: Set(notes.map(\.id))), text: "\(title)\n\(text)", modified: now())
            notes.insert(note, at: 0)
            settings.inboxID = note.id
            scheduleSave(note.id, immediate: true)
        }
    }

    /// A note made by another module (a meeting's transcript): first in the list, written at once,
    /// not selected (the tab stays on the note being read or edited).
    @discardableResult
    public func addExternal(text: String) -> Note? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let note = Note(id: Note.newID(at: now(), taken: Set(notes.map(\.id))), text: text, modified: now())
        notes.insert(note, at: 0)
        scheduleSave(note.id, immediate: true)
        return note
    }

    /// The quick-note hotkey: the last note if it was edited in the last 15 minutes (cursor at the
    /// end), otherwise a fresh one. A blank selected note is always reused.
    public func quickNote() {
        query = ""
        if let s = selected, s.isBlank {
            focusToken &+= 1
            return
        }
        if let recent = notes.max(by: { $0.modified < $1.modified }),
           now().timeIntervalSince(recent.modified) < Self.quickReuse {
            selectedID = recent.id
            focusToken &+= 1
            return
        }
        create()
    }

    // MARK: Visibility

    /// The tab appeared or went away. Shown with no notes: an empty one waits for typing.
    func setVisible(_ on: Bool) {
        guard on != visible else { return }
        visible = on
        if on {
            if loaded, notes.isEmpty { create() } else { focusToken &+= 1 }
        } else {
            query = ""
            confirmingDelete = false
            if let id = selectedID { dropIfBlank(id) }
            Task { await flush() }
        }
    }

    // MARK: Saving

    func scheduleSave(_ id: String, immediate: Bool = false) {
        dirty.insert(id)
        pending.removeValue(forKey: id)?.cancel()
        let delay = immediate ? Duration.zero : debounce
        pending[id] = Task { [weak self] in
            if delay > .zero {
                try? await Delay.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            await self?.write(id)
        }
    }

    // `pending[id]` keeps the task until it is replaced or the note deleted, so a delete can wait
    // for a write that is already past its debounce.
    private func write(_ id: String) async {
        guard dirty.remove(id) != nil, let note = notes.first(where: { $0.id == id }) else { return }
        if note.isBlank, settings.inboxID != id {
            await store.delete(id)
        } else {
            await store.write(note)
        }
    }

    /// Writes every pending edit now (leaving the tab, quitting).
    public func flush() async {
        for task in pending.values { task.cancel() }
        pending.removeAll()
        for id in dirty { await write(id) }
    }

    /// Writes every pending edit synchronously (quitting: no later turn of the run loop).
    func flushNow() {
        for task in pending.values { task.cancel() }
        pending.removeAll()
        for id in dirty {
            guard let note = notes.first(where: { $0.id == id }) else { continue }
            if note.isBlank, settings.inboxID != id {
                try? FileManager.default.removeItem(at: store.url(id))
            } else {
                _ = NotesStore.atomicWrite(note, in: store.directory)
            }
        }
        dirty.removeAll()
    }

    /// A note left blank goes away (memory and disk), unless it is still being edited.
    private func dropIfBlank(_ id: String) {
        guard let n = notes.first(where: { $0.id == id }), n.isBlank, settings.inboxID != id else { return }
        pending.removeValue(forKey: id)?.cancel()
        dirty.remove(id)
        notes.removeAll { $0.id == id }
        if settings.pinnedID == id { settings.pinnedID = nil }
        if selectedID == id { selectedID = notes.sorted { $0.modified > $1.modified }.first?.id }
        let store = store
        Task { await store.delete(id) }
    }
}
