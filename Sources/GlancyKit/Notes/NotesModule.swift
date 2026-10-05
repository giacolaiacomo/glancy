import AppKit
import SwiftUI

/// Quick notes in the notch: plain `.md` files, a list and an editor, a quick-note hotkey, one
/// note pinned to Home, and command-bar entries ("note buy milk", search). Event-driven only:
/// nothing runs while collapsed; the keyboard is taken only while the tab is on screen.
@MainActor
public final class NotesModule: GlancyModule {
    public let id: ModuleID = .notes
    public let model: NotesModel
    /// Synthetic notes in a temp folder (the renderer; never the user's notes).
    let sample: Bool

    private var hub: ActivityHub?
    private var hotkey: HotkeyManager.Token?
    private var loadTask: Task<Void, Never>?
    private var started = false
    private var tabVisible = false
    static let focusOwner = "notes.editor"

    /// The hotkey is set but the system refused it (taken by another app).
    public private(set) var hotkeyFailed = false

    public convenience init() {
        let env = ProcessInfo.processInfo
        if env.processName == "glancy-render" || env.environment["GLANCY_NOTES_SAMPLE"] == "1" {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glancy-notes-sample", isDirectory: true)
            let suite = "ai.glancy.notes.sample"
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            self.init(store: NotesStore(directory: dir), settings: NotesSettings(defaults: UserDefaults(suiteName: suite)!), sample: true)
        } else {
            self.init(store: NotesStore(), settings: NotesSettings(), sample: false)
        }
    }

    public init(store: NotesStore, settings: NotesSettings, sample: Bool = false, debounce: Duration = .milliseconds(700),
                now: @escaping () -> Date = { .now }) {
        model = NotesModel(store: store, settings: settings, debounce: debounce, now: now)
        self.sample = sample
        // Settings → Notes is reachable while the module is off: its strings must be there too.
        L10n.addItalian(NotesText.italian)
    }

    // MARK: Lifecycle

    public func start(hub: ActivityHub) {
        guard !started else { return }
        started = true
        self.hub = hub
        L10n.addItalian(NotesText.italian)
        if sample {
            NotesSample.fill(model)
            return
        }
        loadTask = Task { [weak self] in await self?.model.load() }
        registerHotkey()
    }

    public func stop() {
        guard started else { return }
        started = false
        loadTask?.cancel(); loadTask = nil
        if let hotkey { HotkeyManager.shared.unregister(hotkey) }
        hotkey = nil
        setTabVisible(false)
        if !sample { model.flushNow() }
        hub = nil
    }

    public func visibilityChanged(_ visibility: SurfaceVisibility) {
        guard started else { return }
        setTabVisible(visibility == .expanded(.notes))
    }

    private func setTabVisible(_ on: Bool) {
        guard on != tabVisible else { return }
        tabVisible = on
        // The editor and the search field need the panel to be key; given back on leave/collapse.
        SurfaceKeyFocus.request(on, owner: Self.focusOwner)
        model.setVisible(on)
    }

    // MARK: Hotkey

    private func registerHotkey() {
        if let hotkey { HotkeyManager.shared.unregister(hotkey) }
        hotkey = nil
        let combo = model.settings.hotkey
        guard combo.modifiers != 0 else { hotkeyFailed = false; return }
        hotkey = HotkeyManager.shared.register(combo) { [weak self] in self?.quickNote() }
        hotkeyFailed = hotkey == nil
    }

    /// Changes the quick-note hotkey (Settings → Notes); a combination without modifiers clears it.
    public func setHotkey(_ combo: Hotkey) {
        guard combo != model.settings.hotkey else { return }
        model.settings.hotkey = combo
        if started, !sample { registerHotkey() }
    }

    /// The quick-note flow: pick the note (last one if recent, else new), then open the tab; the
    /// editor takes the keyboard with the cursor at the end.
    public func quickNote() {
        model.quickNote()
        hub?.requestOpen(.notes)
    }

    /// Settings → Modules tile: the shortcut, or the count when there is none.
    var settingsSummary: String {
        let key = model.settings.hotkey
        return key.modifiers == 0 ? L10n.tr("%d notes", model.notes.count) : key.description
    }

    /// For conflict checks across Glancy's shortcuts.
    var hotkeyBinding: HotkeyBinding {
        HotkeyBinding(id: "notes.quick", title: L10n.tr("Quick note"), hotkey: model.settings.hotkey)
    }

    // MARK: Send to

    /// A new note in Apple Notes with this text (Automation permission, asked by macOS once).
    func openInNotes(_ note: Note) {
        let html = Self.notesHTML(note.text)
        let source = """
        tell application id "com.apple.Notes"
            activate
            set n to make new note with properties {body:"\(Self.appleScriptEscape(html))"}
            show n
        end tell
        """
        hub?.requestClose()
        DispatchQueue.global(qos: .userInitiated).async {
            var err: NSDictionary?
            _ = NSAppleScript(source: source)?.executeAndReturnError(&err)
        }
    }

