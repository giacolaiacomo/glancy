import Foundation
import Testing
@testable import GlancyKit

private func tempDir(_ name: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("glancy-notes-tests-\(name)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@MainActor private func settings(hotkey: Bool = false) -> NotesSettings {
    let s = NotesSettings(defaults: UserDefaults(suiteName: "ai.glancy.tests.notes.\(UUID().uuidString)")!)
    if !hotkey { s.hotkey = Hotkey(keyCode: 0, modifiers: 0) }   // never grab a real global hotkey in tests
    s.voiceHotkey = Hotkey(keyCode: 0, modifiers: 0)
    return s
}

/// A clock the test moves by hand.
@MainActor private final class Clock {
    var now = Date(timeIntervalSince1970: 1_790_000_000)
    func advance(_ s: TimeInterval) { now = now.addingTimeInterval(s) }
}

private func files(_ dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
}

// MARK: - Store

@Suite struct NotesStoreTests {
    @Test func writeLoadRoundTripKeepsTheDate() async throws {
        let dir = tempDir("store")
        let store = NotesStore(directory: dir)
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        #expect(await store.write(Note(id: "2026-10-05 101010", text: "Groceries\n- [ ] milk", modified: date)))
        #expect(await store.write(Note(id: "older", text: "Old", modified: date.addingTimeInterval(-100))))
        let all = await store.loadAll()
        #expect(all.map(\.id) == ["2026-10-05 101010", "older"])
        #expect(all[0].text == "Groceries\n- [ ] milk")
        #expect(abs(all[0].modified.timeIntervalSince(date)) < 1)
        #expect(files(dir) == ["2026-10-05 101010.md", "older.md"])
        let perms = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("older.md").path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test func atomicOverwriteLeavesNoTempAndSweepsCrashLeftovers() async throws {
        let dir = tempDir("atomic")
        let store = NotesStore(directory: dir)
        let id = "n"
        await store.write(Note(id: id, text: "first version, quite long", modified: .now))
        let inode1 = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("n.md").path)[.systemFileNumber] as? Int
        await store.write(Note(id: id, text: "second", modified: .now))
        let inode2 = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("n.md").path)[.systemFileNumber] as? Int
        // Replaced by rename (a new inode), never rewritten in place.
        #expect(inode1 != inode2)
        #expect(files(dir) == ["n.md"])
        #expect(try String(contentsOf: dir.appendingPathComponent("n.md"), encoding: .utf8) == "second")
        // A crash between the temp write and the rename: the old text survives, the temp is swept.
        try Data("half-writ".utf8).write(to: dir.appendingPathComponent(".n.ABCD1234.tmp"))
        let all = await store.loadAll()
        #expect(all.count == 1 && all[0].text == "second")
        #expect(files(dir) == ["n.md"])
    }

    @Test func deleteRemovesTheFile() async {
        let dir = tempDir("delete")
        let store = NotesStore(directory: dir)
        await store.write(Note(id: "x", text: "bye", modified: .now))
        await store.delete("x")
        #expect(files(dir).isEmpty)
        #expect(await store.loadAll().isEmpty)
    }
}

// MARK: - Model

