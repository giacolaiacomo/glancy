import AppKit
import Observation

/// The history and everything the tab does with it. Capture triggers (event tap, app switch,
/// panel open) live in `ClipboardModule`; they all end in `check(source:)`.
@MainActor @Observable
public final class ClipboardModel {
    public internal(set) var items: [ClipItem] = []
    public internal(set) var loaded = false
    /// The search text. Changing it resets the keyboard selection.
    public var query = "" { didSet { if query != oldValue { selection = 0 } } }
    /// Index into `shown`.
    public internal(set) var selection = 0
    /// The row under the pointer: the preview follows it, else the selection.
    public var hovered: UUID?
    /// The Clipboard tab is on screen.
    public internal(set) var visible = false
    /// ⌘C / ⌘X are seen (listen-only event tap installed). False = app switch / panel open only.
    public internal(set) var copyKeysSeen = false
    /// "Clear all" asked, waiting for the confirmation.
    public var confirmingClear = false
    /// Re-stamped when the tab appears; relative times are computed against it (no ticking).
    public internal(set) var now = Date.now

    /// The lead connects this to the surface's key-focus flag: the tab wants typing while shown.
    public var wantsKeyFocus: Bool { visible }

    public let settings: ClipboardSettings
    @ObservationIgnored let disk: ClipboardDisk
    @ObservationIgnored let pasteboard: NSPasteboard
    @ObservationIgnored let thumbs = ClipThumbs()
    /// The pasteboard generation last looked at.
    @ObservationIgnored var lastChangeCount: Int
    /// Bumped by Clear all: an ingest started before it is thrown away.
    @ObservationIgnored private var epoch = 0
    /// Orders saves and wipes on the disk actor.
    @ObservationIgnored private var diskVersion = 0
    /// Called after an item went back to the pasteboard (the module closes the panel / pastes).
    @ObservationIgnored var onChosen: ((ClipItem) -> Void)?
    @ObservationIgnored private var keyMonitor: Any?

    public init(disk: ClipboardDisk, settings: ClipboardSettings, pasteboard: NSPasteboard = .general) {
        self.disk = disk
        self.settings = settings
        self.pasteboard = pasteboard
        self.lastChangeCount = pasteboard.changeCount
    }

    // MARK: Derived

    public var filtered: [ClipItem] { ClipboardHistory.filter(items, query: query) }

    /// The rows in drawing order: pinned, then recent.
    public var shown: [ClipItem] {
        let s = ClipboardHistory.sections(filtered)
        return s.pinned + s.recent
    }

    var selectedItem: ClipItem? {
        let rows = shown
        return rows.indices.contains(selection) ? rows[selection] : nil
    }

    var previewItem: ClipItem? {
        if let hovered, let item = items.first(where: { $0.id == hovered }) { return item }
        return selectedItem
    }

    // MARK: Loading

    func load() async {
        let stored = await disk.load()
        // Anything captured before the load finished stays on top.
        var merged = stored
        for item in items.reversed() { merged = ClipboardHistory.insert(item, into: merged).list }
        items = ClipboardHistory.trim(merged).list
        loaded = true
        let keep = items
        Task.detached { [disk] in await disk.sweep(keeping: keep) }
    }

    // MARK: Capture

    /// Looks at the pasteboard if it changed since the last look; keeps what is allowed.
    /// `source` is the app the copy came from (best guess of the trigger).
    public func check(source: NSRunningApplication?) {
        let cc = pasteboard.changeCount
        guard cc != lastChangeCount else { return }
        lastChangeCount = cc
        let snapshot = PasteboardSnapshot.read(pasteboard)
        let bundle = source?.bundleIdentifier
        let draft: ClipDraft
        switch ClipboardClassifier.classify(snapshot, source: bundle, excluded: settings.excludedIDs, paused: settings.paused) {
        case .failure: return
        case .success(let d): draft = d
        }
        let name = source?.localizedName
        // Same content again: just move it up (no blob work).
        if let existing = items.first(where: { $0.signature == draft.signature }) {
            items = ClipboardHistory.touch(existing.id, in: items)
            if let i = items.firstIndex(where: { $0.id == existing.id }), bundle != nil {
                items[i].sourceBundleID = bundle
                items[i].sourceName = name
            }
            save()
            return
        }
        let started = epoch
        Task { [disk] in
            guard let item = await disk.ingest(draft, source: bundle, sourceName: name) else { return }
            guard started == self.epoch else { await disk.remove(blobsOf: [item]); return }
            self.add(item)
        }
    }

    /// Inserts a ready item (de-dup, limit) and persists.
    func add(_ item: ClipItem) {
        let result = ClipboardHistory.insert(item, into: items)
        items = result.list
        clampSelection()
        drop(result.dropped)
        save()
    }

    // MARK: Actions

    /// Puts the item back on the pasteboard (marked as ours) and moves it to the top.
    public func choose(_ item: ClipItem) {
        lastChangeCount = ClipboardWriter.write(item, blobs: disk.blobs, to: pasteboard)
        items = ClipboardHistory.touch(item.id, in: items)
        selection = 0
        save()
        onChosen?(item)
    }