    /// Plain text → the HTML body Apple Notes stores (first line as its title).
    static func notesHTML(_ text: String) -> String {
        func esc(_ s: Substring) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "<div><br></div>" : "<div>\(esc($0))</div>" }.joined()
    }

    static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: Surface

    public var tab: PanelTab? {
        PanelTab(module: .notes, symbol: "note.text", title: "Notes") { [model, weak self] in
            AnyView(NotesTabView(model: model, actions: NotesActions(
                openInNotes: { self?.openInNotes($0) },
                copied: { self?.hub?.requestClose() })))
        }
    }

    public func homeCard() -> AnyView? {
        guard let note = model.pinned else { return nil }
        return AnyView(NotesHomeCard(model: model, note: note) { [weak self] in self?.open(note.id) })
    }

    /// Opens the tab on one note.
    func open(_ id: String) {
        model.select(id)
        hub?.requestOpen(.notes)
    }

    // MARK: Command bar

    public func commands() -> [GlancyCommand] {
        [
            GlancyCommand(id: "notes.new", module: .notes, title: L10n.tr("New note"), symbol: "square.and.pencil",
                          keywords: ["new note", "note", "nuova nota", "nota", "appunto", "scrivi"], closesPanel: false) { [weak self] in
                self?.model.create()
                self?.hub?.requestOpen(.notes)
            },
            GlancyCommand(id: "notes.open", module: .notes, title: L10n.tr("Open notes"), symbol: "note.text",
                          keywords: ["notes", "open notes", "note", "apri note", "appunti"], closesPanel: false) { [weak self] in
                self?.hub?.requestOpen(.notes)
            },
        ]
    }

    /// "note buy milk" / "nota comprare latte" → add to Quick notes; anything else (2+ letters)
    /// searches the notes.
    public func results(for query: String) -> [GlancyCommand] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if let text = Self.appendText(trimmed) {
            let inbox = L10n.tr("Quick notes")
            return [GlancyCommand(id: "notes.append", module: .notes, title: L10n.tr("Add to %@: %@", inbox, text),
                                  subtitle: L10n.tr("A new line at the end of the note"), symbol: "text.append",
                                  keywords: [], rank: 95, closesPanel: true) { [weak self] in
                self?.append(text)
            }]
        }
        guard trimmed.count >= 2, model.loaded || sample else { return [] }
        return model.search(trimmed, limit: 5).map { note in
            let title = note.title ?? L10n.tr("New note")
            let titleHit = NLQuery.fold(title).contains(NLQuery.fold(trimmed))
            return GlancyCommand(id: "notes.open.\(note.id)", module: .notes, title: title,
                                 subtitle: Self.snippet(note.text, around: trimmed), symbol: "note.text",
                                 keywords: [], rank: titleHit ? 70 : 55, closesPanel: false) { [weak self] in
                self?.open(note.id)
            }
        }
    }

    /// The words after "note " / "nota " (also "note:" / "nota:"), or nil.
    static func appendText(_ query: String) -> String? {
        let lower = query.lowercased()
        for prefix in ["note:", "nota:", "note ", "nota ", "appunta "] where lower.hasPrefix(prefix) {
            let rest = query.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : rest
        }
        return nil
    }

    func append(_ text: String) {
        model.appendToInbox(text, title: L10n.tr("Quick notes"))
        hub?.show(PeekEvent(module: .notes, duration: 1.8, content: AnyView(NotesAddedPeek(text: text))))
    }

    /// The line of `text` where `query` first appears (or the first body line).
    static func snippet(_ text: String, around query: String) -> String? {
        let q = NLQuery.fold(query)
        let lines = text.split(whereSeparator: \.isNewline).map { Note.plain(String($0)) }.filter { !$0.isEmpty }
        let hit = lines.first { NLQuery.fold($0).contains(q) } ?? lines.dropFirst().first
        return hit.map { String($0.prefix(80)) }
    }
}

private struct NotesAddedPeek: View {
    let text: String
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.done)
            Text(verbatim: L10n.tr("Added to %@", L10n.tr("Quick notes"))).font(Theme.font(.m, .semibold)).foregroundStyle(Theme.primary)
            Text(verbatim: text).font(Theme.font(.m)).foregroundStyle(Theme.secondary)
                .lineLimit(1).frame(maxWidth: 200, alignment: .leading).fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 12)
    }
}

/// Made-up notes for the renderer.
@MainActor
enum NotesSample {
    static func fill(_ model: NotesModel) {
        let now = Date.now
        let notes = [
            Note(id: "sample-1", text: """
            Groceries
            - [x] Coffee beans
            - [ ] Oat milk
            - [ ] Lemons
            - [ ] Basil for the pesto
            """, modified: now.addingTimeInterval(-600)),
            Note(id: "sample-2", text: """
            Release checklist
            - [x] Tag v0.2.0
            - [ ] Update the tap formula
            - [ ] Post the changelog
            """, modified: now.addingTimeInterval(-3 * 3600)),
            Note(id: "sample-3", text: "Ideas\nA notch timer that knows when the kettle boils\nShelf: drop to convert HEIC → JPEG",
                 modified: now.addingTimeInterval(-26 * 3600)),
        ]
        model.notes = notes
        model.loaded = true
        model.settings.pinnedID = "sample-1"
        model.selectedID = "sample-1"
    }
}