@MainActor
@Suite struct NotesModelTests {
    func settle(_ ms: Int = 80) async { try? await Task.sleep(for: .milliseconds(ms)) }
    /// Waits (up to 10 s: busy machines) until the store has seen `n` writes.
    func settleWrites(_ store: NotesStore, _ n: Int) async {
        for _ in 0..<1000 { if await store.writes >= n { break }; try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func createEditDebouncesToOneWrite() async throws {
        let dir = tempDir("debounce")
        let store = NotesStore(directory: dir)
        let model = NotesModel(store: store, settings: settings(), debounce: .milliseconds(60))
        await model.load()
        let note = model.create()
        #expect(model.selectedID == note.id)
        await settle()
        #expect(await store.writes == 0)            // blank: never written
        for i in 1...6 { model.edit(note.id, text: "Plan\nstep \(i)") }
        #expect(await store.writes == 0)            // still typing
        await settleWrites(store, 1)
        #expect(await store.writes == 1)
        #expect(try String(contentsOf: dir.appendingPathComponent("\(note.id).md"), encoding: .utf8) == "Plan\nstep 6")
        // A later pause writes again.
        model.edit(note.id, text: "Plan\nstep 7")
        await settleWrites(store, 2)
        #expect(await store.writes == 2)
    }

    @Test func flushWritesPendingAtOnce() async throws {
        let dir = tempDir("flush")
        let store = NotesStore(directory: dir)
        let model = NotesModel(store: store, settings: settings(), debounce: .seconds(30))
        let n = model.create()
        model.edit(n.id, text: "Urgent")
        await model.flush()
        #expect(await store.writes == 1)
        #expect(files(dir) == ["\(n.id).md"])
        // Quitting: written synchronously, before the run loop turns again.
        model.edit(n.id, text: "Urgent, edited at quit")
        model.flushNow()
        #expect(try String(contentsOf: dir.appendingPathComponent("\(n.id).md"), encoding: .utf8) == "Urgent, edited at quit")
        #expect(files(dir) == ["\(n.id).md"])
    }

    @Test func blankNoteIsDroppedWhenLeftAndDeleteRemovesFile() async {
        let dir = tempDir("blank")
        let store = NotesStore(directory: dir)
        let s = settings()
        let model = NotesModel(store: store, settings: s, debounce: .milliseconds(10))
        let a = model.create(text: "Keep me")
        await settle()
        let b = model.create()
        #expect(model.notes.count == 2)
        model.select(a.id)                           // leaving the blank one
        #expect(model.notes.map(\.id) == [a.id])
        #expect(!model.notes.contains { $0.id == b.id })
        s.pinnedID = a.id
        model.delete(a.id)
        await settle()
        #expect(model.notes.isEmpty)
        #expect(s.pinnedID == nil)
        #expect(files(dir).isEmpty)
    }

    @Test func searchIsCaseAndAccentBlindTitleFirst() {
        let model = NotesModel(store: NotesStore(directory: tempDir("search")), settings: settings())
        let clock = Date(timeIntervalSince1970: 1_780_000_000)
        model.notes = [
            Note(id: "1", text: "Spesa\n- [ ] caffè\n- [ ] latte", modified: clock),
            Note(id: "2", text: "Caffè\nprovare il nuovo", modified: clock.addingTimeInterval(-50)),
            Note(id: "3", text: "Altro", modified: clock.addingTimeInterval(10)),
        ]
        #expect(model.search("CAFFE").map(\.id) == ["2", "1"])
        #expect(model.search("caffè latte").map(\.id) == ["1"])
        #expect(model.search("zzz").isEmpty)
        model.query = "spesa"
        #expect(model.listed.map(\.id) == ["1"])
        model.query = ""
        #expect(model.listed.map(\.id) == ["3", "1", "2"])
    }

    @Test func titlesAndPreviewsDropMarkdown() {
        let n = Note(id: "x", text: "\n## Plan\n- [x] done thing\n* bullet\nplain", modified: .now)
        #expect(n.title == "Plan")
        #expect(n.bodyLines == ["done thing", "bullet", "plain"])
        #expect(Note(id: "y", text: "  \n ", modified: .now).title == nil)
        #expect(Note.newID(at: Date(timeIntervalSince1970: 0), taken: []).count == 17)
        let id = Note.newID(at: .now, taken: [])
        #expect(Note.newID(at: .now, taken: [id]) == id + "-2")
    }

    @Test func inboxAppendCreatesThenAppends() async {
        let dir = tempDir("inbox")
        let store = NotesStore(directory: dir)
        let s = settings()
        let model = NotesModel(store: store, settings: s)
        model.appendToInbox("buy milk", title: "Quick notes")
        let id = s.inboxID
        #expect(id != nil)
        model.appendToInbox("  call Anna ", title: "Quick notes")
        await settle()
        #expect(model.notes.first { $0.id == id }?.text == "Quick notes\nbuy milk\ncall Anna")
        #expect(model.notes.count == 1)
        // Written straight away (the panel closes right after).
        #expect(files(dir) == ["\(id!).md"])
    }
}

// MARK: - Checklist

@Suite struct ChecklistTests {
    @Test func markersFindEveryKindOfBox() {
        let text = "Title\n- [ ] milk\n  * [x] eggs\n+ [X] Bread\n-[ ] not a box\n- [ ]tight\n- [ ]"
        let m = Checklist.markers(in: text)
        #expect(m.count == 4)
        #expect(m.map(\.checked) == [false, true, true, false])
        let ns = text as NSString
        #expect(ns.substring(with: m[0].prefix) == "- [ ]")
        #expect(ns.substring(with: m[0].box) == "[ ]")
        #expect(ns.substring(with: m[1].line) == "  * [x] eggs")
    }

    @Test func toggleOnlyOnTheMarker() throws {
        let text = "Shop\n- [ ] milk 🥛\n- [x] eggs"
        let ns = text as NSString
        let box = ns.range(of: "[ ]").location
        let on = try #require(Checklist.toggle(text, at: box + 1))
        #expect(on.text == "Shop\n- [x] milk 🥛\n- [x] eggs")
        // Clicking the dash counts; clicking the words does not.
        #expect(Checklist.toggle(text, at: box - 2)?.text == on.text)
        #expect(Checklist.toggle(text, at: ns.range(of: "milk").location) == nil)
        let off = try #require(Checklist.toggle(on.text, at: (on.text as NSString).range(of: "[x] eggs").location))
        #expect(off.text == "Shop\n- [x] milk 🥛\n- [ ] eggs")
        #expect(off.replacement == "[ ]")
    }

    @MainActor @Test func modelToggleEditsAndSaves() async throws {
        let dir = tempDir("toggle")
        let store = NotesStore(directory: dir)
        let model = NotesModel(store: store, settings: settings(), debounce: .milliseconds(10))
        let n = model.create(text: "List\n- [ ] one")
        model.toggleCheck(n.id, at: ("List\n- [ ] one" as NSString).range(of: "[").location)
        #expect(model.selected?.text == "List\n- [x] one")
        try? await Task.sleep(for: .milliseconds(80))
        #expect(try String(contentsOf: dir.appendingPathComponent("\(n.id).md"), encoding: .utf8) == "List\n- [x] one")
    }

    @Test func returnContinuesOrEndsLists() {
        #expect(Checklist.continuation(in: "a\n- [x] milk", caret: 12) == .insert("\n- [ ] "))
        #expect(Checklist.continuation(in: "  * [ ] milk", caret: 12) == .insert("\n  * [ ] "))
        #expect(Checklist.continuation(in: "x\n- [ ] ", caret: 8) == .endList(NSRange(location: 2, length: 6)))
        #expect(Checklist.continuation(in: "- item", caret: 6) == .insert("\n- "))
        #expect(Checklist.continuation(in: "- ", caret: 2) == .endList(NSRange(location: 0, length: 2)))
        #expect(Checklist.continuation(in: "plain", caret: 5) == nil)
    }
}

// MARK: - Module: quick note, focus, command bar

@MainActor
@Suite(.serialized) struct NotesModuleTests {
    @Test func defaultHotkeyIsCtrlOptN() {
        #expect(NotesSettings.defaultHotkey.description == "⌃⌥N")
        let s = NotesSettings(defaults: UserDefaults(suiteName: "ai.glancy.tests.notes.\(UUID().uuidString)")!)
        #expect(s.hotkey == NotesSettings.defaultHotkey)
    }

    @Test func quickNoteReusesRecentElseCreatesAndOpensTheTabWithFocus() async {
        let clock = Clock()
        let module = NotesModule(store: NotesStore(directory: tempDir("quick")), settings: settings(),
                                 debounce: .milliseconds(10), now: { clock.now })
        let hub = ActivityHub()
        var opened: [ModuleID?] = []
        hub.onOpenRequest = { opened.append($0) }
        module.start(hub: hub)
        await loaded(module)   // the (empty) load

        // Nothing yet: a new note, the tab opens.
        module.quickNote()
        #expect(opened == [.notes])
        #expect(module.model.notes.count == 1)
        let first = module.model.selectedID
        module.model.edit(first!, text: "Call back")
        let token = module.model.focusToken

        // Within 15 minutes: the same note, the editor focused again.
        clock.advance(10 * 60)
        module.quickNote()
        #expect(module.model.selectedID == first)
        #expect(module.model.focusToken != token)
        #expect(module.model.notes.count == 1)

        // Later: a new one.
        clock.advance(20 * 60)
        module.quickNote()
        #expect(module.model.notes.count == 2)
        #expect(module.model.selectedID != first)

        // The tab on screen takes the keyboard; collapsing gives it back and drops the blank note.
        var focus: [Bool] = []
        let saved = SurfaceKeyFocus.handler
        SurfaceKeyFocus.handler = { focus.append($0) }
        module.visibilityChanged(.expanded(.notes))
        module.visibilityChanged(.collapsed)
        SurfaceKeyFocus.handler = saved
        #expect(focus.first == true)
        #expect(focus.last == false)
        #expect(module.model.notes.count == 1)
        module.stop()
    }

    @Test func appendResultsInEnglishAndItalian() async {
        let module = NotesModule(store: NotesStore(directory: tempDir("cmd")), settings: settings(), debounce: .milliseconds(10))
        let hub = ActivityHub()
        module.start(hub: hub)
        await loaded(module)
        L10n.apply(.en)   // another suite may have switched the language
        #expect(NotesModule.appendText("note buy milk") == "buy milk")
        #expect(NotesModule.appendText("Nota comprare latte") == "comprare latte")
        #expect(NotesModule.appendText("note:  call Anna") == "call Anna")
        #expect(NotesModule.appendText("note ") == nil)
        #expect(NotesModule.appendText("notebook") == nil)

        let r = module.results(for: "note buy milk")
        #expect(r.count == 1 && r[0].id == "notes.append" && r[0].rank == 95)
        r[0].run()
        let r2 = module.results(for: "nota comprare latte")
        r2[0].run()
        let inbox = module.model.notes.first { $0.id == module.model.settings.inboxID }
        #expect(inbox?.text == "Quick notes\nbuy milk\ncomprare latte")
        #expect(hub.peek?.module == .notes)

        // Search: title and body, opens the note.
        module.model.create(text: "Groceries\n- [ ] oat milk")
        var opened: [ModuleID?] = []
        hub.onOpenRequest = { opened.append($0) }
        let hits = module.results(for: "groc")
        #expect(hits.map(\.title) == ["Groceries"])
        #expect(hits[0].rank == 70)
        let body = module.results(for: "milk")
        #expect(body.count == 2)
        #expect(body.allSatisfy { $0.rank == 55 })
        hits[0].run()
        #expect(opened == [.notes])
        #expect(module.model.selected?.title == "Groceries")
        #expect(module.results(for: "m").isEmpty)
        module.stop()
    }

    @Test func fixedCommandsAndItalianTitles() {
        let module = NotesModule(store: NotesStore(directory: tempDir("cmds")), settings: settings())
        let hub = ActivityHub()
        module.start(hub: hub)
        L10n.apply(.it)
        #expect(module.commands().map(\.title) == ["Nuova nota", "Apri le note", "Registra nota vocale"])
        #expect(module.results(for: "nota latte").first?.title == "Aggiungi a Note rapide: latte")
        L10n.apply(.en)
        #expect(module.commands().map(\.id) == ["notes.new", "notes.open", "notes.voice.record"])
        #expect(module.commands().first?.keywords.contains("nuova nota") == true)
        module.stop()
    }

    @Test func homeCardOnlyForAPinnedNote() {
        let module = NotesModule(store: NotesStore(directory: tempDir("home")), settings: settings())
        module.start(hub: ActivityHub())
        #expect(module.homeCard() == nil)
        let n = module.model.create(text: "Pinned\n- [ ] a\n- [x] b")
        module.model.togglePin(n.id)
        #expect(module.homeCard() != nil)
        let lines = NotesFormat.previewLines(n.text, max: 3)
        #expect(lines.map(\.text) == ["a", "b"])
        #expect(lines.map(\.checked) == [false, true])
        #expect(lines[0].box == ("Pinned\n- [ ] a" as NSString).range(of: "[ ]").location)
        module.stop()
    }

    @Test func notesHTMLIsEscaped() {
        #expect(NotesModule.notesHTML("A <b> & \"c\"\n\nend") == "<div>A &lt;b&gt; &amp; \"c\"</div><div><br></div><div>end</div>")
        #expect(NotesModule.appleScriptEscape(#"say "hi" \ bye"#) == #"say \"hi\" \\ bye"#)
    }
}

// MARK: - Media in the command bar

@MainActor
@Suite(.serialized) struct MediaCommandTests {
    func playingModule(playing: Bool = true) throws -> MediaModule {
        let dir = tempDir("media")
        let payload: [String: Any] = ["bundleIdentifier": "com.apple.Music", "title": "Golden Hour Drive", "artist": "Paper Lanterns",
                                      "playing": playing, "durationMicros": 236_000_000, "elapsedTimeMicros": 1_000_000,
                                      "timestampEpochMicros": Int(Date.now.timeIntervalSince1970 * 1_000_000)]
        let url = dir.appendingPathComponent("np.json")
        try JSONSerialization.data(withJSONObject: payload).write(to: url)
        let m = MediaModule(stream: AdapterStream(pidFile: dir.appendingPathComponent("pid")), locate: { nil })
        m.fixturePath = url.path
        m.start(hub: ActivityHub())
        return m
    }

    @Test func nothingPlayingNothingOffered() {
        let dir = tempDir("media-none")
        let m = MediaModule(stream: AdapterStream(pidFile: dir.appendingPathComponent("pid")), locate: { nil })
        let url = dir.appendingPathComponent("np.json")
        try? Data("null".utf8).write(to: url)
        m.fixturePath = url.path
        m.start(hub: ActivityHub())
        #expect(m.commands().isEmpty)
        #expect(m.results(for: "play").isEmpty)
        m.stop()
    }

    @Test func verbsInEnglishAndItalian() throws {
        L10n.apply(.en)
        let m = try playingModule()
        // Never run here: the bar would control the user's real player.
        #expect(m.results(for: "play").map(\.id) == ["media.toggle"])
        #expect(m.results(for: "pausa").map(\.id) == ["media.toggle"])
        #expect(m.results(for: "Pàusa ").first?.rank == 90)
        #expect(m.results(for: "next").map(\.id) == ["media.next"])
        #expect(m.results(for: "avanti").map(\.id) == ["media.next"])
        #expect(m.results(for: "indietro").map(\.id) == ["media.previous"])
        #expect(m.results(for: "testo").map(\.id) == ["media.lyrics"])
        #expect(m.results(for: "lyr").first?.rank == 60)
        #expect(m.results(for: "pa").isEmpty)
        #expect(m.results(for: "weather").isEmpty)
        #expect(m.commands().map(\.id) == ["media.toggle", "media.next", "media.previous", "media.lyrics"])
        #expect(m.commands()[0].title == "Pause")
        #expect(m.commands()[0].subtitle == "Golden Hour Drive · Paper Lanterns")
        L10n.apply(.it)
        #expect(m.commands().map(\.title) == ["Pausa", "Brano successivo", "Brano precedente", "Mostra il testo"])
        L10n.apply(.en)
        m.stop()
    }

    @Test func showLyricsOpensTheMediaTab() throws {
        let m = try playingModule(playing: false)
        let hub = ActivityHub()
        m.stop(); m.start(hub: hub)
        var opened: [ModuleID?] = []
        hub.onOpenRequest = { opened.append($0) }
        m.lyrics.settings.shown = false
        L10n.apply(.en)
        #expect(m.commands()[0].title == "Play")
        m.results(for: "lyrics").first?.run()
        #expect(opened == [.media])
        #expect(m.lyrics.settings.shown)
        m.stop()
    }
}

/// Waits for the module's launch load (slow CI machines need far more than a fixed few ms).
@MainActor private func loaded(_ module: NotesModule, timeout: Double = 10) async {
    let end = Date.now.addingTimeInterval(timeout)
    while !module.model.loaded, Date.now < end { try? await Task.sleep(for: .milliseconds(5)) }
}