    public func chooseSelected() {
        if let item = selectedItem { choose(item) }
    }

    public func togglePin(_ item: ClipItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].pinned.toggle()
        let result = ClipboardHistory.trim(items)
        items = result.list
        drop(result.dropped)
        save()
    }

    public func delete(_ item: ClipItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        let gone = items.remove(at: i)
        if hovered == gone.id { hovered = nil }
        clampSelection()
        drop([gone])
        save()
    }

    public func clearAll() {
        epoch += 1
        items = []
        selection = 0
        hovered = nil
        confirmingClear = false
        thumbs.clear()
        diskVersion += 1
        let v = diskVersion
        Task { [disk] in await disk.wipe(version: v) }
    }

    /// Never record from this app again; its items go too.
    public func exclude(bundleID: String, name: String) {
        settings.excluded[bundleID] = name
        let gone = items.filter { $0.sourceBundleID == bundleID }
        items.removeAll { $0.sourceBundleID == bundleID }
        clampSelection()
        drop(gone)
        save()
    }

    public func include(bundleID: String) { settings.excluded[bundleID] = nil }

    func moveSelection(_ delta: Int) {
        let count = shown.count
        guard count > 0 else { return }
        selection = min(max(0, selection + delta), count - 1)
        hovered = nil
    }

    private func clampSelection() {
        selection = min(selection, max(0, shown.count - 1))
    }

    private func drop(_ gone: [ClipItem]) {
        guard !gone.isEmpty else { return }
        for item in gone { thumbs.forget(item) }
        Task { [disk] in await disk.remove(blobsOf: gone) }
    }

    private func save() {
        let snapshot = items
        diskVersion += 1
        let v = diskVersion
        Task { [disk] in await disk.scheduleSave(snapshot, version: v) }
    }

    // MARK: Visibility & keyboard

    /// The tab appeared / went away. Thumbnails and the key monitor exist only while shown.
    func setVisible(_ on: Bool) {
        guard on != visible else { return }
        visible = on
        SurfaceKeyFocus.request(on)   // search field + ↑↓⏎ need the panel to be key
        if on {
            now = .now
            installKeyMonitor()
        } else {
            removeKeyMonitor()
            thumbs.clear()
            query = ""
            selection = 0
            hovered = nil
            confirmingClear = false
        }
    }

    /// Local monitor: sees keys only while the panel is key. ↑↓ move, ⏎ copies, ⌘⌫ deletes,
    /// ⌘P pins; typing goes to the search field, or into the query when the field has no focus.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let used = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return used ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// True when the key was used.
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        switch event.keyCode {
        case 125: moveSelection(1); return true                       // ↓
        case 126: moveSelection(-1); return true                      // ↑
        case 36, 76: chooseSelected(); return true                    // ⏎ / ⌤
        case 51 where flags == .command && (query.isEmpty || !(event.window?.firstResponder is NSText)):   // ⌘⌫
            if let item = selectedItem { delete(item) }
            return true
        default: break
        }
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "p" {
            if let item = selectedItem { togglePin(item) }
            return true
        }
        // The field is typing for itself.
        if event.window?.firstResponder is NSText { return false }
        guard flags.isEmpty else { return false }
        if event.keyCode == 51 {
            if !query.isEmpty { query.removeLast() }
            return true
        }
        guard let chars = event.characters, !chars.isEmpty,
              chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 })
        else { return false }
        query += chars
        return true
    }
}

/// Image thumbnails and app icons, alive only while the tab is on screen.
@MainActor @Observable
final class ClipThumbs {
    private(set) var images: [String: NSImage] = [:]
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    @ObservationIgnored private var loading: Set<String> = []

    /// Starts loading a thumbnail (`pixels` on the longest side) for an image item.
    func load(_ item: ClipItem, blobs: URL, pixels: Int) async {
        guard let name = item.imageBlob else { return }
        let key = "\(pixels):\(name)"
        guard images[key] == nil, loading.insert(key).inserted else { return }
        let url = blobs.appendingPathComponent(name)
        let box = await Task.detached(priority: .userInitiated) {
            ImageBox(ClipImage.thumbnail(url: url, maxPixels: pixels))
        }.value
        loading.remove(key)
        guard let cg = box.image else { return }
        images[key] = NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
    }

    func image(_ item: ClipItem, pixels: Int) -> NSImage? {
        item.imageBlob.flatMap { images["\(pixels):\($0)"] }
    }

    /// The source app's icon (system-cached; ours only keeps the reference while visible).
    func icon(_ bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let icon = icons[bundleID] { return icon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = icon
        return icon
    }

    func forget(_ item: ClipItem) {
        guard let name = item.imageBlob else { return }
        images = images.filter { !$0.key.hasSuffix(name) }
    }

    func clear() {
        if !images.isEmpty { images = [:] }
        icons = [:]
        loading = []
    }
}

private struct ImageBox: @unchecked Sendable {
    let image: CGImage?
    init(_ image: CGImage?) { self.image = image }
}
